#!/usr/bin/env python3
"""
Turns on licence-key emails: stores a Resend API key in the fulfilment service's config on the PC
and restarts the service.

    python3 web/service/set_email_key.py

Run it yourself. The key is typed at a hidden prompt and goes straight to the PC over SSH on stdin,
so it never appears on screen, in shell history, in a process list, or in this repo.

Once it's in, every purchase is emailed its key from keys@macid.net (replies go to
support@macid.net), and the "Lost your key?" form on macid.net starts working.
"""
import getpass
import json
import re
import subprocess
import sys
import urllib.request

HOST = "samue@100.112.210.4"
SENDER = "Mac ID <keys@macid.net>"

key = getpass.getpass("Resend API key (starts with re_, input hidden): ").strip()
if not re.fullmatch(r"re_[A-Za-z0-9_]{10,}", key):
    sys.exit("That doesn't look like a Resend API key. They start with re_ and have no spaces.")

# Single-quoted PowerShell strings don't interpolate, and the pattern above rules out quotes.
# WriteAllText writes UTF-8 without the byte-order mark Set-Content would add.
script = f"""
$ErrorActionPreference = 'Stop'
$path = 'C:\\MacIDService\\config.json'
$c = Get-Content $path -Raw | ConvertFrom-Json
$c | Add-Member -NotePropertyName resend_api_key -NotePropertyValue '{key}' -Force
$c | Add-Member -NotePropertyName email_from -NotePropertyValue '{SENDER}' -Force
[System.IO.File]::WriteAllText($path, ($c | ConvertTo-Json -Depth 5))
Stop-ScheduledTask -TaskName 'MacID-Fulfilment'
Start-Sleep 2
Start-ScheduledTask -TaskName 'MacID-Fulfilment'
Start-Sleep 4
'saved and restarted'
"""
result = subprocess.run(["ssh", "-o", "ConnectTimeout=15", HOST, "powershell -NoProfile -Command -"],
                        input=script, text=True, capture_output=True)
if "saved and restarted" not in result.stdout:
    sys.exit("Couldn't update the PC:\n" + (result.stderr or result.stdout)[-800:])
print("Saved on the PC and restarted the service.")

# Proves the whole path end to end: a real email with a real key, sent only to an address that
# already has an order.
test = input("Send a test? Enter the email of an existing order (or press Return to skip): ").strip()
if test:
    request = urllib.request.Request(
        "https://macid.net/api/recover", data=json.dumps({"email": test}).encode(), method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "MacID-Setup/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            print(f"Asked for it ({response.status}). If {test} has an order, the key arrives in a minute.")
    except urllib.error.HTTPError as exc:
        print(f"The service said {exc.code}: {exc.read().decode()[:200]}")
