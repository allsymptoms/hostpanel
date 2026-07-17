#!/usr/bin/env python3
"""
HostPanel - AI chat web hosting control panel
A single-file Flask backend that:
  * serves a chat UI
  * stores API keys for LLM providers (NVIDIA NIM, OpenAI, etc.)
  * parses natural-language hosting requests and runs provisioning scripts
  * returns real credentials to the user
"""
import os, json, subprocess, shlex, re, secrets, uuid, time, hashlib
md5 = hashlib.md5
from pathlib import Path
from flask import Flask, request, jsonify, send_from_directory, Response

ROOT = Path(os.environ.get("HOSTPANEL_ROOT", "/opt/hostpanel"))
CONFIG = ROOT / "config"
SCRIPTS = Path(__file__).parent / "scripts"
DATA = ROOT / "data"
CONFIG.mkdir(parents=True, exist_ok=True)
DATA.mkdir(parents=True, exist_ok=True)

APIKEYS_FILE = CONFIG / "apikeys.json"
DNSCONFIG_FILE = CONFIG / "dnsconfig.json"
SESSIONS_FILE = DATA / "sessions.json"
ADMIN_PASS = os.environ.get("HOSTPANEL_ADMIN_PASS", secrets.token_hex(8))

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Config / API key helpers
# ---------------------------------------------------------------------------
def load_apikeys():
    if APIKEYS_FILE.exists():
        return json.loads(APIKEYS_FILE.read_text())
    return {}

def save_apikeys(d):
    APIKEYS_FILE.write_text(json.dumps(d, indent=2))
    os.chmod(APIKEYS_FILE, 0o600)

def load_dnsconfig():
    if DNSCONFIG_FILE.exists():
        return json.loads(DNSCONFIG_FILE.read_text())
    return {}

def save_dnsconfig(d):
    DNSCONFIG_FILE.write_text(json.dumps(d, indent=2))
    os.chmod(DNSCONFIG_FILE, 0o600)

PROVIDERS = {
    "nvidia_nim": {
        "label": "NVIDIA NIM",
        "url": "https://integrate.api.nvidia.com/v1/chat/completions",
        "model_default": "meta/llama-3.1-8b-instruct",
        "header": "Authorization",
    },
    "openai": {
        "label": "OpenAI",
        "url": "https://api.openai.com/v1/chat/completions",
        "model_default": "gpt-4o-mini",
        "header": "Authorization",
    },
    "openrouter": {
        "label": "OpenRouter",
        "url": "https://openrouter.ai/api/v1/chat/completions",
        "model_default": "openai/gpt-4o-mini",
        "header": "Authorization",
    },
}

# ---------------------------------------------------------------------------
# LLM call (used to interpret chat, not strictly required for provisioning)
# ---------------------------------------------------------------------------
import urllib.request

def call_llm(user_text, history, provider, api_key, model):
    """Call the configured provider. Returns assistant text or raises."""
    p = PROVIDERS.get(provider)
    if not p or not api_key:
        raise RuntimeError("Provider not configured or API key missing")
    url = p["url"]
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
    ]
    for h in history[-6:]:
        messages.append({"role": h["role"], "content": h["text"]})
    messages.append({"role": "user", "content": user_text})
    payload = json.dumps({"model": model, "messages": messages, "temperature": 0.2}).encode()
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header(p["header"], f"Bearer {api_key}")
    with urllib.request.urlopen(req, timeout=60) as r:
        resp = json.loads(r.read().decode())
    return resp["choices"][0]["message"]["content"]

SYSTEM_PROMPT = """You are the operator of a Linux web-hosting control panel.
The user talks to you in natural language to manage hosting.
You can do these actions (output ONE command line as JSON in a ```json code block, nothing else):
  - create_user: {"action":"create_user","username":"<unixname>"}
  - create_vhost: {"action":"create_vhost","username":"<unixname>","domain":"<domain>"}
  - install_wordpress: {"action":"install_wordpress","username":"<unixname>","domain":"<domain>","title":"<site title>","admin_user":"<wp admin>","admin_email":"<email>"}
  - setup_ssl: {"action":"setup_ssl","domain":"<domain>","dns":"<cloudflare|route53|manual|empty for http>"}
  - status: {"action":"status"}
  - show_activity: {"action":"show_activity"}
  - backup: {"action":"backup","domain":"<domain>"}
  - list_backups: {"action":"list_backups","domain":"<domain or empty for all>"}
  - restore: {"action":"restore","domain":"<domain>","backup_ref":"<ref>","db_only":false,"files_only":false}
  - setup_firewall: {"action":"setup_firewall"}
  - setup_fail2ban: {"action":"setup_fail2ban"}
  - delete_vhost: {"action":"delete_vhost","domain":"<domain>","no_backup":false}
  - uninstall_wordpress: {"action":"uninstall_wordpress","domain":"<domain>","no_backup":false}
  - delete_user: {"action":"delete_user","username":"<unixname>","no_backup":false}
  - create_vhost (static): {"action":"create_vhost","username":"<unixname>","domain":"<domain>","type":"static"}
  - create_vhost (proxy app): {"action":"create_vhost","username":"<unixname>","domain":"<domain>","type":"proxy","port":3000}
  - install_ghost: {"action":"install_ghost","username":"<unixname>","domain":"<domain>"}
  - install_nextcloud: {"action":"install_nextcloud","username":"<unixname>","domain":"<domain>","admin_user":"admin","admin_email":"a@b.com"}
  - db_manage: {"action":"db_manage","db_action":"<create|list|dump|resetpw>","username":"<unixname>","db":"<dbname>","db_user":"<dbuser>"}
  - clone_site: {"action":"clone_site","username":"<unixname>","src":"<domain>","dst":"<domain>"}
  - snapshot: {"action":"snapshot","target":"<domain|all>"}
  - monitor: {"action":"monitor"}
If required info is missing, reply with plain text asking the user for it (no JSON).
Keep replies short and friendly. Always confirm with the real credentials the scripts return.
For destructive actions (delete/uninstall) you may set "no_backup":false to keep the default backup-first behavior."""

# ---------------------------------------------------------------------------
# Script running
# ---------------------------------------------------------------------------
def run_script(name, args):
    script = SCRIPTS / name
    if not script.exists():
        return {"status": "error", "error": f"script {name} missing"}
    cmd = ["bash", str(script)] + [str(a) for a in args]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return {"status": "error", "error": "script timed out"}
    # Try to parse the whole stdout as JSON first (scripts emit pretty-printed JSON),
    # then fall back to the last JSON-looking line.
    out_text = out.stdout.strip()
    result = None
    try:
        result = json.loads(out_text)
    except Exception:
        for l in reversed(out_text.splitlines()):
            l = l.strip()
            if not l:
                continue
            try:
                result = json.loads(l)
                break
            except Exception:
                continue
    if out.returncode != 0:
        return {"status": "error", "error": out.stderr.strip() or (result or {}).get("error", "failed"),
                "detail": out.stdout}
    if isinstance(result, list):
        return {"status": "ok", "items": result}
    if result is None:
        return {"status": "ok", "raw": out.stdout}
    return result

# ---------------------------------------------------------------------------
# Chat intent -> action
# ---------------------------------------------------------------------------
def handle_message(text, history):
    t = text.lower()
    # Very robust local parser (works even without API key):
    #  "create user X" / "add user X"
    #  "host domain example.com for user X" / "create site example.com under X"
    #  "install wordpress on example.com for user X"
    # Plus: if an API key is set, ask the LLM to extract structured intent.
    m_user = re.search(r"(?:user|account|client)\s+([a-z_][a-z0-9_-]{0,31})", t)
    # Domain detection: bare domain anywhere OR after a keyword
    m_domain = re.search(r"(?:domain|site|host|for|on)\s+([a-z0-9.-]+\.[a-z]{2,})", t) \
        or re.search(r"\b([a-z0-9-]+\.[a-z0-9-]+\.[a-z]{2,})\b", t) \
        or re.search(r"\b([a-z0-9-]{2,}\.[a-z]{2,})\b", t)
    m_wp = "wordpress" in t
    wants_user = re.search(r"(create|add|new|make)\s+(?:a\s+)?(?:hosting\s+)?user", t)
    wants_vhost = re.search(r"(host|create\s+site|add\s+domain|point\s+domain)", t) and m_domain

    # Try LLM enhancement if configured
    keys = load_apikeys()
    provider = keys.get("provider")
    if provider and keys.get("key"):
        try:
            resp = call_llm(text, history, provider, keys["key"], keys.get("model", PROVIDERS[provider]["model_default"]))
            intent = extract_json(resp)
            if intent:
                return execute_intent(intent)
        except Exception as e:
            # fall back to regex parser, but surface a note
            note = f"(LLM unavailable: {e}; used built-in parser)\n"
    else:
        note = ""

    # Built-in parser
    if wants_user and m_user:
        return execute_intent({"action": "create_user", "username": m_user.group(1)}, note)
    if m_wp and m_domain and m_user:
        return execute_intent({
            "action": "install_wordpress", "username": m_user.group(1),
            "domain": m_domain.group(1),
            "title": "My WordPress Site",
            "admin_user": "admin",
            "admin_email": f"admin@{m_domain.group(1)}",
        }, note)
    if wants_vhost and m_domain and m_user:
        return execute_intent({"action": "create_vhost", "username": m_user.group(1), "domain": m_domain.group(1)}, note)
    # SSL: "enable ssl/https for domain X" or "secure domain X with lets encrypt"
    #      "use dns" / "dns validation" selects DNS-01 challenge
    if m_domain and re.search(r"(ssl|https|secure|lets ?encrypt|certbot|encrypt)", t):
        dns = "dns" if re.search(r"\b(dns|cloudflare|route53|wildcard)\b", t) else ""
        return execute_intent({"action": "setup_ssl", "domain": m_domain.group(1), "dns": dns}, note)
    # FTP: "create ftp for user X domain Y" / "ftp account for ..."
    if re.search(r"\bftp\b", t) and m_user and m_domain:
        m_ftp = re.search(r"ftp(?:\s+(?:user|account))?\s+([a-z_][a-z0-9_-]{0,31})", t)
        ftp_user = m_ftp.group(1) if m_ftp else f"{m_user.group(1)}ftp"
        return execute_intent({"action": "create_ftp", "username": m_user.group(1),
                               "domain": m_domain.group(1), "ftp_user": ftp_user}, note)
    # Site hosting expansion (check BEFORE panel proxy, which also matches "proxy")
    if re.search(r"(static site|host a static|static page)", t) and m_domain and m_user:
        return execute_intent({"action": "create_vhost", "username": m_user.group(1),
                               "domain": m_domain.group(1), "type": "static"}, note)
    if re.search(r"(reverse proxy|node app|app on port|proxy .* to .* for user|proxy my)", t) and m_domain and m_user:
        m_port = re.search(r"port\s+(\d+)", t)
        port = m_port.group(1) if m_port else "3000"
        return execute_intent({"action": "create_vhost", "username": m_user.group(1),
                               "domain": m_domain.group(1), "type": "proxy", "port": port}, note)
    if re.search(r"ghost", t) and m_domain and m_user:
        return execute_intent({"action": "install_ghost", "username": m_user.group(1), "domain": m_domain.group(1)}, note)
    if re.search(r"nextcloud", t) and m_domain and m_user:
        a_user = re.search(r"admin\s+(\S+)", t)
        a_email = re.search(r"([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})", t)
        return execute_intent({"action": "install_nextcloud", "username": m_user.group(1),
                               "domain": m_domain.group(1),
                               "admin_user": a_user.group(1) if a_user else "admin",
                               "admin_email": a_email.group(1) if a_email else f"admin@{m_domain.group(1)}"}, note)
    # Proxy: panel hardening "enable proxy/auth" or "secure the panel with basic auth"
    if re.search(r"(proxy|basic auth|secure the panel|auth|expose safely|harden)", t) and "domain" not in t:
        return execute_intent({"action": "setup_proxy"}, note)
    # Database management (check before generic status/"list")
    if re.search(r"database|db user|mysql", t) and m_user:
        act = "list"
        if re.search(r"create|new", t): act = "create"
        elif re.search(r"dump|export|backup db", t): act = "dump"
        elif re.search(r"reset|rotate|change.*password|password", t): act = "resetpw"
        m_db = re.search(r"(?:database|db)\s+([a-z_][a-z0-9_]{0,31})", t) or re.search(r"([a-z_][a-z0-9_]{0,31})\s+for user", t)
        db = m_db.group(1) if m_db else ""
        return execute_intent({"action": "db_manage", "db_action": act,
                               "username": m_user.group(1), "db": db}, note)
    if "status" in t or re.search(r"(show users|list users|inventory|list sites|list domains)", t):
        return execute_intent({"action": "status"}, note)
    # Activity feed
    if re.search(r"(activity|audit|recent|history|what (did|have) you (do|done))", t):
        return execute_intent({"action": "show_activity"}, note)
    # Backups
    if re.search(r"backup", t) and m_domain:
        return execute_intent({"action": "backup", "domain": m_domain.group(1)}, note)
    if re.search(r"(list backups|show backups|available backups)", t):
        d = m_domain.group(1) if m_domain else ""
        return execute_intent({"action": "list_backups", "domain": d}, note)
    if re.search(r"restore", t) and m_domain:
        ref = ""
        m_ref = re.search(r"(backup|from)\s+([a-z0-9._-]+_[0-9]{8}-[0-9]{6})", t)
        if m_ref:
            ref = m_ref.group(2)
        return execute_intent({"action": "restore", "domain": m_domain.group(1), "backup_ref": ref}, note)
    # Firewall / fail2ban
    if re.search(r"(firewall|ufw|firewalld|open ports)", t):
        return execute_intent({"action": "setup_firewall"}, note)
    if re.search(r"fail2ban|brute ?force|ban attackers|intrusion", t):
        return execute_intent({"action": "setup_fail2ban"}, note)
    # Monitoring / snapshot
    if re.search(r"(monitor|health check|cert expiry|expir)", t):
        return execute_intent({"action": "monitor"}, note)
    if re.search(r"(snapshot|backup (everything|all|before)|pre-?change backup)", t):
        d = m_domain.group(1) if m_domain else "all"
        return execute_intent({"action": "snapshot", "target": d}, note)
    # Clone / staging
    if re.search(r"(clone|staging|copy).*(site|domain|to|for)", t) and m_domain:
        m_dst = re.search(r"(?:to|staging|for)\s+([a-z0-9-]+\.[a-z0-9-]+\.[a-z]{2,})", t) \
            or re.search(r"staging\.([a-z0-9-]+\.[a-z]{2,})", t)
        dst = m_dst.group(1) if m_dst else ""
        if not dst and m_user:
            dst = f"staging.{m_domain.group(1)}"
        if dst:
            return execute_intent({"action": "clone_site", "username": m_user.group(1) if m_user else "",
                                   "src": m_domain.group(1), "dst": dst}, note)
    # Teardown (destructive) — require explicit confirmation
    if re.search(r"(delete|remove|uninstall|tear ?down|destroy)", t):
        if re.search(r"wordpress", t) and m_domain:
            return require_confirm({"action": "uninstall_wordpress", "domain": m_domain.group(1)})
        if re.search(r"domain|site|vhost", t) and m_domain:
            return require_confirm({"action": "delete_vhost", "domain": m_domain.group(1)})
        if m_user:
            return require_confirm({"action": "delete_user", "username": m_user.group(1)})
        if m_domain:
            return require_confirm({"action": "delete_vhost", "domain": m_domain.group(1)})

    return None  # means: ask the user for clarification

def extract_json(text):
    m = re.search(r"```json\s*(.*?)```", text, re.S)
    if m:
        try:
            return json.loads(m.group(1))
        except Exception:
            pass
    try:
        return json.loads(text)
    except Exception:
        return None

# Pending destructive actions awaiting confirmation (session_id -> intent)
PENDING_CONFIRM = {}

def require_confirm(intent):
    """Ask the user to confirm a destructive action before executing."""
    labels = {
        "delete_user": f"⚠️ This will DELETE hosting user `{intent.get('username')}` and ALL their sites (after a backup).",
        "delete_vhost": f"⚠️ This will REMOVE the site `{intent.get('domain')}` (after a backup).",
        "uninstall_wordpress": f"⚠️ This will REMOVE WordPress from `{intent.get('domain')}` (after a backup).",
    }
    msg = labels.get(intent["action"], "⚠️ Confirm this destructive action?")
    PENDING_CONFIRM[_confirm_token(intent)] = intent
    return {
        "reply": (msg + "\n\nReply **yes** to proceed, or anything else to cancel."),
        "confirm_token": _confirm_token(intent),
    }

def _confirm_token(intent):
    return md5(json.dumps(intent, sort_keys=True).encode()).hexdigest()[:12]

def execute_intent(intent, note="", confirm_token=None):
    # Honor an explicit confirm/cancel if a token was passed
    action = intent.get("action")
    if confirm_token:
        pending = PENDING_CONFIRM.pop(confirm_token, None)
        if pending is None:
            return {"reply": "That confirmation has expired or is unknown. Please repeat the request."}
        intent = pending
        action = intent.get("action")
    if action == "create_user":
        r = run_script("create_user.sh", [intent["username"]])
    elif action == "create_vhost":
        r = run_script("create_vhost.sh", [intent["username"], intent["domain"]])
    elif action == "install_wordpress":
        r = run_script("install_wordpress.sh", [
            intent["username"], intent["domain"],
            intent.get("title", "My WordPress Site"),
            intent.get("admin_user", "admin"),
            intent.get("admin_email", f"admin@{intent['domain']}"),
        ])
    elif action == "status":
        r = run_script("list_users.sh", [])
    elif action == "setup_ssl":
        args = [intent["domain"]]
        if intent.get("email"):
            args.append(intent["email"])
        else:
            args.append("")
        # dns provider: explicit request, or the configured default
        dns_provider = intent.get("dns") or ""
        if not dns_provider:
            dns_provider = load_dnsconfig().get("provider", "")
        args.append(dns_provider)
        r = run_script("setup_ssl.sh", args)
    elif action == "create_ftp":
        args = [intent["username"], intent["domain"], intent.get("ftp_user", f"{intent['username']}ftp")]
        if intent.get("ftp_password"):
            args.append(intent["ftp_password"])
        r = run_script("create_ftp.sh", args)
    elif action == "setup_proxy":
        args = []
        if intent.get("admin_user"):
            args.append(intent["admin_user"])
        if intent.get("admin_password"):
            args.append(intent["admin_password"])
        if intent.get("public_domain"):
            args.append(intent["public_domain"])
        r = run_script("setup_proxy.sh", args)
    elif action == "show_activity":
        r = run_script("show_activity.sh", [])
    elif action == "backup":
        r = run_script("backup.sh", [intent["domain"]])
    elif action == "list_backups":
        r = run_script("list_backups.sh", [intent.get("domain", "")]) if intent.get("domain") else run_script("list_backups.sh", [])
    elif action == "restore":
        args = [intent["domain"], intent.get("backup_ref", "")]
        if intent.get("db_only"):
            args.append("--db-only")
        elif intent.get("files_only"):
            args.append("--files-only")
        r = run_script("restore.sh", args)
    elif action == "setup_firewall":
        r = run_script("setup_firewall.sh", [])
    elif action == "setup_fail2ban":
        r = run_script("setup_fail2ban.sh", [])
    elif action == "delete_vhost":
        args = [intent["domain"]]
        if intent.get("no_backup"):
            args.append("--no-backup")
        r = run_script("delete_vhost.sh", args)
    elif action == "uninstall_wordpress":
        args = [intent["domain"]]
        if intent.get("no_backup"):
            args.append("--no-backup")
        r = run_script("uninstall_wordpress.sh", args)
    elif action == "delete_user":
        args = [intent["username"]]
        if intent.get("no_backup"):
            args.append("--no-backup")
        r = run_script("delete_user.sh", args)
    elif action == "install_ghost":
        r = run_script("install_ghost.sh", [intent["username"], intent["domain"]])
    elif action == "install_nextcloud":
        args = [intent["username"], intent["domain"]]
        if intent.get("admin_user"): args.append(intent["admin_user"])
        if intent.get("admin_email"): args.append(intent["admin_email"])
        if intent.get("admin_pass"): args.append(intent["admin_pass"])
        r = run_script("install_nextcloud.sh", args)
    elif action == "db_manage":
        args = [intent["db_action"], intent["username"]]
        if intent.get("db"): args.append(intent["db"])
        if intent.get("db_user"): args.append(intent["db_user"])
        if intent.get("db_pass"): args.append(intent["db_pass"])
        r = run_script("db_manage.sh", args)
    elif action == "clone_site":
        args = [intent.get("username",""), intent["src"], intent["dst"]]
        if intent.get("type"): args.append(intent["type"])
        r = run_script("clone_site.sh", args)
    elif action == "snapshot":
        r = run_script("snapshot.sh", [intent.get("target", "all")])
    elif action == "monitor":
        r = run_script("monitor.sh", [])
    else:
        return {"reply": note + f"Unknown action: {action}"}
    return format_result(action, r, note)

def format_result(action, r, note):
    if not r:
        return {"reply": note + "No output from script."}
    if r.get("status") == "error":
        return {"reply": note + f"❌ Failed: {r.get('error','unknown error')}"}
    if action == "create_user":
        return {"reply": note + f"✅ Created hosting user `{r['username']}`.\nHome: `{r['home']}`\nDocroot: `{r['docroot']}`"}
    if action == "create_vhost":
        return {"reply": note + f"✅ Virtual host ready for `{r['domain']}`.\nDocroot: `{r['docroot']}`\nPoint DNS A record to this server's IP."}
    if action == "install_wordpress":
        db = r.get("database", {})
        ad = r.get("admin", {})
        return {"reply": note + (
            f"✅ WordPress installed for `{r['domain']}`!\n\n"
            f"🌐 Site: {r['site_url']}\n"
            f"🔐 Admin: {r['admin_url']}\n\n"
            f"WP admin user: `{ad.get('user')}`\n"
            f"WP admin email: `{ad.get('email')}`\n"
            f"WP admin password: `{ad.get('password')}`\n\n"
            f"Database name: `{db.get('name')}`\n"
            f"Database user: `{db.get('user')}`\n"
            f"Database password: `{db.get('password')}`"
        )}
    if action == "status":
        users = r.get("users", []) if isinstance(r, dict) else (r if isinstance(r, list) else [])
        if not users:
            return {"reply": note + "No hosting users created yet."}
        lines = [f"👤 `{u['username']}` — sites: {', '.join(u.get('sites',[])) or 'none'}" for u in users]
        return {"reply": note + "Current hosting users:\n" + "\n".join(lines)}
    if action == "setup_ssl":
        return {"reply": note + (
            f"✅ HTTPS enabled for `{r['domain']}`!\n\n"
            f"🔒 Site: {r['https']}\n"
            f"Method: {r.get('method','webroot')}\n"
            f"Certificate: `{r['certificate']}`\n"
            f"Auto-renews via certbot timer."
        )}
    if action == "create_ftp":
        return {"reply": note + (
            f"✅ FTP account created for `{r['domain']}`!\n\n"
            f"FTP host: your server IP (port 21)\n"
            f"FTP user: `{r['ftp_user']}`\n"
            f"FTP password: `{r['password']}`\n"
            f"Jailed to: `{r['docroot']}` (no SSH access)"
        )}
    if action == "setup_proxy":
        return {"reply": note + (
            f"✅ Panel now behind nginx with basic auth.\n\n"
            f"Admin user: `{r['admin_user']}`\n"
            f"Admin password: `{r['password']}`\n\n"
            f"{r.get('note','')}"
        )}
    if action == "show_activity":
        entries = r.get("entries", []) if isinstance(r, dict) else []
        if not entries:
            return {"reply": note + "No activity recorded yet."}
        lines = [f"`{e['time']}`  {e['action']}  {e['result']}  {e.get('args','')}" for e in entries]
        return {"reply": note + "Recent activity:\n" + "\n".join(lines)}
    if action == "backup":
        return {"reply": note + (
            f"✅ Backup created for `{r['domain']}`.\n\n"
            f"Reference: `{r['backup_ref']}`\n"
            f"Archive: `{r['archive']}`\n"
            f"Database dump: `{r['db_dump']}`\n"
            f"Size: {r['size']}"
        )}
    if action == "list_backups":
        backups = r.get("backups", []) if isinstance(r, dict) else []
        if not backups:
            return {"reply": note + "No backups found."}
        lines = [f"`{b['ref']}`  ({b['domain']})  size={b['size']}  {b['when']}" for b in backups]
        return {"reply": note + "Available backups:\n" + "\n".join(lines)}
    if action == "restore":
        return {"reply": note + (
            f"✅ Restored `{r['domain']}` from backup `{r['backup_ref']}`.\n"
            f"Files restored: {'yes' if r.get('restored_files') else 'no'}\n"
            f"Database restored: {'yes' if r.get('restored_db') else 'no'}"
        )}
    if action == "setup_firewall":
        return {"reply": note + f"✅ Firewall configured via `{r['firewall']}`.\nOpen ports: 22, 80, 443, 21, 40000–40100 (FTP passive), 8080."}
    if action == "setup_fail2ban":
        return {"reply": note + f"✅ fail2ban enabled.\nJails: {r['jails']}"}
    if action == "delete_vhost":
        return {"reply": note + f"🗑️ Removed site `{r['domain']}` (backup: `{r['backup']}`)."}
    if action == "uninstall_wordpress":
        return {"reply": note + f"🗑️ Removed WordPress from `{r['domain']}` (backup: `{r['backup']}`)."}
    if action == "delete_user":
        return {"reply": note + f"🗑️ Deleted hosting user `{r['username']}` and {r['sites_removed']} site(s)."}
    if action == "install_ghost":
        return {"reply": note + (
            f"✅ Ghost/Node app installed for `{r['domain']}`!\n\n"
            f"🌐 Site: http://{r['domain']}\n"
            f"Proxy port: {r['port']}\n"
            f"Service: `{r['service']}`\n"
            f"App dir: `{r['appdir']}`"
        )}
    if action == "install_nextcloud":
        return {"reply": note + (
            f"✅ Nextcloud installed for `{r['domain']}`!\n\n"
            f"🌐 Site: http://{r['domain']}\n"
            f"Admin user: `{r['admin_user']}`\n"
            f"Database: `{r['database']}`\n"
            f"DB user: `{r['database_user']}`\n"
            f"DB password: `{r['database_password']}`"
        )}
    if action == "db_manage":
        if r.get("action") == "list":
            dbs = r.get("databases", [])
            if not dbs:
                return {"reply": note + "No databases found."}
            return {"reply": note + "Databases:\n" + "\n".join(f"`{d}`" for d in dbs)}
        if r.get("action") == "dump":
            return {"reply": note + f"✅ Dumped `{r['database']}` to `{r['file']}`."}
        if r.get("action") == "resetpw":
            return {"reply": note + f"🔐 Rotated password for DB user `{r['db_user']}` on `{r['database']}`: `{r['db_password']}`"}
        return {"reply": note + f"✅ Created database `{r['database']}` (user `{r['db_user']}`, pass `{r['db_password']}`)."}
    if action == "clone_site":
        return {"reply": note + (
            f"✅ Cloned `{r['src']}` to `{r['dst']}`.\n\n"
            f"Docroot: `{r['docroot']}`\n"
            f"Database: `{r['database']}`"
        )}
    if action == "snapshot":
        refs = r.get("refs", [])
        if not refs:
            return {"reply": note + "No sites to snapshot."}
        return {"reply": note + "📸 Snapshot created:\n" + "\n".join(f"`{x}`" for x in refs)}
    if action == "monitor":
        rep = r.get("report", [])
        if not rep:
            return {"reply": note + "No sites to monitor."}
        lines = [f"`{e['domain']}`  http={e.get('http_status')} cert={e.get('cert_expiry_days')}d ({e.get('cert_level')})"
                 for e in rep]
        return {"reply": note + "🩺 Monitoring report:\n" + "\n".join(lines) +
                "\n\n(Detailed JSON: /opt/hostpanel/data/monitor.json)"}
    return {"reply": note + json.dumps(r, indent=2)}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return send_from_directory(Path(__file__).parent / "static", "index.html")

@app.route("/api/chat", methods=["POST"])
def chat():
    data = request.get_json(force=True)
    text = data.get("message", "").strip()
    sid = data.get("session", "") or secrets.token_hex(8)
    sessions = {}
    if SESSIONS_FILE.exists():
        sessions = json.loads(SESSIONS_FILE.read_text())
    history = sessions.get(sid, [])
    history.append({"role": "user", "text": text})

    # If there's a pending confirmation for this session, treat the reply as yes/no
    pending_token = data.get("confirm_token") or sessions.get(sid, [{}])[-1:][0].get("_pending")
    if pending_token and pending_token in PENDING_CONFIRM:
        if re.search(r"^(yes|y|confirm|proceed|do it|go ahead)\b", text, re.I):
            result = execute_intent({}, confirm_token=pending_token)
        else:
            PENDING_CONFIRM.pop(pending_token, None)
            result = {"reply": "Cancelled. No changes were made."}
    else:
        result = handle_message(text, history)

    if result is None:
        reply = ("I can help you with hosting. Try things like:\n"
                 "• `create user acme`\n"
                 "• `host domain acme.com for user acme`\n"
                 "• `install wordpress on acme.com for user acme`\n"
                 "• `host a static site static.acme.com for user acme`\n"
                 "• `proxy my node app on port 3000 to app.acme.com for user acme`\n"
                 "• `install ghost on ghost.acme.com for user acme`\n"
                 "• `install nextcloud on cloud.acme.com for user acme`\n"
                 "• `create database mydb for user acme`\n"
                 "• `clone acme.com to staging.acme.com for user acme`\n"
                 "• `show users` / `show activity`\n"
                 "• `backup acme.com` / `snapshot all`\n"
                 "• `run monitor`\n"
                 "• `configure firewall` / `enable fail2ban`\n\n"
                 "What would you like to do? (I'll ask for any missing details.)")
    else:
        reply = result["reply"]

    # Stash the confirm token so the next message (yes/no) resolves it
    reply_obj = {"role": "assistant", "text": reply}
    if "confirm_token" in result:
        reply_obj["_pending"] = result["confirm_token"]
    history.append(reply_obj)
    sessions[sid] = history[-20:]
    SESSIONS_FILE.write_text(json.dumps(sessions, indent=2))
    return jsonify({"reply": reply, "session": sid, **({"confirm_token": result["confirm_token"]} if "confirm_token" in result else {})})

@app.route("/api/apikeys", methods=["GET", "POST"])
def apikeys():
    if request.method == "GET":
        keys = load_apikeys()
        # never return the raw key
        return jsonify({"provider": keys.get("provider"),
                        "model": keys.get("model"),
                        "configured": bool(keys.get("key")),
                        "providers": list(PROVIDERS.keys())})
    data = request.get_json(force=True)
    provider = data.get("provider")
    key = data.get("key", "")
    model = data.get("model", "")
    if provider not in PROVIDERS:
        return jsonify({"error": "unknown provider"}), 400
    keys = load_apikeys()
    keys["provider"] = provider
    keys["key"] = key
    keys["model"] = model or PROVIDERS[provider]["model_default"]
    save_apikeys(keys)
    return jsonify({"ok": True, "provider": provider, "configured": bool(key)})

DNS_PROVIDERS = {
    "cloudflare": "certbot-dns-cloudflare (needs a Cloudflare API token)",
    "route53": "certbot-dns-route53 (uses AWS creds / instance role)",
    "manual": "manual DNS-01 (you add the TXT record when prompted)",
}

@app.route("/api/dnsconfig", methods=["GET", "POST"])
def dnsconfig():
    if request.method == "GET":
        d = load_dnsconfig()
        return jsonify({"provider": d.get("provider"), "configured": bool(d.get("provider")),
                        "providers": list(DNS_PROVIDERS.keys())})
    data = request.get_json(force=True)
    provider = data.get("provider", "")
    creds = data.get("credentials", "")
    if provider not in DNS_PROVIDERS:
        return jsonify({"error": "unknown dns provider"}), 400
    d = {"provider": provider, "credentials": creds}
    save_dnsconfig(d)
    return jsonify({"ok": True, "provider": provider, "configured": True})


@app.route("/api/admin/info")
def admin_info():
    return jsonify({"admin_password": ADMIN_PASS, "root": str(ROOT)})

if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1", help="bind address (default 127.0.0.1; use 0.0.0.0 only if not behind the nginx proxy)")
    p.add_argument("--port", type=int, default=8080)
    args = p.parse_args()
    print(f"HostPanel admin password (first run): {ADMIN_PASS}")
    print(f"Serving on http://{args.host}:{args.port}  (HOSTPANEL_ROOT={ROOT})")
    app.run(host=args.host, port=args.port)
