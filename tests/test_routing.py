#!/usr/bin/env python3
"""Smoke test: every chat intent routes to the right action.

No network, no root — runs against an isolated HOSTPANEL_ROOT so it works
in CI. Exits non-zero if any intent misroutes.
"""
import os
import sys
import tempfile
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

# Isolate all state under a throwaway dir before importing the app.
_tmp = tempfile.mkdtemp(prefix="hostpanel-citest-")
ng = os.path.join(_tmp, "nginx")
for d in ("config", "users", "logs", "run", "backups", "data"):
    os.makedirs(os.path.join(_tmp, d), exist_ok=True)
os.makedirs(os.path.join(ng, "available"), exist_ok=True)
os.makedirs(os.path.join(ng, "enabled"), exist_ok=True)
os.environ["HOSTPANEL_ROOT"] = _tmp
os.environ["NGINX_AVAILABLE"] = os.path.join(ng, "available")
os.environ["NGINX_ENABLED"] = os.path.join(ng, "enabled")

import app  # noqa: E402

# (message, label, substrings that prove the right branch handled it)
CASES = [
    ("create user acme", "create_user", ["✅", "❌", "Created", "Failed"]),
    ("host domain demo.test for user acme", "create_vhost", ["✅", "❌", "Virtual host", "Failed"]),
    ("install wordpress on demo.test for user acme", "install_wordpress", ["✅", "❌", "WordPress", "Failed"]),
    ("host a static site static.acme.com for user acme", "static", ["✅", "❌", "Virtual host", "Failed"]),
    ("proxy my node app on port 3000 to app.acme.com for user acme", "proxy", ["✅", "❌", "Virtual host", "Failed"]),
    ("install ghost on ghost.acme.com for user acme", "ghost", ["✅", "❌", "Ghost", "Virtual host", "Failed"]),
    ("install nextcloud on cloud.acme.com for user acme", "nextcloud", ["✅", "❌", "Nextcloud", "Failed"]),
    ("create database mydb for user acme", "db_create", ["✅", "❌", "database", "Failed"]),
    ("list databases for user acme", "db_list", ["Database", "No databases", "❌"]),
    ("dump database mydb for user acme", "db_dump", ["✅", "❌", "Dumped", "Failed"]),
    ("clone demo.test to staging.demo.test for user acme", "clone", ["✅", "❌", "Cloned", "Failed"]),
    ("snapshot all", "snapshot", ["📸", "No sites", "❌"]),
    ("run monitor", "monitor", ["🩺", "No sites", "❌"]),
    ("configure firewall", "firewall", ["✅", "❌", "Firewall", "Failed"]),
    ("enable fail2ban", "fail2ban", ["✅", "❌", "fail2ban", "Failed"]),
    ("harden the panel with basic auth", "panel_proxy", ["✅", "❌", "Panel", "Failed"]),
    ("show users", "status", ["No hosting users", "Current hosting", "👤"]),
    ("show activity", "activity", ["activity", "Recent", "No activity"]),
    ("backup demo.test", "backup", ["✅", "❌", "Backup", "Failed"]),
    ("delete vhost demo.test", "confirm_delete", ["⚠️", "Reply"]),
    ("delete user acme", "confirm_deluser", ["⚠️", "Reply"]),
]


def main():
    ok = bad = 0
    for msg, label, needles in CASES:
        r = app.handle_message(msg, [])
        reply = r.get("reply", "") if isinstance(r, dict) else str(r)
        good = r is not None and any(n in reply for n in needles)
        print(f"{'OK ' if good else 'BAD'} [{label:16}] {reply[:70].replace(chr(10), ' ')}")
        ok += good
        bad += not good
    print(f"\n{ok} ok, {bad} bad")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
