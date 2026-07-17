#!/usr/bin/env bash
# create_vhost.sh - create an nginx virtual host for a domain under a user
# Usage: create_vhost.sh <username> <domain> [type] [upstream_port]
#   type: wordpress|php|static|proxy   (default: wordpress)
#   upstream_port: required for type=proxy (the localhost port to proxy to)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"
DOMAIN="${2:-}"
TYPE="${3:-wordpress}"
UPSTREAM_PORT="${4:-}"

is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
id "$USERNAME" &>/dev/null || fail "User '$USERNAME' does not exist; create the user first"
need_cmd nginx

DOCROOT="$(docroot_for "$USERNAME" "$DOMAIN")"
mkdir -p "$DOCROOT"
chown -R "${USERNAME}:${USERNAME}" "$DOCROOT"

mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED"
CONF="${NGINX_AVAILABLE}/${DOMAIN}.conf"
[[ -f "$CONF" ]] && fail "vhost config already exists for '$DOMAIN'"

# --- Build the location/extra block per type ---
EXTRA=""
case "$TYPE" in
  wordpress|php)
    EXTRA=$(cat <<'EOF'
    index index.php index.html;
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }
EOF
)
    ;;
  static)
    EXTRA=$(cat <<'EOF'
    index index.html;
EOF
)
    ;;
  proxy)
    [[ -n "$UPSTREAM_PORT" ]] || fail "type=proxy requires an upstream port (4th arg)"
    EXTRA=$(cat <<EOF
    location / {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
)
    # proxy sites don't serve from docroot
    DOCROOT=""
    ;;
  *)
    fail "Unknown vhost type: '$TYPE' (use wordpress|php|static|proxy)"
    ;;
esac

cat > "$CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
$( [[ -n "$DOCROOT" ]] && echo "    root ${DOCROOT};" )
    ${EXTRA}

    access_log ${USERS_DIR}/${USERNAME}/logs/${DOMAIN}.access.log;
    error_log  ${USERS_DIR}/${USERNAME}/logs/${DOMAIN}.error.log;

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$CONF" "${NGINX_ENABLED}/${DOMAIN}.conf"

nginx -t || { rm -f "${NGINX_ENABLED}/${DOMAIN}.conf"; fail "nginx config test failed"; }
systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null \
  || warn "Could not reload nginx (not running as service?); run 'nginx -s reload' manually"

USERJSON="${CONFIG_DIR}/user_${USERNAME}.json"
if [[ -f "$USERJSON" ]]; then
  TMP=$(mktemp)
  jq --arg d "$DOMAIN" --arg t "$TYPE" '.sites += [$d] | .site_types[$d] = $t' "$USERJSON" > "$TMP" && mv "$TMP" "$USERJSON"
fi

audit "create_vhost" "ok" "$DOMAIN type=$TYPE"
log "Created vhost: $DOMAIN -> ${DOCROOT:-proxy:${UPSTREAM_PORT}} (type=$TYPE)"
jq -n --arg status ok --arg domain "$DOMAIN" --arg type "$TYPE" --arg docroot "${DOCROOT:-}" \
  '{status:$status, domain:$domain, type:$type, docroot:$docroot}'
