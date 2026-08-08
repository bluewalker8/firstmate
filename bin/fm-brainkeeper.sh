#!/usr/bin/env bash
# Brainkeeper-only entry point for extraction, promotion, compile, query, health,
# and rollback.  Firstmate hooks never invoke this script.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
ENGINE="$FM_ROOT/libexec/fm_brain.py"
FIXTURE="$FM_ROOT/tests/fixtures/brainkeeper-orchestration.json"

command -v python3 >/dev/null 2>&1 || {
  printf 'fm-brainkeeper: python3 is required\n' >&2
  exit 1
}
[ -f "$ENGINE" ] || {
  printf 'fm-brainkeeper: engine missing: %s\n' "$ENGINE" >&2
  exit 1
}

if [ -z "${FM_BRAIN_VAULT:-}" ] && [ -f "$FM_HOME/config/brain-vault" ]; then
  IFS= read -r FM_BRAIN_VAULT < "$FM_HOME/config/brain-vault" || true
  export FM_BRAIN_VAULT
fi
if [ -z "${FM_BRAIN_VAULT:-}" ]; then
  encoded_home=${HOME//\//-}
  canonical_vault="$HOME/.claude/projects/$encoded_home/memory"
  if [ -d "$canonical_vault/.obsidian" ]; then
    FM_BRAIN_VAULT=$canonical_vault
    export FM_BRAIN_VAULT
  fi
fi

command_name=${1:-}
[ -n "$command_name" ] || {
  printf 'usage: fm-brainkeeper.sh {drain|serve|query|rollback|health|rebuild|evaluate} [arguments]\n' >&2
  exit 64
}
shift

export FM_BRAINKEEPER_ROLE=1

case "$command_name" in
  drain|serve|evaluate)
    if [ -n "${FM_BRAIN_HOME:-}" ]; then
      exec python3 "$ENGINE" --home "$FM_BRAIN_HOME" "$command_name" "$@" --evaluation-fixture "$FIXTURE"
    fi
    exec python3 "$ENGINE" "$command_name" "$@" --evaluation-fixture "$FIXTURE"
    ;;
  query|rollback|health|rebuild)
    if [ -n "${FM_BRAIN_HOME:-}" ]; then
      exec python3 "$ENGINE" --home "$FM_BRAIN_HOME" "$command_name" "$@"
    fi
    exec python3 "$ENGINE" "$command_name" "$@"
    ;;
  *)
    printf 'usage: fm-brainkeeper.sh {drain|serve|query|rollback|health|rebuild|evaluate} [arguments]\n' >&2
    exit 64
    ;;
esac
