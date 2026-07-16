#!/usr/bin/env bash
# backup.sh - back up a site's docroot + database to a timestamped archive
# Usage: backup.sh <domain> [note]
# Writes tar.gz + optional .sql to BACKUP_DIR/<domain>_<timestamp>/
# Emits JSON: {status, domain, backup_ref, archive, db_dump, size}
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

DOMAIN="${1:-}"
NOTE="${2:-}"
is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"

VH="$NGINX_AVAILABLE/${DOMAIN}.conf"
[[ -f "$VH" ]] || fail "No vhost config for '$DOMAIN'"

DOCROOT="$(docroot_for_domain "$DOMAIN")"
[[ -n "$DOCROOT" && -d "$DOCROOT" ]] || fail "Docroot not found for '$DOMAIN'"

TS="$(date +%Y%m%d-%H%M%S)"
REF="${DOMAIN}_${TS}"
DEST="${BACKUP_DIR}/${REF}"
mkdir -p "$DEST"

# Archive docroot
ARCHIVE="${DEST}/${DOMAIN}.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$DOCROOT")" "$(basename "$DOCROOT")" \
  || fail "tar of docroot failed"
log "Backed up docroot for $DOMAIN -> $ARCHIVE"

DB_DUMP=""
if [[ -f "$DOCROOT/wp-config.php" ]]; then
  DB="$(wp_db_name "$DOCROOT")"
  if [[ -n "$DB" ]]; then
    DB_DUMP="${DEST}/${DOMAIN}.sql"
    if mysql_dump "$DB" > "$DB_DUMP" 2>/dev/null; then
      log "Backed up database '$DB' -> $DB_DUMP"
    else
      warn "DB dump failed for '$DB'; docroot backup still saved"
      DB_DUMP=""
    fi
  fi
fi

SIZE="$(du -sh "$DEST" | cut -f1)"
audit "backup" "ok" "$DOMAIN ref=$REF note=$NOTE"
jq -n --arg status ok --arg domain "$DOMAIN" --arg backup_ref "$REF" \
       --arg archive "$ARCHIVE" --arg db_dump "${DB_DUMP:-none}" --arg size "$SIZE" \
  '{status:$status, domain:$domain, backup_ref:$backup_ref, archive:$archive, db_dump:$db_dump, size:$size}'
