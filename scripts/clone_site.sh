#!/usr/bin/env bash
# clone_site.sh - clone a production site to a staging subdomain
# Usage: clone_site.sh <username> <src_domain> <dst_domain> [type]
# Copies the docroot, clones the database (data + a new DB user), and creates a
# vhost for dst_domain (default type = same as source). WordPress: updates the
# siteurl/home in the cloned DB so links resolve on the staging domain.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"; SRC="${2:-}"; DST="${3:-}"; TYPE="${4:-}"
is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
is_valid_domain "$SRC" || fail "Invalid source domain: '$SRC'"
is_valid_domain "$DST" || fail "Invalid dest domain: '$DST'"
SRCDOC="$(docroot_for_domain "$SRC")"
[[ -n "$SRCDOC" && -d "$SRCDOC" ]] || fail "No source docroot for '$SRC'"

# Determine type from source if not given
if [[ -z "$TYPE" ]]; then
  UJ="${CONFIG_DIR}/user_${USERNAME}.json"
  TYPE="$(jq -r --arg d "$SRC" '.site_types[$d] // "wordpress"' "$UJ" 2>/dev/null || echo wordpress)"
fi

# Snapshot source first (safety)
bash "$(dirname "$0")/backup.sh" "$SRC" >/dev/null 2>&1 || warn "source backup failed"

# Create dest vhost (same type; for proxy we can't easily re-proxy, default php/static)
if [[ "$TYPE" == "proxy" ]]; then TYPE="php"; fi
bash "$(dirname "$0")/create_vhost.sh" "$USERNAME" "$DST" "$TYPE" >/dev/null 2>&1 \
  || fail "could not create vhost for $DST"

DSTDOC="$(docroot_for_domain "$DST")"
mkdir -p "$DSTDOC"
cp -a "$SRCDOC/." "$DSTDOC/"
chown -R "${USERNAME}:${USERNAME}" "$DSTDOC"

# Clone DB if source is WordPress
SRC_DB="$(wp_db_name "$SRCDOC")"
if [[ -n "$SRC_DB" ]]; then
  DST_DB="clone_${USERNAME}_$(echo "$DST" | tr -d '.')"; DST_DB="${DST_DB:0:64}"
  DST_USER="clone_${USERNAME}"; DST_PASS="$(gen_pass 20)"
  mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$DST_DB\`;" 2>/dev/null || fail "create clone DB failed"
  mysql_exec -e "CREATE USER IF NOT EXISTS '$DST_USER'@'localhost' IDENTIFIED BY '$DST_PASS';" 2>/dev/null || true
  mysql_exec -e "GRANT ALL ON \`$DST_DB\`.* TO '$DST_USER'@'localhost';" 2>/dev/null || true
  mysql_exec -e "FLUSH PRIVILEGES;" 2>/dev/null || true
  mysql_dump "$SRC_DB" 2>/dev/null | mysql_exec "$DST_DB" 2>/dev/null || warn "DB clone failed"
  # Rewrite siteurl/home in cloned DB
  mysql_exec "$DST_DB" -e "UPDATE wp_options SET option_value='https://$DST' WHERE option_name IN ('siteurl','home');" 2>/dev/null || true
  # Point wp-config at the clone DB
  sed -i "s/DB_NAME', *'[^']*'/DB_NAME', '$DST_DB'/; s/DB_USER', *'[^']*'/DB_USER', '$DST_USER'/; s/DB_PASSWORD', *'[^']*'/DB_PASSWORD', '$DST_PASS'/" "$DSTDOC/wp-config.php" 2>/dev/null || true
  DBINFO="db=$DST_DB user=$DST_USER"
else
  DBINFO="db=none"
fi

audit "clone_site" "ok" "$SRC -> $DST ($DBINFO)"
log "Cloned $SRC to $DST"
jq -n --arg status ok --arg src "$SRC" --arg dst "$DST" --arg docroot "$DSTDOC" --arg db "${DST_DB:-none}" \
  '{status:$status, src:$src, dst:$dst, docroot:$docroot, database:$db}'
