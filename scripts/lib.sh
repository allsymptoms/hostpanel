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
NGINX_AVAILABLE="${NGINX_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/sites-enabled}"

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

# --- Audit log (every provisioning action, who/what/when) ---
# Append-only, root-only readable. Format: ISO8601<TAB>action<TAB>args<TAB>result
AUDIT_FILE="${LOG_DIR}/audit.log"
audit() {
  local action="$1" result="$2"; shift 2
  local args="$*"
  echo -e "$(date -Iseconds)\t${action}\t${result}\t${args}" >> "$AUDIT_FILE" 2>/dev/null || true
}

# --- Emit a JSON result on stdout, log line to stderr/logfile ---
# Usage: emit_json '{"status":"ok",...}'   (logs the same to the audit/provision log)
emit_json() {
  local json="$1"
  echo "$json"
}

# --- Resolve which hosting user owns a given domain (reads vhost conf) ---
user_for_domain() {
  local domain="$1"
  local vh="$NGINX_AVAILABLE/${domain}.conf"
  [[ -f "$vh" ]] || { echo ""; return 1; }
  # docroot like /opt/hostpanel/users/<user>/www/<domain>
  sed -n 's@.*root[[:space:]]*/opt/hostpanel/users/\([a-z_][a-z0-9_-]*\)/www.*@\1@p' "$vh" | head -1
}

# --- Resolve a domain's docroot from its vhost conf ---
docroot_for_domain() {
  local domain="$1"
  local vh="$NGINX_AVAILABLE/${domain}.conf"
  [[ -f "$vh" ]] || { echo ""; return 1; }
  sed -n 's@.*root[[:space:]]*\(/[^;]*\);.*@\1@p' "$vh" | head -1
}

# --- Look up a site's MySQL DB name from its wp-config (if WP) ---
wp_db_name() {
  local docroot="$1"
  [[ -f "$docroot/wp-config.php" ]] || { echo ""; return 1; }
  sed -n "s/.*DB_NAME',[[:space:]]*'\([^']*\)'.*/\1/p" "$docroot/wp-config.php" | head -1
}

# --- Backup storage root ---
BACKUP_DIR="${HOSTPANEL_ROOT}/backups"

# --- Run a MySQL statement as admin (socket w/ sudo, or root password from env) ---
mysql_exec() {
  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "$@"
  else
    sudo mysql "$@" 2>/dev/null || mysql -u root "$@" 2>/dev/null \
      || mysql -e "" "$@" 2>/dev/null || { echo "mysql_exec: could not connect" >&2; return 1; }
  fi
}

# --- Dump a single database to stdout (admin) ---
mysql_dump() {
  local db="$1"
  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" --single-transaction "$db"
  else
    sudo mysqldump "$db" --single-transaction 2>/dev/null || mysqldump -u root "$db" --single-transaction 2>/dev/null \
      || { echo "mysql_dump: could not dump $db" >&2; return 1; }
  fi
}
