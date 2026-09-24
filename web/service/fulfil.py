#!/usr/bin/env python3
"""
Mac ID order fulfilment.

Runs on the Windows box behind Caddy (which proxies /api/* here). Lemon Squeezy calls
/api/ls/webhook when someone pays; this hands them the next licence key from a pre-minted pool
and files it under the claim token their browser generated, so the checkout page can show it
the moment payment completes.

Two deliberate properties:

* It never holds the licence-minting secret. Keys are minted on the Mac with
  `macid-license mint-batch` and shipped here as a finite pool. If this machine is ever
  compromised, what leaks is the unused pool - not the ability to mint unlimited licences.
  That is also why this is a separate program from the Mac's admin server, which CAN mint:
  do not merge them.
* Every request that changes state is authenticated. Webhooks must carry Lemon Squeezy's
  HMAC-SHA256 signature over the raw body; the sales feed needs the admin token. The claim
  endpoint needs only the buyer's own unguessable token.

Stdlib only, so it runs on a bare Python install with nothing to keep updated.
"""

import hashlib
import hmac
import json
import os
import re
import sys
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.json")
POOL = os.path.join(HERE, "pool.txt")
POOL_INCOMING = os.path.join(HERE, "pool-incoming.txt")
SALES = os.path.join(HERE, "sales.json")
ACTIVATIONS = os.path.join(HERE, "activations.json")
TERMS = os.path.join(HERE, "terms.json")
TRIALS = os.path.join(HERE, "trials.json")
LOG = os.path.join(HERE, "fulfil.log")

HOST, PORT = "127.0.0.1", 8790
MAX_BODY = 256 * 1024
CLAIM_RE = re.compile(r"^[A-Za-z0-9_-]{22,64}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
TERMS_VERSION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

LOCK = threading.Lock()


# ------------------------------------------------------------------ plumbing

def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(message):
    line = f"{now()} {message}"
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def load_config():
    # utf-8-sig: Windows PowerShell writes a byte-order mark, which plain utf-8 json.load rejects.
    with open(CONFIG, encoding="utf-8-sig") as fh:
        config = json.load(fh)
    for required in ("webhook_secret", "admin_token", "receipt_secret"):
        if not config.get(required):
            raise SystemExit(f"config.json is missing {required!r}")
    return config


def read_json(path, default):
    if not os.path.exists(path):
        return default
    with open(path, encoding="utf-8") as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError:
            # Never carry on from an empty store: that would make every past sale look unfulfilled
            # and hand out fresh keys on the next retry. Stop and make someone look.
            raise SystemExit(f"{path} is not valid JSON - refusing to continue")


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)


# ------------------------------------------------------------------ key pool

def _read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [line.strip() for line in fh if line.strip()]


def merge_incoming():
    """Top-ups land in a separate file so a copy in progress can never race a sale."""
    incoming = _read_lines(POOL_INCOMING)
    if not incoming:
        return
    pool = _read_lines(POOL)
    seen = set(pool)
    pool += [k for k in incoming if k not in seen]
    tmp = POOL + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(pool) + ("\n" if pool else ""))
    os.replace(tmp, POOL)
    os.remove(POOL_INCOMING)
    log(f"pool topped up with {len(incoming)} keys, now {len(pool)}")


def pop_key():
    merge_incoming()
    pool = _read_lines(POOL)
    if not pool:
        return None, 0
    key, rest = pool[0], pool[1:]
    tmp = POOL + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(rest) + ("\n" if rest else ""))
    os.replace(tmp, POOL)
    return key, len(rest)


def pool_size():
    return len(_read_lines(POOL)) + len(_read_lines(POOL_INCOMING))


# ------------------------------------------------------------------ email (optional)

def email_configured(config):
    return bool(config.get("resend_api_key") and config.get("email_from"))


def send_email(config, to, subject, text):
    """Sends through Resend. Returns a short result string for the log; never raises."""
    if not email_configured(config):
        return "not configured"
    body = json.dumps({"from": config["email_from"], "to": [to], "subject": subject, "text": text,
                       "reply_to": "support@macid.net"}).encode()
    request = urllib.request.Request(
        "https://api.resend.com/emails", data=body, method="POST",
        headers={"Authorization": f"Bearer {config['resend_api_key']}", "Content-Type": "application/json",
                 "User-Agent": "MacID-Fulfilment/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return f"sent ({response.status})"
    except Exception as exc:  # noqa: BLE001 - any failure is recorded, never fatal
        return f"failed: {exc}"


def send_key_email(config, sale):
    """Backup delivery. The page shows the key directly; this covers a closed tab."""
    if not email_configured(config) or not sale.get("email") or not sale.get("key"):
        return "not configured"
    first = (sale.get("name") or "").split(" ")[0] or "there"
    text = (
        f"Hi {first},\n\n"
        f"Thanks for buying Mac ID. Your licence key:\n\n"
        f"    {sale['key']}\n\n"
        f"Paste it into Mac ID when it asks, or in Settings > About. It never expires, and it "
        f"activates on one Mac; to move it to a new Mac, just reply to this email.\n\n"
        f"Keep this email. If you ever lose your key, search your inbox for \"Mac ID licence key\" "
        f"and it'll be right here.\n\n"
        f"Download: https://macid.net\n"
    )
    return send_email(config, sale["email"], "Your Mac ID licence key", text)


# ------------------------------------------------------------------ lost key recovery

EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$")
RECOVER_WINDOW = 3600
RECOVER_PER_EMAIL = 3
RECOVER_PER_IP = 10
_recover_hits = {}


def _rate_limited(bucket, limit):
    stamp = time.time()
    hits = [t for t in _recover_hits.get(bucket, []) if stamp - t < RECOVER_WINDOW]
    _recover_hits[bucket] = hits
    if len(hits) >= limit:
        return True
    hits.append(stamp)
    return False


def handle_recover(config, payload, client_ip):
    """"Lost your key?" on the website. Email is the login: the key is only ever sent to the
    address the order was placed with, so knowing someone's email gets you nothing but sending them
    their own key. The answer is the same whether or not the address bought anything, so the form
    can't be used to find out who's a customer."""
    email = str(payload.get("email") or "").strip().lower()
    if not EMAIL_RE.match(email) or len(email) > 254:
        return 400, {"error": "bad email"}
    if not email_configured(config):
        return 503, {"error": "email not configured"}
    with LOCK:
        if _rate_limited("ip:" + client_ip, RECOVER_PER_IP) or _rate_limited("email:" + email, RECOVER_PER_EMAIL):
            return 429, {"error": "too many requests"}
        sales = [s for s in read_json(SALES, {}).values()
                 if (s.get("email") or "").strip().lower() == email and s.get("key") and not s.get("refunded")]
    if sales:
        keys = "\n".join(f"    {s['key']}" for s in sales)
        first = (sales[-1].get("name") or "").split(" ")[0] or "there"
        text = (
            f"Hi {first},\n\n"
            f"Here {'is your' if len(sales) == 1 else 'are your'} Mac ID licence key{'' if len(sales) == 1 else 's'}:\n\n"
            f"{keys}\n\n"
            f"Paste it into Mac ID when it asks, or in Settings > About.\n\n"
            f"A key activates on one Mac. If you've moved to a new Mac, reply to this email and we'll move "
            f"it for you.\n\n"
            f"If you didn't ask for this, you can ignore it - the key was only sent to you.\n\n"
            f"Download: https://macid.net\n"
        )

        def run():
            result = send_email(config, sales[-1]["email"], "Your Mac ID licence key", text)
            log(f"recovery for {email.split('@')[0][:3]}***: {len(sales)} key(s), email {result}")
        threading.Thread(target=run, daemon=True).start()
    else:
        log("recovery: no order for that email")
    return 200, {"ok": True}


def email_in_background(config, order_id):
    def run():
        with LOCK:
            sale = read_json(SALES, {}).get(order_id)
        if not sale:
            return
        result = send_key_email(config, sale)
        with LOCK:
            sales = read_json(SALES, {})
            if order_id in sales:
                sales[order_id]["emailed"] = result
                write_json(SALES, sales)
        log(f"order {order_id}: email {result}")
    threading.Thread(target=run, daemon=True).start()


# ------------------------------------------------------------------ order handling

def handle_order_created(config, payload):
    data = payload.get("data") or {}
    attrs = data.get("attributes") or {}
    order_id = str(data.get("id") or "")
    if not order_id:
        return 400, {"error": "no order id"}
    if attrs.get("status") != "paid":
        log(f"order {order_id}: status {attrs.get('status')!r}, not issuing")
        return 200, {"ok": True, "issued": False}

    # A test-mode checkout is paid with Lemon Squeezy's public test card, so anyone who finds it could
    # "buy" a real, working key for nothing. Test orders only draw from the pool while
    # `allow_test_orders` is switched on for a deliberate end-to-end test.
    if attrs.get("test_mode") and not config.get("allow_test_orders"):
        log(f"order {order_id}: test-mode order ignored (allow_test_orders is off)")
        return 200, {"ok": True, "issued": False, "ignored": "test order"}

    custom = (payload.get("meta") or {}).get("custom_data") or {}
    claim = str(custom.get("claim") or "")
    # The version of the Terms of Use the buyer ticked before checkout. Checked by format only: the
    # website won't open checkout without it, so an order missing it didn't come through that page.
    terms = str(custom.get("terms") or "")
    terms = terms if TERMS_VERSION_RE.match(terms) else ""
    if claim and not CLAIM_RE.match(claim):
        claim = ""

    with LOCK:
        sales = read_json(SALES, {})
        # Lemon Squeezy retries until it gets a 2xx, so the same order can arrive more than once.
        # Issuing again would give one buyer two keys and drain the pool.
        if order_id in sales:
            return 200, {"ok": True, "duplicate": True}

        key, remaining = pop_key()
        sales[order_id] = {
            "order_id": order_id,
            "order_number": attrs.get("order_number"),
            "name": attrs.get("user_name") or "",
            "email": attrs.get("user_email") or "",
            "total": attrs.get("total_formatted") or "",
            "currency": attrs.get("currency") or "",
            "test_mode": bool(attrs.get("test_mode")),
            "created": now(),
            "claim": claim,
            "terms": terms,
            "terms_accepted": now() if terms else "",
            "key": key,
            "status": "issued" if key else "awaiting key",
            "refunded": "",
            "emailed": "",
        }
        write_json(SALES, sales)

    if key:
        log(f"order {order_id}: issued a key to {sales[order_id]['email']}, {remaining} left in pool")
        if remaining < int(config.get("low_stock_warning", 20)):
            log(f"WARNING: only {remaining} keys left - top up the pool")
        email_in_background(config, order_id)
    else:
        # Still a 200: making Lemon Squeezy retry would not conjure a key, and the sale is recorded
        # so it can be fulfilled by hand from the admin dashboard.
        log(f"ERROR order {order_id}: POOL EMPTY - fulfil by hand")
    return 200, {"ok": True, "issued": bool(key)}


def handle_order_refunded(payload):
    order_id = str((payload.get("data") or {}).get("id") or "")
    with LOCK:
        sales = read_json(SALES, {})
        if order_id in sales:
            # Recorded, not enforced: keys verify offline, so a refund cannot switch one off.
            sales[order_id]["refunded"] = now()
            write_json(SALES, sales)
    log(f"order {order_id}: refunded")
    return 200, {"ok": True}


# ------------------------------------------------------------------ activation
#
# One Mac per licence. The app sends a SHA-256 of the licence key (never the key itself) and a SHA-256
# fingerprint of the Mac's hardware UUID. The first Mac to ask gets the key; the same Mac asking again
# (a reinstall) is fine; any other Mac is refused until the binding is released from the admin
# dashboard. Storing only hashes means this file can't be mined for working keys, and a key can't be
# claimed by someone who doesn't already have it.

def receipt_for(config, key_hash, machine):
    """What the app stores as proof of activation. Bound to both the key and the Mac, so copying a
    receipt to another Mac doesn't carry the licence with it."""
    message = f"macid-activation-v1|{key_hash}|{machine}".encode()
    return hmac.new(config["receipt_secret"].encode(), message, hashlib.sha256).hexdigest()


def handle_activate(config, payload):
    key_hash = str(payload.get("key_hash") or "").lower()
    machine = str(payload.get("machine") or "").lower()
    if not HEX64_RE.match(key_hash) or not HEX64_RE.match(machine):
        return 400, {"error": "bad request"}
    with LOCK:
        activations = read_json(ACTIVATIONS, {})
        row = activations.get(key_hash)
        if row and row.get("machine") != machine:
            row["refused"] = row.get("refused", 0) + 1
            row["last_refused"] = now()
            write_json(ACTIVATIONS, activations)
            log(f"activation REFUSED: key {key_hash[:10]} is bound to another Mac")
            return 409, {"error": "already_activated"}
        if not row:
            row = {"machine": machine, "activated": now(), "refused": 0}
            log(f"activation: key {key_hash[:10]} bound to Mac {machine[:10]}")
        row["last_seen"] = now()
        row["version"] = clean(payload.get("version"), 16)
        row["os"] = clean(payload.get("os"), 24)
        terms = str(payload.get("terms") or "")
        if TERMS_VERSION_RE.match(terms):
            row["terms"] = terms
        activations[key_hash] = row
        write_json(ACTIVATIONS, activations)
    return 200, {"ok": True, "receipt": receipt_for(config, key_hash, machine)}


def handle_terms_accept(payload):
    """A copy of Mac ID recording that its user agreed to a version of the Terms of Use. Keyed by the
    same hashed Mac fingerprint as activation, so a purchase, an activation and an agreement on the
    same Mac line up in the admin dashboard - without ever storing anything identifying."""
    machine = str(payload.get("machine") or "").lower()
    version = str(payload.get("version") or "")
    if not HEX64_RE.match(machine) or not TERMS_VERSION_RE.match(version):
        return 400, {"error": "bad request"}
    with LOCK:
        records = read_json(TERMS, {})
        row = records.get(machine) or {"accepted": {}}
        row["accepted"].setdefault(version, now())
        row["latest"] = version
        row["app_version"] = clean(payload.get("app_version"), 16)
        row["os"] = clean(payload.get("os"), 24)
        row["last_seen"] = now()
        records[machine] = row
        write_json(TERMS, records)
    log(f"terms {version} accepted on Mac {machine[:10]}")
    return 200, {"ok": True}


def handle_trial(payload):
    """One free trial per Mac. The app calls this when a trial starts and at launch while one is
    running; the answer is the earliest start this Mac has ever reported, and the app adopts it.
    That is what stops a trial being renewed by deleting its keychain record, reinstalling, or
    making a new macOS user account - all of which the local record alone can't see."""
    machine = str(payload.get("machine") or "").lower()
    if not HEX64_RE.match(machine):
        return 400, {"error": "bad request"}
    current = time.time()
    try:
        claimed = float(payload.get("started") or current)
    except (TypeError, ValueError):
        claimed = current
    # A start in the future would lengthen the trial; only ever accept one that shortens it.
    claimed = min(claimed, current)
    with LOCK:
        records = read_json(TRIALS, {})
        row = records.get(machine)
        if not row:
            row = {"started_ts": claimed, "first_seen": now()}
            log(f"trial started on Mac {machine[:10]}")
        row["started_ts"] = min(float(row.get("started_ts") or claimed), claimed)
        row["started"] = datetime.fromtimestamp(row["started_ts"], timezone.utc).isoformat(timespec="seconds")
        row["last_seen"] = now()
        row["app_version"] = clean(payload.get("app_version"), 16)
        row["os"] = clean(payload.get("os"), 24)
        records[machine] = row
        write_json(TRIALS, records)
    return 200, {"ok": True, "started": row["started_ts"]}


def clean(value, limit):
    return re.sub(r"[^A-Za-z0-9._ -]", "", str(value or ""))[:limit]


# ------------------------------------------------------------------ HTTP

class Handler(BaseHTTPRequestHandler):
    config = None

    def log_message(self, *args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _admin_ok(self):
        supplied = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        return bool(supplied) and hmac.compare_digest(supplied, self.config["admin_token"])

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path.rstrip("/")

        if path == "/api/health":
            return self._send(200, {"ok": True})

        if path == "/api/claim":
            token = (parse_qs(url.query).get("token") or [""])[0]
            if not CLAIM_RE.match(token):
                return self._send(400, {"error": "bad token"})
            with LOCK:
                matches = [s for s in read_json(SALES, {}).values() if s.get("claim") == token]
            ready = [s for s in matches if s.get("key")]
            if ready:
                return self._send(200, {
                    "status": "ready",
                    "keys": [s["key"] for s in ready],
                    "name": ready[-1].get("name", ""),
                    "email": ready[-1].get("email", ""),
                    # Lets the page say "we've emailed it to you too" only when that's true.
                    "emailed": email_configured(self.config),
                })
            if matches:
                return self._send(200, {"status": "delayed"})
            return self._send(200, {"status": "pending"})

        if path == "/api/terms":
            if not self._admin_ok():
                return self._send(403, {"error": "forbidden"})
            with LOCK:
                return self._send(200, read_json(TERMS, {}))

        if path == "/api/trials":
            if not self._admin_ok():
                return self._send(403, {"error": "forbidden"})
            with LOCK:
                return self._send(200, read_json(TRIALS, {}))

        if path == "/api/activations":
            if not self._admin_ok():
                return self._send(403, {"error": "forbidden"})
            with LOCK:
                return self._send(200, read_json(ACTIVATIONS, {}))

        if path == "/api/sales":
            if not self._admin_ok():
                return self._send(403, {"error": "forbidden"})
            with LOCK:
                sales = list(read_json(SALES, {}).values())
                remaining = pool_size()
            return self._send(200, {"sales": sales, "pool_remaining": remaining})

        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        if path in ("/api/activate", "/api/activation/release", "/api/terms/accept", "/api/trial", "/api/recover"):
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 4096:
                return self._send(413, {"error": "bad length"})
            try:
                payload = json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, ValueError):
                return self._send(400, {"error": "bad JSON"})
            if path == "/api/activate":
                return self._send(*handle_activate(self.config, payload))
            if path == "/api/terms/accept":
                return self._send(*handle_terms_accept(payload))
            if path == "/api/trial":
                return self._send(*handle_trial(payload))
            if path == "/api/recover":
                client_ip = (self.headers.get("CF-Connecting-IP")
                             or (self.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
                             or self.client_address[0])
                return self._send(*handle_recover(self.config, payload, client_ip))
            # Releasing a binding lets a key move to another Mac - admin only, or "only works once"
            # would mean nothing.
            if not self._admin_ok():
                return self._send(403, {"error": "forbidden"})
            key_hash = str(payload.get("key_hash") or "").lower()
            with LOCK:
                activations = read_json(ACTIVATIONS, {})
                released = activations.pop(key_hash, None)
                write_json(ACTIVATIONS, activations)
            log(f"activation released for key {key_hash[:10]}" if released else f"release: no binding for {key_hash[:10]}")
            return self._send(200, {"ok": True, "released": bool(released)})

        if path != "/api/ls/webhook":
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._send(413, {"error": "bad length"})
        raw = self.rfile.read(length)

        # Signature over the exact bytes received - verify before parsing anything.
        expected = hmac.new(self.config["webhook_secret"].encode(), raw, hashlib.sha256).hexdigest()
        supplied = self.headers.get("X-Signature", "")
        if not hmac.compare_digest(expected, supplied):
            log("rejected a webhook with a bad signature")
            return self._send(401, {"error": "bad signature"})

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            return self._send(400, {"error": "bad JSON"})

        event = (payload.get("meta") or {}).get("event_name")
        if event == "order_created":
            code, body = handle_order_created(self.config, payload)
        elif event == "order_refunded":
            code, body = handle_order_refunded(payload)
        else:
            code, body = 200, {"ok": True, "ignored": event}
        return self._send(code, body)


def main():
    Handler.config = load_config()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else PORT
    log(f"fulfilment service on http://{HOST}:{port}, {pool_size()} keys in pool")
    ThreadingHTTPServer((HOST, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
