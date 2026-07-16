#!/usr/bin/env bash
# setup_ssl.sh - issue a Let's Encrypt cert for a domain and enable HTTPS + redirect
# Usage: setup_ssl.sh <domain> [email] [dns_provider]
#   dns_provider: cloudflare | route53 | manual | "" (empty = HTTP-01 webroot)
#
# DNS-01 (cloudflare/route53) needs NO open port 80 and works behind firewalls /
# for wildcard certs. Credentials come from the panel's dnsconfig.json:
#   cloudflare -> {"credentials": "<Cloudflare API token with Zone:DNS edit>"}
#   route53    -> AWS creds in env (AWS_ACCESS_KEY_ID/SECRET/REGION) or instance role
#   manual     -> prints the TXT record for you to add, then completes interactively
#
# HTTP-01 (default, no provider) requires an A record + port 80 reachable and the
# vhost already created (create_vhost.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

DOMAIN="${1:-}"
EMAIL="${2:-}"
DNS_PROVIDER="${3:-}"

is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
need_cmd certbot
need_cmd nginx

CONF="${NGINX_AVAILABLE}/${DOMAIN}.conf"
[[ -f "$CONF" ]] || fail "vhost not found for '$DOMAIN'; run create_vhost.sh first"

WEBROOT="${USERS_DIR}/_acme"   # shared webroot for ACME HTTP-01 challenges

# ---------------------------------------------------------------------------
# Determine the challenge method
# ---------------------------------------------------------------------------
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

CERTOUT=$(mktemp)
EMAIL_ARGS=""
if [[ -n "$EMAIL" ]]; then
  EMAIL_ARGS="--agree-tos -m $EMAIL"
else
  EMAIL_ARGS="--agree-tos --register-unsafely-without-email"
fi

if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
  # Read token from panel dnsconfig
  DNSCONF="${CONFIG_DIR}/dnsconfig.json"
  [[ -f "$DNSCONF" ]] || fail "No DNS config. Set it in the panel (⚙ DNS) or pass credentials."
  TOKEN="$(jq -r '.credentials // empty' "$DNSCONF" 2>/dev/null)"
  [[ -n "$TOKEN" ]] || fail "Cloudflare API token missing in dnsconfig.json"
  INI="${CONFIG_DIR}/cloudflare.ini"
  printf 'dns_cloudflare_api_token = %s\n' "$TOKEN" > "$INI"
  chmod 600 "$INI"
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$INI" \
    -d "$DOMAIN" --non-interactive $EMAIL_ARGS --expand 2>&1 | tee "$CERTOUT" \
    || fail "certbot (cloudflare DNS) failed: $(tail -4 $CERTOUT)"

elif [[ "$DNS_PROVIDER" == "route53" ]]; then
  # certbot-dns-route53 uses AWS creds / instance role automatically
  certbot certonly --dns-route53 -d "$DOMAIN" \
    --non-interactive $EMAIL_ARGS --expand 2>&1 | tee "$CERTOUT" \
    || fail "certbot (route53 DNS) failed: $(tail -4 $CERTOUT)"

elif [[ "$DNS_PROVIDER" == "manual" ]]; then
  # Interactive DNS-01: certbot prints the TXT record; operator adds it, then certbot
  # continues. This is the only mode that needs a human at the keyboard.
  certbot certonly --manual --preferred-challenges dns -d "$DOMAIN" \
    --non-interactive $EMAIL_ARGS --expand 2>&1 | tee "$CERTOUT" \
    || fail "certbot (manual DNS) failed: $(tail -4 $CERTOUT)"

else
  # HTTP-01 webroot fallback (needs port 80 + A record)
  mkdir -p "$WEBROOT/.well-known/acme-challenge"
  chown -R www-data:www-data "$WEBROOT" 2>/dev/null || chown -R nginx:nginx "$WEBROOT" 2>/dev/null || true
  # Ensure the vhost has the ACME webroot location block
  if ! grep -q "well-known/acme-challenge" "$CONF"; then
    TMP=$(mktemp)
    awk '
      /server \{/ { depth=1 }
      {
        if ($0 ~ /^}/ && depth==1 && !inserted) {
          print "    location ^~ /.well-known/acme-challenge/ { root '"$WEBROOT"'; allow all; }"
          inserted=1
        }
        print
      }
    ' "$CONF" > "$TMP" && mv "$TMP" "$CONF"
  fi
  nginx -t || fail "nginx config invalid before cert request"
  systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
    --non-interactive $EMAIL_ARGS --expand 2>&1 | tee "$CERTOUT" \
    || fail "certbot (webroot) failed: $(tail -4 $CERTOUT)"
fi

[[ -f "$CERT" && -f "$KEY" ]] || fail "cert files not found after issuance"

# ---------------------------------------------------------------------------
# Rewrite the vhost: add 443 server block + redirect
# ---------------------------------------------------------------------------
TMP=$(mktemp)
DOCROOT=$(grep -m1 '^\s*root' "$CONF" | awk '{print $2}' | tr -d ';')

PHP_BLOCK=""
if grep -q "fastcgi_pass" "$CONF"; then
  PHP_BLOCK=$(cat <<'EOF'
        index index.php index.html;
        location ~ \.php$ {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/run/php/php-fpm.sock;
        }
EOF
)
else
  PHP_BLOCK="        index index.html;"
fi

cat > "$TMP" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    location ^~ /.well-known/acme-challenge/ { root ${WEBROOT}; allow all; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;

    root ${DOCROOT};
    ${PHP_BLOCK}

    access_log ${USERS_DIR}/*/logs/${DOMAIN}.access.log;
    error_log  ${USERS_DIR}/*/logs/${DOMAIN}.error.log;

    location / { try_files \$uri \$uri/ =404; }
    location ~ /\.ht { deny all; }
}
EOF
mv "$TMP" "$CONF"
ln -sf "$CONF" "${NGINX_ENABLED}/${DOMAIN}.conf"

nginx -t || fail "nginx config invalid after SSL setup"
systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true

METHOD="${DNS_PROVIDER:-webroot}"
log "SSL enabled for $DOMAIN (method=$METHOD)"
jq -n --arg status ok --arg domain "$DOMAIN" --arg method "$METHOD" \
       --arg cert "$CERT" --arg key "$KEY" \
  '{status:$status, domain:$domain, method:$method, https:"https://${DOMAIN}", certificate:$cert, private_key:$key, note:"Auto-renews via certbot timer"}'
