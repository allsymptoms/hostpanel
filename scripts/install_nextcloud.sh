#!/usr/bin/env bash
# install_nextcloud.sh - install Nextcloud (PHP) into a domain's docroot
# Usage: install_nextcloud.sh <username> <domain> <admin_user> <admin_email> [admin_pass]
# Requires a php-type vhost to already exist (create_vhost.sh <user> <domain> php).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"; DOMAIN="${2:-}"; ADMIN_USER="${3:-admin}"; ADMIN_EMAIL="${4:-}"
ADMIN_PASS="${5:-}"

is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
[[ -n "$ADMIN_EMAIL" ]] || fail "Admin email required"
DOCROOT="$(docroot_for_domain "$DOMAIN")"
[[ -n "$DOCROOT" && -d "$DOCROOT" ]] || fail "No vhost/docroot for '$DOMAIN'; run create_vhost first (type=php)"
need_cmd curl; need_cmd unzip

NC_VER="29.0.5"
URL="https://download.nextcloud.com/server/releases/nextcloud-${NC_VER}.zip"
TMPZ="$(mktemp -d)"
log "Downloading Nextcloud $NC_VER"
curl -fsSL "$URL" -o "$TMPZ/nc.zip" || fail "download failed"
unzip -q "$TMPZ/nc.zip" -d "$TMPZ"
cp -a "$TMPZ/nextcloud/." "$DOCROOT/"
chown -R "${USERNAME}:${USERNAME}" "$DOCROOT"

# DB
DB_NAME="nc_${USERNAME}_$(echo "$DOMAIN" | tr -d '.')"; DB_NAME="${DB_NAME:0:64}"
DB_USER="nc_${USERNAME}"; DB_PASS="$(gen_pass 20)"
mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;" 2>/dev/null || fail "could not create DB"
mysql_exec -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>/dev/null || true
mysql_exec -e "GRANT ALL ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>/dev/null || true
mysql_exec -e "FLUSH PRIVILEGES;" 2>/dev/null || true

# Occ (nextcloud CLI) install
if [[ -x "$DOCROOT/occ" ]]; then
  sudo -u "$USERNAME" php "$DOCROOT/occ" maintenance:install \
    --database "mysql" --database-name "$DB_NAME" --database-user "$DB_USER" --database-pass "$DB_PASS" \
    --admin-user "$ADMIN_USER" --admin-pass "${ADMIN_PASS:-$(gen_pass 16)}" --admin-email "$ADMIN_EMAIL" 2>/dev/null \
    || warn "occ install step failed (may need manual setup at /)"
fi

audit "install_nextcloud" "ok" "$DOMAIN"
log "Installed Nextcloud for $DOMAIN"
jq -n --arg status ok --arg domain "$DOMAIN" --arg admin "$ADMIN_USER" \
       --arg db "$DB_NAME" --arg db_user "$DB_USER" --arg db_pass "$DB_PASS" \
  '{status:$status, domain:$domain, admin_user:$admin, database:$db, database_user:$db_user, database_password:$db_pass}'
