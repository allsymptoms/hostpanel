#!/usr/bin/env bash
# show_activity.sh - tail the audit log for the activity feed
# Usage: show_activity.sh [lines default 20]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

N="${1:-20}"
AUDIT_FILE="${LOG_DIR}/audit.log"
if [[ ! -f "$AUDIT_FILE" ]]; then
  jq -n --arg status ok --argjson entries '[]' '{status:$status, entries:[]}'
  exit 0
fi

# newest first, parse TSV into JSON entries
entries="[]"
while IFS=$'\t' read -r ts action result args; do
  [[ -z "$ts" ]] && continue
  entries="$(echo "$entries" | jq --arg ts "$ts" --arg a "$action" --arg r "$result" --arg x "$args" \
    '. + [{time:$ts, action:$a, result:$r, args:$x}]')"
done < <(tail -n "$N" "$AUDIT_FILE" | tac)

jq -n --arg status ok --argjson entries "$entries" '{status:$status, entries:$entries}'
