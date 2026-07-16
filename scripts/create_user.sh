#!/usr/bin/env bash
# create_user.sh - create a system hosting user (jailed-ish: own home + www dir)
# Usage: create_user.sh <username> [shell? default /usr/sbin/nologin]
# Emits JSON to stdout on success so the backend can parse it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

USERNAME="${1:-}"
SHELL_ARG="${2:-/usr/sbin/nologin}"

is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME' (lowercase, 1-32 chars, [a-z0-9_-])"
if id "$USERNAME" &>/dev/null; then
  fail "User '$USERNAME' already exists"
fi

need_cmd useradd

# Create user with home, no login shell by default (FTP/SSH can be enabled later)
useradd --create-home --shell "$SHELL_ARG" --skel /dev/null "$USERNAME" \
  || fail "useradd failed for '$USERNAME'"

# Hosting directories
mkdir -p "${USERS_DIR}/${USERNAME}/www"
mkdir -p "${USERS_DIR}/${USERNAME}/logs"
chown -R "${USERNAME}:${USERNAME}" "${USERS_DIR}/${USERNAME}"
chmod 755 "${USERS_DIR}/${USERNAME}"

# Record user in panel db
jq -n --arg u "$USERNAME" --arg created "$(date -Iseconds)" \
  '{username:$u, created:$created, sites:[]}' \
  > "${CONFIG_DIR}/user_${USERNAME}.json"

log "Created hosting user: $USERNAME"
jq -n --arg username "$USERNAME" \
       --arg home "/home/$USERNAME" \
       --arg www "${USERS_DIR}/${USERNAME}/www" \
       --arg status "ok" \
  '{status:$status, username:$username, home:$home, docroot:$www}'
