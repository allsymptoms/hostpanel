#!/usr/bin/env bash
# delete_user.sh - remove a hosting user and all their sites (backup-first)
# Usage: delete_user.sh <username> [--no-backup]
# Backs up every site for the user, disables vhosts, drops WP databases, removes the
# system user + home + panel records. Use with care; backs up by default.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"
NO_BACKUP=0
[[ "${2:-}" == "--no-backup" ]] && NO_BACKUP=1

is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
id "$USERNAME" &>/dev/null || fail "User '$USERNAME' does not exist"
UJ="${CONFIG_DIR}/user_${USERNAME}.json"
[[ -f "$UJ" ]] || fail "No panel record for '$USERNAME'"

SITES=($(jq -r '.sites[]?' "$UJ"))

if [[ "$NO_BACKUP" -eq 0 && ${#SITES[@]} -gt 0 ]]; then
  log "Backing up all sites for $USERNAME before deletion"
  for s in "${SITES[@]}"; do
    bash "$(dirname "$0")/delete_vhost.sh" "$s" 2>/dev/null \
      || warn "delete_vhost failed for $s"
  done
fi

# Remove any remaining vhosts for this user (in case sites list was stale)
for conf in "$NGINX_AVAILABLE"/*".conf"; do
  [[ -f "$conf" ]] || continue
  if grep -q "/users/${USERNAME}/www" "$conf" 2>/dev/null; then
    d="$(basename "$conf" .conf)"
    rm -f "${NGINX_ENABLED}/${d}.conf" "$conf"
  fi
done
nginx -t 2>/dev/null && (systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true) \
  || warn "nginx reload skipped/failed"

# Remove system user + home
userdel -r "$USERNAME" 2>/dev/null || warn "userdel failed for '$USERNAME'"
rm -rf "${USERS_DIR}/${USERNAME}"
rm -f "$UJ"

audit "delete_user" "ok" "$USERNAME sites=${#SITES[@]}"
log "Deleted hosting user: $USERNAME"
jq -n --arg status ok --arg username "$USERNAME" --arg sites "${#SITES[@]}" \
  '{status:$status, username:$username, sites_removed:($sites|tonumber)}'
