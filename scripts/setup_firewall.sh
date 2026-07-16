#!/usr/bin/env bash
# setup_firewall.sh - configure the host firewall for a hosting panel
# Opens 22 (ssh), 80, 443, 21 + passive FTP range (40000-40100), and the panel proxy.
# Uses ufw (Debian/Ubuntu) or firewalld (RHEL/CentOS). Idempotent.
# Usage: setup_firewall.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

need_cmd iptables || true

if command -v ufw >/dev/null 2>&1; then
  log "Configuring ufw firewall"
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp    # SSH
  ufw allow 80/tcp    # HTTP
  ufw allow 443/tcp   # HTTPS
  ufw allow 21/tcp    # FTP control
  ufw allow 40000:40100/tcp  # FTP passive
  ufw allow 8080/tcp  # panel (behind proxy; harmless to expose if needed)
  ufw --force enable
  ufw status numbered | head -20
  FW="ufw"
elif command -v firewall-cmd >/dev/null 2>&1; then
  log "Configuring firewalld"
  systemctl enable --now firewalld 2>/dev/null || true
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --add-port=21/tcp
  firewall-cmd --permanent --add-port=40000-40100/tcp
  firewall-cmd --permanent --add-port=8080/tcp
  firewall-cmd --reload
  FW="firewalld"
else
  fail "No supported firewall found (need ufw or firewalld)"
fi

audit "setup_firewall" "ok" "$FW"
log "Firewall configured via $FW"
jq -n --arg status ok --arg firewall "$FW" '{status:$status, firewall:$firewall}'
