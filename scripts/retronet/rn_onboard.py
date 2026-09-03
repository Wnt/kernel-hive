#!/usr/bin/env python3
"""rn-onboard — put one station on the retronet, from one command.

    scripts/retronet/rn-onboard.sh <id> --address 10.99.0.N --mac <mac> \
        [--uin <uin>] [--static] [--planes web,icq] [--client <key>] [--apply]

Before this existed, joining a station to the plane meant copying some other
station's `rn-tapnet.sh` and editing four names in it, hand-writing a registry
block, remembering `user-open`, remembering the roster row, and remembering that
the real MAC must never reach git. Nine stations in one night hit a different
subset of those each time. This does all of it from one allocation row, or
prints exactly what it WOULD do.

**Dry-run by default.** `--apply` is what writes, and what appends to the
BOX-side local.env; without it nothing is touched and every file is printed as a
diff-shaped summary.

**It refuses to commit a real address (rule 1).** The real MAC goes to
`/data/kernel-hive/registry/local.env` as `RN_<ID>_MAC` in a single append; the
committed files carry the scrubbed `02:00:00:00:00:<octet>`. Every rendered byte
is re-checked before it is written — see `rn_onboard_lib.check_committable`.

What it does NOT do, on purpose:

* **allocate.** The address, MAC and UIN come from `wave.sh alloc`, which is the
  one thing holding the plane's uniqueness ledger. Pass them in.
* **write `RETRONET_DHCP_RESERVATIONS`.** Same owner. A reservation is needed
  even for a static guest (it is the ledger), and it is NOT live until
  `scripts/retronet/web/install-dhcp.sh` re-renders `/etc/retronet/dhcp.env` in
  CT 951 — the first guest of the 2026-09-03 wave leased a pool address because
  of exactly that gap.
* **flip `onboarded`.** That word means "a frame shows this client signed in".
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rn_onboard_lib as lib  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
TEMPLATE_TAP = Path(__file__).resolve().parent / "rn-tapnet.template.sh"
TEMPLATE_DOC = Path(__file__).resolve().parent / "rn-station-doc.template.md"
ROSTER = REPO / "scripts/retronet/icq/roster.json"


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="rn-onboard.sh", description="join one station to the retronet")
    p.add_argument("station")
    p.add_argument("--address", required=True, help="the allocated 10.99.0.N")
    p.add_argument("--mac", required=True, help="the allocated real MAC; only its last octet is committed")
    p.add_argument("--uin", default="", help="the allocated ICQ UIN (required for the icq plane)")
    p.add_argument("--planes", default="web,icq", help="comma-separated: web,icq")
    p.add_argument("--static", action="store_true", help="the guest predates DHCP; reserve anyway")
    p.add_argument("--client", default="", help="roster client key, e.g. gaim0599 (see ICQ-CLIENTS.md)")
    p.add_argument("--password", default="", help="ICQ password; generated (6-8, [a-z0-9]) when omitted")
    p.add_argument("--joined", default=dt.date.today().isoformat())
    p.add_argument(
        "--mac-exception",
        default="",
        metavar="REASON",
        help="accept a MAC off the fleet scheme, stating why (irix keeps SGI's OUI and "
        "macos753 Apple's, because the guest programs its own station address)",
    )
    p.add_argument("--apply", action="store_true", help="write the files and append to the box local.env")
    return p.parse_args(argv)


def preflight(args: argparse.Namespace, planes: list[str], password: str) -> list[str]:
    problems = lib.check_names(args.station) + lib.check_address(args.address)
    if not (REPO / "registry/stations" / f"{args.station}.json").exists():
        problems.append(f"registry/stations/{args.station}.json does not exist — this is not a station id")
    for plane in planes:
        if plane not in lib.PLANES:
            problems.append(f"unknown plane {plane!r} (known: {', '.join(lib.PLANES)})")
    if not lib.real_mac(args.mac):
        problems.append(
            f"--mac {args.mac} is already a placeholder; pass the REAL allocated MAC "
            f"(expected {lib.expected_mac(args.address)}) so it can reach local.env"
        )
    elif args.mac.lower() != lib.expected_mac(args.address) and not args.mac_exception:
        problems.append(
            f"--mac {args.mac} does not follow the fleet scheme for {args.address} "
            f"(expected {lib.expected_mac(args.address)}); fix the allocation, or pass "
            f"--mac-exception '<why the guest owns its own address>'"
        )
    if "icq" in planes:
        if not args.uin.isdigit():
            problems.append("--uin is required (and numeric) for the icq plane")
        if not args.client:
            problems.append("--client is required for the icq plane (the roster's seeding driver key)")
        problems += lib.check_password(password)
    return problems


def build(args: argparse.Namespace, planes: list[str], password: str) -> dict[Path, str]:
    """Every file this run would write, keyed by path. Nothing here touches disk."""
    addressing = "static" if args.static else "dhcp"
    tokens = lib.tokens_for(
        args.station,
        args.address,
        args.mac,
        uin=args.uin,
        planes=tuple(planes),
        addressing=addressing,
        date=args.joined,
    )
    out: dict[Path, str] = {}

    tap = REPO / "streamhost/stations" / args.station / "rn-tapnet.sh"
    out[tap] = lib.render(TEMPLATE_TAP.read_text(encoding="utf-8"), tokens, str(tap))

    doc = REPO / lib.station_doc(args.station)
    if not doc.exists():
        out[doc] = lib.render(TEMPLATE_DOC.read_text(encoding="utf-8"), tokens, str(doc))

    registry = REPO / "registry/stations" / f"{args.station}.json"
    row = json.loads(registry.read_text(encoding="utf-8"))
    row["retronet"] = lib.registry_block(
        args.station, args.address, planes=planes, addressing=addressing, joined=args.joined
    )
    text = json.dumps(row, indent=1, ensure_ascii=False) + "\n"
    problems = lib.check_committable(json.dumps(row["retronet"]), str(registry))
    if problems:
        raise SystemExit("\n".join(problems))
    out[registry] = text

    if "icq" in planes:
        roster = json.loads(ROSTER.read_text(encoding="utf-8"))
        roster = lib.insert_roster_row(roster, lib.roster_row(args.station, args.uin, args.client))
        out[ROSTER] = json.dumps(roster, indent=2, ensure_ascii=False) + "\n"
    return out


def netdev_lines(args: argparse.Namespace) -> list[str]:
    """The launcher lines nobody can render for you — the device model is a
    per-guest decision — printed so the shape and the two traps travel with it."""
    key = lib.env_key(args.station, "mac")
    return [
        f"  -netdev tap,id=rn0,ifname={lib.tap_name(args.station)},script=no,downscript=no \\",
        f'  -device rtl8139,netdev=rn0,mac="${key}" \\',
        "",
        "  # …and if this station has an x11warp pointer, its slirp NIC becomes:",
        "  -netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:<port>-10.0.2.15:6000 \\",
        "",
        "  # rn-tapnet.sh up must run BEFORE qemu, under set -e, so a guest never",
        "  # starts uncontained:",
        '  "$(dirname "$0")/rn-tapnet.sh" up',
    ]


def run_gateway(args: argparse.Namespace, password: str, apply: bool) -> int:
    for cmd in lib.gateway_commands(args.uin, args.station, password):
        shown = list(cmd)
        if "user-set" in shown:
            shown[-1] = "<pass>"
        remote = " ".join(shown)
        if not apply:
            print(f"  would run: ssh lab '{remote}'")
            continue
        print(f"  ssh lab '{remote}'")
        proc = subprocess.run(["ssh", "lab", " ".join(cmd)], capture_output=True, text=True)
        sys.stdout.write(proc.stdout)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            return proc.returncode
    return 0


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    planes = [p for p in args.planes.split(",") if p]
    password = args.password or (lib.generate_password() if "icq" in planes else "")

    problems = preflight(args, planes, password)
    if problems:
        for problem in problems:
            print(f"rn-onboard: {problem}", file=sys.stderr)
        return 2

    files = build(args, planes, password)
    env_text = lib.local_env_append(args.station, args.mac, password or None)

    mode = "APPLY" if args.apply else "DRY-RUN (nothing written; add --apply)"
    print(f"rn-onboard {args.station} — {mode}")
    print(f"  address {args.address}  tap {lib.tap_name(args.station)}  guard {lib.chain_name(args.station)}")
    print(f"  MAC {args.mac} -> committed as {lib.placeholder_mac(args.mac)}, real value to {lib.LOCAL_ENV}")
    print()
    for path, text in files.items():
        rel = path.relative_to(REPO)
        verb = "write" if args.apply else "would write"
        state = "new" if not path.exists() else "update"
        print(f"  {verb} {rel} ({state}, {len(text.splitlines())} lines)")
        if args.apply:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            if path.suffix == ".sh":
                path.chmod(0o755)
    print()
    print(f"  launcher lines to add to streamhost/stations/{args.station}/qemu-streamhost.sh:")
    for line in netdev_lines(args):
        print(f"  {line}")
    print()
    print(f"  single append to {lib.LOCAL_ENV} (box-side, never git):")
    for line in env_text.splitlines():
        if args.apply or line.startswith("#"):
            print(f"    {line}")
        else:
            print(f"    {line.split('=')[0]}=<value, written only under --apply>")
    if args.apply:
        quoted = env_text.replace("'", "'\\''")
        subprocess.run(["ssh", "lab", f"printf '%s' '{quoted}' >> {lib.LOCAL_ENV}"], check=True)
        print("    appended")
    print()
    if "icq" in planes:
        print("  gateway account:")
        rc = run_gateway(args, password, args.apply)
        if rc:
            return rc
    print()
    print("  next, and none of it is automatic:")
    print("    1. add the netdev lines above to the launcher, then COLD-bake the golden")
    print("       (the MAC lives in the device vmstate; loadvm on the old set is invalid)")
    print("    2. wave.sh alloc must already have put the reservation in")
    print("       RETRONET_DHCP_RESERVATIONS; render it with")
    print("       ssh lab '/data/kernel-hive/scripts/retronet/web/install-dhcp.sh --apply'")
    print("    3. python3 scripts/stations-registry.py generate && make station-registry-check")
    print(f"    4. fill in {lib.station_doc(args.station)} as you prove each plane")
    print(f"    5. scripts/retronet/rn-verify.sh {args.station}   (on the box, after landing)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
