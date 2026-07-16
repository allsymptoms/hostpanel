#!/usr/bin/env bash
# setup_fail2ban.sh - install & enable fail2ban with jails for SSH, nginx, and vsftpd
# Protects the panel login (basic-auth via nginx), SSH, and FTP from brute force.
# Usage: setup_fail2ban.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

need_cmd fail2ban-server || need_cmd fail2ban-client || \
  { command -v apt-get >/dev/null && apt-get install -y fail2ban >/dev/null 2>&1; } || \
  { command -v dnf >/dev/null && dnf install -y fail2ban >/dev/null 2>&1; } || \
  { command -v yum >/dev/null && yum install -y fail2ban >/dev/null 2>&1; } || \
  { command -v apk >/dev/null && apk add fail2ban >/dev/null 2>&1; } || \
  fail "Could not install fail2ban"

F2B_DIR="/etc/fail2ban"
mkdir -p "$F2B_DIR/jail.d"

cat > "$F2B_DIR/jail.d/hostpanel.conf" <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
port    = http,https
logpath = /var/log/nginx/error.log

[vsftpd]
enabled = true
port    = ftp,ftp-data
logpath = /var/log/vsftpd.log
EOF

systemctl enable --now fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null \
  || fail2ban-client restart 2>/dev/null || fail "Could not start fail2ban"
sleep 2
fail2ban-client status 2>/dev/null | head -10 || true

audit "setup_fail2ban" "ok" "hostpanel.conf"
log "fail2ban enabled with sshd, nginx-http-auth, vsftpd jails"
jq -n --arg status ok --arg jails "sshd,nginx-http-auth,vsftpd" \
  '{status:$status, jails:$jails}'
