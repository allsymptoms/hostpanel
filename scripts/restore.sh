#!/usr/bin/env bash
# restore.sh - restore a site from a prior backup
# Usage: restore.sh <domain> <backup_ref> [--db-only] [--files-only]
# backup_ref is like "acme.com_20260101-120000" (the dir name under BACKUP_DIR).
# Restores the docroot (and DB if present) for the domain. The vhost must already exist.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

DOMAIN="${1:-}"
REF="${2:-}"
DB_ONLY=0; FILES_ONLY=0
for a in "${@:3}"; do
  [[ "$a" == "--db-only" ]] && DB_ONLY=1
  [[ "$a" == "--files-only" ]] && FILES_ONLY=1
done

is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
[[ -n "$REF" ]] || fail "backup_ref required"
SRC="${BACKUP_DIR}/${REF}"
[[ -d "$SRC" ]] || fail "Backup not found: $SRC"

VH="$NGINX_AVAILABLE/${DOMAIN}.conf"
[[ -f "$VH" ]] || fail "No vhost config for '$DOMAIN'; create the vhost before restoring"

DOCROOT="$(docroot_for_domain "$DOMAIN")"
[[ -n "$DOCROOT" && -d "$DOCROOT" ]] || fail "Docroot not found for '$DOMAIN'"

RESTORED_FILES=0; RESTORED_DB=0

if [[ "$DB_ONLY" -eq 0 ]]; then
  ARCHIVE="${SRC}/${DOMAIN}.tar.gz"
  [[ -f "$ARCHIVE" ]] || fail "Docroot archive missing in backup: $ARCHIVE"
  # Extract into the docroot's parent (archive contains the docroot dir name)
  tar -xzf "$ARCHIVE" -C "$(dirname "$DOCROOT")" \
    || fail "extract failed"
  USERNAME="$(user_for_domain "$DOMAIN")"
  [[ -n "$USERNAME" ]] && chown -R "${USERNAME}:${USERNAME}" "$DOCROOT" 2>/dev/null || true
  RESTORED_FILES=1
  log "Restored docroot for $DOMAIN from $ARCHIVE"
fi

if [[ "$FILES_ONLY" -eq 0 ]]; then
  SQL="${SRC}/${DOMAIN}.sql"
  if [[ -f "$SQL" ]]; then
    # Recreate DB if missing, then import
    DB="$(wp_db_name "$DOCROOT")"
    if [[ -z "$DB" ]]; then
      # Fall back to a deterministic name
      DB="wp_${DOMAIN//./_}"
    fi
    mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$DB\`;" 2>/dev/null || warn "could not ensure DB $DB"
    mysql_exec "$DB" < "$SQL" 2>/dev/null && RESTORED_DB=1 && log "Restored DB '$DB' from $SQL" \
      || warn "DB restore failed"
  fi
fi

audit "restore" "ok" "$DOMAIN ref=$REF files=$RESTORED_FILES db=$RESTORED_DB"
jq -n --arg status ok --arg domain "$DOMAIN" --arg backup_ref "$REF" \
       --argjson files "$RESTORED_FILES" --argjson db "$RESTORED_DB" \
  '{status:$status, domain:$domain, backup_ref:$backup_ref, restored_files:$files, restored_db:$db}'
