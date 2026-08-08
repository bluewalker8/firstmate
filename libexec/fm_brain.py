#!/usr/bin/env python3
"""Brainkeeper-owned extraction, validation, compilation, and rollback.

Every maintenance command is role-gated and is intended to be called through
fm-brainkeeper.sh.  Foreground hooks use the separate fm_capture.py runtime.
Only the Python standard library is used.
"""

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Sequence, Tuple


EXTRACTOR_VERSION = "brainkeeper-rules-v1"
MAX_BATCH_EVENTS = 10000
MAX_REVIEW_BYTES = 65536
MAX_HOT_TOKENS = 1500
MAX_DECISION_CONTEXT_TOKENS = 3000
MAX_COMPILE_EDITS = 20
ALLOWED_TYPES = {"correction", "decision", "standard", "priority", "failure_lesson"}
ALLOWED_SCOPES = {"global", "project", "client"}
PRIVATE_DIR_MODE = 0o700
PRIVATE_FILE_MODE = 0o600

SECRET_PATTERNS = [
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}\b"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{12,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{12,}\b", re.IGNORECASE),
    re.compile(
        r"\b(?:password|passwd|secret|api[_ -]?key|access[_ -]?token)\s*[:=]\s*[^\s,;]{4,}",
        re.IGNORECASE,
    ),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]

FORBIDDEN_ACTIVE_PATTERNS = [
    re.compile(r"ignore (?:all )?(?:previous|system) instructions", re.IGNORECASE),
    re.compile(r"reveal (?:a |the )?(?:secret|token|password)", re.IGNORECASE),
    re.compile(r"merge (?:without|before) (?:approval|authorization)", re.IGNORECASE),
    re.compile(r"(?:delete|erase) (?:all|every) (?:event|claim|memory|file)", re.IGNORECASE),
]


def utc_now() -> str:
    forced = os.environ.get("FM_BRAIN_NOW")
    if forced:
        return normalize_time(forced)
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def normalize_time(value: str) -> str:
    value = value.strip()
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(normalize_time(value).replace("Z", "+00:00"))


def sha256_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def stable_id(prefix: str, *parts: str, size: int = 32) -> str:
    material = "\0".join(parts).encode("utf-8")
    return prefix + hashlib.sha256(material).hexdigest()[:size]


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def pretty_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def ensure_private_dir(path: Path) -> Path:
    path.mkdir(mode=PRIVATE_DIR_MODE, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError("private path is not a real directory: %s" % path)
    os.chmod(str(path), PRIVATE_DIR_MODE)
    return path


def fsync_dir(path: Path) -> None:
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_temp(path: Path, data: bytes) -> Path:
    ensure_private_dir(path.parent)
    fd, raw = tempfile.mkstemp(prefix=".partial-", dir=str(path.parent))
    tmp = Path(raw)
    try:
        os.fchmod(fd, PRIVATE_FILE_MODE)
        with os.fdopen(fd, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    return tmp


def write_once(path: Path, data: bytes, failpoint: Optional[str] = None) -> bool:
    """Create path once after a fully fsynced same-directory temporary file."""
    if path.exists():
        if path.read_bytes() != data:
            raise RuntimeError("immutable record collision: %s" % path)
        return False
    tmp = write_temp(path, data)
    if failpoint and os.environ.get("FM_BRAIN_FAILPOINT") == failpoint:
        os._exit(87)
    try:
        try:
            os.link(str(tmp), str(path))
            os.chmod(str(path), PRIVATE_FILE_MODE)
            fsync_dir(path.parent)
            return True
        except FileExistsError:
            if path.read_bytes() != data:
                raise RuntimeError("immutable record collision: %s" % path)
            return False
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def replace_if_changed(path: Path, data: bytes) -> bool:
    if path.exists() and path.read_bytes() == data:
        return False
    tmp = write_temp(path, data)
    try:
        os.replace(str(tmp), str(path))
        os.chmod(str(path), PRIVATE_FILE_MODE)
        fsync_dir(path.parent)
        return True
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def read_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise RuntimeError("expected JSON object: %s" % path)
    return value


def redact_secrets(text: str) -> str:
    redacted = text
    for pattern in SECRET_PATTERNS:
        redacted = pattern.sub("[REDACTED_SECRET]", redacted)
    return redacted


def brain_home(args: argparse.Namespace) -> Path:
    explicit = getattr(args, "home", None) or os.environ.get("FM_BRAIN_HOME")
    if explicit:
        return ensure_private_dir(Path(explicit).expanduser().resolve())
    fm_home = os.environ.get("FM_HOME")
    if not fm_home:
        fm_home = str(Path(__file__).resolve().parent.parent)
    return ensure_private_dir(Path(fm_home).expanduser().resolve() / "data" / "brain")


def event_dirs(home: Path) -> Dict[str, Path]:
    root = ensure_private_dir(home / "events")
    return {
        "root": root,
        "pending": ensure_private_dir(root / "pending"),
        "inbox": ensure_private_dir(root / "inbox"),
        "delivery_errors": ensure_private_dir(root / "delivery-errors"),
        "processed": ensure_private_dir(root / "processed"),
    }


def require_brainkeeper() -> None:
    if os.environ.get("FM_BRAINKEEPER_ROLE") != "1":
        raise RuntimeError("memory maintenance is restricted to the Brainkeeper entry point")


def resolve_vault(args: argparse.Namespace) -> Path:
    raw = getattr(args, "vault", None) or os.environ.get("FM_BRAIN_VAULT")
    if not raw:
        raise RuntimeError("Brainkeeper requires --vault or FM_BRAIN_VAULT")
    vault = Path(raw).expanduser().resolve()
    if not vault.is_dir() or vault == Path(vault.anchor):
        raise RuntimeError("vault must be an existing bounded directory")
    return vault


def keeper_dirs(home: Path, vault: Path) -> Dict[str, Path]:
    private = ensure_private_dir(home / "brainkeeper")
    brain = ensure_private_dir(vault / "firstmate-brain")
    ledger = ensure_private_dir(brain / "ledger")
    generated = ensure_private_dir(brain / "generated")
    return {
        "private": private,
        "candidates": ensure_private_dir(private / "candidates"),
        "alerts": ensure_private_dir(private / "reported-alerts"),
        "failures": ensure_private_dir(private / "failures"),
        "batch_failures": ensure_private_dir(private / "batch-failures"),
        "completed_batches": ensure_private_dir(private / "completed-batches"),
        "brain": brain,
        "ledger": ledger,
        "claims": ensure_private_dir(ledger / "claims"),
        "conflicts": ensure_private_dir(ledger / "conflicts"),
        "batches": ensure_private_dir(ledger / "batches"),
        "reviews": ensure_private_dir(brain / "reviews"),
        "schema": ensure_private_dir(brain / "schema"),
        "generated": generated,
        "topics": ensure_private_dir(generated / "topics"),
        "hot": ensure_private_dir(generated / "hot"),
        "archive": ensure_private_dir(brain / "derived-archive"),
    }


class KeeperLock:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.handle: Optional[Any] = None

    def __enter__(self) -> "KeeperLock":
        ensure_private_dir(self.path.parent)
        self.handle = self.path.open("a+", encoding="utf-8")
        os.chmod(str(self.path), PRIVATE_FILE_MODE)
        fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self.handle:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()


def slug(value: str) -> str:
    clean = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not clean:
        clean = "topic"
    return clean[:64] + "-" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]


def normalize_value(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def claim_subject(kind: str, value: str) -> Tuple[str, str]:
    match = re.match(r"\s*([^:=]{2,80})\s*[:=]\s*(.+)\s*$", value)
    if match:
        return slug(match.group(1)), match.group(2).strip()
    if kind in {"standard", "correction"}:
        method = re.match(r"(.+?)\s+for\s+(.+)$", value, re.IGNORECASE)
        if method:
            return "method-for-" + slug(method.group(2)), method.group(1).strip()
        return "default-method", value.strip()
    return kind + "-" + hashlib.sha256(normalize_value(value).encode("utf-8")).hexdigest()[:12], value.strip()


def line_is_external(line: str) -> bool:
    stripped = line.lstrip()
    if stripped.startswith(">") or line.startswith("    ") or line.startswith("\t"):
        return True
    return bool(re.search(r"\b(?:webpage|website|article|quoted instructions?|tool output|external source)\b", line, re.IGNORECASE))


def extract_line(line: str) -> Optional[Dict[str, Any]]:
    stripped = line.strip()
    if not stripped:
        return None
    quoted = line_is_external(line)
    working = stripped.lstrip("> ")
    patterns: Sequence[Tuple[str, re.Pattern]] = [
        ("failure_lesson", re.compile(r"^failure[ _-]?lesson\s*:\s*(.+)$", re.IGNORECASE)),
        ("priority", re.compile(r"^priority(?:\s+until\s+(\d{4}-\d{2}-\d{2}(?:T[^ ]+)?))?\s*:\s*(.+)$", re.IGNORECASE)),
        ("correction", re.compile(r"^correction\s*:\s*(.+)$", re.IGNORECASE)),
        ("decision", re.compile(r"^decision\s*:\s*(.+)$", re.IGNORECASE)),
        ("standard", re.compile(r"^standard\s*:\s*(.+)$", re.IGNORECASE)),
    ]
    for kind, pattern in patterns:
        match = pattern.match(working)
        if not match:
            continue
        if kind == "priority":
            value = match.group(2).strip()
            until = match.group(1)
            if until and len(until) == 10:
                until += "T23:59:59Z"
            return {"type": kind, "value": value, "valid_until": until, "external": quoted}
        value = match.group(1).strip()
        if kind == "correction":
            correction = re.match(r"stop\s+(.+?),\s*(?:instead\s+)?use\s+(.+)$", value, re.IGNORECASE)
            if correction:
                return {
                    "type": kind,
                    "old_value": correction.group(1).strip(),
                    "value": correction.group(2).strip().rstrip("."),
                    "external": quoted,
                }
        return {"type": kind, "value": value, "external": quoted}
    correction = re.match(r"^stop\s+(.+?),\s*(?:instead\s+)?use\s+(.+)$", working, re.IGNORECASE)
    if correction:
        return {
            "type": "correction",
            "old_value": correction.group(1).strip(),
            "value": correction.group(2).strip().rstrip("."),
            "external": quoted,
        }
    standard = re.match(r"^use\s+(.+)$", working, re.IGNORECASE)
    if standard:
        return {"type": "standard", "value": standard.group(1).strip().rstrip("."), "external": quoted}
    standing = re.match(r"^(?:always|from now on,?)\s+(.+)$", working, re.IGNORECASE)
    if standing:
        return {"type": "standard", "value": standing.group(1).strip().rstrip("."), "external": quoted}
    proposal = re.match(r"^memory proposal\s*:\s*(correction|decision|standard|priority|failure[ _-]?lesson)\s*:\s*(.+)$", working, re.IGNORECASE)
    if proposal:
        kind = proposal.group(1).lower().replace("-", "_").replace(" ", "_")
        return {"type": kind, "value": proposal.group(2).strip(), "external": quoted, "proposal": True}
    return None


def extract_candidates(event: Dict[str, Any]) -> List[Dict[str, Any]]:
    output: List[Dict[str, Any]] = []
    for speaker in event.get("speakers", []):
        if not isinstance(speaker, dict):
            continue
        content = speaker.get("content")
        if not isinstance(content, str):
            continue
        in_fence = False
        for line_number, line in enumerate(content.splitlines(), start=1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            parsed = extract_line(("> " if in_fence else "") + line)
            if not parsed:
                continue
            kind = parsed["type"]
            value = parsed["value"]
            subject, value = claim_subject(kind, value)
            transaction_time = event["completed_at"]
            candidate_id = stable_id("ca_", event["event_id"], str(line_number), speaker.get("role", ""), kind, value)
            external = bool(parsed.get("external"))
            authority = "untrusted_external" if external else ("blue_explicit" if speaker.get("role") == "user" else "firstmate_inference")
            privacy = "secret_redacted" if "[REDACTED_SECRET]" in line else "personal_local"
            output.append({
                "schema_version": "firstmate.candidate.v1",
                "candidate_id": candidate_id,
                "type": kind,
                "subject": subject,
                "value": value,
                "old_value": parsed.get("old_value"),
                "speaker": speaker.get("speaker") or speaker.get("role"),
                "scope": event["scope"],
                "authority": authority,
                "valid_from": transaction_time,
                "valid_until": parsed.get("valid_until"),
                "transaction_time": transaction_time,
                "confidence": 1.0 if authority == "blue_explicit" else 0.5,
                "privacy": privacy,
                "extractor_version": EXTRACTOR_VERSION,
                "source_turn": {"thread_id": event["thread_id"], "turn_id": event["turn_id"]},
                "source_hash": speaker["content_hash"],
                "source_event_id": event["event_id"],
                "evidence": {
                    "pointer": event["source"]["pointer"],
                    "line": line_number,
                    "excerpt": redact_secrets(line.strip())[:512],
                },
                "proposed_supersedes": [],
                "status": "extracted",
                "reason": None,
            })
    return output


def validate_candidate(candidate: Dict[str, Any]) -> Optional[str]:
    required = [
        "candidate_id", "type", "subject", "value", "speaker", "scope", "authority",
        "valid_from", "transaction_time", "confidence", "privacy", "extractor_version",
        "source_turn", "source_hash", "evidence", "proposed_supersedes",
    ]
    if any(key not in candidate for key in required):
        return "schema_missing_field"
    if candidate["type"] not in ALLOWED_TYPES:
        return "schema_invalid_type"
    scope = candidate["scope"]
    if not isinstance(scope, dict) or scope.get("kind") not in ALLOWED_SCOPES or not scope.get("id"):
        return "schema_invalid_scope"
    try:
        parse_time(candidate["valid_from"])
        parse_time(candidate["transaction_time"])
        if candidate.get("valid_until"):
            parse_time(candidate["valid_until"])
    except (ValueError, TypeError):
        return "schema_invalid_time"
    if len(candidate["value"].encode("utf-8")) > 4096:
        return "bounded_value_exceeded"
    return None


def list_records(path: Path, suffix: str = ".json") -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    if not path.is_dir():
        return records
    for item in sorted(path.rglob("*" + suffix)):
        if item.name.startswith(".partial-"):
            continue
        records.append(read_json(item))
    return records


def batch_states(dirs: Dict[str, Path]) -> Dict[str, str]:
    states: Dict[str, str] = {}
    for record in list_records(dirs["batches"]):
        batch_id = record.get("batch_id")
        state = record.get("state")
        if isinstance(batch_id, str) and isinstance(state, str):
            states[batch_id] = state
    return states


def accepted_claims(dirs: Dict[str, Path], include_inactive: bool = False) -> List[Dict[str, Any]]:
    states = batch_states(dirs)
    claims = list_records(dirs["claims"])
    if not include_inactive:
        claims = [claim for claim in claims if states.get(claim.get("batch_id")) == "active"]
    return claims


def currently_active_claims(dirs: Dict[str, Path], as_of: str, include_expired: bool = False) -> List[Dict[str, Any]]:
    claims = accepted_claims(dirs)
    active_batch_ids = {claim["batch_id"] for claim in claims}
    superseded = {
        superseded_id
        for claim in claims
        for superseded_id in claim.get("supersedes", [])
        if claim["batch_id"] in active_batch_ids
    }
    moment = parse_time(as_of)
    output = []
    for claim in claims:
        if claim["claim_id"] in superseded:
            continue
        if parse_time(claim["valid_from"]) > moment:
            continue
        until = claim.get("valid_until")
        if not include_expired and until and parse_time(until) < moment:
            continue
        output.append(claim)
    return output


def unresolved_conflicts(conflicts: List[Dict[str, Any]], claims: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    output = []
    for conflict in conflicts:
        resolved = any(
            claim["scope"] == conflict["scope"]
            and claim["subject"] == conflict["subject"]
            and claim["type"] == "correction"
            and claim["authority"] == "blue_explicit"
            and parse_time(claim["transaction_time"]) >= parse_time(conflict["transaction_time"])
            and claim["claim_id"] not in conflict["claim_ids"]
            for claim in claims
        )
        if not resolved:
            output.append(conflict)
    return output


def promote_candidate(candidate: Dict[str, Any], active: List[Dict[str, Any]]) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    reason = validate_candidate(candidate)
    if reason:
        candidate.update(status="quarantined", reason=reason)
        return candidate, None
    if candidate["privacy"] != "personal_local":
        candidate.update(status="quarantined", reason="privacy_gate")
        return candidate, None
    if candidate["authority"] == "untrusted_external":
        candidate.update(status="quarantined", reason="poisoning_gate")
        return candidate, None
    if candidate["authority"] != "blue_explicit":
        candidate.update(status="proposed", reason="authority_gate")
        return candidate, None
    if candidate["type"] == "failure_lesson":
        candidate.update(status="proposed", reason="promotion_type_gate")
        return candidate, None
    if candidate["type"] == "priority" and not candidate.get("valid_until"):
        candidate.update(status="proposed", reason="validity_gate")
        return candidate, None
    if any(pattern.search(candidate["value"]) for pattern in FORBIDDEN_ACTIVE_PATTERNS):
        candidate.update(status="quarantined", reason="behavioral_safety_gate")
        return candidate, None

    same_scope = [claim for claim in active if claim["scope"] == candidate["scope"]]
    old_value = candidate.get("old_value")
    supersedes: List[str] = []
    if isinstance(old_value, str) and old_value.strip():
        old_normalized = normalize_value(old_value)
        matches = [
            claim for claim in same_scope
            if normalize_value(claim["value"]) == old_normalized
            or old_normalized in normalize_value(claim["value"])
        ]
        supersedes = [claim["claim_id"] for claim in matches]
        if matches:
            candidate["subject"] = matches[-1]["subject"]
    candidate["proposed_supersedes"] = supersedes

    same_subject = [claim for claim in same_scope if claim["subject"] == candidate["subject"]]
    if any(normalize_value(claim["value"]) == normalize_value(candidate["value"]) for claim in same_subject):
        candidate.update(status="rejected", reason="duplicate_active_claim")
        return candidate, None
    unresolved = [claim for claim in same_subject if claim["claim_id"] not in supersedes and claim["authority"] == candidate["authority"]]
    if unresolved:
        candidate["proposed_supersedes"] = [claim["claim_id"] for claim in unresolved]
        candidate.update(status="conflict", reason="equal_authority_conflict")
        return candidate, None

    claim_id = stable_id("cl_", candidate["candidate_id"], candidate["authority"], candidate["scope"]["kind"], candidate["scope"]["id"])
    claim = {
        "schema_version": "firstmate.claim.v1",
        "claim_id": claim_id,
        "candidate_id": candidate["candidate_id"],
        "type": candidate["type"],
        "subject": candidate["subject"],
        "value": candidate["value"],
        "speaker": candidate["speaker"],
        "scope": candidate["scope"],
        "authority": candidate["authority"],
        "valid_from": candidate["valid_from"],
        "valid_until": candidate.get("valid_until"),
        "transaction_time": candidate["transaction_time"],
        "confidence": candidate["confidence"],
        "privacy": candidate["privacy"],
        "extractor_version": candidate["extractor_version"],
        "source_turn": candidate["source_turn"],
        "source_hash": candidate["source_hash"],
        "source_event_id": candidate["source_event_id"],
        "evidence": candidate["evidence"],
        "supersedes": supersedes,
    }
    candidate.update(status="accepted", reason=None)
    return candidate, claim


def scope_key(scope: Dict[str, str]) -> str:
    return scope["kind"] + ":" + scope["id"]


def render_topic(scope: Dict[str, str], subject: str, claims: List[Dict[str, Any]]) -> bytes:
    lines = [
        "---",
        "generated: true",
        "namespace: %s" % scope_key(scope),
        "topic: %s" % subject,
        "---",
        "",
        "# %s" % subject.replace("-", " ").title(),
        "",
    ]
    for claim in sorted(claims, key=lambda item: (item["transaction_time"], item["claim_id"])):
        turn = claim["source_turn"]
        lines.extend([
            "- %s" % claim["value"],
            "  - Claim: `%s`" % claim["claim_id"],
            "  - Authority: `%s`" % claim["authority"],
            "  - Scope: `%s`" % scope_key(claim["scope"]),
            "  - Valid: `%s` to `%s`" % (claim["valid_from"], claim.get("valid_until") or "open"),
            "  - Transaction: `%s`" % claim["transaction_time"],
            "  - Source: `%s/%s`, `%s`" % (turn["thread_id"], turn["turn_id"], claim["source_hash"]),
            "  - Evidence: `%s`" % claim["evidence"]["pointer"],
        ])
        if claim.get("supersedes"):
            lines.append("  - Supersedes: %s" % ", ".join("`%s`" % item for item in claim["supersedes"]))
    lines.append("")
    return ("\n".join(lines)).encode("utf-8")


def conservative_tokens(text: str) -> int:
    raw = len(text.encode("utf-8"))
    return (raw + 3) // 4


def render_hot(claims: List[Dict[str, Any]], conflicts: List[Dict[str, Any]]) -> Tuple[bytes, int, int]:
    global_claims = [claim for claim in claims if claim["scope"] == {"kind": "global", "id": "firstmate"}]
    order = {"correction": 0, "priority": 1, "decision": 2, "standard": 3, "failure_lesson": 4}
    global_claims.sort(key=lambda item: (order.get(item["type"], 9), item["subject"], item["transaction_time"], item["claim_id"]))
    lines = ["# Active Firstmate rules", ""]
    global_conflicts = [item for item in conflicts if item["scope"] == {"kind": "global", "id": "firstmate"}]
    if global_conflicts:
        lines.extend(["## Withheld conflicts", ""])
        for conflict in sorted(global_conflicts, key=lambda item: (item["transaction_time"], item["conflict_id"])):
            turn = conflict["source_turn"]
            entry = [
                "- Conflict `%s` on `%s`; candidate `%s` remains withheld." % (conflict["conflict_id"], conflict["subject"], conflict["candidate_id"]),
                "  Authority `%s`; transaction `%s`; source `%s/%s`, `%s`; existing %s." % (
                    conflict["authority"], conflict["transaction_time"], turn["thread_id"], turn["turn_id"],
                    conflict["source_hash"], ", ".join("`%s`" % item for item in conflict["claim_ids"]),
                ),
            ]
            trial = "\n".join(lines + entry + [""])
            if conservative_tokens(trial) <= MAX_HOT_TOKENS:
                lines.extend(entry)
        lines.append("")
    included = 0
    for claim in global_claims:
        entry = [
            "- %s" % claim["value"],
            "  Claim `%s`; authority `%s`; valid `%s` to `%s`; transaction `%s`; source `%s/%s`, `%s`." % (
                claim["claim_id"], claim["authority"], claim["valid_from"], claim.get("valid_until") or "open",
                claim["transaction_time"], claim["source_turn"]["thread_id"], claim["source_turn"]["turn_id"], claim["source_hash"],
            ),
        ]
        trial = "\n".join(lines + entry + [""])
        if conservative_tokens(trial) > MAX_HOT_TOKENS:
            continue
        lines.extend(entry)
        included += 1
    omitted = len(global_claims) - included
    if omitted:
        marker = "<!-- %d lower-priority active rule(s) omitted by the 1,500-token bound. -->" % omitted
        trial = "\n".join(lines + [marker, ""])
        if conservative_tokens(trial) <= MAX_HOT_TOKENS:
            lines.append(marker)
    lines.append("")
    text = "\n".join(lines)
    return text.encode("utf-8"), conservative_tokens(text), omitted


def active_version(dirs: Dict[str, Path]) -> str:
    active = sorted(batch_id for batch_id, state in batch_states(dirs).items() if state == "active")
    return stable_id("ver_", *active)


def render_views(dirs: Dict[str, Path], as_of: str, force_batch: Optional[str] = None) -> Tuple[Dict[Path, bytes], Dict[str, Any]]:
    states = batch_states(dirs)
    if force_batch:
        states[force_batch] = "active"
    all_claims = list_records(dirs["claims"])
    accepted = [claim for claim in all_claims if states.get(claim.get("batch_id")) == "active"]
    conflict_records = [item for item in list_records(dirs["conflicts"]) if states.get(item.get("batch_id")) == "active"]
    superseded = {item for claim in accepted for item in claim.get("supersedes", [])}
    moment = parse_time(as_of)
    active = [
        claim for claim in accepted
        if claim["claim_id"] not in superseded
        and parse_time(claim["valid_from"]) <= moment
        and (not claim.get("valid_until") or parse_time(claim["valid_until"]) >= moment)
    ]
    conflicts = unresolved_conflicts(conflict_records, active)
    groups: Dict[Tuple[str, str, str], List[Dict[str, Any]]] = {}
    for claim in active:
        scope = claim["scope"]
        groups.setdefault((scope["kind"], scope["id"], claim["subject"]), []).append(claim)
    views: Dict[Path, bytes] = {}
    index_lines = ["# Firstmate Brain", "", "Generated from immutable accepted claims.", ""]
    for key in sorted(groups):
        kind, scope_id, subject = key
        rel = Path("topics") / slug(kind + ":" + scope_id) / (slug(subject) + ".md")
        views[rel] = render_topic({"kind": kind, "id": scope_id}, subject, groups[key])
        index_lines.append("- [[%s|%s / %s]]" % (str(rel.with_suffix("")).replace(os.sep, "/"), scope_key({"kind": kind, "id": scope_id}), subject))
    if conflicts:
        index_lines.extend(["", "## Withheld conflicts", "", "- %d unresolved conflict record(s)." % len(conflicts)])
    index_lines.append("")
    views[Path("index.md")] = ("\n".join(index_lines)).encode("utf-8")
    active_batches = sorted(batch_id for batch_id, state in states.items() if state == "active")
    log_lines = ["# Active Brainkeeper batches", ""] + ["- `%s`" % item for item in active_batches] + [""]
    views[Path("log.md")] = ("\n".join(log_lines)).encode("utf-8")
    hot, hot_tokens, omitted = render_hot(active, conflicts)
    views[Path("hot") / "global.md"] = hot
    index_record = {
        "schema_version": "firstmate.active-index.v1",
        "version_id": stable_id("ver_", *active_batches),
        "claims": sorted(active, key=lambda item: item["claim_id"]),
        "conflicts": sorted(conflicts, key=lambda item: item["conflict_id"]),
    }
    views[Path("active-index.json")] = canonical_json(index_record)
    return views, {
        "active_claims": len(active),
        "active_batches": active_batches,
        "version_id": index_record["version_id"],
        "hot_tokens": hot_tokens,
        "hot_bytes": len(hot),
        "hot_omitted": omitted,
    }


SCHEMAS = {
    "event.schema.json": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Firstmate completed turn event",
        "type": "object",
        "required": ["event_id", "thread_id", "turn_id", "completed_at", "cwd", "scope", "speakers", "source"],
    },
    "candidate.schema.json": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Brainkeeper candidate",
        "type": "object",
        "required": ["candidate_id", "type", "source_turn", "source_hash", "scope", "authority", "valid_from", "transaction_time", "privacy", "extractor_version", "proposed_supersedes"],
    },
    "claim.schema.json": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Accepted Firstmate claim",
        "type": "object",
        "required": ["claim_id", "batch_id", "type", "value", "authority", "scope", "source_turn", "source_hash", "evidence", "supersedes"],
    },
    "batch.schema.json": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Immutable Brainkeeper batch transition",
        "type": "object",
        "required": ["batch_id", "version_id", "state", "transaction_time"],
    },
}


def install_schemas(dirs: Dict[str, Path]) -> None:
    for name, schema in SCHEMAS.items():
        write_once(dirs["schema"] / name, pretty_json(schema))


def file_map(root: Path) -> Dict[Path, bytes]:
    output: Dict[Path, bytes] = {}
    if not root.is_dir():
        return output
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.name.startswith(".partial-"):
            output[path.relative_to(root)] = path.read_bytes()
    return output


def make_review(batch_id: str, before: Dict[Path, bytes], after: Dict[Path, bytes], claims: List[Dict[str, Any]]) -> bytes:
    changed = sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))
    lines = ["# Brainkeeper batch %s" % batch_id, "", "## Bounded derived diff", ""]
    for path in changed[:MAX_COMPILE_EDITS]:
        old = sha256_bytes(before[path]) if path in before else "absent"
        new = sha256_bytes(after[path]) if path in after else "absent"
        lines.append("- `%s`: `%s` -> `%s`" % (str(path), old, new))
    lines.extend(["", "## Accepted claims", ""])
    for claim in claims:
        lines.append("- `%s` %s [%s, %s]" % (claim["claim_id"], claim["value"], claim["authority"], scope_key(claim["scope"])))
    if not claims:
        lines.append("- None")
    lines.append("")
    data = "\n".join(lines).encode("utf-8")
    if len(data) > MAX_REVIEW_BYTES:
        data = data[: MAX_REVIEW_BYTES - 24] + b"\n[REVIEW TRUNCATED]\n"
    return data


def evaluate_fixture(path: Optional[Path]) -> str:
    if path is None or not path.exists():
        raise RuntimeError("held-out orchestration fixture is required")
    value = json.loads(path.read_text(encoding="utf-8"))
    cases = value.get("cases") if isinstance(value, dict) else None
    if not isinstance(cases, list) or not cases:
        raise RuntimeError("held-out orchestration fixture has no cases")
    observed = []
    for case in cases:
        parsed = []
        for line in str(case.get("content", "")).splitlines():
            item = extract_line(line)
            if item:
                parsed.append(item["type"])
        expected = case.get("candidate_types", [])
        if parsed != expected:
            raise RuntimeError("held-out orchestration regression: %s" % case.get("name", "unnamed"))
        observed.append({"name": case.get("name"), "candidate_types": parsed})
    return sha256_bytes(canonical_json(observed))


def evaluate_claims(claims: List[Dict[str, Any]], fixture: Optional[Path]) -> str:
    for claim in claims:
        if validate_candidate({
            "candidate_id": claim["candidate_id"], "type": claim["type"], "subject": claim["subject"],
            "value": claim["value"], "speaker": claim["speaker"], "scope": claim["scope"],
            "authority": claim["authority"], "valid_from": claim["valid_from"],
            "valid_until": claim.get("valid_until"), "transaction_time": claim["transaction_time"],
            "confidence": claim["confidence"], "privacy": claim["privacy"],
            "extractor_version": claim["extractor_version"], "source_turn": claim["source_turn"],
            "source_hash": claim["source_hash"], "evidence": claim["evidence"],
            "proposed_supersedes": claim["supersedes"],
        }):
            raise RuntimeError("staged claim failed schema evaluation")
        if claim["authority"] != "blue_explicit" or claim["privacy"] != "personal_local":
            raise RuntimeError("staged claim failed authority or privacy evaluation")
        if any(pattern.search(claim["value"]) for pattern in FORBIDDEN_ACTIVE_PATTERNS):
            raise RuntimeError("staged claim failed behavioral evaluation")
    fixture_digest = evaluate_fixture(fixture)
    return sha256_bytes(canonical_json({"fixture": fixture_digest, "claims": [item["claim_id"] for item in claims]}))


def apply_views(dirs: Dict[str, Path], views: Dict[Path, bytes], stats: Dict[str, Any]) -> List[str]:
    generated = dirs["generated"]
    before = file_map(generated)
    changed = sorted(path for path in set(before) | set(views) if before.get(path) != views.get(path))
    if len(changed) > MAX_COMPILE_EDITS:
        raise RuntimeError("bounded edit gate exceeded: %d files" % len(changed))
    archive_version = stats["version_id"]
    for rel in changed:
        target = generated / rel
        if rel not in views:
            archived = ensure_private_dir(dirs["archive"] / archive_version / rel.parent) / rel.name
            if target.exists():
                replace_if_changed(archived, target.read_bytes())
                target.unlink()
                fsync_dir(target.parent)
            continue
        replace_if_changed(target, views[rel])
    state = {
        "schema_version": "firstmate.compile-state.v1",
        "last_successful_compile": utc_now(),
        "as_of": stats.get("as_of"),
        "version_id": stats["version_id"],
        "changed_files": [str(item) for item in changed],
        "hot_tokens": stats["hot_tokens"],
        "hot_bytes": stats["hot_bytes"],
    }
    replace_if_changed(dirs["private"] / "compile-state.json", canonical_json(state))
    return [str(item) for item in changed]


def write_batch_record(dirs: Dict[str, Path], batch_id: str, state: str, record: Dict[str, Any]) -> None:
    order = {"prepared": "01", "evaluated": "02", "active": "03", "deactivated": "04", "failed": "05"}
    suffix = stable_id("tr_", batch_id, state, str(record.get("transaction_time")))[:20]
    path = dirs["batches"] / ("%s-%s-%s-%s.json" % (batch_id, order[state], state, suffix))
    write_once(path, canonical_json(record))


def mark_processed(event_root: Dict[str, Path], event: Dict[str, Any], batch_id: str) -> None:
    record = {
        "schema_version": "firstmate.processed-event.v1",
        "event_id": event["event_id"],
        "delivery_hash": event["delivery_hash"],
        "batch_id": batch_id,
        "processed_at": utc_now(),
        "extractor_version": EXTRACTOR_VERSION,
    }
    processed_scope = ensure_private_dir(event_root["processed"] / slug(scope_key(event["scope"])))
    path = processed_scope / (event["event_id"] + ".json")
    if path.exists():
        existing = read_json(path)
        if existing.get("delivery_hash") != event["delivery_hash"] or existing.get("batch_id") != batch_id:
            raise RuntimeError("processed event marker collision: %s" % event["event_id"])
        return
    write_once(path, canonical_json(record))


def mark_batch_completed(dirs: Dict[str, Path], batch_id: str, event_ids: List[str]) -> None:
    record = {
        "schema_version": "firstmate.completed-batch.v1",
        "batch_id": batch_id,
        "event_ids": event_ids,
        "completed_at": utc_now(),
    }
    path = dirs["completed_batches"] / (batch_id + ".json")
    if path.exists():
        existing = read_json(path)
        if existing.get("event_ids") != event_ids:
            raise RuntimeError("completed batch marker collision: %s" % batch_id)
        return
    write_once(path, canonical_json(record))


def recover_incomplete_active_batch(home: Path, dirs: Dict[str, Path], event_root: Dict[str, Path]) -> Optional[Dict[str, Any]]:
    states = batch_states(dirs)
    prepared = [record for record in list_records(dirs["batches"]) if record.get("state") == "prepared"]
    for record in reversed(prepared):
        batch_id = record["batch_id"]
        if states.get(batch_id) != "active" or (dirs["completed_batches"] / (batch_id + ".json")).exists():
            continue
        scope = record["scope"]
        processed_scope = event_root["processed"] / slug(scope_key(scope))
        event_ids = record["event_ids"]
        missing_ids = [event_id for event_id in event_ids if not (processed_scope / (event_id + ".json")).exists()]
        if not missing_ids:
            mark_batch_completed(dirs, batch_id, event_ids)
            continue
        recovered_events = []
        for event_id in event_ids:
            matches = list(event_root["inbox"].rglob(event_id + ".json"))
            if len(matches) != 1:
                raise RuntimeError("active batch recovery cannot resolve source event: %s" % event_id)
            recovered_events.append(read_json(matches[0]))
        as_of = record["transaction_time"]
        views, stats = render_views(dirs, as_of)
        stats["as_of"] = as_of
        changed = apply_views(dirs, views, stats)
        for event in recovered_events:
            mark_processed(event_root, event, batch_id)
        mark_batch_completed(dirs, batch_id, event_ids)
        return {"state": "recovered", "batch_id": batch_id, "processed_events": len(recovered_events), "changed_files": changed}
    return None


def event_batch(home: Path, limit: int) -> List[Dict[str, Any]]:
    dirs = event_dirs(home)
    events = []
    selected_scope: Optional[Dict[str, str]] = None
    for path in sorted(dirs["inbox"].rglob("ev_*.json")):
        event = read_json(path)
        processed_scope = dirs["processed"] / slug(scope_key(event["scope"]))
        if (processed_scope / path.name).exists():
            continue
        if selected_scope is None:
            selected_scope = event["scope"]
        if event["scope"] != selected_scope:
            continue
        events.append(event)
        if len(events) >= limit:
            break
    return events


def drain_once(args: argparse.Namespace) -> Dict[str, Any]:
    require_brainkeeper()
    home = brain_home(args)
    vault = resolve_vault(args)
    dirs = keeper_dirs(home, vault)
    event_root = event_dirs(home)
    fixture = Path(args.evaluation_fixture).resolve() if args.evaluation_fixture else None
    with KeeperLock(dirs["private"] / "brainkeeper.lock"):
        install_schemas(dirs)
        recovered = recover_incomplete_active_batch(home, dirs, event_root)
        if recovered:
            return recovered
        events = event_batch(home, min(max(args.limit, 1), MAX_BATCH_EVENTS))
        if not events:
            now = utc_now()
            views, stats = render_views(dirs, now)
            current = file_map(dirs["generated"])
            if current != views:
                stats["as_of"] = now
                changed = apply_views(dirs, views, stats)
                return {"state": "validity_compile", "processed_events": 0, "changed_files": changed, "hot_tokens": stats["hot_tokens"]}
            return {"state": "idle", "processed_events": 0}
        states = batch_states(dirs)
        parent_version = active_version(dirs)
        batch_id = stable_id("bt_", EXTRACTOR_VERSION, parent_version, *[item["event_id"] for item in events])
        active_batch_ids = sorted([item for item, state in states.items() if state == "active"] + [batch_id])
        version_id = stable_id("ver_", *active_batch_ids)
        if states.get(batch_id) == "active":
            views, stats = render_views(dirs, as_of=max(event["completed_at"] for event in events))
            stats["as_of"] = max(event["completed_at"] for event in events)
            changed = apply_views(dirs, views, stats)
            for event in events:
                mark_processed(event_root, event, batch_id)
            mark_batch_completed(dirs, batch_id, [event["event_id"] for event in events])
            return {"state": "recovered", "batch_id": batch_id, "processed_events": len(events), "changed_files": changed}

        as_of = max(event["completed_at"] for event in events)
        active = currently_active_claims(dirs, as_of)
        candidates: List[Dict[str, Any]] = []
        claims: List[Dict[str, Any]] = []
        for event in events:
            try:
                extracted = extract_candidates(event)
            except Exception as exc:
                failure = {
                    "schema_version": "firstmate.extraction-failure.v1",
                    "event_id": event.get("event_id"),
                    "source_hash": event.get("delivery_hash"),
                    "extractor_version": EXTRACTOR_VERSION,
                    "transaction_time": utc_now(),
                    "error_class": type(exc).__name__,
                }
                write_once(dirs["failures"] / (stable_id("xf_", str(event.get("event_id")), type(exc).__name__) + ".json"), canonical_json(failure))
                extracted = []
            for candidate in extracted:
                candidate, claim = promote_candidate(candidate, active + claims)
                candidate["batch_id"] = batch_id
                candidate_scope = ensure_private_dir(dirs["candidates"] / slug(scope_key(candidate["scope"])))
                write_once(candidate_scope / (candidate["candidate_id"] + ".json"), canonical_json(candidate))
                if candidate["status"] == "conflict":
                    conflict = {
                        "schema_version": "firstmate.conflict.v1",
                        "conflict_id": stable_id("cf_", candidate["candidate_id"], *candidate["proposed_supersedes"]),
                        "candidate_id": candidate["candidate_id"],
                        "claim_ids": candidate["proposed_supersedes"],
                        "batch_id": batch_id,
                        "subject": candidate["subject"],
                        "authority": candidate["authority"],
                        "scope": candidate["scope"],
                        "transaction_time": candidate["transaction_time"],
                        "source_turn": candidate["source_turn"],
                        "source_hash": candidate["source_hash"],
                        "evidence": candidate["evidence"],
                    }
                    conflict_scope = ensure_private_dir(dirs["conflicts"] / slug(scope_key(candidate["scope"])))
                    write_once(conflict_scope / (conflict["conflict_id"] + ".json"), canonical_json(conflict))
                candidates.append(candidate)
                if claim:
                    claim["batch_id"] = batch_id
                    claims.append(claim)

        prepared = {
            "schema_version": "firstmate.batch.v1",
            "batch_id": batch_id,
            "version_id": version_id,
            "parent_version_id": parent_version,
            "state": "prepared",
            "transaction_time": as_of,
            "event_ids": [item["event_id"] for item in events],
            "scope": events[0]["scope"],
            "candidate_ids": [item["candidate_id"] for item in candidates],
            "claim_ids": [item["claim_id"] for item in claims],
            "extractor_version": EXTRACTOR_VERSION,
        }
        write_batch_record(dirs, batch_id, "prepared", prepared)
        for claim in claims:
            claim_scope = ensure_private_dir(dirs["claims"] / slug(scope_key(claim["scope"])))
            write_once(claim_scope / (claim["claim_id"] + ".json"), canonical_json(claim))

        before = file_map(dirs["generated"])
        staged_views, staged_stats = render_views(dirs, as_of, force_batch=batch_id)
        review = make_review(batch_id, before, staged_views, claims)
        write_once(dirs["reviews"] / (batch_id + ".md"), review)

        staged_changed = [path for path in set(before) | set(staged_views) if before.get(path) != staged_views.get(path)]
        if len(staged_changed) > MAX_COMPILE_EDITS:
            failed = dict(prepared)
            failed.update(state="failed", transaction_time=as_of, error_class="BoundedEditGate")
            write_batch_record(dirs, batch_id, "failed", failed)
            write_once(dirs["batch_failures"] / (batch_id + ".json"), canonical_json(failed))
            for event in events:
                mark_processed(event_root, event, batch_id)
            raise RuntimeError("bounded edit gate exceeded before activation: %d files" % len(staged_changed))

        try:
            evaluation_digest = evaluate_claims(claims, fixture)
        except Exception as exc:
            failed = dict(prepared)
            failed.update(state="failed", transaction_time=utc_now(), error_class=type(exc).__name__)
            write_batch_record(dirs, batch_id, "failed", failed)
            write_once(dirs["batch_failures"] / (batch_id + ".json"), canonical_json(failed))
            for event in events:
                mark_processed(event_root, event, batch_id)
            raise
        evaluated = dict(prepared)
        evaluated.update(state="evaluated", transaction_time=as_of, evaluation_digest=evaluation_digest)
        write_batch_record(dirs, batch_id, "evaluated", evaluated)
        if os.environ.get("FM_BRAIN_FAILPOINT") == "brainkeeper_after_evaluation_before_activation":
            os._exit(88)
        active_record = dict(evaluated)
        active_record.update(state="active", transaction_time=as_of)
        write_batch_record(dirs, batch_id, "active", active_record)
        if os.environ.get("FM_BRAIN_FAILPOINT") == "brainkeeper_after_activation_before_compile":
            os._exit(89)

        views, stats = render_views(dirs, as_of)
        stats["as_of"] = as_of
        changed = apply_views(dirs, views, stats)
        for event in events:
            mark_processed(event_root, event, batch_id)
        mark_batch_completed(dirs, batch_id, [event["event_id"] for event in events])
        return {
            "state": "active",
            "batch_id": batch_id,
            "version_id": stats["version_id"],
            "processed_events": len(events),
            "candidates": len(candidates),
            "accepted_claims": len(claims),
            "changed_files": changed,
            "hot_tokens": stats["hot_tokens"],
            "evaluation_digest": evaluation_digest,
        }


def command_drain(args: argparse.Namespace) -> int:
    result = drain_once(args)
    print(json.dumps(result, sort_keys=True))
    return 0


def command_serve(args: argparse.Namespace) -> int:
    require_brainkeeper()
    while True:
        result = drain_once(args)
        if args.once:
            print(json.dumps(result, sort_keys=True))
            return 0
        if result.get("state") != "idle":
            print(json.dumps(result, sort_keys=True), flush=True)
        time.sleep(max(1.0, args.interval))


def command_query(args: argparse.Namespace) -> int:
    require_brainkeeper()
    home = brain_home(args)
    dirs = keeper_dirs(home, resolve_vault(args))
    index_path = dirs["generated"] / "active-index.json"
    if not index_path.exists():
        print("[]")
        return 0
    index = read_json(index_path)
    claims = index.get("claims", [])
    scope = {"kind": args.scope_kind, "id": args.scope_id}
    output = [claim for claim in claims if claim.get("scope") == scope and (not args.topic or claim.get("subject") == args.topic)]
    print(json.dumps(output, sort_keys=True, ensure_ascii=False))
    return 0


def decision_context_markdown(
    claims: List[Dict[str, Any]],
    conflicts: List[Dict[str, Any]],
    scope: Dict[str, str],
    topics: List[str],
    as_of: str,
    version_id: str,
) -> str:
    lines = [
        "# Current Firstmate decision context",
        "",
        "- Scope: `%s`" % scope_key(scope),
        "- Topics: %s" % (", ".join("`%s`" % topic for topic in topics) if topics else "all exact topics"),
        "- As of: `%s`" % as_of,
        "- Version: `%s`" % version_id,
        "- Complete for this exact scope and topic selection: `true`",
        "- Memory supplies context only. Existing deterministic action gates remain authoritative.",
        "",
        "## Current typed facts",
        "",
    ]
    if not claims:
        lines.append("- None")
    for claim in sorted(claims, key=lambda item: (item["scope"]["kind"], item["scope"]["id"], item["subject"], item["transaction_time"], item["claim_id"])):
        turn = claim["source_turn"]
        lines.extend([
            "- %s" % claim["value"],
            "  - Type and precedence: `%s`, `%s`" % (claim["type"], claim["authority"]),
            "  - Claim and scope: `%s`, `%s`" % (claim["claim_id"], scope_key(claim["scope"])),
            "  - Freshness: valid `%s` to `%s`; transaction `%s`" % (claim["valid_from"], claim.get("valid_until") or "open", claim["transaction_time"]),
            "  - Source: `%s/%s`, `%s`, evidence `%s`" % (turn["thread_id"], turn["turn_id"], claim["source_hash"], claim["evidence"]["pointer"]),
            "  - Supersedes: %s" % (", ".join("`%s`" % item for item in claim.get("supersedes", [])) or "none"),
        ])
    lines.extend(["", "## Withheld conflicts", ""])
    if not conflicts:
        lines.append("- None")
    for conflict in sorted(conflicts, key=lambda item: (item["transaction_time"], item["conflict_id"])):
        turn = conflict["source_turn"]
        lines.extend([
            "- Conflict `%s` on `%s`; candidate `%s` is withheld." % (conflict["conflict_id"], conflict["subject"], conflict["candidate_id"]),
            "  - Precedence: `%s`; existing claims %s" % (conflict["authority"], ", ".join("`%s`" % item for item in conflict["claim_ids"])),
            "  - Freshness: transaction `%s`" % conflict["transaction_time"],
            "  - Source: `%s/%s`, `%s`, evidence `%s`" % (turn["thread_id"], turn["turn_id"], conflict["source_hash"], conflict["evidence"]["pointer"]),
        ])
    lines.append("")
    return "\n".join(lines)


def command_context(args: argparse.Namespace) -> int:
    vault = resolve_vault(args)
    brain = vault / "firstmate-brain"
    index_path = brain / "generated" / "active-index.json"
    batches_path = brain / "ledger" / "batches"
    if not index_path.is_file() or not batches_path.is_dir():
        raise RuntimeError("compiled decision context is unavailable; Brainkeeper must drain first")
    index = read_json(index_path)
    expected_version = active_version({"batches": batches_path})
    if index.get("version_id") != expected_version:
        raise RuntimeError("compiled decision context is stale; Brainkeeper must finish the active batch")

    as_of = normalize_time(args.as_of or utc_now())
    moment = parse_time(as_of)
    exact_scope = {"kind": args.scope_kind, "id": args.scope_id}
    allowed_scopes = [{"kind": "global", "id": "firstmate"}]
    if exact_scope not in allowed_scopes:
        allowed_scopes.append(exact_scope)
    topics = args.topic or []

    claims = []
    for claim in index.get("claims", []):
        if claim.get("scope") not in allowed_scopes:
            continue
        if topics and claim.get("subject") not in topics:
            continue
        if parse_time(claim["valid_from"]) > moment:
            continue
        if claim.get("valid_until") and parse_time(claim["valid_until"]) < moment:
            continue
        claims.append(claim)
    conflicts = [
        item for item in index.get("conflicts", [])
        if item.get("scope") in allowed_scopes and (not topics or item.get("subject") in topics)
    ]
    context = decision_context_markdown(claims, conflicts, exact_scope, topics, as_of, expected_version)
    tokens = conservative_tokens(context)
    if tokens > args.max_tokens:
        raise RuntimeError(
            "complete decision context needs %d conservative tokens, above bound %d; narrow --topic without accepting a partial dump"
            % (tokens, args.max_tokens)
        )
    sys.stdout.write(context)
    return 0


def command_rollback(args: argparse.Namespace) -> int:
    require_brainkeeper()
    home = brain_home(args)
    dirs = keeper_dirs(home, resolve_vault(args))
    with KeeperLock(dirs["private"] / "brainkeeper.lock"):
        states = batch_states(dirs)
        matches = [
            item for item in list_records(dirs["batches"])
            if item.get("state") == "active"
            and item.get("version_id") == args.version_id
            and states.get(item.get("batch_id")) == "active"
        ]
        if len(matches) != 1:
            raise RuntimeError("version does not identify exactly one active batch: %s" % args.version_id)
        batch_id = matches[0]["batch_id"]
        now = normalize_time(args.as_of or utc_now())
        current_version = active_version(dirs)
        remaining_batches = sorted(item for item, state in states.items() if state == "active" and item != batch_id)
        record = {
            "schema_version": "firstmate.batch.v1",
            "batch_id": batch_id,
            "version_id": stable_id("ver_", *remaining_batches),
            "parent_version_id": current_version,
            "target_version_id": args.version_id,
            "state": "deactivated",
            "transaction_time": now,
            "reason": "operator_rollback",
        }
        write_batch_record(dirs, batch_id, "deactivated", record)
        views, stats = render_views(dirs, now)
        stats["as_of"] = now
        changed = apply_views(dirs, views, stats)
        print(json.dumps({
            "state": "deactivated",
            "batch_id": batch_id,
            "deactivated_version_id": args.version_id,
            "version_id": stats["version_id"],
            "changed_files": changed,
        }, sort_keys=True))
    return 0


def health_snapshot(home: Path, dirs: Dict[str, Path], as_of: str) -> Dict[str, Any]:
    event_root = event_dirs(home)
    pending_events = []
    for path in event_root["inbox"].rglob("ev_*.json"):
        event = read_json(path)
        processed_scope = event_root["processed"] / slug(scope_key(event["scope"]))
        if not (processed_scope / path.name).exists():
            pending_events.append(event)
    queue_lag = 0.0
    if pending_events:
        oldest = min(parse_time(item["completed_at"]) for item in pending_events)
        queue_lag = max(0.0, (parse_time(as_of) - oldest).total_seconds())
    candidates = list_records(dirs["candidates"])
    claims = accepted_claims(dirs, include_inactive=True)
    states = batch_states(dirs)
    active_conflict_records = [item for item in list_records(dirs["conflicts"]) if states.get(item.get("batch_id")) == "active"]
    current_claims = currently_active_claims(dirs, as_of)
    conflicts = unresolved_conflicts(active_conflict_records, current_claims)
    stale = [claim for claim in claims if claim.get("valid_until") and parse_time(claim["valid_until"]) < parse_time(as_of)]
    compile_state_path = dirs["private"] / "compile-state.json"
    compile_state = read_json(compile_state_path) if compile_state_path.exists() else {}
    hot_path = dirs["hot"] / "global.md"
    hot = hot_path.read_text(encoding="utf-8") if hot_path.exists() else ""
    partials = list(home.rglob(".partial-*"))
    return {
        "schema_version": "firstmate.health.v1",
        "queue_depth": len(pending_events),
        "queue_lag_seconds": round(queue_lag, 6),
        "failed_extraction": len(list_records(dirs["failures"])),
        "failed_batches": len(list_records(dirs["batch_failures"])),
        "quarantined_candidates": sum(1 for item in candidates if item.get("status") == "quarantined"),
        "conflicts": len(conflicts),
        "unreported_conflicts": sum(1 for item in conflicts if not (dirs["alerts"] / (item["conflict_id"] + ".json")).exists()),
        "stale_claims": len(stale),
        "delivery_errors": len(list_records(event_root["delivery_errors"])),
        "orphan_partials": len(partials),
        "last_successful_compile": compile_state.get("last_successful_compile"),
        "hot_view_bytes": len(hot.encode("utf-8")),
        "hot_view_tokens": conservative_tokens(hot),
    }


def command_health(args: argparse.Namespace) -> int:
    require_brainkeeper()
    home = brain_home(args)
    dirs = keeper_dirs(home, resolve_vault(args))
    now = normalize_time(args.as_of or utc_now())
    snapshot = health_snapshot(home, dirs, now)
    if args.exceptions_only:
        problems = {
            key: snapshot[key]
            for key in ["queue_depth", "failed_extraction", "failed_batches", "quarantined_candidates", "unreported_conflicts", "delivery_errors", "orphan_partials"]
            if snapshot[key]
        }
        if snapshot["hot_view_tokens"] > MAX_HOT_TOKENS:
            problems["hot_view_tokens"] = snapshot["hot_view_tokens"]
        if not snapshot["last_successful_compile"]:
            problems["last_successful_compile"] = None
        if not problems:
            return 0
        print(json.dumps(problems, sort_keys=True))
        if args.mark_reported:
            states = batch_states(dirs)
            active_records = [item for item in list_records(dirs["conflicts"]) if states.get(item.get("batch_id")) == "active"]
            for conflict in unresolved_conflicts(active_records, currently_active_claims(dirs, now)):
                marker = {"conflict_id": conflict["conflict_id"], "reported_at": now}
                write_once(dirs["alerts"] / (conflict["conflict_id"] + ".json"), canonical_json(marker))
        return 2
    print(json.dumps(snapshot, sort_keys=True))
    return 0


def command_rebuild(args: argparse.Namespace) -> int:
    require_brainkeeper()
    home = brain_home(args)
    dirs = keeper_dirs(home, resolve_vault(args))
    compile_state_path = dirs["private"] / "compile-state.json"
    if args.as_of:
        as_of = normalize_time(args.as_of)
    elif compile_state_path.exists():
        as_of = read_json(compile_state_path).get("as_of") or utc_now()
    else:
        as_of = utc_now()
    views, stats = render_views(dirs, as_of)
    current = file_map(dirs["generated"])
    exact = current == views
    if args.verify_only:
        print(json.dumps({"byte_exact": exact, "version_id": stats["version_id"], "hot_tokens": stats["hot_tokens"]}, sort_keys=True))
        return 0 if exact else 3
    stats["as_of"] = as_of
    changed = apply_views(dirs, views, stats)
    print(json.dumps({"byte_exact_before": exact, "changed_files": changed, "version_id": stats["version_id"], "hot_tokens": stats["hot_tokens"]}, sort_keys=True))
    return 0


def command_evaluate(args: argparse.Namespace) -> int:
    require_brainkeeper()
    digest = evaluate_claims([], Path(args.evaluation_fixture).resolve())
    print(json.dumps({"status": "pass", "evaluation_digest": digest}, sort_keys=True))
    return 0


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", help="private brain home; defaults to FM_BRAIN_HOME or FM_HOME/data/brain")
    sub = parser.add_subparsers(dest="command", required=True)

    def maintenance(name: str) -> argparse.ArgumentParser:
        command = sub.add_parser(name)
        command.add_argument("--vault", help="existing Obsidian vault root")
        return command

    drain = maintenance("drain")
    drain.add_argument("--limit", type=int, default=100)
    drain.add_argument("--evaluation-fixture", required=True)
    drain.set_defaults(func=command_drain)
    serve = maintenance("serve")
    serve.add_argument("--limit", type=int, default=100)
    serve.add_argument("--evaluation-fixture", required=True)
    serve.add_argument("--interval", type=float, default=5.0)
    serve.add_argument("--once", action="store_true")
    serve.set_defaults(func=command_serve)
    query = maintenance("query")
    query.add_argument("--scope-kind", choices=sorted(ALLOWED_SCOPES), required=True)
    query.add_argument("--scope-id", required=True)
    query.add_argument("--topic")
    query.set_defaults(func=command_query)
    context = maintenance("context")
    context.add_argument("--scope-kind", choices=sorted(ALLOWED_SCOPES), required=True)
    context.add_argument("--scope-id", required=True)
    context.add_argument("--topic", action="append")
    context.add_argument("--as-of")
    context.add_argument("--max-tokens", type=int, default=MAX_DECISION_CONTEXT_TOKENS)
    context.set_defaults(func=command_context)
    rollback = maintenance("rollback")
    rollback.add_argument("--version-id", required=True)
    rollback.add_argument("--as-of")
    rollback.set_defaults(func=command_rollback)
    health = maintenance("health")
    health.add_argument("--as-of")
    health.add_argument("--exceptions-only", action="store_true")
    health.add_argument("--mark-reported", action="store_true")
    health.set_defaults(func=command_health)
    rebuild = maintenance("rebuild")
    rebuild.add_argument("--as-of")
    rebuild.add_argument("--verify-only", action="store_true")
    rebuild.set_defaults(func=command_rebuild)
    evaluate = maintenance("evaluate")
    evaluate.add_argument("--evaluation-fixture", required=True)
    evaluate.set_defaults(func=command_evaluate)
    return parser


def main() -> int:
    os.umask(0o077)
    parser = make_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except BrokenPipeError:
        return 0
    except Exception as exc:
        print("fm-brain: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
