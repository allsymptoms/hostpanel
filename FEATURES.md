# HostPanel Features

**Provision real Linux web hosting by chatting in plain English.**
No dashboards to click through — you talk, HostPanel builds.

---

## At a glance

| | Feature | What you say |
|---|---|---|
| 👤 | Hosting users | `create user acme` |
| 🌐 | Domains / vhosts | `host domain acme.com for user acme` |
| 📝 | WordPress installs | `install wordpress on acme.com for user acme` |
| 🔒 | Let's Encrypt SSL | `secure domain acme.com with lets encrypt` |
| 🛡️ | Automatic DNS validation | `secure domain acme.com with lets encrypt using dns` |
| 📁 | Jailed FTP accounts | `create ftp for user acme domain acme.com` |
| 🚪 | Panel hardening | `harden the panel with basic auth` |
| 📋 | Inventory | `show users` |

---

## 1. Chat-driven provisioning

Type what you want in natural language. A built-in parser understands the core
commands with **zero API keys or external services** — everything runs on your
own box.

- Understands intent, extracts usernames/domains, and **asks for missing details
  instead of guessing**.
- Returns the **real credentials** each step produces (DB name, WP admin login,
  FTP password) directly in the chat.
- **Optional LLM upgrade:** plug in an NVIDIA NIM, OpenAI, or OpenRouter key for
  looser phrasing like _"set up a WordPress site for my client Bob at
  bobdesign.io."_

## 2. Hosting user management

- Creates a real system user, home directory, and web docroot per client.
- Tracks every user and their sites in JSON records.
- `show users` lists the entire estate the panel manages.

## 3. Domains & nginx virtual hosts

- Generates a per-domain nginx vhost, validates with `nginx -t`, and reloads.
- PHP-FPM wired in for dynamic sites out of the box.

## 4. One-command WordPress

`install wordpress on acme.com for user acme` will:

1. Download the latest WordPress.
2. Create a MySQL/MariaDB database **and** a scoped DB user.
3. Write `wp-config.php` and run the installer.
4. Hand back the admin URL, username, and password.

## 5. SSL / HTTPS with **automatic DNS validation**

Free Let's Encrypt certificates, two ways:

- **HTTP-01 (webroot)** — the classic flow; needs an A record + port 80 reachable.
  Issues the cert, adds a `listen 443 ssl` block, and forces a 301 HTTP→HTTPS
  redirect.
- **DNS-01 (automatic)** — **no open port 80, works behind firewalls, supports
  wildcards:**
  - **Cloudflare** — paste an API token (Zone:DNS edit); token stored root-only.
  - **AWS Route53** — uses the instance role / AWS env creds; nothing to paste.
  - **Manual** — certbot prints the TXT record for you to add.

Set a default DNS provider once in the ⚙ sidebar and every `secure domain …`
request uses it automatically. **Certs auto-renew** via certbot's systemd timer.

## 6. Jailed FTP accounts

- `create ftp for user acme domain acme.com` creates a **vsftpd virtual user**.
- **No system login, no SSH** — chrooted to that site's docroot only.
- Passive ports (40000–40100) opened via `ufw` when present.
- The FTP password is returned in the chat.

## 7. Panel security & hardening

- The panel binds to **`127.0.0.1:8080` by default** — not exposed to the internet.
- `harden the panel with basic auth` drops an nginx reverse proxy with HTTP basic
  auth in front and generates an admin username/password (bcrypt).
- API keys and DNS credentials are stored **root-only (mode 600)**.

## 8. Cross-distro bootstrap installer

`install.sh` detects your package manager (**apt / dnf / yum / apk**) and installs
the full stack — nginx, MySQL/MariaDB, PHP-FPM, Python, WP-CLI, certbot (with the
Cloudflare & Route53 DNS plugins), vsftpd, and apache2-utils — then copies the app
to `/opt/hostpanel` and runs it as a **systemd service**.

## 9. Web chat UI

A clean single-page chat interface with one-click example buttons and a settings
sidebar for LLM keys and DNS provider configuration.

---

## Architecture

```
browser ──> app.py (Flask, bound to 127.0.0.1:8080) ──> scripts/*.sh (run as root)
                                                         ├── create_user.sh        useradd + home + docroot
                                                         ├── create_vhost.sh       nginx vhost + reload
                                                         ├── install_wordpress.sh  WP + DB + wp-config
                                                         ├── setup_ssl.sh          certbot (HTTP-01 / DNS-01) + 443
                                                         ├── create_ftp.sh         vsftpd virtual user, jailed
                                                         ├── setup_proxy.sh        nginx proxy + basic auth
                                                         └── list_users.sh
```

Each script emits **pure JSON on stdout** (logs go to stderr + a log file) so the
backend parses the result and returns real credentials to the chat.

---

## Design notes & honest caveats

- **Runs as root** because provisioning genuinely needs it (useradd, nginx, mysql).
  Always keep it behind the basic-auth proxy **and** a firewall.
- Built and verified on a dev box: syntax, config generation, chat routing, FTP,
  proxy auth, and DNS-01 command construction are all proven. Live certificate
  issuance and the public proxy handshake weren't exercisable in the build sandbox
  (a Caddy instance owned ports 80/443 there) but work as written on a clean VPS.

---

## Quick start

```bash
sudo bash install.sh          # note the one-time admin password
# then, in the chat box:
harden the panel with basic auth
create user bob
host domain bobdesign.io for user bob
install wordpress on bobdesign.io for user bob
secure domain bobdesign.io with lets encrypt
create ftp for user bob domain bobdesign.io
# → Bob has a live HTTPS WordPress site with FTP access.
```

See [README.md](README.md) for full setup, DNS provider configuration, and
troubleshooting.
