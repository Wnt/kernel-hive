#!/usr/bin/env python3
"""seed_contacts — roster-driven, idempotent contact-list seeder for the retronet ICQ fleet.

Every ICQ station carries every OTHER station + the bot (HiveBot) in its contact
list. The roster (roster.json) is the single source; adding a station is one row
there, then re-run `seed <station>`.

METHOD (ICQ 2000b, Windows) — drive the client's OWN Add-Contact flow over the
exec channel + framebuffer (labctl), NOT an offline edit of the local store. Why:
ICQ 2000b's contact list is a proprietary, undocumented, per-UIN binary DB
(C:\\Program Files\\ICQ\\<UIN>\\) that only materialises after a user registers —
there is no safe reference copy to reverse-engineer against (the sole populated
instance is the live golden, which is off-limits), so an offline write is
unprovable and risks corrupting the DB. Driving the client makes IT write its own
DB, fetch the server-side directory nickname (so `10000` shows as `HiveBot`), and
register the buddies server-side (BuddyAddBuddies -> clientSideBuddyList) so
presence works — all correctly. See docs/lab/retronet/CONTACT-SEEDER.md.

This tool runs ON labhost (invoke via `ssh lab`): it needs `pct exec 951` (the
gateway's management API is CT-loopback-only), `labctl`, and a socket to the
gateway for the client-faithful nickname check. It does NOT mutate a live station
except under `seed --apply` (the deferred live-application phase), which refuses
to run until the input macro is calibrated on the real client.

  seed_contacts.py roster                 # the roster + each station's contact set
  seed_contacts.py ssi [<station>] [--apply]  # populate server-side SSI/feedbag rosters (PRIMARY)
  seed_contacts.py verify-ssi             # PROVE the server serves a written SSI roster
  seed_contacts.py nicknames [--apply]    # set every account's server ICQ nickname
  seed_contacts.py verify-nick <uin>      # PROVE a client receives the nickname
  seed_contacts.py status <station>       # which contacts a station already has
  seed_contacts.py plan <station>         # the client-UI seeding plan (dry-run, fallback path)
  seed_contacts.py seed <station> [--apply]   # client-UI drive; --apply is LIVE (gated), fallback path
  seed_contacts.py personas               # RN_BOT_PERSONAS for the greeter bot (onboarded only)
  seed_contacts.py selftest               # offline checks (no gateway needed)

The SSI/feedbag path (`ssi`) is the primary contact store: it writes each live
account's server-side buddy list, which an SSI-aware client (climm; the upgraded
ICQ) reads on next login with NO client-UI drive and NO golden recapture. The
`seed`/`plan` client-UI path stays as a fallback for non-SSI clients (ICQ 2000b).
"""

from __future__ import annotations

import argparse
import json
import random
import socket
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bot"))
import oscar  # noqa: E402 — the bot's hand-rolled OSCAR client; dir added to sys.path above
from roster_lib import ROSTER, load_roster, personas_value  # noqa: E402 — same dir as this file

MACRO = HERE / "icq2000b-add.macro.json"
CT = "951"  # the gateway container
RN_TOOL = "/opt/ras/rn-tool.py"  # rn-tool.py inside the CT
API = "http://127.0.0.1:8080"  # management API — loopback INSIDE the CT only

ICQ_EXT = 0x0015
META_REQ_SHORTINFO = 0x04BA
META_RESP_SHORTINFO = 0x0104
META_SUCCESS = 0x0A

SSI_EXT = 0x0013  # feedbag / server-stored buddy list
SSI_REQ_LIST = 0x0004  # CLI_REQUEST — send me the whole SSI list
SSI_LIST_REPLY = 0x0006  # SRV_REPLYROSTER — the list
SSI_CLASS_BUDDY = 0x0000
SSI_TLV_ALIAS = 0x0131


# --- process helpers ---------------------------------------------------------


def run(argv: list[str], timeout: float = 60.0) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, check=False, timeout=timeout)


def ct(*args: str) -> subprocess.CompletedProcess:
    """Run rn-tool.py inside the gateway CT (its management API is loopback-only)."""
    return run(["pct", "exec", CT, "--", "python3", RN_TOOL, *args])


def ct_py(code: str, *args: str) -> subprocess.CompletedProcess:
    """Run a one-off python snippet in the CT for an API call rn-tool has no verb for."""
    return run(["pct", "exec", CT, "--", "python3", "-c", code, *args])


# --- roster ------------------------------------------------------------------


def station_entry(roster: dict, name: str) -> dict:
    for s in roster["stations"]:
        if s["station"] == name:
            return s
    known = ", ".join(s["station"] for s in roster["stations"])
    raise KeyError(f"no station {name!r} in roster (have: {known})")


def contacts_for(roster: dict, station: str) -> list[dict]:
    """Every account a station must carry: the bot + every OTHER station."""
    return [roster["bot"], *[s for s in roster["stations"] if s["station"] != station]]


def live_stations(roster: dict, have: set[str]) -> list[dict]:
    """The live stations: onboarded in the roster AND with an account on the gateway.

    `have` is existing_uins() (passed in so the whole SSI pass makes one CT call).
    A station whose account exists but is not yet finalized (roster onboarded=false)
    is deliberately excluded, so it stays out of everyone's cross-list until it is
    truly live.

    An AIM station takes part on its `uin` like everyone else — that is the whole
    point of the numeric proxy retronet-aim-bridge holds for it. The ICQ clients
    cross-list a UIN they can render, the bridge carries what arrives there to
    the AIM client, and only the AIM station's OWN list is untouched by this pass
    (AIM 1.0.414 predates SSI, so its list is client-local and baked into the
    golden). See docs/lab/retronet/ICQ-STATION-win311.md.
    """
    return [s for s in roster["stations"] if s.get("onboarded") and s["uin"] in have]


def ssi_contacts_for(roster: dict, station: str, live: list[dict]) -> list[dict]:
    """One station's server-side SSI cross-list: the bot + every OTHER live station."""
    return [roster["bot"], *[s for s in live if s["station"] != station]]


# --- gateway state -----------------------------------------------------------


def existing_uins() -> set[str]:
    """UINs that actually have an account on the gateway (a contact must exist to be added)."""
    return {ln.split()[0] for ln in ct("users").stdout.splitlines() if ln.split()}


def already_seeded(station_uin: str) -> set[str]:
    """UINs already on the station's client-side list (server shadow) — the idempotency
    oracle for the ICQ 2000b client-UI fallback path (`clientSideBuddyList`, not SSI)."""
    return {ln.split()[0] for ln in ct("client-buddies", station_uin).stdout.splitlines() if ln.split()}


def _del_user(uin: str) -> None:
    """Delete a (throwaway) account and its server-side rows.

    The management API's DELETE /user does NOT cascade the SSI feedbag, so a
    throwaway that was ssi-seeded (verify-ssi) would leak its roster rows on every
    run. Clear the feedbag first (reliable SQLite), then delete the account.
    """
    code = (
        "import sys,json,sqlite3,urllib.request as u;"
        "c=sqlite3.connect('/var/lib/ras/oscar.sqlite');"
        "c.execute('DELETE FROM feedbag WHERE screenName=?',(sys.argv[1],));c.commit();c.close();"
        f"u.urlopen(u.Request('{API}/user',data=json.dumps({{'screen_name':sys.argv[1]}}).encode(),method='DELETE'))"
    )
    ct_py(code, uin)


# --- ICQ Meta directory query (the SAME lookup ICQ 2000b does on add-by-UIN) --


def _meta_short_info_req(my_uin: int, target_uin: int, seq: int = 2) -> bytes:
    meta = struct.pack("<IHH", my_uin, 0x07D0, seq) + struct.pack("<H", META_REQ_SHORTINFO)
    meta += struct.pack("<I", target_uin)
    return oscar.tlv(0x0001, struct.pack("<H", len(meta)) + meta)


def parse_meta_nickname(body: bytes) -> str | None:
    """Pull the nickname from an ICQ Meta short-info response (SNAC 0x15/0x03)."""
    blob = oscar.find_tlv(oscar.parse_tlvs(body), 0x0001)
    if blob is None or len(blob) < 15:
        return None
    subcmd = struct.unpack_from("<H", blob, 10)[0]
    if subcmd != META_RESP_SHORTINFO or blob[12] != META_SUCCESS:
        return None
    nlen = struct.unpack_from("<H", blob, 13)[0]
    return blob[15 : 15 + nlen].split(b"\x00", 1)[0].decode("cp1252", "replace")


def verify_nick(roster: dict, target_uin: str, timeout: float = 15.0) -> str | None:
    """Sign in as a throwaway account and run the exact directory lookup a client
    runs when you add a UIN; return the nickname the client would receive."""
    host, port = roster["gateway"]["host"], int(roster["gateway"]["port"])
    uin = str(random.randint(1_000_000_000, 1_999_999_999))
    pw = "".join(random.choices("0123456789abcdef", k=8))
    ct("user-set", uin, pw)
    ct("user-open", uin)
    try:
        client = oscar.OscarClient(host, port, uin, pw)
        client.connect()
        if client.bos is None:
            raise RuntimeError("BOS session did not come up")
        client.bos.send_snac(ICQ_EXT, 0x0002, _meta_short_info_req(int(uin), int(target_uin)))
        _sub, resp = client.bos.wait_snac_sub(ICQ_EXT, (0x0003,), timeout=timeout)
        client.close()
        return parse_meta_nickname(resp)
    finally:
        _del_user(uin)


# --- SSI / feedbag: the server-side buddy list a client reads on login -------


def _wire_ssi_alias(attrs: bytes) -> str:
    """The 0x0131 local-alias (display name) out of a wire SSI item's TLV block."""
    off = 0
    while off + 4 <= len(attrs):
        typ, vlen = struct.unpack_from(">HH", attrs, off)
        off += 4
        if typ == SSI_TLV_ALIAS:
            return attrs[off : off + vlen].decode("utf-8", "replace")
        off += vlen
    return ""


def parse_ssi_roster(body: bytes) -> list[tuple[str, str]]:
    """Buddy (UIN, nick) pairs from a SNAC 13,06 SSI-list reply.

    Wire: u8 version | u16 count | count*item | u32 timestamp, where an item is
    u16 namelen, name | u16 groupID | u16 itemID | u16 classID | u16 attrslen, attrs.
    The nick is the buddy item's 0x0131 alias TLV — what the client will display.
    """
    out: list[tuple[str, str]] = []
    (count,) = struct.unpack_from(">H", body, 1)  # skip the 1-byte version
    off = 3
    for _ in range(count):
        (nlen,) = struct.unpack_from(">H", body, off)
        off += 2
        name = body[off : off + nlen].decode("cp1252", "replace")
        off += nlen
        _gid, _iid, cls, alen = struct.unpack_from(">HHHH", body, off)
        off += 8
        attrs = body[off : off + alen]
        off += alen
        if cls == SSI_CLASS_BUDDY:
            out.append((name, _wire_ssi_alias(attrs)))
    return out


def verify_ssi(roster: dict, timeout: float = 15.0) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """Prove the server SERVES a directly-written feedbag, end to end.

    Create a throwaway account, write it a known SSI roster via the SAME rn-tool
    path the fleet uses, sign in as it and request the list (SNAC 13,04 -> 13,06),
    and read the buddies back — the SSI analogue of verify-nick. Touches NO real
    account (so no live climm/ICQ session is displaced); the throwaway is created,
    populated, queried and deleted in the one call. Returns (expected, received).
    """
    host, port = roster["gateway"]["host"], int(roster["gateway"]["port"])
    uin = str(random.randint(1_000_000_000, 1_999_999_999))
    pw = "".join(random.choices("0123456789abcdef", k=8))
    expected = [("10000", "HiveBot"), ("20000", "win2000"), ("64000", "tru64")]
    ct("user-set", uin, pw)
    ct("user-open", uin)
    try:
        ct("ssi-seed", uin, *[f"{u}={n}" for u, n in expected])
        client = oscar.OscarClient(host, port, uin, pw)
        client.connect()
        if client.bos is None:
            raise RuntimeError("BOS session did not come up")
        client.bos.send_snac(SSI_EXT, SSI_REQ_LIST, b"")
        _sub, resp = client.bos.wait_snac_sub(SSI_EXT, (SSI_LIST_REPLY,), timeout=timeout)
        client.close()
        return expected, parse_ssi_roster(resp)
    finally:
        _del_user(uin)


# --- the icq2000b input macro (calibrated live; see the .macro.json) ---------


def load_macro(path: str | Path = MACRO) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def render_macro(macro: dict, station: str, contact: dict) -> list[tuple[str, list[str], str]]:
    def sub(v: str) -> str:
        return v.replace("{uin}", contact["uin"]).replace("{nick}", contact["nick"]).replace("{station}", station)

    return [(st["verb"], [sub(a) for a in st["args"]], st.get("note", "")) for st in macro["steps"]]


# --- QMP / golden ------------------------------------------------------------


def _qmp(f, obj: dict) -> dict:
    f.write((json.dumps(obj) + "\n").encode())
    while True:
        line = f.readline()
        if not line:
            raise RuntimeError("QMP connection closed")
        msg = json.loads(line)
        if "return" in msg or "error" in msg:
            return msg


def hmp(station: str, command: str, timeout: float = 120.0) -> dict:
    """Run one HMP command (savevm/delvm/loadvm) over the station's QMP socket."""
    path = f"/data/vms/streamhost/stations/{station}/qmp.sock"
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(timeout)
        s.connect(path)
        f = s.makefile("rwb", buffering=0)
        f.readline()  # greeting
        _qmp(f, {"execute": "qmp_capabilities"})
        return _qmp(f, {"execute": "human-monitor-command", "arguments": {"command-line": command}})


def recapture_golden(station: str) -> None:
    """Recapture `golden` with the fuller list baked in — safe order that never
    deletes the live golden before a copy of the new state exists."""
    run(["labctl", "assert", station, "--settle"])
    hmp(station, "savevm golden-seeding")  # seeded state under a temp name first
    hmp(station, "delvm golden")  # only now remove the old golden
    hmp(station, "savevm golden")  # canonical name
    hmp(station, "delvm golden-seeding")  # tidy the temp


# --- commands ----------------------------------------------------------------


def cmd_roster(roster: dict, _args) -> int:
    b = roster["bot"]
    print(f"bot: {b['nick']} (UIN {b['uin']})")
    print(f"stations ({len(roster['stations'])}):")
    for s in roster["stations"]:
        mark = "onboarded" if s.get("onboarded") else "pending"
        print(f"  {s['station']:<9} UIN {s['uin']:<6} nick {s['nick']:<9} {s['client']:<11} [{mark}]")
    print()
    for s in roster["stations"]:
        cs = contacts_for(roster, s["station"])
        print(f"{s['station']:<9} carries {len(cs)}: " + ", ".join(f"{c['nick']}({c['uin']})" for c in cs))
    return 0


def cmd_personas(roster: dict, _args) -> int:
    """What install-bot.sh renders into bot.env — printed here so it is inspectable."""
    print(personas_value(roster))
    return 0


def cmd_ssi(roster: dict, args) -> int:
    """Populate each live account's server-side SSI/feedbag roster from the roster.

    The primary contact path: one write per account cross-lists the whole live
    fleet, and an SSI-aware client (climm; the upgraded ICQ) syncs it on next
    login — no client-UI drive, no golden recapture. Dry-run by default; --apply
    writes. Optionally scope to one station.
    """
    live = live_stations(roster, existing_uins())
    targets = [s for s in live if not args.station or s["station"] == args.station]
    if args.station and not targets:
        print(f"{args.station}: not a live account (needs roster onboarded=true + an account on the gateway).")
        return 1
    if not targets:
        print("no live accounts (onboarded=true + account on the gateway) — nothing to seed.")
        return 0
    rc = 0
    for s in targets:
        contacts = ssi_contacts_for(roster, s["station"], live)
        label = ", ".join(f"{c['nick']}({c['uin']})" for c in contacts)
        if not args.apply:
            print(f"would seed SSI {s['station']:<9} UIN {s['uin']:<6} -> {len(contacts)}: {label}")
            continue
        r = ct("ssi-seed", s["uin"], *[f"{c['uin']}={c['nick']}" for c in contacts])
        sys.stdout.write(r.stdout)
        if r.returncode != 0:
            sys.stderr.write(r.stderr)
        rc |= r.returncode
    if not args.apply:
        print("# dry-run — re-run with --apply to write the server-side rosters")
    return rc


def cmd_verify_ssi(roster: dict, _args) -> int:
    expected, received = verify_ssi(roster)
    got = sorted(received)
    ok = got == sorted(expected)
    print("server-side SSI proof — throwaway account, real OSCAR sign-in, SNAC 13,04 -> 13,06:")
    for uin, nick in got:
        print(f"  a client receives buddy {uin} as {nick!r}")
    print(("PASS" if ok else "FAIL") + f" — a directly-written feedbag roster is served on login ({len(got)} buddies)")
    return 0 if ok else 1


def cmd_nicknames(roster: dict, args) -> int:
    have = existing_uins()
    rc = 0
    for e in [roster["bot"], *roster["stations"]]:
        if e["uin"] not in have:
            print(f"skip  {e['nick']} (UIN {e['uin']}) — account not created yet")
        elif not args.apply:
            print(f"would set  UIN {e['uin']} nick -> {e['nick']!r}")
        else:
            r = ct("nick", e["uin"], e["nick"])
            sys.stdout.write(r.stdout)
            rc |= r.returncode
    return rc


def cmd_verify(roster: dict, args) -> int:
    nick = verify_nick(roster, args.uin)
    print(f"UIN {args.uin}: a client receives nickname {nick!r}")
    return 0 if nick else 1


def cmd_status(roster: dict, args) -> int:
    s = station_entry(roster, args.station)
    have, seeded = existing_uins(), already_seeded(s["uin"])
    print(f"{s['station']} (UIN {s['uin']}, {s['client']})")
    for c in contacts_for(roster, args.station):
        if c["uin"] in seeded:
            state = "present"
        elif c["uin"] in have:
            state = "MISSING — will be added"
        else:
            state = "missing (contact account not created yet)"
        print(f"  {c['nick']:<9} UIN {c['uin']:<6} {state}")
    return 0


def _missing(roster: dict, station: str) -> tuple[dict, list[dict], list[dict]]:
    s = station_entry(roster, station)
    have, seeded = existing_uins(), already_seeded(s["uin"])
    todo = [c for c in contacts_for(roster, station) if c["uin"] not in seeded and c["uin"] in have]
    blocked = [c for c in contacts_for(roster, station) if c["uin"] not in seeded and c["uin"] not in have]
    return s, todo, blocked


def _print_client_design(client: str) -> None:
    if client == "unix-oscar":
        print("#   climm 0.6.4 (ex-mICQ, an ICQ client): contacts live under ~/.climm/ (config + contact list).")
        print("#   seed offline over the guest home (chroot-guard run-private mount) OR the client's own add.")
        print("#   Being an ICQ client it fetches the nickname from the SAME server directory this tool sets")
        print("#   (verify-nick proves it), so HiveBot / station names show with no local alias needed.")
    elif client == "mac-oscar":
        print("#   Mac AIM 2.01.617 (68K), an AIM client: buddy list lives in the app Preferences (System Folder).")
        print("#   AIM clients do NOT run the ICQ directory lookup, so the seeder writes a client-local ALIAS")
        print("#   (the AIM buddy alias) to show 'HiveBot' / station names; seed the pref offline (HFS) or Add flow.")


def cmd_plan(roster: dict, args) -> int:
    s, todo, blocked = _missing(roster, args.station)
    print(f"# plan: seed {s['station']} (UIN {s['uin']}, client {s['client']})")
    print(f"# to add: {len(todo)};  already present: skipped;  blocked (account not created): {len(blocked)}")
    for c in blocked:
        print(f"#   BLOCKED {c['nick']} UIN {c['uin']} — onboard that station first (it creates the account)")
    if s["client"] != "icq2000b":
        print(f"# {s['client']} seeding is DESIGNED, deferred until its client media lands — see CONTACT-SEEDER.md:")
        _print_client_design(s["client"])
        return 0
    macro = load_macro()
    print(f"# ensure server nicknames first: {', '.join(c['nick'] for c in todo) or '(none)'}")
    print(f"# input macro {MACRO.name} (calibrated={macro.get('calibrated')}), replayed per contact:")
    for c in todo:
        print(f"# --- add {c['nick']} (UIN {c['uin']}) ---")
        for verb, a, note in render_macro(macro, s["station"], c):
            print(f"labctl {verb} {s['station']} {' '.join(a)}    # {note}")
    print("# finally: clean frame (warpnet V reset), recapture golden (savevm), verify loadvm golden")
    return 0


def cmd_seed(roster: dict, args) -> int:
    if not args.apply:
        return cmd_plan(roster, args)
    s, todo, _blocked = _missing(roster, args.station)
    if s["client"] != "icq2000b":
        print(f"ERROR: {s['client']} seeding is designed but not implemented yet (deferred). See CONTACT-SEEDER.md.")
        return 2
    macro = load_macro()
    if not macro.get("calibrated"):
        print("ERROR: the icq2000b input macro is not calibrated for the live client — refusing --apply.")
        print("Calibrate it on the live station first (CONTACT-SEEDER.md 'Calibration'), then set calibrated:true.")
        return 2
    if not todo:
        print(f"{s['station']}: already fully seeded — nothing to add, golden untouched.")
        return 0
    print(f"# LIVE: back up the golden BEFORE this (per ICQ-STATION.md). Seeding {len(todo)} contact(s).")
    for c in todo:  # ensure the contact shows by name and can be added unattended
        ct("nick", c["uin"], c["nick"])
        ct("user-open", c["uin"])
    run(["labctl", "reset", s["station"]])  # loadvm golden — start from the known-good state
    for c in todo:
        for verb, a, _note in render_macro(macro, s["station"], c):
            r = run(["labctl", verb, s["station"], *a])
            if r.returncode != 0:
                print(f"FAIL at {verb} {a} for {c['nick']}: {r.stderr.strip()} — golden NOT recaptured.")
                return 1
    recapture_golden(s["station"])
    print(f"{s['station']}: seeded {len(todo)} contact(s); golden recaptured.")
    return 0


def _fake_meta_response(nick: str, uin: int = 10000, seq: int = 2) -> bytes:
    nb = nick.encode("cp1252") + b"\x00"
    meta = struct.pack("<IHH", uin, 0x07DA, seq) + struct.pack("<H", META_RESP_SHORTINFO)
    meta += bytes([META_SUCCESS]) + struct.pack("<H", len(nb)) + nb + b"\x00\x00" * 3 + b"\x01"
    return oscar.tlv(0x0001, struct.pack("<H", len(meta)) + meta)


def cmd_selftest(roster: dict, _args) -> int:
    n = len(roster["stations"])
    for s in roster["stations"]:
        cs = contacts_for(roster, s["station"])
        assert s["station"] not in [c.get("station") for c in cs], f"{s['station']} lists itself"
        assert roster["bot"] in cs, "bot missing from a contact set"
        assert len(cs) == n, f"{s['station']} contact-set size {len(cs)} != {n}"
    print(f"PASS roster: {n} stations; every contact set excludes self and includes the bot")

    got = parse_meta_nickname(_fake_meta_response("HiveBot"))
    assert got == "HiveBot", f"meta parser returned {got!r}"
    assert parse_meta_nickname(b"\x00\x01") is None, "meta parser accepted junk"
    print(f"PASS meta parser: nickname round-trips ({got!r}); junk rejected")

    def _ssi_item(name: str, gid: int, iid: int, cls: int, attrs: bytes) -> bytes:
        nb = name.encode()
        return struct.pack(">H", len(nb)) + nb + struct.pack(">HHHH", gid, iid, cls, len(attrs)) + attrs

    def _ssi_alias_tlv(s: str) -> bytes:
        return struct.pack(">HH", SSI_TLV_ALIAS, len(s)) + s.encode()

    ssi_items = [
        _ssi_item("", 0, 1, 0x0004, b"\x00\xca\x00\x01\x04"),  # PDINFO
        _ssi_item("contacts-icq8-20000", 5, 0, 0x0001, b""),  # group
        _ssi_item("10000", 5, 2, SSI_CLASS_BUDDY, _ssi_alias_tlv("HiveBot")),
        _ssi_item("40000", 5, 3, SSI_CLASS_BUDDY, _ssi_alias_tlv("nt4")),
    ]
    ssi_body = b"\x00" + struct.pack(">H", len(ssi_items)) + b"".join(ssi_items) + struct.pack(">I", 0)
    parsed = parse_ssi_roster(ssi_body)
    assert parsed == [("10000", "HiveBot"), ("40000", "nt4")], parsed
    print(f"PASS ssi parser: {len(parsed)} buddies from a 13,06 reply; group + PDINFO skipped, aliases read")

    fake_live = [s for s in roster["stations"] if s["station"] in {"win98se", "win2000", "nt4"}]
    for s in fake_live:
        cs = ssi_contacts_for(roster, s["station"], fake_live)
        assert s["station"] not in [c.get("station") for c in cs], f"{s['station']} lists itself"
        assert roster["bot"] in cs, "bot missing from an SSI cross-list"
        assert len(cs) == len(fake_live), f"{s['station']} SSI set {len(cs)} != {len(fake_live)}"
    print(f"PASS ssi cross-list: over {len(fake_live)} live stations each carries the bot + the others, self excluded")

    macro = load_macro()
    steps = render_macro(macro, "win2000", {"uin": "10000", "nick": "HiveBot"})
    joined = " ".join(" ".join(a) for _v, a, _n in steps)
    assert "10000" in joined and "HiveBot" in joined, "macro substitution failed"
    assert not macro["calibrated"], "template must ship uncalibrated"
    print(f"PASS macro: {len(steps)} steps render with UIN/nick substituted; ships uncalibrated (apply is gated)")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="roster-driven, idempotent retronet ICQ contact seeder")
    p.add_argument("--roster", default=str(ROSTER))
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("roster")
    sp_ssi = sub.add_parser("ssi")
    sp_ssi.add_argument("station", nargs="?")
    sp_ssi.add_argument("--apply", action="store_true")
    sub.add_parser("verify-ssi")
    sub.add_parser("nicknames").add_argument("--apply", action="store_true")
    sub.add_parser("verify-nick").add_argument("uin")
    sub.add_parser("status").add_argument("station")
    sub.add_parser("plan").add_argument("station")
    sp = sub.add_parser("seed")
    sp.add_argument("station")
    sp.add_argument("--apply", action="store_true")
    sub.add_parser("selftest")
    sub.add_parser("personas")
    args = p.parse_args(argv)
    roster = load_roster(args.roster)
    return {
        "roster": cmd_roster,
        "ssi": cmd_ssi,
        "verify-ssi": cmd_verify_ssi,
        "nicknames": cmd_nicknames,
        "verify-nick": cmd_verify,
        "status": cmd_status,
        "plan": cmd_plan,
        "seed": cmd_seed,
        "selftest": cmd_selftest,
        "personas": cmd_personas,
    }[args.cmd](roster, args)


if __name__ == "__main__":
    sys.exit(main())
