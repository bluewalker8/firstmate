#!/usr/bin/env python3
"""Small deterministic foreground runtime for completed-turn capture only."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Dict, Iterable, Optional, Tuple


SCHEMA_VERSION = "firstmate.turn.v1"
MAX_CONTENT_BYTES = 65536
MAX_CWD_BYTES = 2048
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


def normalize_time(value: str) -> str:
    parsed = dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def utc_now() -> str:
    forced = os.environ.get("FM_BRAIN_NOW")
    if forced:
        return normalize_time(forced)
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def sha256_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def stable_id(prefix: str, *parts: str) -> str:
    return prefix + hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()[:32]


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


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


def read_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise RuntimeError("expected JSON object: %s" % path)
    return value


def read_stdin_json() -> Dict[str, Any]:
    raw = sys.stdin.buffer.read()
    if not raw:
        raise RuntimeError("JSON input is required")
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("JSON input must be an object")
    return value


def redact_secrets(text: str) -> str:
    for pattern in SECRET_PATTERNS:
        text = pattern.sub("[REDACTED_SECRET]", text)
    return text


def bounded_text(value: Any, limit: int) -> Tuple[str, bool, int, str]:
    text = value if isinstance(value, str) else ""
    raw = text.encode("utf-8")
    redacted = redact_secrets(text)
    sanitized = redacted.encode("utf-8")
    truncated = len(sanitized) > limit
    if truncated:
        sanitized = sanitized[:limit]
        while sanitized:
            try:
                redacted = sanitized.decode("utf-8")
                break
            except UnicodeDecodeError:
                sanitized = sanitized[:-1]
        redacted += "\n[TRUNCATED]"
    return redacted, truncated, len(raw), sha256_bytes(raw)


def safe_identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 512 or "\x00" in value:
        raise RuntimeError("invalid %s" % label)
    return value


def brain_home(args: argparse.Namespace) -> Path:
    explicit = args.home or os.environ.get("FM_BRAIN_HOME")
    if explicit:
        return ensure_private_dir(Path(explicit).expanduser().resolve())
    fm_home = os.environ.get("FM_HOME") or str(Path(__file__).resolve().parent.parent)
    return ensure_private_dir(Path(fm_home).expanduser().resolve() / "data" / "brain")


def event_dirs(home: Path) -> Dict[str, Path]:
    root = ensure_private_dir(home / "events")
    return {
        "pending": ensure_private_dir(root / "pending"),
        "inbox": ensure_private_dir(root / "inbox"),
        "delivery_errors": ensure_private_dir(root / "delivery-errors"),
        "processed": ensure_private_dir(root / "processed"),
    }


def resolve_scope(payload: Dict[str, Any], cwd: str) -> Dict[str, str]:
    kind = payload.get("scope_kind") or os.environ.get("FM_BRAIN_SCOPE_KIND")
    scope_id = payload.get("scope_id") or os.environ.get("FM_BRAIN_SCOPE_ID")
    client_id = os.environ.get("FM_BRAIN_CLIENT_ID")
    if client_id and not kind:
        kind, scope_id = "client", client_id
    if not kind:
        fm_home = os.environ.get("FM_HOME")
        if fm_home:
            try:
                relative = Path(cwd).expanduser().resolve().relative_to(Path(fm_home).expanduser().resolve() / "projects")
                if relative.parts:
                    kind, scope_id = "project", relative.parts[0]
            except (ValueError, OSError):
                pass
    if not kind:
        kind, scope_id = "global", "firstmate"
    if kind not in {"global", "project", "client"}:
        raise RuntimeError("invalid scope kind")
    if not isinstance(scope_id, str) or not scope_id or len(scope_id) > 200:
        raise RuntimeError("invalid scope id")
    return {"kind": kind, "id": scope_id}


def scope_dir(root: Path, scope: Dict[str, str]) -> Path:
    token = scope["kind"] + "-" + hashlib.sha256((scope["kind"] + ":" + scope["id"]).encode("utf-8")).hexdigest()[:16]
    return ensure_private_dir(root / token)


def build_pending(payload: Dict[str, Any]) -> Dict[str, Any]:
    thread_id = safe_identifier(payload.get("session_id") or payload.get("thread_id"), "thread id")
    turn_id = safe_identifier(payload.get("turn_id"), "turn id")
    prompt = payload.get("prompt") if "prompt" in payload else payload.get("user")
    cwd_value = payload.get("cwd") or os.getcwd()
    cwd = bounded_text(cwd_value if isinstance(cwd_value, str) else os.getcwd(), MAX_CWD_BYTES)[0]
    content, truncated, source_bytes, source_hash = bounded_text(prompt, MAX_CONTENT_BYTES)
    eid = stable_id("ev_", SCHEMA_VERSION, thread_id, turn_id)
    return {
        "schema_version": SCHEMA_VERSION,
        "event_id": eid,
        "thread_id": thread_id,
        "turn_id": turn_id,
        "submitted_at": normalize_time(str(payload.get("submitted_at") or utc_now())),
        "cwd": cwd,
        "scope": resolve_scope(payload, cwd),
        "user": {
            "role": "user", "speaker": "blue", "content": content,
            "content_hash": source_hash, "source_bytes": source_bytes, "truncated": truncated,
        },
        "source": {
            "adapter": str(payload.get("adapter") or "codex-project-hook"),
            "pointer": "session:%s/turn:%s" % (thread_id, turn_id),
        },
    }


def record_delivery_error(dirs: Dict[str, Path], eid: str, reason: str, payload: Dict[str, Any]) -> None:
    payload_hash = sha256_bytes(canonical_json(payload))
    path = dirs["delivery_errors"] / (stable_id("de_", eid, reason, payload_hash) + ".json")
    if path.exists():
        return
    write_once(path, canonical_json({
        "schema_version": "firstmate.delivery-error.v1", "event_id": eid, "reason": reason,
        "transaction_time": utc_now(), "payload_hash": payload_hash,
    }))


def stage_pending(home: Path, payload: Dict[str, Any]) -> Dict[str, Any]:
    dirs = event_dirs(home)
    pending = build_pending(payload)
    path = dirs["pending"] / (pending["event_id"] + ".json")
    if path.exists():
        existing = read_json(path)
        if existing.get("user", {}).get("content_hash") != pending["user"]["content_hash"]:
            record_delivery_error(dirs, pending["event_id"], "prompt_retry_hash_mismatch", pending)
            raise RuntimeError("prompt retry changed content for %s" % pending["event_id"])
        return {"event_id": pending["event_id"], "state": "duplicate"}
    write_once(path, canonical_json(pending))
    return {"event_id": pending["event_id"], "state": "pending"}


def finalize(home: Path, payload: Dict[str, Any]) -> Dict[str, Any]:
    dirs = event_dirs(home)
    thread_id = safe_identifier(payload.get("session_id") or payload.get("thread_id"), "thread id")
    turn_id = safe_identifier(payload.get("turn_id"), "turn id")
    eid = stable_id("ev_", SCHEMA_VERSION, thread_id, turn_id)
    assistant = payload.get("last_assistant_message") if "last_assistant_message" in payload else payload.get("assistant")
    assistant = assistant if isinstance(assistant, str) else ""
    pending_path = dirs["pending"] / (eid + ".json")
    pending = read_json(pending_path) if pending_path.exists() else None
    cwd_value = payload.get("cwd") or os.getcwd()
    cwd = bounded_text(cwd_value if isinstance(cwd_value, str) else os.getcwd(), MAX_CWD_BYTES)[0]
    scope = pending["scope"] if pending else resolve_scope(payload, cwd)
    final_path = scope_dir(dirs["inbox"], scope) / (eid + ".json")
    if final_path.exists():
        existing = read_json(final_path)
        speakers = existing.get("speakers", [])
        existing_hash = speakers[1].get("content_hash") if len(speakers) > 1 else None
        if existing_hash != bounded_text(assistant, MAX_CONTENT_BYTES)[3]:
            record_delivery_error(dirs, eid, "completion_retry_hash_mismatch", payload)
            return {"event_id": eid, "state": "duplicate_conflict"}
        return {"event_id": eid, "state": "duplicate"}
    if pending is None:
        record_delivery_error(dirs, eid, "missing_pending_prompt", payload)
        raise RuntimeError("completed turn has no pending prompt: %s" % eid)
    content, truncated, source_bytes, source_hash = bounded_text(assistant, MAX_CONTENT_BYTES)
    event = {
        "schema_version": SCHEMA_VERSION, "event_id": eid, "thread_id": thread_id, "turn_id": turn_id,
        "submitted_at": pending["submitted_at"],
        "completed_at": normalize_time(str(payload.get("completed_at") or utc_now())),
        "cwd": pending["cwd"], "scope": pending["scope"],
        "speakers": [pending["user"], {
            "role": "assistant", "speaker": "firstmate", "content": content,
            "content_hash": source_hash, "source_bytes": source_bytes, "truncated": truncated,
        }],
        "source": pending["source"],
    }
    event["delivery_hash"] = sha256_bytes(canonical_json(event))
    created = write_once(final_path, canonical_json(event), "capture_after_fsync_before_link")
    try:
        pending_path.unlink()
        fsync_dir(pending_path.parent)
    except FileNotFoundError:
        pass
    return {"event_id": eid, "state": "captured" if created else "duplicate"}


def command_prompt(args: argparse.Namespace) -> int:
    print(json.dumps(stage_pending(brain_home(args), read_stdin_json()), sort_keys=True))
    return 0


def command_complete(args: argparse.Namespace) -> int:
    print(json.dumps(finalize(brain_home(args), read_stdin_json()), sort_keys=True))
    return 0


def command_exchange(args: argparse.Namespace) -> int:
    home = brain_home(args)
    inputs: Iterable[Dict[str, Any]]
    if args.ndjson:
        def records() -> Iterable[Dict[str, Any]]:
            for line in sys.stdin:
                if line.strip():
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise RuntimeError("NDJSON records must be objects")
                    yield value
        inputs = records()
    else:
        inputs = [read_stdin_json()]
    captured = duplicates = 0
    last = None
    for payload in inputs:
        pending = build_pending(payload)
        final_path = scope_dir(event_dirs(home)["inbox"], pending["scope"]) / (pending["event_id"] + ".json")
        if not final_path.exists():
            stage_pending(home, payload)
        result = finalize(home, payload)
        last = result["event_id"]
        if result["state"] == "captured":
            captured += 1
        else:
            duplicates += 1
    print(json.dumps({"captured": captured, "duplicates": duplicates, "last_event_id": last}, sort_keys=True))
    return 0


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home")
    sub = parser.add_subparsers(dest="command", required=True)
    prompt = sub.add_parser("capture-prompt")
    prompt.set_defaults(func=command_prompt)
    complete = sub.add_parser("capture-complete")
    complete.set_defaults(func=command_complete)
    exchange = sub.add_parser("capture-exchange")
    exchange.add_argument("--ndjson", action="store_true")
    exchange.set_defaults(func=command_exchange)
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except Exception as exc:
        print("fm-turn-capture: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
