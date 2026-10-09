#!/usr/bin/env python3
"""Generate a qBittorrent WebUI password hash (WebUI\\Password_PBKDF2).

qBittorrent stores the WebUI password as PBKDF2-HMAC-SHA512 with 100,000
iterations, a random 16-byte salt and a 64-byte key, written as
base64(salt):base64(key). Paste the output into vault_qbt_webui_password_pbkdf2.

Usage:
    python3 scripts/qbt-password-hash.py            # prompts for the password
    python3 scripts/qbt-password-hash.py --salt B64  # reuse a salt (for checking a hash)
"""
import argparse
import base64
import getpass
import hashlib
import os

ITERATIONS = 100_000


def qbt_hash(password: str, salt: bytes) -> str:
    key = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, ITERATIONS, dklen=64)
    return f"{base64.b64encode(salt).decode()}:{base64.b64encode(key).decode()}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--salt", help="base64 salt to reuse instead of a random one")
    args = parser.parse_args()

    password = getpass.getpass("WebUI password: ")
    if not args.salt and password != getpass.getpass("Again: "):
        raise SystemExit("Passwords don't match.")
    salt = base64.b64decode(args.salt) if args.salt else os.urandom(16)
    print(qbt_hash(password, salt))


if __name__ == "__main__":
    main()
