"""Invite codes — the 15-character strings a person types on the login page.

ONE format serves both the bootstrap token that mints the very first admin and
every invite an admin issues afterwards, so the "I have an invite" box has
exactly one thing to parse and the operator has exactly one thing to explain.

The alphabet is Crockford base32 (no I, L, O or U), which buys three things a
raw hex or base64 code does not: no character pair that a human reads back
wrongly over a phone, no accidental profanity from the vowel U, and a documented
canonical mapping for the mistakes people DO make — a typed I or L means 1, a
typed O means 0. 15 characters is 75 bits, far past guessing, and short enough
to read aloud in three groups of five.

Codes are never stored, only their SHA-256: the state file is a list of hashes,
so a copy of it does not let the reader redeem an outstanding invite.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets

# Crockford base32: digits + uppercase letters, minus I, L, O, U.
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
LENGTH = 15
GROUP = 5

# What a human might type instead of the canonical character.
_CONFUSABLE = {"I": "1", "L": "1", "O": "0", "U": "V"}


def generate() -> str:
    """A fresh code in display form: XXXXX-XXXXX-XXXXX."""
    raw = "".join(secrets.choice(ALPHABET) for _ in range(LENGTH))
    return format_display(raw)


def format_display(code: str) -> str:
    """Group a canonical code for reading aloud. Input must be normalized."""
    return "-".join(code[i : i + GROUP] for i in range(0, len(code), GROUP))


def normalize(code: str) -> str:
    """Canonical form of whatever the user typed, or "" if it cannot be one.

    Dashes, spaces and case are noise; confusable characters are mapped the way
    Crockford specifies. Anything left outside the alphabet, or a wrong length,
    is not a code at all — the caller must treat "" as "no match" and never as
    "empty code matches empty stored value".
    """
    out = []
    for ch in code.upper():
        if ch in ("-", " ", "\t"):
            continue
        ch = _CONFUSABLE.get(ch, ch)
        if ch not in ALPHABET:
            return ""
        out.append(ch)
    joined = "".join(out)
    return joined if len(joined) == LENGTH else ""


def hash_code(code: str) -> str:
    """SHA-256 of the NORMALIZED code. Returns "" for anything unparseable, so a
    junk code can never collide with a stored hash."""
    canonical = normalize(code)
    if not canonical:
        return ""
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def matches(code: str, stored_hash: str) -> bool:
    """Constant-time comparison of a typed code against a stored hash."""
    candidate = hash_code(code)
    if not candidate or not stored_hash:
        return False
    return hmac.compare_digest(candidate, stored_hash)
