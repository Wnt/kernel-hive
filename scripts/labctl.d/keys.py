"""labctl.d/keys.py — paced keystroke delivery: qcode tables, per-tile
pacing/remap lookups and the chord builder + sender used by `labctl type`
and `labctl key`. Moved verbatim out of scripts/labctl (size-exclusions.json
split, step 3). Imports from labctl.d/common only — never from labctl.
"""

import os, re, sys, time

from common import QmpConn, TILES_DIR, cdrv, die, is_x11_tile, read_env

# --- paced keystroke delivery -------------------------------------------------
#
# An emulator samples its keyboard ports ONCE PER EMULATED FRAME. What has to
# survive a frame is therefore the RELEASE->PRESS GAP between successive keys,
# not the key hold: with no gap the guest sees one continuous press and the
# second key never registers. Measured on mpf2 (MAME, 60 Hz) typing 16 keys:
# gap 0 ms -> 0/16 landed, 8 ms -> 4/16, 12 ms -> 12/16, 16 ms (one frame) ->
# 16/16. streamhost already solves this for the browser stream path with the
# per-tile SH_KEY_MIN_HOLD_MS / SH_KEY_MIN_GAP_MS knobs (mpf2 32/32,
# amstradcpc 40/40 for its 50 Hz scan); labctl drives QMP directly and used to
# bypass them entirely, so `labctl type mpf2 "PRINT 123456"` printed
# "ok: typed 12 chars" while the guest received "343456".
#
# So: where the tile declares those knobs, honour them here — QMP send-key's
# own hold-time argument for the hold, a real sleep for the gap. Where a tile
# declares nothing, behaviour is unchanged (the cdrv.py route).
PLAIN_QCODE = {
    " ": "spc",
    "\n": "ret",
    "\t": "tab",
    "-": "minus",
    "=": "equal",
    "[": "bracket_left",
    "]": "bracket_right",
    "\\": "backslash",
    ";": "semicolon",
    "'": "apostrophe",
    "`": "grave_accent",
    ",": "comma",
    ".": "dot",
    "/": "slash",
}
SHIFT_QCODE = {
    "!": "1",
    "@": "2",
    "#": "3",
    "$": "4",
    "%": "5",
    "^": "6",
    "&": "7",
    "*": "8",
    "(": "9",
    ")": "0",
    "_": "minus",
    "+": "equal",
    "{": "bracket_left",
    "}": "bracket_right",
    "|": "backslash",
    ":": "semicolon",
    '"': "apostrophe",
    "~": "grave_accent",
    "<": "comma",
    ">": "dot",
    "?": "slash",
}


def key_pacing(c, name):
    """(hold_ms, gap_ms) declared by the tile, or (None, None) when it declares
    nothing. Source of truth is the live station.env — the same file the daemon
    reads — so labctl and the stream path cannot drift apart."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    env = read_env(os.path.join(tile_dir, "station.env"))

    def ms(key):
        raw = env.get(key)
        if raw in (None, ""):
            return None
        try:
            return max(0, int(raw))
        except ValueError:
            return None

    return ms("SH_KEY_MIN_HOLD_MS"), ms("SH_KEY_MIN_GAP_MS")


_KEYMAP_ESCAPES = {"%25": "%", "%2C": ",", "%3A": ":"}


def keymap_unescape(tok):
    """Undo the three escapes the wire format needs.

    SH_KEY_MAP is `guest:host` pairs joined by commas, so a guest or host
    character that IS a colon or a comma cannot be written literally: ':' as a
    guest char renders as `::-`, whose split(':', 1) yields an empty guest and
    is silently DROPPED. That bites any German-layout machine — the KC 85/4
    puts ':' on the host '-' key — and it fails as one missing character rather
    than as an error. scripts/stations-registry.py percent-encodes exactly '%',
    ',' and ':' when it renders the value; nothing else is touched, so every
    map written before this existed parses unchanged.
    """
    return re.sub(r"%(25|2C|3A)", lambda m: _KEYMAP_ESCAPES["%" + m.group(1)], tok)


def key_remap(c, name):
    """Per-tile guest-char -> host-char remap, for keyboards whose layout does
    not match a PC one (the MPF-II puts '=' on Shift+O and '-' on Shift+I, and
    its shifted number row is offset by one key; the KC 85/4 is a German
    keyboard whose plain letter row is UPPER case). Declared as station.env
    SH_KEY_MAP="=:O,-:I,+:P" or as a 'key_map' object in the tiles.json entry;
    absent on most tiles, so nothing is remapped unless it is declared."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    raw = read_env(os.path.join(tile_dir, "station.env")).get("SH_KEY_MAP")
    mapping = {}
    if isinstance(c.get("key_map"), dict):
        mapping.update({str(k): str(v) for k, v in c["key_map"].items()})
    for pair in (raw or "").split(","):
        if ":" in pair:
            guest, host = pair.split(":", 1)
            if guest and host:
                mapping[keymap_unescape(guest)] = keymap_unescape(host)
    return mapping


def char_chord(ch):
    """The qcode chord that produces one character on a PC layout, or None."""
    if ch.isalpha() and ch.isupper():
        return ["shift", ch.lower()]
    if (ch.isalpha() or ch.isdigit()) and ch.isascii():
        return [ch.lower()]
    if ch in PLAIN_QCODE:
        return [PLAIN_QCODE[ch]]
    if ch in SHIFT_QCODE:
        return ["shift", SHIFT_QCODE[ch]]
    return None


def text_chords(text, mapping):
    """Chords for a string. Unmappable characters are a hard error rather than
    the silent substitution the old path did — a keystroke that cannot be sent
    must not be reported as sent."""
    chords, bad = [], []
    for ch in text:
        chord = char_chord(mapping.get(ch, ch))
        if chord is None:
            bad.append(ch)
        else:
            chords.append(chord)
    if bad:
        die("cannot map character(s) %s to a key chord" % " ".join(repr(b) for b in bad))
    return chords


def send_chords_paced(qmp, chords, hold_ms, gap_ms):
    """Send chords over ONE QMP connection, holding each for hold_ms and
    leaving gap_ms of released keyboard between them."""
    conn = QmpConn(qmp, timeout=10)
    try:
        for index, chord in enumerate(chords):
            args = {"keys": [{"type": "qcode", "data": q} for q in chord]}
            if hold_ms:
                args["hold-time"] = hold_ms
            conn.execute("send-key", args)
            if gap_ms and index != len(chords) - 1:
                time.sleep(gap_ms / 1000.0)
    finally:
        conn.close()


def looks_like_emulator_bridge(c, name):
    """Tiles whose keystrokes end up inside an EMULATOR (a MAME/emulator bridge
    guest, or an x11/shm emulator tile) — the ones where an unpaced burst is
    silently swallowed by the emulated input scan."""
    if is_x11_tile(c):
        return True
    haystack = " ".join(str(c.get(k) or "") for k in ("dir", "exec_key", "notes"))
    return "bridge" in haystack.lower()


def warn_unpaced(c, name):
    if looks_like_emulator_bridge(c, name):
        sys.stderr.write(
            "labctl: WARNING — %s declares no SH_KEY_MIN_HOLD_MS/SH_KEY_MIN_GAP_MS "
            "in its station.env, and it drives an emulator that samples its keyboard "
            "once per emulated frame. Keys sent back-to-back CAN be silently "
            "dropped or merged, so a success line here is NOT proof the guest got "
            "the text — verify with 'labctl shot %s'.\n" % (name, name)
        )


def type_text(c, name, text, trailing=None):
    """Type text (optionally plus a trailing chord, e.g. ret) with the tile's
    declared pacing, falling back to the historical cdrv route when the tile
    declares none. Returns a short description of the route taken."""
    hold_ms, gap_ms = key_pacing(c, name)
    if hold_ms is None and gap_ms is None:
        warn_unpaced(c, name)
        r = cdrv(c["qmp"], "sh" if trailing == ["ret"] else "type", text)
        if r.returncode != 0:
            die("type failed: %s" % r.stderr.strip())
        return "unpaced QMP send-key (tile declares no pacing)"
    chords = text_chords(text, key_remap(c, name))
    if trailing:
        chords.append(trailing)
    try:
        send_chords_paced(c["qmp"], chords, hold_ms, gap_ms)
    except (OSError, RuntimeError) as exc:
        die("type failed: %s" % exc)
    return "paced QMP send-key (hold %sms, gap %sms)" % (hold_ms or 0, gap_ms or 0)
