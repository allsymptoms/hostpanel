#!/usr/bin/env bash
# install_wordpress.sh - install WordPress for a domain under a user
# Usage: install_wordpress.sh <username> <domain> <site_title> <admin_user> <admin_email> [admin_pass]
# If admin_pass omitted, a random one is generated and returned in JSON.
# Emits JSON with all credentials.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"
DOMAIN="${2:-}"
SITE_TITLE="${3:-My WordPress Site}"
ADMIN_USER="${4:-admin}"
ADMIN_EMAIL="${5:-}"
ADMIN_PASS="${6:-}"

is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
[[ -n "$ADMIN_EMAIL" ]] || fail "Admin email is required"
[[ "$ADMIN_EMAIL" =~ ^[^@\ ]+@[^@\ ]+\.[^@\ ]+$ ]] || fail "Invalid admin email: '$ADMIN_EMAIL'"

id "$USERNAME" &>/dev/null || fail "User '$USERNAME' does not exist"
DOCROOT="$(docroot_for "$USERNAME" "$DOMAIN")"
[[ -d "$DOCROOT" ]] || fail "Docroot missing; create vhost first"

need_cmd mysql
need_cmd mysqladmin
need_cmd curl

# --- Database ---
DB_NAME="wp_${USERNAME}_$(echo "$DOMAIN" | tr -d '.')"
DB_NAME="${DB_NAME:0:64}"
DB_USER="wp_${USERNAME}"
DB_PASS="$(gen_pass 20)"

# MySQL root: try socket with sudo first, then root creds from env
mysql_exec() {
  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "$@"
  else
    sudo mysql "$@" 2>/dev/null || mysql -u root "$@"
  fi
}

# Create DB + user (idempotent-ish)
mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;" \
  || fail "Failed to create database '$DB_NAME'"
mysql_exec -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" \
  || fail "Failed to create DB user '$DB_USER'"
mysql_exec -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';" \
  || fail "Failed to grant privileges"
mysql_exec -e "FLUSH PRIVILEGES;"

# --- Download WordPress ---
cd "$DOCROOT"
if [[ ! -f "$DOCROOT/wp-load.php" ]]; then
  log "Downloading WordPress into $DOCROOT"
  curl -fsSL https://wordpress.org/latest.tar.gz -o /tmp/wp.tar.gz \
    || fail "Failed to download WordPress"
  tar -xzf /tmp/wp.tar.gz -C /tmp
  # move contents of wordpress/ into docroot
  cp -a /tmp/wordpress/. "$DOCROOT"/ 2>/dev/null || \
    (shopt -s dotglob; cp -a /tmp/wordpress/* "$DOCROOT"/)
  rm -rf /tmp/wordpress /tmp/wp.tar.gz
fi

# --- wp-config.php ---
if [[ ! -f "$DOCROOT/wp-config.php" ]]; then
  cp "$DOCROOT/wp-config-sample.php" "$DOCROOT/wp-config.php"
  # Inject DB constants
  sed -i "s/^define( *'DB_NAME'.*/define('DB_NAME', '${DB_NAME}');/" "$DOCROOT/wp-config.php"
  sed -i "s/^define( *'DB_USER'.*/define('DB_USER', '${DB_USER}');/" "$DOCROOT/wp-config.php"
  sed -i "s/^define( *'DB_PASSWORD'.*/define('DB_PASSWORD', '${DB_PASS}');/" "$DOCROOT/wp-config.php"
  sed -i "s/^define( *'DB_HOST'.*/define('DB_HOST', 'localhost');/" "$DOCROOT/wp-config.php"

  # Unique auth keys/salts
  SALTS=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ || true)
  if [[ -n "$SALTS" ]]; then
    # Replace the placeholder block
    python3 - "$DOCROOT/wp-config.php" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
start = s.find("define('AUTH_KEY'")
end = s.find("define('NONCE_SALT'")
if start != -1 and end != -1:
    block = s[start:end]
    end += len("define('NONCE_SALT', 'put your unique phrase here');")
    # fetch fresh salts
    import urllib.request
    try:
        salts = urllib.request.urlopen("https://api.wordpress.org/secret-key/1.1/salt/", timeout=20).read().decode()
    except Exception:
        salts = ""
    if salts:
        s = s[:start] + salts + s[end:]
        open(p,'w').write(s)
PY
  fi
fi

chown -R "${USERNAME}:${USERNAME}" "$DOCROOT"

# --- Admin password ---
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(gen_pass 16)"
fi

# --- Run the install ---
# Prefer WP-CLI if present
if command -v wp >/dev/null 2>&1; then
  wp core install --path="$DOCROOT" \
    --url="http://${DOMAIN}" --title="$SITE_TITLE" \
    --admin_user="$ADMIN_USER" --admin_password="$ADMIN_PASS" \
    --admin_email="$ADMIN_EMAIL" --allow-root 2>&1 | tee -a "${LOG_DIR}/provision.log" >&2 \
    || warn "wp core install reported an issue"
else
  # Fallback: use wp-admin/install.php via curl is not reliable; require manual step.
  warn "WP-CLI not found. WordPress files + DB are ready, but run the web install at http://${DOMAIN}/wp-admin/install.php"
fi

log "WordPress installed for $DOMAIN (db=$DB_NAME)"
jq -n \
  --arg status ok \
  --arg domain "$DOMAIN" \
  --arg site_url "http://${DOMAIN}" \
  --arg admin_url "http://${DOMAIN}/wp-admin/" \
  --arg db_name "$DB_NAME" \
  --arg db_user "$DB_USER" \
  --arg db_pass "$DB_PASS" \
  --arg admin_user "$ADMIN_USER" \
  --arg admin_email "$ADMIN_EMAIL" \
  --arg admin_pass "$ADMIN_PASS" \
  '{
    status:$status, domain:$domain, site_url:$site_url, admin_url:$admin_url,
    database:{name:$db_name, user:$db_user, password:$db_pass},
    admin:{user:$admin_user, email:$admin_email, password:$admin_pass}
  }'
