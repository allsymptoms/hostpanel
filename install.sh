#!/usr/bin/env bash
# install.sh - HostPanel bootstrap installer
# Run on a fresh Linux VPS (Ubuntu/Debian/CentOS/RHEL/Rocky/Alma).
#   curl -fsSL https://your-host/hostpanel/install.sh | sudo bash
# or:  sudo bash install.sh
set -euo pipefail

HOSTPANEL_ROOT="${HOSTPANEL_ROOT:-/opt/hostpanel}"
APP_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ADMIN_PASS="$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash install.sh"; exit 1; }

echo "=== HostPanel installer ==="
echo "Target: $HOSTPANEL_ROOT"
echo "Admin password (save this): $ADMIN_PASS"
echo

# --- Detect package manager ---
if command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf >/dev/null 2>&1; then PM=dnf
elif command -v yum >/dev/null 2>&1; then PM=yum
elif command -v apk >/dev/null 2>&1; then PM=apk
else echo "Unsupported package manager"; exit 1
fi
echo "Package manager: $PM"

install_pkg(){
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf|yum) "$PM" install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
  esac
}

# --- System packages ---
echo "-> Installing system packages"
if [[ "$PM" == "apt" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  install_pkg nginx mysql-server php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip \
    python3 python3-venv python3-pip curl jq unzip sudo certbot python3-certbot-nginx \
    python3-certbot-dns-cloudflare python3-certbot-dns-route53 vsftpd apache2-utils fail2ban ufw nodejs
elif [[ "$PM" == "apk" ]]; then
  install_pkg nginx mysql php php-fpm php-curl php-gd php-mbstring php-xml php-zip \
    python3 py3-pip curl jq unzip sudo certbot vsftpd apache2-utils fail2ban
  install_pkg certbot-dns-cloudflare certbot-dns-route53 2>/dev/null || true
else
  install_pkg nginx mariadb-server php-fpm php-cli php-mysqlnd php-curl php-gd php-mbstring php-xml php-zip \
    python3 python3-pip curl jq unzip sudo certbot vsftpd httpd-tools fail2ban nodejs
  install_pkg certbot-dns-cloudflare certbot-dns-route53 2>/dev/null || true
fi

# --- Enable services ---
echo "-> Enabling services"
systemctl enable nginx mysql php-fpm vsftpd 2>/dev/null || true
systemctl start nginx mysql php-fpm vsftpd 2>/dev/null || service nginx start 2>/dev/null || true

# --- Secure MySQL / create root if needed ---
echo "-> Preparing MySQL"
mysql -u root -e "SELECT 1;" >/dev/null 2>&1 || mysql -u root <<'SQL' 2>/dev/null || true
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;
SQL

# --- Copy panel files ---
echo "-> Installing HostPanel to $HOSTPANEL_ROOT"
mkdir -p "$HOSTPANEL_ROOT"/{scripts,static,config,data,logs,run}
cp -r "$APP_REPO_DIR"/scripts/*.sh "$HOSTPANEL_ROOT/scripts/"
cp -r "$APP_REPO_DIR"/app.py "$HOSTPANEL_ROOT/"
cp -r "$APP_REPO_DIR"/static/* "$HOSTPANEL_ROOT/static/"
chmod +x "$HOSTPANEL_ROOT"/scripts/*.sh

# --- Python deps (venv) ---
echo "-> Setting up Python venv"
python3 -m venv "$HOSTPANEL_ROOT/venv"
"$HOSTPANEL_ROOT/venv/bin/pip" install --quiet --upgrade pip
"$HOSTPANEL_ROOT/venv/bin/pip" install --quiet flask

# --- WP-CLI (optional but recommended) ---
if ! command -v wp >/dev/null 2>&1; then
  echo "-> Installing WP-CLI"
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
fi

# --- systemd service ---
echo "-> Writing systemd unit"
cat > /etc/systemd/system/hostpanel.service <<EOF
[Unit]
Description=HostPanel AI Hosting Control Panel
After=network.target

[Service]
Type=simple
Environment=HOSTPANEL_ROOT=${HOSTPANEL_ROOT}
Environment=HOSTPANEL_ADMIN_PASS=${ADMIN_PASS}
ExecStart=${HOSTPANEL_ROOT}/venv/bin/python ${HOSTPANEL_ROOT}/app.py --host 127.0.0.1
WorkingDirectory=${HOSTPANEL_ROOT}
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hostpanel
systemctl restart hostpanel

# --- Daily monitoring timer (cert expiry + site health) ---
cat > /etc/systemd/system/hostpanel-monitor.service <<EOF
[Unit]
Description=HostPanel site/cert monitor
After=network.target

[Service]
Type=oneshot
Environment=HOSTPANEL_ROOT=${HOSTPANEL_ROOT}
ExecStart=${HOSTPANEL_ROOT}/scripts/monitor.sh
EOF

cat > /etc/systemd/system/hostpanel-monitor.timer <<EOF
[Unit]
Description=Run HostPanel monitor daily

[Timer]
OnCalendar=*-*-* 06:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now hostpanel-monitor.timer 2>/dev/null || true

# --- Done ---
sleep 2
if systemctl is-active --quiet hostpanel; then
  echo
  echo "✅ HostPanel is running at http://<your-server-ip>:8080"
  echo "   Admin password: $ADMIN_PASS"
  echo "   Files: $HOSTPANEL_ROOT"
  echo "   Logs: journalctl -u hostpanel -f"
else
  echo "⚠️  Service may not have started. Check: journalctl -u hostpanel"
fi
