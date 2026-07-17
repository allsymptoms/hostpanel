# HostPanel — conventions for AI agents & contributors

AI chat web-hosting control panel: provision real Linux hosting by chatting in
plain English. Flask backend + regex chat parser (optional LLM) that shells out
to bash scripts running as root. Stack: Flask + nginx + bash, MariaDB, certbot.

## Architecture
- `app.py` — Flask backend. `handle_message()` parses intent (regex first, LLM
  optional) → `execute_intent()` → `run_script()` → `format_result()`.
- `scripts/*.sh` — one script per operation, invoked as root (systemd User=root).
- `scripts/lib.sh` — shared helpers, sourced by every script.
- `static/index.html` — chat UI.
- `install.sh` — cross-distro bootstrap installer (apt/dnf/yum/apk).

## Hard rules (break these and things silently fail)
- **Script stdout is PURE JSON.** All logs, progress, and errors go to stderr or
  the log file — never stdout. `run_script()` parses the *entire* stdout as one
  JSON object. A stray `echo` to stdout corrupts the parse.
- **Errors:** emit `{"status":"error","error":"..."}` to stdout and exit non-zero;
  `format_result()` renders `status==error` as a user-facing ❌.
- **Destructive actions are backup-first + confirmed.** delete/uninstall take a
  safety backup, then require a confirm token (`require_confirm()` →
  `PENDING_CONFIRM` → user replies "yes"). Support `--no-backup` as an opt-out arg.

## lib.sh helpers (reuse, don't reinvent)
- `docroot_for <user> [domain]` — per-domain docroot
  `/opt/hostpanel/users/<user>/www/<domain>` (omit domain for the user-level dir).
  Multiple sites per user are isolated on disk.
- `audit <action> <result> [args]` — append-only JSON audit log.
- `mysql_exec` — run SQL as root.
- Path vars are **env-overridable** for test isolation: `HOSTPANEL_ROOT`,
  `NGINX_AVAILABLE`, `NGINX_ENABLED`. Never hardcode `/etc/nginx/...` or
  `/opt/hostpanel/...` — go through lib.sh.

## Data model
- User record: `${CONFIG_DIR}/user_<user>.json` with `sites:[]`.
- vhost: `/etc/nginx/sites-available/<domain>.conf` (type wordpress|php|static|proxy).
- WP DB: `wp_<user>_<domain-nodots>` (≤64 chars), DB user `wp_<user>`.

## Coding style
KISS / DRY. Match surrounding code. Concise, clever, elegant — shorthand over
ceremony. Clean the diff before every commit.

## Verification (no canonical test command)
- Write a focused throwaway script `/tmp/hermes-verify-*.sh`, run it against the
  changed behavior, clean it up, and report it as **ad-hoc** — not "suite green".
- Isolate side effects: export `HOSTPANEL_ROOT`/`NGINX_*` to a `mktemp -d` tree.
- CI (`.github/workflows/ci.yml`) runs on every push/PR: `bash -n` on all
  scripts, shellcheck (warnings non-fatal), `py_compile app.py`, and
  `tests/test_routing.py`.
- `tests/test_routing.py` asserts **intent routing** correctness and is designed
  to pass as a **non-root** user (privileged ops fail → the reply is still a
  proper ❌/confirm; the test checks routing, not privilege). Add a case here
  whenever you add a chat intent.

## Release flow
Commit → push main → tag `vX.Y.Z` → `git archive` tarball → GitHub Release with
the tarball asset. Never commit secrets; the token lives only in the push URL.
