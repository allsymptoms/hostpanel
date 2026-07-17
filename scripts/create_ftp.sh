#!/usr/bin/env bash
# create_ftp.sh - create an FTP account jailed to a user's web docroot
# Usage: create_ftp.sh <username> <domain> <ftp_user> [ftp_password]
# If ftp_password omitted, a random one is generated and returned in JSON.
# Uses vsftpd with a virtual-user db (PAM) mapped to the hosting system user,
# chrooted to the site docroot. The hosting user's login shell stays nologin,
# so this grants FTP only (no SSH).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"
DOMAIN="${2:-}"
FTP_USER="${3:-}"
FTP_PASS="${4:-}"

is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
is_valid_domain "$DOMAIN" || fail "Invalid domain: '$DOMAIN'"
[[ -n "$FTP_USER" ]] || fail "ftp_user is required"
is_valid_user "$FTP_USER" || fail "Invalid ftp_user: '$FTP_USER'"

id "$USERNAME" &>/dev/null || fail "Hosting user '$USERNAME' does not exist"
DOCROOT="$(docroot_for "$USERNAME" "$DOMAIN")"
[[ -d "$DOCROOT" ]] || fail "Docroot missing for '$USERNAME'"

need_cmd vsftpd
need_cmd htpasswd

VSFTPD_CONF="/etc/vsftpd.conf"
VUSER_DB="/etc/vsftpd/virtual_users"
VUSER_DIR="/etc/vsftpd/virtual"
mkdir -p "$(dirname "$VUSER_DB")" "$VUSER_DIR"

# Detect public IP for passive FTP (best-effort)
SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || curl -fsSL https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
[[ -n "$SERVER_IP" ]] || SERVER_IP="__SERVER_IP__"

# --- One-time vsftpd base config (idempotent) ---
if ! grep -q "HostPanel-managed" "$VSFTPD_CONF" 2>/dev/null; then
  # Preserve any existing listen settings; append our managed block
  cat >> "$VSFTPD_CONF" <<'EOF'

# === HostPanel-managed ===
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
guest_enable=YES
guest_username=nobody
virtual_use_local_privs=YES
pam_service_name=vsftpd_virtual
user_sub_token=$USER
local_root=/opt/hostpanel/users/$USER/www
user_config_dir=/etc/vsftpd/virtual
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
pasv_address=__SERVER_IP__
EOF
  sed -i "s/__SERVER_IP__/${SERVER_IP}/" "$VSFTPD_CONF"

  # PAM module for virtual users
  cat > /etc/pam.d/vsftpd_virtual <<'EOF'
auth required pam_pwdfile.so pwdfile=/etc/vsftpd/virtual_users
account required pam_permit.so
EOF

  # Open passive ports in the firewall if ufw is present
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 40000:40100/tcp 2>/dev/null || true
    ufw allow 21/tcp 2>/dev/null || true
  fi
fi

# --- Create / update the virtual user password ---
if [[ -z "$FTP_PASS" ]]; then
  FTP_PASS="$(gen_pass 16)"
fi
# htpasswd with -b -c creates/updates; -c only on first user
if [[ ! -f "$VUSER_DB" ]]; then
  htpasswd -b -c -B "$VUSER_DB" "$FTP_USER" "$FTP_PASS"
else
  htpasswd -b -B "$VUSER_DB" "$FTP_USER" "$FTP_PASS"
fi

# --- Per-user config: map to the real hosting user + docroot ---
cat > "${VUSER_DIR}/${FTP_USER}" <<EOF
guest_username=${USERNAME}
local_root=${DOCROOT}
EOF

# Ensure docroot owned by hosting user (ftp guest writes as that uid)
chown -R "${USERNAME}:${USERNAME}" "$DOCROOT"

# Restart vsftpd
systemctl restart vsftpd 2>/dev/null || service vsftpd restart 2>/dev/null \
  || fail "Could not (re)start vsftpd"

log "FTP user '$FTP_USER' created for $DOMAIN (jailed to $DOCROOT)"
jq -n --arg status ok --arg ftp_user "$FTP_USER" --arg password "$FTP_PASS" \
       --arg domain "$DOMAIN" --arg docroot "$DOCROOT" \
  '{status:$status, ftp_user:$ftp_user, password:$password, domain:$domain, docroot:$docroot, note:"FTP jailed to site docroot; no SSH access"}'
