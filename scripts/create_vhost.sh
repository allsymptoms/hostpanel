#!/usr/bin/env bash
# create_vhost.sh - create an nginx virtual host for a domain under a user
# Usage: create_vhost.sh <username> <domain> [php? default on]
# Requires nginx installed. Emits JSON.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"
DOMAIN="${2:-}"
ENABLE_PHP="${3:-on}"

is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
id "$USERNAME" &>/dev/null || fail "User '$USERNAME' does not exist; create the user first"
need_cmd nginx

DOCROOT="$(docroot_for "$USERNAME")"
mkdir -p "$DOCROOT"
chown -R "${USERNAME}:${USERNAME}" "$DOCROOT"

mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED"

CONF="${NGINX_AVAILABLE}/${DOMAIN}.conf"

if [[ -f "$CONF" ]]; then
  fail "vhost config already exists for '$DOMAIN'"
fi

PHP_BLOCK=""
if [[ "$ENABLE_PHP" == "on" ]]; then
  PHP_BLOCK=$(cat <<'EOF'
    index index.php index.html;
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }
EOF
)
else
  PHP_BLOCK=$(cat <<'EOF'
    index index.html;
EOF
)
fi

cat > "$CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${DOCROOT};
    ${PHP_BLOCK}

    access_log ${USERS_DIR}/${USERNAME}/logs/${DOMAIN}.access.log;
    error_log  ${USERS_DIR}/${USERNAME}/logs/${DOMAIN}.error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$CONF" "${NGINX_ENABLED}/${DOMAIN}.conf"

# Test config before reload
nginx -t || { rm -f "${NGINX_ENABLED}/${DOMAIN}.conf"; fail "nginx config test failed"; }

systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null \
  || warn "Could not reload nginx (not running as service?); run 'nginx -s reload' manually"

# Register site in user json
USERJSON="${CONFIG_DIR}/user_${USERNAME}.json"
if [[ -f "$USERJSON" ]]; then
  TMP=$(mktemp)
  jq --arg d "$DOMAIN" '.sites += [$d]' "$USERJSON" > "$TMP" && mv "$TMP" "$USERJSON"
fi

log "Created vhost: $DOMAIN -> $DOCROOT (php=$ENABLE_PHP)"
jq -n --arg domain "$DOMAIN" --arg docroot "$DOCROOT" --arg status ok \
  '{status:$status, domain:$domain, docroot:$docroot}'
