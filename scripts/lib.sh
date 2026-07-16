#!/usr/bin/env bash
# lib.sh - shared helpers for HostPanel provisioning scripts
# Sourced by every script. Not executable on its own.

set -euo pipefail

# --- Paths ---
HOSTPANEL_ROOT="${HOSTPANEL_ROOT:-/opt/hostpanel}"
CONFIG_DIR="${HOSTPANEL_ROOT}/config"
USERS_DIR="${HOSTPANEL_ROOT}/users"
LOG_DIR="${HOSTPANEL_ROOT}/logs"
RUN_DIR="${HOSTPANEL_ROOT}/run"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

# --- Logging ---
# Logs go to the log file + stderr ONLY (never stdout), so scripts can emit
# clean machine-readable JSON on stdout for the backend to parse.
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "${LOG_DIR}/provision.log" >&2; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "${LOG_DIR}/provision.log" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "${LOG_DIR}/provision.log" >&2; }

# --- Cleanup trap on error ---
fail() { err "$1"; exit 1; }

# --- Validate a domain name (basic RFC-ish check) ---
is_valid_domain() {
  local d="$1"
  [[ -z "$d" ]] && return 1
  # allow idn-ish: letters, digits, dots, hyphen; no leading/trailing hyphen per label
  if [[ ! "$d" =~ ^[a-zA-Z0-9](([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    return 1
  fi
  return 0
}

# --- Validate unix username ---
is_valid_user() {
  local u="$1"
  [[ -z "$u" ]] && return 1
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# --- Check a command exists ---
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

# --- Generate a random password ---
gen_pass() {
  local len="${1:-16}"
  tr -dc 'A-Za-z0-9!@#%^&*()-_=+' < /dev/urandom | head -c "$len"
  echo
}

# --- Detect web server docroot layout ---
docroot_for() {
  local user="$1"
  echo "${USERS_DIR}/${user}/www"
}

# Ensure required runtime dirs exist (called by scripts that run as root)
ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$USERS_DIR" "$LOG_DIR" "$RUN_DIR"
}
