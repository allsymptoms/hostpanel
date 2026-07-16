#!/usr/bin/env bash
# delete_vhost.sh - remove an nginx virtual host for a domain (with backup-first)
# Usage: delete_vhost.sh <domain> [--no-backup]
# Backs up the site (docroot + DB) to BACKUP_DIR before removing, unless --no-backup.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

DOMAIN="${1:-}"
NO_BACKUP=0
[[ "${2:-}" == "--no-backup" ]] && NO_BACKUP=1

is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
VH="$NGINX_AVAILABLE/${DOMAIN}.conf"
[[ -f "$VH" ]] || fail "No vhost config for '$DOMAIN'"

USERNAME="$(user_for_domain "$DOMAIN")"
DOCROOT="$(docroot_for_domain "$DOMAIN")"
BACKUP_REF=""

if [[ "$NO_BACKUP" -eq 0 ]]; then
  if [[ -n "$DOCROOT" && -d "$DOCROOT" ]]; then
    log "Backing up site '$DOMAIN' before deletion"
    BACKUP_REF="$(bash "$(dirname "$0")/backup.sh" "$DOMAIN" 2>/dev/null | jq -r '.backup_ref // empty' 2>/dev/null || true)"
  fi
fi

# Drop the DB if this was a WordPress site
if [[ -n "$DOCROOT" && -f "$DOCROOT/wp-config.php" ]]; then
  DB="$(wp_db_name "$DOCROOT")"
  if [[ -n "$DB" ]]; then
    log "Dropping database '$DB'"
    mysql_exec -e "DROP DATABASE IF EXISTS \`$DB\`;" 2>/dev/null || warn "Could not drop DB '$DB' (maybe already gone)"
  fi
fi

# Disable + remove vhost
rm -f "${NGINX_ENABLED}/${DOMAIN}.conf"
rm -f "$VH"
nginx -t 2>/dev/null && (systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true) \
  || warn "nginx reload skipped/failed"

# Remove from user json sites list
if [[ -n "$USERNAME" ]]; then
  UJ="${CONFIG_DIR}/user_${USERNAME}.json"
  [[ -f "$UJ" ]] && jq --arg d "$DOMAIN" '(.sites //= []) | .sites -= [$d]' "$UJ" > "$UJ.tmp" && mv "$UJ.tmp" "$UJ"
fi

audit "delete_vhost" "ok" "$DOMAIN backup=$BACKUP_REF"
log "Deleted vhost: $DOMAIN"
jq -n --arg status ok --arg domain "$DOMAIN" --arg backup "${BACKUP_REF:-none}" \
  '{status:$status, domain:$domain, backup:$backup}'
