"""hl_gmail_import: put a message straight into the user's Gmail mailbox with the Gmail API (messages.import).

Why: the mail VPS has no outbound path except the mailbox provider's authenticated SMTP relay, which rewrites
From to the authenticating account, so every forward shows up as "me". messages.import keeps the headers
intact, is scanned and classified like SMTP delivery, and does not count against the relay's daily allowance.

Credentials: <oauth file> (JSON: client_id, client_secret, refresh_token; mode 0600, owner mailhold),
made once by hl-mailhold-auth. The short-lived access token is cached next to it. Nothing here ever sends mail.
Every failure returns (False, reason) so the caller can fall back to the SMTP relay.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

TOKEN_URL = "https://oauth2.googleapis.com/token"
IMPORT_URL = ("https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/import"
              "?uploadType=multipart&internalDateSource=dateHeader")
SCOPE = "https://www.googleapis.com/auth/gmail.insert"
TIMEOUT = 30


class AuthLapsed(Exception):
    """The refresh token was revoked or expired: a human must run hl-mailhold-auth again."""


def _access_token(oauth_file: Path, force: bool = False) -> str:
    cache = oauth_file.with_name(oauth_file.stem + "-access.json")
    if not force:
        try:
            c = json.loads(cache.read_text())
            if c.get("expires_at", 0) - 120 > time.time():
                return c["access_token"]
        except (OSError, ValueError, KeyError):
            pass
    creds = json.loads(oauth_file.read_text())
    data = urllib.parse.urlencode({"client_id": creds["client_id"], "client_secret": creds["client_secret"],
                                   "refresh_token": creds["refresh_token"], "grant_type": "refresh_token"}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=data), timeout=TIMEOUT) as r:
            tok = json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        if e.code in (400, 401) and "invalid_grant" in body:
            raise AuthLapsed(body) from None
        raise RuntimeError(f"token refresh HTTP {e.code}: {body}") from None
    tmp = cache.with_suffix(f".{uuid.uuid4().hex[:8]}.tmp")
    tmp.write_text(json.dumps({"access_token": tok["access_token"],
                               "expires_at": time.time() + int(tok.get("expires_in", 3600))}))
    os.chmod(tmp, 0o600)
    os.replace(tmp, cache)
    return tok["access_token"]


def deliver(raw: bytes, oauth_file: Path, labels: tuple[str, ...] = ("INBOX", "UNREAD")) -> tuple[bool, str]:
    """Import one RFC 822 message. -> (ok, detail); detail is the Gmail message id on success."""
    if not oauth_file.is_file():
        return False, "no oauth file"
    boundary = "mailhold-" + uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
            f"{json.dumps({'labelIds': list(labels)})}\r\n"
            f"--{boundary}\r\nContent-Type: message/rfc822\r\n\r\n").encode() + raw + f"\r\n--{boundary}--\r\n".encode()
    try:
        for attempt in (1, 2):
            token = _access_token(oauth_file, force=attempt == 2)
            req = urllib.request.Request(IMPORT_URL, data=body, method="POST",
                                         headers={"Authorization": f"Bearer {token}",
                                                  "Content-Type": f"multipart/related; boundary={boundary}"})
            try:
                with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                    return True, json.loads(r.read()).get("id", "?")
            except urllib.error.HTTPError as e:
                detail = e.read().decode(errors="replace")[:300]
                if e.code == 401 and attempt == 1:
                    continue
                return False, f"HTTP {e.code}: {detail}"
        return False, "unreachable"
    except AuthLapsed as e:
        return False, f"auth lapsed: {e}"
    except Exception as e:  # noqa: BLE001 - the caller falls back to the relay
        return False, f"{type(e).__name__}: {e}"[:300]
