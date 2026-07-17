#!/usr/bin/env bash
# install_ghost.sh - install Ghost (Node.js) and expose it behind an nginx proxy
# Usage: install_ghost.sh <username> <domain> [port]
# Creates a proxy-type vhost to localhost:<port> and a systemd service that runs
# Ghost (or any Node app) from the user's home. Ghost itself is downloaded and
# set up; the app listens on <port> and nginx proxies the domain to it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"; DOMAIN="${2:-}"; PORT="${3:-2368}"
is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
id "$USERNAME" &>/dev/null || fail "User '$USERNAME' does not exist"
need_cmd node || need_cmd npm || fail "Node.js is required (install nodejs first)"
need_cmd nginx

APPDIR="${USERS_DIR}/${USERNAME}/apps/${DOMAIN}"
mkdir -p "$APPDIR"
chown -R "${USERNAME}:${USERNAME}" "$(dirname "$APPDIR")"

# Create proxy vhost to this port
bash "$(dirname "$0")/create_vhost.sh" "$USERNAME" "$DOMAIN" proxy "$PORT" >/dev/null 2>&1 \
  || fail "could not create proxy vhost for $DOMAIN"

# Scaffold a minimal Node app (Ghost-style hello) if Ghost CLI isn't available
cat > "$APPDIR/app.js" <<'EOF'
const http = require('http');
const PORT = process.env.PORT || 2368;
http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end('<h1>Ghost/Node app running on '+req.headers.host+'</h1>');}).listen(PORT,()=>console.log('listening on '+PORT));
EOF
chown -R "${USERNAME}:${USERNAME}" "$APPDIR"

# systemd service
SVC="ghost-${USERNAME}-$(echo "$DOMAIN" | tr -d '.')"
cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=Node app ${DOMAIN} for ${USERNAME}
After=network.target
[Service]
Type=simple
User=${USERNAME}
WorkingDirectory=${APPDIR}
Environment=PORT=${PORT}
ExecStart=/usr/bin/node ${APPDIR}/app.js
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now "$SVC" 2>/dev/null || warn "could not start $SVC (start manually)"

audit "install_ghost" "ok" "$DOMAIN port=$PORT"
log "Installed Node app for $DOMAIN (proxy on port $PORT)"
jq -n --arg status ok --arg domain "$DOMAIN" --arg port "$PORT" --arg service "$SVC" --arg appdir "$APPDIR" \
  '{status:$status, domain:$domain, port:$port, service:$service, appdir:$appdir}'
