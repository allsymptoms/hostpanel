#!/usr/bin/env bash
# monitor.sh - check cert expiry + site health, write a status report
# Usage: monitor.sh
# For every vhost on the server:
#   - if a Let's Encrypt cert exists, report days-to-expiry (warn < 21, crit < 7)
#   - curl the site; report HTTP status (warn if not 2xx/3xx)
# Writes /opt/hostpanel/data/monitor.json and appends alerts to the audit log.
# Designed to run from a daily systemd timer / cron.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_dirs
mkdir -p "$HOSTPANEL_ROOT/data"

report="[]"
shopt -s nullglob
for conf in "$NGINX_AVAILABLE"/*.conf; do
  d="$(basename "$conf" .conf)"
  entry="$(jq -n --arg domain "$d" '{domain:$domain}')"

  # Cert expiry
  cert="/etc/letsencrypt/live/${d}/fullchain.pem"
  if [[ -f "$cert" ]]; then
    exp=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
    exp_ts=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    days=$(( (exp_ts - now_ts) / 86400 ))
    lvl="ok"; [[ "$days" -lt 7 ]] && lvl="crit"; [[ "$days" -lt 21 && "$days" -ge 7 ]] && lvl="warn"
    entry="$(echo "$entry" | jq --argjson days "$days" --arg lvl "$lvl" '. + {cert_expiry_days:$days, cert_level:$lvl}')"
    [[ "$lvl" != "ok" ]] && audit "monitor" "$lvl" "$d cert expires in $days days"
  else
    entry="$(echo "$entry" | jq '. + {cert_expiry_days:null, cert_level:"none"}')"
  fi

  # HTTP health
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${d}" 2>/dev/null || echo 000)
  hlvl="ok"; [[ "$code" =~ ^(000|5..)$ ]] && hlvl="crit"; [[ "$code" =~ ^4..$ ]] && hlvl="warn"
  entry="$(echo "$entry" | jq --arg code "$code" --arg lvl "$hlvl" '. + {http_status:$code, http_level:$lvl}')"
  [[ "$hlvl" != "ok" ]] && audit "monitor" "$hlvl" "$d http=$code"

  report="$(echo "$report" | jq --argjson e "$entry" '. + [$e]')"
done
shopt -u nullglob

echo "$report" | jq . > "$HOSTPANEL_ROOT/data/monitor.json"
jq -n --arg status ok --argjson report "$report" '{status:$status, report:$report}'
