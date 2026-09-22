#!/usr/bin/env python3
"""
Mac ID licence admin — issue keys, and keep a record of who has one.

    ./server.py            then open http://127.0.0.1:8787

Binds to 127.0.0.1 ONLY, and that is not a detail. Minting a licence requires the Ed25519 private
key in the login keychain, so anything that can reach this server can issue unlimited licences for
your app. It must never be exposed to a network or put behind a tunnel.

Storage is a plain JSON file next to this script. No database, no dependencies beyond the standard
library, and a format you can read, grep and back up without any tooling.
"""

import json
import os
import re
import secrets
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(HERE, "licenses.json")
LICENSE_TOOL = os.path.join(HERE, "bin", "macid-license")
HOST, PORT = "127.0.0.1", 8787

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


# ----------------------------------------------------------------- storage

def load():
    if not os.path.exists(STORE):
        return []
    with open(STORE) as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError:
            # Never silently start from empty — that would look like the records vanished.
            raise SystemExit(f"{STORE} is not valid JSON. Fix or move it; refusing to overwrite.")


def save(rows):
    # Write to a sibling then rename: a crash mid-write must not truncate the only copy of who
    # bought what.
    tmp = STORE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(rows, fh, indent=2)
    os.replace(tmp, STORE)


# ----------------------------------------------------------------- minting

def mint():
    """Returns (key, license_id). Raises if the signing key isn't reachable."""
    if not os.path.exists(LICENSE_TOOL):
        raise RuntimeError(
            f"Licence tool not built. Run:\n"
            f"  swiftc -O -o {LICENSE_TOOL} ../../src/tools/licensetool/main.swift"
        )
    proc = subprocess.run([LICENSE_TOOL, "mint"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "macid-license failed")
    key = proc.stdout.strip()
    # The tool prints `id=<n> issued=<date>` to stderr.
    m = re.search(r"id=(\d+)", proc.stderr)
    return key, (m.group(1) if m else "")


def verify(key):
    if not os.path.exists(LICENSE_TOOL):
        return False
    return subprocess.run([LICENSE_TOOL, "verify", key],
                          capture_output=True, text=True).returncode == 0


# ----------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # the dashboard is the UI; request spam is noise

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        # This server can mint licences; never let a page from elsewhere talk to it.
        self.send_header("Access-Control-Allow-Origin", "null")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as fh:
                return self._send(200, fh.read(), "text/html; charset=utf-8")
        if path == "/api/licenses":
            return self._send(200, json.dumps(load()))
        if path == "/api/export.csv":
            rows = load()
            out = ["name,email,key,license_id,price,note,issued,revoked"]
            for r in rows:
                out.append(",".join('"' + str(r.get(k, "")).replace('"', '""') + '"'
                                    for k in ("name", "email", "key", "license_id",
                                              "price", "note", "issued", "revoked")))
            return self._send(200, "\n".join(out), "text/csv")
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._send(400, json.dumps({"error": "bad JSON"}))

        if path == "/api/issue":
            name = (payload.get("name") or "").strip()
            email = (payload.get("email") or "").strip()
            if not name:
                return self._send(400, json.dumps({"error": "A name is required."}))
            if not EMAIL_RE.match(email):
                return self._send(400, json.dumps({"error": "That email doesn't look right."}))

            rows = load()
            # Warn rather than block: reissuing to the same person is legitimate (lost key, second
            # machine), but doing it by accident is not, so the caller has to confirm.
            if any(r["email"].lower() == email.lower() and not r.get("revoked")
                   for r in rows) and not payload.get("confirm_duplicate"):
                return self._send(409, json.dumps({
                    "error": "duplicate",
                    "message": f"{email} already has an active licence. Issue another?"}))

            try:
                key, license_id = mint()
            except Exception as exc:
                return self._send(500, json.dumps({"error": str(exc)}))

            row = {
                "name": name,
                "email": email,
                "key": key,
                "license_id": license_id,
                "price": payload.get("price", "4.99"),
                "note": (payload.get("note") or "").strip(),
                "issued": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "revoked": "",
                "ref": secrets.token_hex(4),
            }
            rows.append(row)
            save(rows)
            return self._send(200, json.dumps(row))

        if path == "/api/revoke":
            # A note only. Licences verify offline against the public key, so nothing can actually
            # withdraw one already issued — this records that you consider it void, and is the
            # honest limit of an offline scheme.
            ref = payload.get("ref")
            rows = load()
            for r in rows:
                if r.get("ref") == ref:
                    r["revoked"] = "" if r.get("revoked") else datetime.now(
                        timezone.utc).isoformat(timespec="seconds")
                    save(rows)
                    return self._send(200, json.dumps(r))
            return self._send(404, json.dumps({"error": "not found"}))

        return self._send(404, json.dumps({"error": "not found"}))


def main():
    if not os.path.exists(LICENSE_TOOL):
        print(f"! Licence tool missing at {LICENSE_TOOL}")
        print("  Build it once with:")
        print(f"    swiftc -O -o '{LICENSE_TOOL}' "
              f"'{os.path.abspath(os.path.join(HERE, '../../src/tools/licensetool/main.swift'))}'")
        print()
    print(f"Mac ID licence admin  →  http://{HOST}:{PORT}")
    print(f"records: {STORE}")
    print("bound to localhost only — this can mint licences, never expose it\n")
    try:
        HTTPServer((HOST, PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
