#!/usr/bin/env bash
# db_manage.sh - manage MySQL databases for a hosting user
# Usage:
#   db_manage.sh create <username> <dbname> [dbuser] [dbpass]
#   db_manage.sh list <username>            # list DBs owned by the user
#   db_manage.sh dump <username> <dbname>   # dump to a backup file, return path
#   db_manage.sh resetpw <username> <dbname> <dbuser>   # rotate the db user password
# Naming convention: db names prefixed wp_/nc_ per app; this script accepts any
# name and scopes grants to localhost for the given db user.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs

ACTION="${1:-}"; USERNAME="${2:-}"; shift 2 2>/dev/null || true
is_valid_user "$USERNAME" || fail "Invalid username: '$USERNAME'"
id "$USERNAME" &>/dev/null || fail "User '$USERNAME' does not exist"

case "$ACTION" in
  create)
    DB="${1:-}"; DBUSER="${2:-${DB}}"; DBPASS="${3:-$(gen_pass 20)}"
    [[ -n "$DB" ]] || fail "db name required"
    mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$DB\`;" 2>/dev/null || fail "create DB failed"
    mysql_exec -e "CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';" 2>/dev/null || true
    mysql_exec -e "GRANT ALL ON \`$DB\`.* TO '$DBUSER'@'localhost';" 2>/dev/null || fail "grant failed"
    mysql_exec -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    audit "db_create" "ok" "$DB user=$DBUSER"
    jq -n --arg status ok --arg action create --arg database "$DB" --arg db_user "$DBUSER" --arg db_pass "$DBPASS" \
      '{status:$status, action:$action, database:$database, db_user:$db_user, db_password:$db_pass}'
    ;;
  list)
    OUT=$(mysql_exec -e "SHOW DATABASES;" 2>/dev/null | grep -vE "^(Database|information_schema|performance_schema|mysql|sys)$" || true)
    dbs="[]"
    while IFS= read -r d; do [[ -z "$d" ]] && continue; dbs=$(echo "$dbs" | jq --arg d "$d" '. + [$d]'); done <<< "$OUT"
    jq -n --arg status ok --arg action list --argjson databases "$dbs" '{status:$status, action:$action, databases:$databases}'
    ;;
  dump)
    DB="${1:-}"; [[ -n "$DB" ]] || fail "db name required"
    DEST="${BACKUP_DIR}/${DB}_$(date +%Y%m%d-%H%M%S).sql"
    mkdir -p "$BACKUP_DIR"
    mysql_dump "$DB" > "$DEST" 2>/dev/null || fail "dump failed"
    audit "db_dump" "ok" "$DB -> $DEST"
    jq -n --arg status ok --arg action dump --arg database "$DB" --arg file "$DEST" '{status:$status, action:$action, database:$database, file:$file}'
    ;;
  resetpw)
    DB="${1:-}"; DBUSER="${2:-}"; NEWP="$(gen_pass 20)"
    [[ -n "$DB" && -n "$DBUSER" ]] || fail "db name and db user required"
    mysql_exec -e "ALTER USER '$DBUSER'@'localhost' IDENTIFIED BY '$NEWP';" 2>/dev/null || fail "reset failed"
    mysql_exec -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    audit "db_resetpw" "ok" "$DB user=$DBUSER"
    jq -n --arg status ok --arg action resetpw --arg database "$DB" --arg db_user "$DBUSER" --arg db_pass "$NEWP" \
      '{status:$status, action:$action, database:$database, db_user:$db_user, db_password:$db_pass}'
    ;;
  *)
    fail "Unknown db action: '$ACTION' (create|list|dump|resetpw)"
    ;;
esac
