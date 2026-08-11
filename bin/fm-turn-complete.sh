#!/usr/bin/env bash
# Chain the supervision Stop guard and capture only a genuinely completed turn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

printf '%s' "$payload" | "$SCRIPT_DIR/fm-turnend-guard.sh"
guard_status=$?
[ "$guard_status" -eq 0 ] || exit "$guard_status"

# Capture failures are reported by Brainkeeper health.  They must not add a
# continuation model call or suppress an already completed response.
printf '%s' "$payload" | "$SCRIPT_DIR/fm-turn-capture.sh" complete >/dev/null 2>&1 || true
exit 0
