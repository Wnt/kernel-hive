# Session handover — 2026-08-10 evening

**This is the current handover.** Two earlier files share this date and are both
still useful for their own topic, but neither describes present state:
[`SESSION-HANDOVER-2026-08-10.md`](SESSION-HANDOVER-2026-08-10.md) (the Xerox
wave) and
[`SESSION-HANDOVER-2026-08-10-trixie.md`](SESSION-HANDOVER-2026-08-10-trixie.md)
(the migration; its §§3-9 are still accurate, its state section is not).

56 commits, all pushed to `origin/main`. Nothing uncommitted.

---

## 1. Live labhost state — read this before touching anything

**Five stations are deliberately stopped.** None is broken:

| Station | Why | Restart when |
|---|---|---|
| `indyr4400`, `star`, `nextstep` | labhost's three biggest CPU consumers; the operator stopped them to free capacity | The measurement campaign ends |
| `atarist` | Stopped **and soft-hidden** so nobody opens it mid-measurement | The de-bridging spike ends |
| `amiga` | Pre-existing, cleanly stopped at 02:12 (`ExecMainStatus=15`), **not** part of the above | Before migrating it — prove it healthy on bookworm first |

**One de-bridging spike arm is running on purpose** and must not be killed:

- arm B `dbr-armb` — host-native MAME ST via `drawshm` (tier 3)
- arm A `dbr-arma` was **terminated and abandoned 2026-08-11** (operator
  decision after the CPU verdict): QEMU down, streamhost stopped, gallery row
  withdrawn, no longer kept in sync with binary changes. Its `armA/` files
  stay on disk for the record.

**A deliberate serve-manifest overlay is published**, exposing both arms at
`/os/dbr-arma` and `/os/dbr-armb` while hiding them from the grid.
*(Updated 2026-08-11: the overlay now declares itself in `serve/darklaunch.d/`
and box-sync reports it `DARKLAUNCH` without blocking `git push` — withdrawing
before a push is no longer needed. See "Darklaunch overlays" in
`scripts/README.md`.)*

```
ssh lab '/data/vms/soltest/debridge-7f3a/gallery-arms.py withdraw'   # remove the exposure
ssh lab '/data/vms/soltest/debridge-7f3a/gallery-arms.py publish'    # re-expose
```

**The trixie migration is PAUSED** so labhost stays quiet for the latency
campaign. Ambient load is fine; sustained CPU campaigns are not.

---

## 2. Where the migration stands

**15 of 28 kiosks on trixie (54%)**, up from 3 this morning. `bookworm 13 ·
trixie 15 · DETACHED 1 · OK 27`.

Landed today: `decos` (wave-1 retry), wave 2's `bbcmicro armeval zx81 dragon32
oricatmos`, wave 4's `c128 vic20 plus4 pet2001 cbm8032 cbm2`.

Not landed: `mpf2`/`kc854` rolled back on a second-cold-boot liveness failure
that is theirs, not the suite's — **their trixie binaries are already built**, so
the retry is the cheap half. `amstradcpc`/`alto` were rolled back cleanly mid-run
when the migration was paused. Remaining: `alto amiga amstradcpc apple2 c64
daybreak indyr4400 kc854 mpf2 nextstep sinclairql star zxspectrum`.

**Do not run a wave with `--flip -j >1` before reading §4** — it was a
lost-update race until today.

---

## 3. The de-bridging spike — the decision gate has been passed

The question was whether to stop wrapping emulators in a Debian kiosk. **The
conversion removes real work**, measured at matched resolution, interleaved
A/B/A/B, three rounds:

| | arm A (bridge) | arm B (host-native) |
|---|---:|---:|
| emulator | 120.0 / 120.0 / 120.6 | 92.9 / 92.5 / 92.1 |
| streamhost | 26.7 / 26.1 / 25.9 | 9.1 / 9.1 / 9.0 |
| **total (% of one core)** | **146.8 / 146.2 / 146.6** | **102.0 / 101.6 / 101.1** |

Paired delta **44.8 / 44.6 / 45.5 points — arm B costs 69% of arm A.** About
half a core per station, with streamhost at a third of its bridged cost. Rounds
agree within 0.9 points.

**What was built to get there**, all on `main`:

- **`drawshm`** (`scripts/build-guests/patches/mame-drawshm.patch`) — a
  **driver-agnostic** MAME OSD *render* module publishing into the existing
  `IFB1` mapping with no change to the Rust consumer. Proven on a **Dragon 32**,
  not the SGI Indy, and at native geometry differs from MAME's own
  `video:snapshot()` by 96 px in one character cell. Takes an arbitrary
  `MAME_SHM_SIZE`, which is what lets the two arms be pixel-matched.
- **`build-mame-atarist.sh`** — host-native MAME ST, ccache **98.8%** on a cache
  warmed only by chroot builds, because host and chroot are now the same gcc-14.
- **One binary runs in both arms** — host and trixie bridge guest, six
  byte-identical framebuffer md5s. That is a direct dividend of the migration.
- A `drawshm` frame **reaches the browser** through streamhost (1024×768, 98.57%
  non-black), so the consumer's seqlock/damage/remap paths work against a
  producer they had never seen.

**The latency curve has NOT been run.** Its fixtures are pointer-driven and the
pointer is broken on both arms (§5). The measurement design is
[`DEBRIDGE-SPIKE-MEASUREMENT.md`](DEBRIDGE-SPIKE-MEASUREMENT.md); the rig and
bring-up commands are in `scripts/debridge-spike/README.md`.

**The finding that matters beyond this spike:** the ctlsock *module* is generic,
but `mame_input.rs`'s pointer strategy is **Indy-specific** — it converges by
reading Newport VC2 hardware-cursor registers, which only the Indy has. And
`KEY_MATRIX` is a hardcoded IRIX keyboard table. So "the input plane is
machine-generic" is true for the transport and **false for pointer and keys**.
Anyone converting the other eight MAME tiles inherits that.

---

## 4. Tooling built today

| Tool | What it removes |
|---|---|
| `scripts/dev/migrate-wave.sh` | Concurrency cap, load ceiling, declarative serialization groups, verdict table — three agents hand-rolled all of it badly |
| `scripts/dev/frame-compare.py` | Eyeball acceptance. **Cannot pass a black frame** — the discriminator is non-dominant pixel count, because five live exhibits have only 2 distinct colours |
| `scripts/dev/tile-accept.sh` | The post-migration health bundle |
| `scripts/dev/box-sync-push.sh` | The repo→labhost half. Refuses labhost-authoritative rows, re-verifies through the gate's own reverse-scrub path |
| `docs/lab/MIGRATION-WAVE-BRIEF.md` | The brief a wave agent reads instead of re-deriving the plan |
| `docs/lab/LABCTL.md` | The labctl manual that used to sit in every agent's context |

**`migrate-tile.sh` had four bugs, all fixed.** Three cost live stations: a poll
that read a **line count as an exit code** (so a quiet build was declared dead),
a rollback that raced the builder it abandoned, and incomplete staging. Three
separate agents each rediscovered them, and each **damaged a live station** —
`decos`, `plus4`, `bbcmicro` all had a checkpoint recaptured over them by an abandoned
builder. All three survived on luck. Launch/poll/stop now lives in
`scripts/lib/box-detached-build.sh` and the rollback **fails closed**.

The fourth was found by inspection before it bit: `--flip` was an **unlocked
read-modify-write** of the shared ledger, so under `-j 2` two stations finishing
together silently reverted one station's migration while both reported success.
Reproduced, then fixed with a lock on the ledger's own inode.

---

## 5. Known broken, with diagnosis

- **Arm B's pointer runs away.** Structural: the closed loop reads Newport VC2
  registers the Atari ST does not have, so the residual never shrinks and it
  bleeds counts forever. `SH_MAMECMD_ABS=0` will not simply fix it — dead
  reckoning needs 1:1 delta application, and the ST adds TOS acceleration on top
  of a quadrature encoder capped near 125 counts/emulated-second.
- **Arm A's pointer is inverted on both axes.** A clean sign negation. Its QEMU
  has `usb-tablet` only (no relative device) and MAME runs with `-mouse`, which
  grabs and reads relative motion. Likely fixable in MAME's own `cfg/` input map.
- **Arm B's keyboard probably does not reach the guest** — `KEY_MATRIX` is the
  Indy matrix. Arm A is unaffected.
- **Fixture 3 is 9.03% of the frame, not >35%** as an earlier draft claimed on an
  eyeballed count. It does **not** force the full-frame encode path; a resolution
  switch or screen clear would.
- `mpf2`'s readiness predicate accepts any warning-free frame with >100
  non-black pixels, so **a GRUB console passes it**. Fix as part of its retry.

---

## 6. Platform work

- **Architecture docs**: [`GUEST-TIERS.md`](../GUEST-TIERS.md) (five tiers, not
  three — `openvms` runs two sibling VMs, and the posters have no launcher),
  [`IO-PATHS.md`](../IO-PATHS.md) (pointer/keyboard/video/sound per tier),
  [`OVERHEAD.md`](../OVERHEAD.md) (what each tier costs).
  [`ARCHITECTURE.md`](../ARCHITECTURE.md) now shows the **three capture fronts**,
  with the bridge arrow visibly leaving the *kiosk* framebuffer.
- **Soft hide / dark launch**: `listing: { state, reason, since }` in a registry
  entry keeps the manifest row (flagged `listed: false`) so `/os/<id>` still
  resolves while the grid and 3D hall filter it out. Discoverability, not access
  control. It hides a station that **belongs** in the lineup; it cannot admit a
  non-lineup rig, because `gen_tiles_json.py` hard-fails on a declared station with
  no live directory.
- **box-sync 205 → 232 pairs** — the serving plane and the whole auth plane had
  none. Found a `test-clientlog.sh` on labhost that was **95 lines stale**.
- **Hourly ZFS snapshot of `data/vms`**, 7-day TTL, labhost-only, not in the repo —
  `/usr/local/sbin/vms-snapshot.sh` + `vms-snapshot.timer`. Restore is a file
  copy out of `/data/vms/.zfs/snapshot/`; **never `zfs rollback`**, it would
  revert every running guest disk. Has a space guard as well as the age policy.
- **`/home/wnt/osgallery` cleaned**: 48 GB → 516 MB, 1,343,862 files → 8,042.
  165 Codex task transcripts harvested first to
  `/home/wnt/osgallery-codex-transcripts.tar.gz` (35.8 MB) — **58 of them existed
  only inside worktrees** and would have been destroyed.
- **`AGENTS.md` 28.4 KB → 5.7 KB (80%)**. It is auto-loaded into every agent, so
  it now carries only damage-preventing rules and a pointer table. Keep it that
  way.

---

## 7. In flight at write time

- **Pointer fixes** for both arms (§5), including arm B's cursor colour if
  trivial. Constrained to leave `irix` byte-for-byte identical by default.
- **`SPA id == SH_TILE`** — exactly two stations diverge (`aros`/`amigaos`,
  `solaris`/`solariscde`). Renaming the **daemon** side to match the registry id,
  `aros` first. `solaris` is the riskiest station in the fleet (patched QEMU with
  `gallery-hid-pci`). `labctl gen` hard-fails on a declared/live mismatch, so
  repo and box must move together.

## 8. Open, not started

1. Resume the migration: `mpf2`+`kc854` retry, wave 3, wave 5, then `star`
   (nuget), `sinclairql`/`zxspectrum` (romsets vs 0.276), `c64` (detached — full
   rebuild, **no rollback**, take a copy first).
2. Run the latency curve once the pointer works, or pivot the fixtures to
   keyboard (`Ctrl-R` alert, character echo, screen clear) and stop fighting
   quadrature.
3. Un-hide and restart `atarist`; restart the three stopped stations.
4. `docs/history/TECH-DEBT-INVENTORY.md` item 17 and the 14 remaining
   architecture-research questions (task list).
5. `.git/modules` in the old osgallery tree — 211 MB of re-cloneable MAME fork
   history, would take that tree to ~305 MB.

## 9. Rules that earned their place today

- **A step that reports success while doing nothing is this repo's recurring
  defect.** Four instances today: the poll that read a line count as an exit
  code, the unlocked ledger flip, `labctl assert --settle` passing on a frozen
  frame, and `mpf2` accepting a GRUB console. Assume it, look for it.
- **Verify the agent's justification when it overrides an instruction.** Two did
  today, both correctly — and both times the reason was checkable in one command.
- **Route each check to the cheapest competent verifier.** Machine checks
  (teardown, hashes, gates) belong to the agent; "does it look right" belongs to
  the operator. Do not spend a Playwright run proving something they can see.
- **Resolve processes through `/proc/<pid>/exe`, never a cmdline grep** — it
  self-matches and has reported phantom survivors.
- **Merge conflicts on the ledger are a UNION**, never a side. Picking a side
  silently reverts a whole wave.
