#!/usr/bin/env bash
# Read-only exact-scope decision context compiler for thin Firstmate agents.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
ENGINE="$FM_ROOT/libexec/fm_brain.py"

command -v python3 >/dev/null 2>&1 || {
  printf 'fm-brain-context: python3 is required\n' >&2
  exit 1
}
[ -f "$ENGINE" ] || {
  printf 'fm-brain-context: engine missing: %s\n' "$ENGINE" >&2
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

if [ -n "${FM_BRAIN_HOME:-}" ]; then
  exec python3 "$ENGINE" --home "$FM_BRAIN_HOME" context "$@"
fi
exec python3 "$ENGINE" context "$@"
