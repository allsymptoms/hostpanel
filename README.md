<div align="center">

# 🚀 HostPanel

### AI Chat Web Hosting Control Panel

**Provision real Linux web hosting by chatting in plain English.**
Create users, host domains, install WordPress, issue SSL, and set up FTP —
just by telling it what you want.

![CI](https://github.com/allsymptoms/hostpanel/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Linux-blue)
![Stack](https://img.shields.io/badge/stack-Flask%20%2B%20nginx%20%2B%20bash-orange)
![No API key required](https://img.shields.io/badge/API%20key-optional-brightgreen)

[Features](FEATURES.md) · [Quick start](#install-on-a-fresh-vps) · [DNS SSL](#automatic-dns-validation-no-port-80-needed)

</div>

---

> **Talk, don't click.** HostPanel turns natural-language requests into real
> provisioning actions on your VPS — and hands back the actual credentials.

```
you:  install wordpress on bobdesign.io for user bob
panel: ✅ WordPress installed! Admin: https://bobdesign.io/wp-admin
       user: admin   password: ••••••••   (DB: wp_bob_bobdesign)
```

**Highlights** — chat-driven provisioning · one-command WordPress · Let's Encrypt
SSL with **automatic DNS-01 validation** (Cloudflare / Route53 / manual) · jailed
FTP accounts · nginx reverse-proxy hardening · **backups & restore** · **firewall +
fail2ban** · **teardown with confirmation + audit log** · cross-distro installer
(apt/dnf/yum/apk). Full list in **[FEATURES.md](FEATURES.md)**.

---

## What it does

A self-hosted control panel you drive by chat. Tell it in plain language to
create hosting users, point domains at them, and install WordPress — it asks
for any missing details and returns the real credentials.

Runs on any Linux VPS (Ubuntu/Debian/CentOS/RHEL/Rocky/Alma). No external
service required.

## Install on a fresh VPS

```bash
# as root
curl -fsSL https://your-domain/hostpanel/install.sh -o install.sh
sudo bash install.sh
```

Or, if you already cloned this repo on the server:

```bash
sudo bash install.sh
```

After install, open `http://<your-server-ip>:8080`. The one-time admin password
is printed at the end of the install and stored in the service environment.

The installer will:
- detect your distro and install nginx, MySQL/MariaDB, PHP-FPM, Python, WP-CLI,
  certbot (Let's Encrypt) and vsftpd (FTP)
- copy the panel to `/opt/hostpanel` and run it as a systemd service bound to
  `127.0.0.1:8080` (`systemctl status hostpanel`)

## Talking to the panel

In the chat box, use phrases like:

- `create user acme`
- `host domain acme.com for user acme`
- `install wordpress on acme.com for user acme`
- `secure domain acme.com with lets encrypt`  (issue a free TLS cert + force HTTPS)
- `create ftp for user acme domain acme.com`  (jailed FTP account)
- `harden the panel with basic auth`  (put the panel behind nginx + password)
- `show users`

If anything is missing (e.g. you say "install wordpress" with no domain), the
panel replies asking for it instead of guessing.

## Securing the panel (recommended)

By default the panel service binds to `127.0.0.1:8080` only — it is not directly
reachable from the internet. To expose it safely, run in chat:

```
harden the panel with basic auth
```

This generates an nginx reverse proxy in front of the app with HTTP basic auth
(`auth_basic`), and the Flask app stays bound to localhost. The generated
admin username/password is shown in the chat reply. You can also pass a domain
to terminate TLS on the proxy once a cert exists.

For the hosted sites themselves, get a free certificate per domain:

```
secure domain acme.com with lets encrypt
```

That runs `certbot --webroot`, rewrites the nginx vhost to listen on 443 with a
301 redirect from HTTP, and renews automatically via certbot's timer. The DNS
A record for the domain must already point at this server.

### Automatic DNS validation (no port 80 needed)

For firewalled servers, wildcard certs, or when port 80 isn't reachable, use the
DNS-01 challenge instead. Configure a DNS provider once (sidebar **⚙ DNS**, or
`POST /api/dnsconfig`), then:

```
secure domain acme.com with lets encrypt using dns
```

Supported providers:

- **Cloudflare** — paste a Cloudflare API token (Zone:DNS edit). The panel writes
  it to `/opt/hostpanel/config/cloudflare.ini` (mode 600) and runs
  `certbot --dns-cloudflare`.
- **Route53** — uses AWS credentials from the environment or an EC2 instance role
  (no token to paste); runs `certbot --dns-route53`.
- **Manual** — `certbot --manual --preferred-challenges dns`; certbot prints a TXT
  record for you to add, then completes. (Only mode needing a human.)

The DNS provider set in **⚙ DNS** becomes the default for every `secure domain …`
request, so "secure domain acme.com with lets encrypt" will automatically use
DNS-01 once a provider is configured. Add "using dns" to force it explicitly.
DNS-01 also supports wildcard domains (`*.acme.com`).

## FTP accounts

```
create ftp for user acme domain acme.com
```

Creates a vsftpd virtual user (no system login, no SSH) jailed to that site's
docroot. The FTP password is returned in the chat. Passive ports 40000–40100
are opened if `ufw` is present.

## Production hardening

HostPanel is built to be run for real clients. Beyond the panel's own basic-auth
proxy, it ships operational tooling:

### Backups & restore

```text
backup acme.com                 # tar docroot + mysqldump (if WordPress)
list backups                    # show all available backups
restore acme.com from <ref>     # restore files (+ DB if present)
```

Backups are timestamped archives under `/opt/hostpanel/backups/<domain>_<ts>/`.
Teardown actions (below) **always back up first** unless you pass `--no-backup`.

### Firewall & brute-force protection

```text
configure firewall             # open 22/80/443/21 + FTP passive (40000–40100) via ufw/firewalld
enable fail2ban                # jails for sshd, nginx-http-auth, vsftpd
```

### Teardown (destructive — confirmation required)

```text
delete vhost acme.com          # removes the site (after a backup)
uninstall wordpress acme.com   # removes WP files + drops its DB (after a backup)
delete user acme               # removes the user and all their sites (after a backup)
```

Destructive requests always ask **"Reply yes to proceed"** before doing anything,
and never act without an explicit confirmation. Every change is written to an
append-only audit log.

### Activity / audit log

```text
show activity                  # recent actions (who/what/when/result)
```

The audit log lives at `/opt/hostpanel/logs/audit.log`.

### More than WordPress — any site

```text
host a static site static.acme.com for user acme   # plain HTML (no PHP)
proxy my node app on port 3000 to app.acme.com for user acme   # nginx -> localhost:3000
install ghost on ghost.acme.com for user acme       # Ghost/Node app behind a proxy
install nextcloud on cloud.acme.com for user acme   # Nextcloud (PHP) + DB
```

- **static** — serves files from the docroot, no PHP engine.
- **proxy** — creates a vhost that reverse-proxies to a local app port (Node,
  Python, Go, etc.). The app is managed by a systemd service the script writes.
- **Ghost** — scaffolds a Node app, creates the proxy vhost + systemd service,
  and starts it. Drop your Ghost/Node code into the app dir to go live.
- **Nextcloud** — downloads Nextcloud into the docroot, creates its DB, and runs
  the installer. Admin creds + DB password are returned in chat.

### Databases

```text
create database mydb for user acme        # create DB + user, returns creds
list databases for user acme              # list the user's databases
dump database mydb for user acme          # export to a backup file
reset password for database mydb for user acme   # rotate the DB user password
```

### Staging from production

```text
clone acme.com to staging.acme.com for user acme   # copies docroot + DB, rewrites URLs
```

`clone` snapshots the source first, creates a staging vhost, copies files, and
clones the database (for WordPress it rewrites `siteurl`/`home` to the staging
domain). Safe, reversible, and great for client previews.

### Monitoring (certs + health)

```text
snapshot all                    # one-click safety backup of every site
run monitor                     # cert-expiry + HTTP health for every site
```

`run monitor` checks each Let's Encrypt cert's days-to-expiry (warns < 21,
crit < 7) and each site's HTTP status, writes a report to
`/opt/hostpanel/data/monitor.json`, and appends any warnings to the audit log.
The installer also enables a **daily systemd timer** (`hostpanel-monitor.timer`)
so this runs automatically at 06:00.

## API keys (optional, for natural-language flexibility)

Without an API key the panel uses a built-in parser that understands the
commands above. For looser natural language ("set up a site for my client
Bob at bobdesign.io with WordPress"), open **⚙ API Keys** and paste a key from:

- **NVIDIA NIM** — https://build.nvidia.com/ (model e.g. `meta/llama-3.1-8b-instruct`)
- **OpenAI** — https://platform.openai.com/api-keys
- **OpenRouter** — https://openrouter.ai/keys

Keys are stored at `/opt/hostpanel/config/apikeys.json` (mode 600, root-only).
The key is sent only to the provider you choose; it never leaves your server
except to call that provider's chat-completions endpoint.

## How it works

```
browser ──> app.py (Flask, bound to 127.0.0.1:8080) ──> scripts/*.sh (run as root)
                                                         ├── create_user.sh        (useradd + home + www dir)
                                                         ├── create_vhost.sh       (nginx vhost + reload)
                                                         ├── install_wordpress.sh  (download WP, create DB, wp-config, install)
                                                         ├── setup_ssl.sh          (certbot cert + 443 vhost + HTTPS redirect)
                                                         ├── create_ftp.sh         (vsftpd virtual user, jailed to docroot)
                                                         ├── setup_proxy.sh        (nginx reverse proxy + basic auth)
                                                         ├── backup.sh / restore.sh (docroot tar + DB dump)
                                                         ├── delete_vhost.sh / uninstall_wordpress.sh / delete_user.sh (teardown, backup-first)
                                                         ├── setup_firewall.sh / setup_fail2ban.sh (host hardening)
                                                         ├── show_activity.sh      (audit log feed)
                                                         ├── monitor.sh / snapshot.sh (certs + health)
                                                         ├── install_ghost.sh / install_nextcloud.sh (apps)
                                                         ├── db_manage.sh          (create/list/dump/reset)
                                                         ├── clone_site.sh         (staging)
                                                         └── list_users.sh
```

Each script emits a JSON result on stdout (logs go to stderr + a log file) so
the backend can parse it and hand the credentials back to the chat.

## Files

```
hostpanel/
├── install.sh            # bootstrap installer (run on the VPS)
├── app.py                # Flask backend + chat intent parser + API-key store
├── static/index.html     # the chat UI
├── scripts/
    ├── lib.sh            # shared helpers (validation, logging, mysql, audit)
    ├── create_user.sh
    ├── create_vhost.sh
    ├── install_wordpress.sh
    ├── setup_ssl.sh
    ├── create_ftp.sh
    ├── setup_proxy.sh
    ├── backup.sh / restore.sh
    ├── delete_vhost.sh / uninstall_wordpress.sh / delete_user.sh
    ├── setup_firewall.sh / setup_fail2ban.sh
    ├── show_activity.sh
    ├── monitor.sh / snapshot.sh
    ├── install_ghost.sh / install_nextcloud.sh
    ├── db_manage.sh
    ├── clone_site.sh
    └── list_users.sh
```

## Manual / troubleshooting

```bash
# logs
journalctl -u hostpanel -f
cat /opt/hostpanel/logs/provision.log
cat /opt/hostpanel/logs/audit.log

# list what the panel knows
bash /opt/hostpanel/scripts/list_users.sh

# list backups
bash /opt/hostpanel/scripts/list_backups.sh

# restart
sudo systemctl restart hostpanel
```

## Security notes

- The panel service binds to `127.0.0.1:8080` by default (not exposed to the
  internet). Expose it safely with `harden the panel with basic auth` (nginx
  reverse proxy + `auth_basic`) rather than opening 8080 directly.
- The panel runs as root because provisioning needs it (useradd, nginx, mysql).
  Keep it behind the basic-auth proxy and a firewall.
- Change the admin password after first login (set `HOSTPANEL_ADMIN_PASS` in
  `/etc/systemd/system/hostpanel.service` and `systemctl daemon-reload`).
- FTP users are vsftpd virtual users with no system login and no SSH — they are
  chrooted to their site docroot only.
- Let's Encrypt certs auto-renew via certbot's systemd timer.
- DNS provider credentials (e.g. Cloudflare token) are stored root-only (0600) in
  `config/dnsconfig.json` and `config/cloudflare.ini`.
- API keys are stored root-only (0600).
- Destructive actions (delete/uninstall/teardown) require an explicit chat
  confirmation and always back up first. All actions are recorded in the
  append-only audit log at `logs/audit.log`.
- `configure firewall` locks down all ports except 22/80/443/21 + FTP passive;
  `enable fail2ban` blocks SSH/panel/FTP brute-force attempts.
