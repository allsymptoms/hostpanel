#!/usr/bin/env bash
# list_backups.sh - list available backups under BACKUP_DIR
# Usage: list_backups.sh [domain]
# Emits JSON: {status, backups:[{ref, domain, size, when}]}
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

FILTER="${1:-}"
mkdir -p "$BACKUP_DIR"

out="[]"
while IFS= read -r d; do
  [[ -d "$d" ]] || continue
  ref="$(basename "$d")"
  dom="${ref%%_*}"
  [[ -n "$FILTER" && "$dom" != "$FILTER" ]] && continue
  size="$(du -sh "$d" 2>/dev/null | cut -f1)"
  # timestamp embedded after first underscore
  ts="${ref#*_}"
  out="$(echo "$out" | jq --arg ref "$ref" --arg domain "$dom" --arg size "$size" --arg when "$ts" \
    '. + [{ref:$ref, domain:$domain, size:$size, when:$when}]')"
done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

jq -n --arg status ok --argjson backups "$out" '{status:$status, backups:$backups}'
