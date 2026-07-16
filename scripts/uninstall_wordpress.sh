#!/usr/bin/env bash
# uninstall_wordpress.sh - remove a WordPress install for a domain (backup-first)
# Usage: uninstall_wordpress.sh <domain> [--no-backup]
# Removes the docroot contents + drops the WP database. The vhost is left in place
# (use delete_vhost.sh to remove it). Backs up first unless --no-backup.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

DOMAIN="${1:-}"
NO_BACKUP=0
[[ "${2:-}" == "--no-backup" ]] && NO_BACKUP=1

is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
VH="$NGINX_AVAILABLE/${DOMAIN}.conf"
[[ -f "$VH" ]] || fail "No vhost config for '$DOMAIN'"

DOCROOT="$(docroot_for_domain "$DOMAIN")"
[[ -n "$DOCROOT" && -f "$DOCROOT/wp-config.php" ]] || fail "No WordPress install at '$DOCROOT'"

BACKUP_REF=""
if [[ "$NO_BACKUP" -eq 0 ]]; then
  BACKUP_REF="$(bash "$(dirname "$0")/backup.sh" "$DOMAIN" 2>/dev/null | jq -r '.backup_ref // empty' 2>/dev/null || true)"
fi

DB="$(wp_db_name "$DOCROOT")"
if [[ -n "$DB" ]]; then
  mysql_exec -e "DROP DATABASE IF EXISTS \`$DB\`;" 2>/dev/null || warn "Could not drop DB '$DB'"
fi

# Remove WP files only (leave the docroot dir)
rm -rf "$DOCROOT"/* "$DOCROOT"/.[!.]* 2>/dev/null || true
log "Removed WordPress files at $DOCROOT"

audit "uninstall_wordpress" "ok" "$DOMAIN backup=$BACKUP_REF"
jq -n --arg status ok --arg domain "$DOMAIN" --arg backup "${BACKUP_REF:-none}" \
  '{status:$status, domain:$domain, backup:$backup}'
