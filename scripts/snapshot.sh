#!/usr/bin/env bash
# snapshot.sh - take a safety backup before a change (global "snapshot-all" or per-site)
# Usage:
#   snapshot.sh all                 # back up every site for every user
#   snapshot.sh <domain>            # back up a single site
# Writes each backup under BACKUP_DIR and records it in the audit log. Returns a
# JSON list of refs created.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

TARGET="${1:-all}"
refs="[]"
if [[ "$TARGET" == "all" ]]; then
  # iterate every vhost conf
  shopt -s nullglob
  for conf in "$NGINX_AVAILABLE"/*.conf; do
    d="$(basename "$conf" .conf)"
    r="$(bash "$(dirname "$0")/backup.sh" "$d" 2>/dev/null | jq -r '.backup_ref // empty')"
    [[ -n "$r" ]] && refs="$(echo "$refs" | jq --arg r "$r" '. + [$r]')"
  done
  shopt -u nullglob
else
  is_valid_domain "$TARGET" || fail "Invalid domain: '$TARGET'"
  r="$(bash "$(dirname "$0")/backup.sh" "$TARGET" 2>/dev/null | jq -r '.backup_ref // empty')"
  [[ -n "$r" ]] && refs="$(echo "$refs" | jq --arg r "$r" '. + [$r]')"
fi

audit "snapshot" "ok" "refs=$(echo "$refs" | jq -c .)"
jq -n --arg status ok --argjson refs "$refs" '{status:$status, refs:$refs}'
