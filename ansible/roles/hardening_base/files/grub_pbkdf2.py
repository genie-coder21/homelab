#!/usr/bin/python3
"""Print a GRUB password_pbkdf2 hash for the password on stdin.  Runs on the Ansible controller.

  { hl-secret get <grub-secret-name>; echo; hl-secret get <grub-salt-secret-name>; } | python3 grub_pbkdf2.py <hostname>

stdin = line 1 the password, line 2 a separate random salt key.
Deterministic, so the role is idempotent: salt = HMAC-SHA256(salt key, "grub-salt:" + hostname) (32 bytes),
unique per host. The salt is never derived from the password, so reading the boot config gives no
shortcut past the PBKDF2 rounds.  Same algorithm GRUB uses to check it:
PBKDF2-HMAC-SHA512, 64-byte key, format grub.pbkdf2.sha512.<iterations>.<salt hex>.<hash hex>
(upper-case hex, like grub-mkpasswd-pbkdf2).  Verify mode (used by the self-test):
  python3 grub_pbkdf2.py --verify <grub.pbkdf2...>   (password on stdin) -> exit 0 if it matches
"""
import hashlib, hmac, sys

ITERATIONS = 100000


def make(pw: bytes, key: bytes, host: str) -> str:
    salt = hmac.new(key, b"grub-salt:" + host.encode(), hashlib.sha256).digest()
    dk = hashlib.pbkdf2_hmac("sha512", pw, salt, ITERATIONS, 64)
    return f"grub.pbkdf2.sha512.{ITERATIONS}.{salt.hex().upper()}.{dk.hex().upper()}"


def verify(pw: bytes, h: str) -> bool:
    _, _, alg, it, salt, dk = h.split(".")
    want = bytes.fromhex(dk)
    got = hashlib.pbkdf2_hmac(alg, pw, bytes.fromhex(salt), int(it), len(want))
    return hmac.compare_digest(got, want)


if __name__ == "__main__":
    lines = sys.stdin.buffer.read().split(b"\n")
    pw = lines[0].strip()
    if not pw:
        sys.exit("no password on stdin")
    if sys.argv[1] == "--verify":
        sys.exit(0 if verify(pw, sys.argv[2]) else 1)
    key = lines[1].strip() if len(lines) > 1 else b""
    if not key:
        sys.exit("no salt key on stdin line 2")
    print(make(pw, key, sys.argv[1]))
