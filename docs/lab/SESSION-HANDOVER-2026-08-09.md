# Session handover — 2026-08-09

Written for a context compaction. Everything below is either **already pushed to
`origin/main`** or **running in a background agent**. Nothing is sitting
uncommitted.

`git log --oneline -1` at handover: `60bc336 build-guests: give the 112-file
flat directory a hierarchy`.

---

## 1. State of the lineup

**55 production stations**, all accepting stream tickets. Added this session:

| Wave | Stations | Slots |
|---|---|---|
| Commodore (zero-media VICE) | `c128` `pet2001` `cbm8032` `cbm2` | 87, 88, 109, 111 |
| PDP-11 (Open SIMH) | `pdp11` `gt40` `decos` | 115, 125, 126 |
| MAME + NeXTSTEP | `zxspectrum` `zx81` `bbcmicro` `dragon32` `oricatmos` `kc854` `sinclairql` `nextstep` | 127–134 |
| Acorn | `armeval` | 135 |

Memory: ~38 GB available with agents' clones running; `--mem 768` proven for the
8-bit kiosk class (C128 measured 387 MB free of 708 with VICE up).

---

## 2. The edge DNAT cap — RESOLVED 2026-08-09, at the source

Slots 131+ (`oricatmos` 54131, `kc854` 54132, `sinclairql` 54133, `nextstep`
54134, `armeval` 54135) were publicly dark because the edge DNATed only
`udp 54080-54130` while the UDP port is `54000 + slot`. Services were active,
tickets passed, signalling returned a valid path — the daemons simply never saw
a packet.

**Fixed by the operator in `16f5124`, better than the plan.** The rule is now
owned by the forwarder repo (`Wnt/forwarder@e612f83`): a tracked
`deploy/site.env` overlay widens `UDP_RELAY_PORT_RANGE` to 54080-54200, and CI
rewrites `/etc/nftables.conf` from it on every push. So the edge rule is
**derived**, and `scripts/serve/install-public-relay.sh` is demoted to an
emergency hotfix rather than the source of truth.

**The agreement set is now three-way** and anything that changes one must change
all: registry `ports.publicRelayLow/High` == forwarder `site.env`
`UDP_RELAY_PORT_RANGE` == `docs/PUBLIC-GALLERY.md`.

Verified end to end afterwards: `kc854`, `sinclairql` and `nextstep` have each
logged **`SESSION_ACCEPTED`** with zero rejections — all above the old cap.
`oricatmos` and `armeval` show no sessions, which means nobody has opened them,
not that they fail.

---

## 3. Agents in flight

| Agent | Doing what | On completion |
|---|---|---|
| **NeXTSTEP pointer promotion** | Shipping the tablet fix to the live tile | Merge its branch, set any render/hero items, deploy all three runtime docs |
| **Xerox Star / Pilot** research | Feasibility, expected to hinge on media | Fold into `docs/lab/research/xerox-add.md` §2 |
| **Xerox Daybreak / ViewPoint** research | Route A (6085 emulator) vs Route B (GlobalView on an existing Windows tile) | Fold into `xerox-add.md` §3 |
| **DEC Alpha NT/2000** research | Emulator feasibility first, then media | Write `docs/lab/research/alpha-nt-add.md` |

All were told: research only, no stations, teardown is part of done, and I write the
final study from their report.

---

## 4. NeXTSTEP absolute pointer — SOLVED, promotion in flight

Five parallel angles per
[`HARD-PROBLEM-METHODOLOGY.md`](HARD-PROBLEM-METHODOLOGY.md). The winner is
written up in [`NEXTSTEP-ABSOLUTE-POINTER.md`](NEXTSTEP-ABSOLUTE-POINTER.md).

**Nothing needed building.** Previous r1847 — the revision the station already
builds — ships `src/tablet.c`, a SummaGraphics/WACOM digitiser, and `sdlevent.c`
already routes *absolute* SDL coordinates to it when `[Tablet] nTabletType` is
non-zero. The builder already writes that key **as `0`**. The guest disk already
carries `/NextAdmin/InstallTablet.app`. Set the key to `2`, run the installer
once: **24/24 targets, max error 0 px**, repeated after the guest moved the
cursor, after `loadvm golden`, and after a fresh QEMU process.

The four losing angles all left something durable (merged, under
`scripts/dev/nsptr/` and `scripts/build-guests/`):
- **no m68k toolchain exists in the checkpoint** — no `cc`, no `/usr/include` — which
  is *why* the tablet route is the only viable one;
- the plant curve (warm gain exactly 10 px/unit, quantised below d=5), which
  proves an external controller cannot converge in 250 ms;
- Previous's own gain is `0.99999975` — the "0.971 scale" ghost in the build
  notes is **not** in the pointer path;
- how NeXTSTEP's cursor actually works (position in guest RAM, re-read every
  mouse packet), recorded as the fallback if the tablet path regresses.

**A correction I published and then had to retract:** I relayed `closed-loop`'s
"majority-vote three RAM shadows" reader as solved; `previous-patch` tested it
and found agreement of only 2/5, 3/5, 2/5. Write-through proof is what makes a
read trustworthy. Recorded in `scripts/dev/nsptr/FINDINGS.md`.

---

## 5. Landed this session, worth not re-deriving

- **Pointer metadata on every station.** `stream.pointer.{present,absolute,method}`
  with a 9-value enum, and a validator that **recomputes all three** from the
  live `SH_INPUT_BACKEND`, the device ledger, labctl's `pointer_mode` and the
  Rust `InputBackend` mapping, failing on disagreement. It found `nt351`
  declaring `SH_POINTER=abs` while running `dbus-rel`, and `solariscde` emitting
  both `SH_POINTER=warpd` and `SH_INPUT_BACKEND=gallery-hid`.
- **Grid badge** for graphical-but-relative-pointer stations (`--warn`, beside
  HW-input). Derived from `stream.pointer`, **not** from `spa.pointerRel` —
  only 3 of the 7 carry that flag, so keying off it would under-report.
- **`scripts/dev/mame-romset.py`** — assembles a romset by **SHA1** from the
  archive.org `MAME_0.224_ROMs_merged` reservoir (72.6 GB, fetched per parent
  zip). Necessary because MAME renames members between versions: the 0.224 zip
  ships `6530-002.bin`, MAME 0.276 wants `6530-002.u2`, identical bytes.
  `-verifyroms` is **not** a usable gate for computer drivers.
- **`scripts/build-guests/` hierarchy** — `tiles/ stages/ emulators/ patches/
  irix/ lib/`, 158 renames, plus the `README.md` that `build-mame-irix.sh` has
  pointed at for years without it existing. **The MAME patches are NOT
  redundant** — they are the documented fallback when the fork submodule is
  absent, and six builders apply one directly.
- **`plus4`** registry pacing corrected to the 80/80 the station actually runs.

---

## 6. Known-pending, not started

1. ~~The edge DNAT rule~~ — **done**, see §2.
2. **Consolidate the MAME builds.** Six of seven binaries pin the same
   `mame0289` and differ only in which single driver file they compiled
   (`bbcb` 116 MB, `dragon` 75, `oricatmos` 69, `mpf2` 68, `kc85` 66, `zx81` 64;
   `sgi`/IRIX stays separate — it is the fork with the IRIX patches).
   `SOURCES=` takes a comma-separated list, so they collapse into one.
   **The operator's caveat is correct and stricter than they put it:** the checkpoint
   is a `savevm` holding the *old* process in RAM, and text pages are
   demand-loaded from the binary file — so swapping it under a restored snapshot
   is not merely stale, it can fault. Every affected station needs a recapture. For
   the six retro stations that is `--force` on builders that already capture and
   re-prove by framebuffer; `mpf2` predates that discipline and is the one
   that is not free. **Open question for the operator: fold `mpf2` in or leave
   it on its own binary?**
3. **Variant policy** (`docs/lab/research/home-computer-candidates.md` §3) —
   `c16`, `dragon64` and `zx80` were measured *pixel-identical at idle* to tiles
   already shipped and should become posters. Deferred by memory:
   `spectrum128` (first to add if space frees), `vic1001`, `vic20se`,
   `amiga3000`.
4. **Xerox / Alpha** — `xerox-add.md` §1 (Alto) and §3 (GlobalView/ViewPoint) are
   **complete**; §2 (Star/Pilot) and the Alpha study are still in flight, as is a
   Longhorn/WinFS study (`longhorn-add.md`, not yet written). Recommendation so
   far: ship **`gvwin` first** — Tier 2, ~0.19 GB, no new emulator or backend,
   proven boot→login→checkpoint→reset on a clone — then `alto`.
5. `/data/vms/sandbox` holds **339 GB** of inert research clones. Safe to delete
   once findings are accepted; `NSPTR-native-tablet/overlay.qcow2` is
   deliberately kept as the promotion source for the pointer fix.

---

## 7. Operating rules learned or confirmed this session

- **Push as soon as work is ready; deploy visual changes.** Standing operator
  instruction.
- **Deploying a station needs THREE runtime documents**, not two: `tiles.json`,
  `gallery-manifest.json` **and** `golden-manifest.json`. The third is the
  allow-list for `POST /restore/<id>`; missing it leaves a healthy station with a
  404ing reset button. The docs said "two" and that is exactly how the Commodore
  wave shipped with dead reset buttons. Corrected in the playbook and six guest
  docs.
- **One worktree per parallel agent; no file-ownership rules.** Operator's call:
  ownership rules cost tokens and cause agents to work around problems they
  could fix at the right level. Git resolves collisions. What still needs a
  human-level pass is *semantic* conflict — three agents independently chose the
  same scene assembly signature, which merges clean and renders four exhibits as
  the same object.
- **Capture the state the machine itself chose**, and put affordances in the UI
  around it — the `plus4` lesson, still the house style.
- **"No checkpoint" read off a station whose builder is still running is a timestamp,
  not a verdict.** `bbcmicro` shipped disabled on that mistake and had to be
  promoted separately.
