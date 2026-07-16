#!/usr/bin/env bash
# setup_proxy.sh - put HostPanel behind nginx with HTTP basic auth
# Usage: setup_proxy.sh [admin_user] [admin_password] [public_domain]
# Makes the Flask app bind to 127.0.0.1 only and serves it publicly via nginx
# with auth_basic. This is the recommended way to expose the panel safely.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

ADMIN_USER="${1:-hostpanel}"
ADMIN_PASS="${2:-$(gen_pass 16)}"
PUBLIC_DOMAIN="${3:-}"

need_cmd nginx
need_cmd htpasswd

HTPASSWD_FILE="${CONFIG_DIR}/.htpasswd"
htpasswd -b -c -B "$HTPASSWD_FILE" "$ADMIN_USER" "$ADMIN_PASS"
chmod 640 "$HTPASSWD_FILE"

PROXY_CONF="${NGINX_AVAILABLE}/hostpanel.conf"

# If a public domain with a live cert is provided, use HTTPS; else HTTP on 80.
if [[ -n "$PUBLIC_DOMAIN" && -f "/etc/letsencrypt/live/${PUBLIC_DOMAIN}/fullchain.pem" ]]; then
  cat > "$PROXY_CONF" <<EOF
server {
    listen 80;
    server_name ${PUBLIC_DOMAIN};
    location ^~ /.well-known/acme-challenge/ { root ${USERS_DIR}/_acme; allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name ${PUBLIC_DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${PUBLIC_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    auth_basic "HostPanel";
    auth_basic_user_file ${HTPASSWD_FILE};
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
else
  # Plain HTTP basic auth (recommend adding a cert afterwards via setup_ssl on a domain)
  LISTEN_DOMAIN=""
  [[ -n "$PUBLIC_DOMAIN" ]] && LISTEN_DOMAIN="server_name ${PUBLIC_DOMAIN};"
  cat > "$PROXY_CONF" <<EOF
server {
    listen 80 default_server;
    ${LISTEN_DOMAIN}
    auth_basic "HostPanel";
    auth_basic_user_file ${HTPASSWD_FILE};
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
fi

ln -sf "$PROXY_CONF" "${NGINX_ENABLED}/hostpanel.conf"
nginx -t || fail "nginx proxy config invalid"
systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true

# --- Bind Flask to localhost so it is not directly exposed ---
SVC="/etc/systemd/system/hostpanel.service"
if [[ -f "$SVC" ]]; then
  # Ensure ExecStart binds to 127.0.0.1
  sed -i 's#--host 0.0.0.0#--host 127.0.0.1#' "$SVC"
  if ! grep -q "127.0.0.1" "$SVC"; then
    sed -i 's#app.py#app.py --host 127.0.0.1#' "$SVC"
  fi
  systemctl daemon-reload
  systemctl restart hostpanel 2>/dev/null || true
else
  warn "systemd unit not found; if running manually, start with: python app.py --host 127.0.0.1"
fi

log "Reverse proxy with basic auth configured (user: $ADMIN_USER)"
jq -n --arg status ok --arg admin_user "$ADMIN_USER" --arg password "$ADMIN_PASS" \
       --arg note "Access the panel via nginx (port 80/443). Flask now bound to 127.0.0.1 only." \
  '{status:$status, admin_user:$admin_user, password:$password, note:$note}'
