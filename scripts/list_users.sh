#!/usr/bin/env bash
# list_users.sh - output JSON array of all hosting users and their sites
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

OUT="[]"
for f in "${CONFIG_DIR}"/user_*.json; do
  [[ -f "$f" ]] || continue
  OUT=$(echo "$OUT" | jq --argjson u "$(cat "$f")" '. + [$u]')
done
jq -n --argjson users "$OUT" '{status:"ok", users:$users}'
