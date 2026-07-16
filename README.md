# HostPanel — AI Chat Web Hosting Control Panel

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
└── scripts/
    ├── lib.sh            # shared helpers (validation, logging, password gen)
    ├── create_user.sh
    ├── create_vhost.sh
    ├── install_wordpress.sh
    ├── setup_ssl.sh
    ├── create_ftp.sh
    ├── setup_proxy.sh
    └── list_users.sh
```

## Manual / troubleshooting

```bash
# logs
journalctl -u hostpanel -f
cat /opt/hostpanel/logs/provision.log

# list what the panel knows
bash /opt/hostpanel/scripts/list_users.sh

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
