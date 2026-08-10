#!/usr/bin/env python3
"""Select, validate and group the tiles of one bookworm -> trixie wave.

The declaration half of scripts/dev/migrate-wave.sh, kept as a real file rather
than a heredoc'd string so shellcheck's blind spot does not swallow it: the
recurring complaint about migrate-tile.sh is that ~230 lines of its box-side
programs ship as quoted strings and no linter has ever seen them.

Three answers come out of one pass because they are entangled — WHICH tiles the
wave covers, WHICH of them are refused before anything starts, and WHICH
serialization group each belongs to:

  * the roster in registry/bridge-waves.json must cover the ledger exactly once
    (a tile in no wave is not a tile that migrates by accident, it is a tile
    nobody planned; indyr4400 is the real one and is declared `unwaved`);
  * a serialization group's membership is DECLARED there and DERIVED here from
    the builders. A hand list nobody re-checks is how a new MAME tile joins the
    fleet without joining the group that keeps two builds out of one chroot.

Any disagreement is exit 2 with the reason on stderr — never a wave that runs
anyway with a quietly wrong group.

usage: migrate-wave-plan.py <repo> tiles <tile>… | wave <name> | remaining
stdout: one TSV row per selected tile —
        tile  suite  group  builder  wave  refusal   ("-" = no refusal)
exit:   0 a plan was printed · 2 usage, unknown tile, or a declaration breach
"""

import json
import os
import re
import sys

MAME_HELPER = re.compile(r"build-mame-[a-z0-9]+\.sh")


def load(repo, rel):
    with open(os.path.join(repo, rel), encoding="utf-8") as fh:
        return json.load(fh)


def enters_shared_chroot(repo, tile):
    """The `derivation` registry/bridge-waves.json documents for mame-chroot.

    True when the tile's builder names an emulators/build-mame-*.sh helper that
    itself resolves the suite's shared chroot. indyr4400 debootstraps its OWN
    throwaway chroot and must NOT match — it shares nothing with anyone.
    """
    path = os.path.join(repo, "scripts/build-guests/tiles", tile + ".sh")
    if not os.path.isfile(path):
        return False
    with open(path, encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    for helper in sorted(set(MAME_HELPER.findall(src))):
        hp = os.path.join(repo, "scripts/build-guests/emulators", helper)
        if not os.path.isfile(hp):
            continue
        with open(hp, encoding="utf-8", errors="replace") as fh:
            if "bridge_mame_chroot_for" in fh.read():
                return True
    return False


DERIVATIONS = {"mame-chroot": enters_shared_chroot}


def check_rosters(suites, rosters, unwaved):
    """Every ledger tile in exactly one wave, or explicitly declared unwaved."""
    errs, wave_of = [], {}
    for name in sorted(rosters):
        for tile in rosters[name]:
            if tile in wave_of:
                errs.append(f"{tile} is in wave {wave_of[tile]} and wave {name}")
            wave_of[tile] = name
    for tile in sorted(set(wave_of) | set(unwaved)):
        if tile not in suites:
            errs.append(f"{tile} is in bridge-waves.json but not in the ledger")
        if tile in wave_of and tile in unwaved:
            errs.append(f"{tile} is both waved and declared unwaved")
    for tile in sorted(suites):
        if tile not in wave_of and tile not in unwaved:
            errs.append(f"ledger tile {tile} is in no wave and not declared unwaved")
    return errs, wave_of


def check_groups(repo, suites, groups):
    """Declared serialization membership vs what the builders actually do."""
    errs, group_of = [], {}
    for name in sorted(groups):
        declared = set(groups[name]["tiles"])
        for tile in sorted(declared):
            if tile in group_of:
                errs.append(f"{tile} is in serialization groups {group_of[tile]} and {name}")
            group_of[tile] = name
        if "derivation" not in groups[name]:
            continue
        rule = DERIVATIONS.get(name)
        if rule is None:
            errs.append(f"group {name} declares a derivation with no rule implemented in this file")
            continue
        real = {t for t in suites if rule(repo, t)}
        for tile in sorted(real - declared):
            errs.append(f"{tile} enters the shared resource of group {name} but is NOT declared in it")
        for tile in sorted(declared - real):
            errs.append(f"{tile} is declared in group {name} but its builder never enters that resource")
    return errs, group_of


def select(mode, sel, suites, rosters, unwaved):
    order = [t for name in sorted(rosters) for t in rosters[name]] + sorted(unwaved)
    if mode == "tiles":
        for tile in sel:
            if tile not in suites:
                sys.exit(f"migrate-wave: {tile!r} is not in registry/bridge-suites.json")
        return list(sel)
    if mode == "wave":
        if not sel or sel[0] not in rosters:
            known = " ".join(sorted(rosters))
            sys.exit(f"migrate-wave: no wave {sel[0] if sel else None!r} (have: {known})")
        return list(rosters[sel[0]])
    return [t for t in order if suites[t] != "trixie"]


def refusal(repo, tile, suite, builder):
    """Why this tile will not be started. Decided before anything runs."""
    if suite == "trixie":
        return "already declared trixie in the ledger"
    if tile == "c64":
        return "DETACHED overlay: a full rebuild, not a rebase (migrate-tile.sh refuses it)"
    if not os.path.isfile(os.path.join(repo, builder)):
        return "no builder at " + builder
    return "-"


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.strip().splitlines()[-3])
    repo, mode, sel = argv[1], argv[2], argv[3:]
    if mode not in ("tiles", "wave", "remaining"):
        sys.exit(f"migrate-wave: unknown selection mode {mode!r}")
    try:
        ledger = load(repo, "registry/bridge-suites.json")
        waves = load(repo, "registry/bridge-waves.json")
    except (OSError, ValueError) as exc:
        sys.exit(f"migrate-wave: {exc}")

    suites, rosters = ledger["tiles"], waves["waves"]
    unwaved, groups = waves.get("unwaved", {}), waves.get("serialization", {})

    errs, wave_of = check_rosters(suites, rosters, unwaved)
    gerrs, group_of = check_groups(repo, suites, groups)
    errs += gerrs
    if errs:
        for err in errs:
            print("migrate-wave: " + err, file=sys.stderr)
        return 2

    chosen = select(mode, sel, suites, rosters, unwaved)
    if not chosen:
        sys.exit("migrate-wave: the selection is empty — nothing to do")
    for tile in chosen:
        builder = os.path.join("scripts/build-guests/tiles", tile + ".sh")
        row = (
            tile,
            suites[tile],
            group_of.get(tile, "-"),
            builder,
            wave_of.get(tile, "unwaved"),
            refusal(repo, tile, suites[tile], builder),
        )
        print("\t".join(row))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
