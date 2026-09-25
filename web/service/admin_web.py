#!/usr/bin/env python3
"""
The Mac ID admin dashboard, hosted on the Windows PC next to the fulfilment service so it's up
whenever the store is.

    C:\\MacIDService\\admin\\admin_web.py     (with server.py and index.html from web/admin/)

It is the same dashboard as web/admin/server.py on the Mac, with three differences:

* Reachable only through Tailscale Serve. It binds to 127.0.0.1; Tailscale publishes it to the
  owner's tailnet (never the internet, never Cloudflare) and stamps every request with the visitor's
  Tailscale login, which must be on the allow-list in admin-web.json. There is no password to leak.
* It can't mint keys. The minting secret stays on the Mac. A free licence issued here is taken from
  the same pre-minted pool as sales, through the fulfilment service, under its lock.
* Hand-issued licences are kept in C:\\MacIDService\\manual.json.
"""

import json
import os
import sys
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import server as base  # noqa: E402  (web/admin/server.py, copied alongside)

SETTINGS = os.path.join(SERVICE_DIR, "admin-web.json")
PORT = 8788

base.STORE = os.path.join(SERVICE_DIR, "manual.json")
base.SERVICE_CONFIG = os.path.join(SERVICE_DIR, "config.json")


def take_from_pool():
    """Stands in for minting: one key from the store's pool. Same (key, licence id) shape."""
    result = base.service_call("/api/pool/take", {})
    if not result.get("key"):
        raise RuntimeError(result.get("error") or "The key pool is empty. Top it up from the Mac.")
    return result["key"], ""


base.mint = take_from_pool

with open(SETTINGS, encoding="utf-8-sig") as fh:
    settings = json.load(fh)
ALLOWED_LOGINS = {login.lower() for login in settings["allowed_logins"]}

BANNER_MAC = "Local only. This page mints licences using the private signing key in your keychain — never put it on a network or behind a tunnel."
BANNER_PC = "Private: only your Tailscale account can open this page. Free licences come from the store’s key pool, so the signing key never leaves your Mac."


class Handler(base.Handler):
    ALLOWED_HOSTS = {h.lower() for h in settings["hosts"]} | {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}

    def _authorized(self):
        # Set by Tailscale Serve for requests from a signed-in tailnet user, and stripped from
        # anything a client sends itself, so it can't be forged from outside this machine.
        return (self.headers.get("Tailscale-User-Login") or "").lower() in ALLOWED_LOGINS

    def do_GET(self):
        path = base.urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html") and not self._refused():
            with open(os.path.join(HERE, "index.html"), encoding="utf-8") as fh:
                page = fh.read().replace(BANNER_MAC, BANNER_PC)
            return self._send(200, page, "text/html; charset=utf-8")
        return super().do_GET()


if __name__ == "__main__":
    print(f"Mac ID admin (PC) on 127.0.0.1:{PORT}, published by Tailscale Serve")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
