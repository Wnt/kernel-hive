# Wave brief — read this before you run a bridge tile migration

You are migrating bridge tiles from the bookworm guest base to trixie. **13 of
28 remain.** This is the only document you need before starting; it assumes
[`AGENTS.md`](../../AGENTS.md) (the lab's access map and hard rules) and points
at [`BRIDGE-TRIXIE-MIGRATION.md`](BRIDGE-TRIXIE-MIGRATION.md) (the procedure and
the two-base design) rather than repeating either.

On 2026-08-10 three agents ran waves in parallel and migrated 12 tiles. Each of
the three independently rediscovered the *same* three driver bugs, and each one
damaged a live production tile before diagnosing it. This brief exists so that
does not happen a fourth time.

---

## 1. What is different now — do not re-derive any of this

**The three `migrate-tile.sh` bugs are FIXED. Do not re-diagnose them, and do
not "fix" them again.** All three were found the expensive way; the fixes are in
`scripts/lib/box-detached-build.sh` and `scripts/dev/migrate-tile.sh`:

| Bug (fixed) | What it did | You will never see it again because |
|---|---|---|
| Poll read a log line count as the builder's exit code | Killed healthy builds that went quiet for one 20 s interval — every bridge builder does, waiting on a guest | The status trailer is metadata-FIRST (`RC <n>` header line), with a numeric assertion on the parse |
| Rollback raced the detached builder it had abandoned | The surviving builder re-baked a golden into the **restored live overlay** — `decos`, `plus4`, `bbcmicro`, three times, all three survived on luck | The rollback kills the builder's recorded process group and verifies it gone through `/proc/<pid>/exe` before touching the overlay; it is fail-closed |
| Staging was incomplete | Fresh per-tile stages died on the first rsync; `zx81` died on a missing `streamhost/tiles/zx81` sidecar | The remote `mkdir -p` creates rsync destination parents, and host-side sidecars are staged |

**ccache is already pulled.** 59.1% on the first cold MAME tree, then 96–100% on
every later one. Do not go looking for build speedups; there are none left of
that size.

**Three new tools exist.** They were built to retire exactly the work three
agents each hand-rolled. Check they are present in your worktree before planning
around them — if they are not, the orchestrator has not landed them yet: **ask,
do not rebuild them.**

| Tool | Replaces | Use it for |
|---|---|---|
| `scripts/dev/migrate-wave.sh` (+ `migrate-wave-plan.py`, `registry/bridge-waves.json`) | Hand-rolled concurrency, load checks, chroot serialization and the summary table | `migrate-wave.sh --wave 3 --dry-run` first, always. Caps tiles in flight (`-j`, default 2), re-checks box load before every launch (`--max-load`, default 10.0 of 16 threads), takes an atomic `mkdir` claim on the shared trixie MAME chroot, refuses stopped tiles and `c64` by name **before anything starts**, and prints the per-tile verdict table + `--json` |
| `scripts/dev/tile-accept.sh` (+ `frame-compare.py`) | "Open the two PNGs and squint" | Post-migration health bundle: unit, health, ticket, `/etc/bridge/suite` read from inside the **production** boot, `labctl reset` proving `loadvm` under the tile's own launcher, and a numeric frame compare. Exit 10 = "the frames differ, a human must look" — that is not a failure |
| `scripts/dev/box-sync-push.sh` (+ `scripts/lib/box-sync-pairs.sh`) | Four hand `scp`s in one day | Each migrated tile dirties ~3 mirrored rows and the pre-push gate blocks on drift **the driver itself created**. `verify-box-sync.sh` to see it, then `box-sync-push.sh --all-drift` (dry-run) and `--apply` |

**Four tiles are inactive, not three.** `indyr4400`, `star` and `nextstep` were
stopped by the operator (§10 of the handover). **`amiga` is down and nobody
declared it** — inactive since 2026-08-10 02:12:28, `ExecMainStatus=15`, after
being active since Aug 5. That also explains its `?` in `labctl ls`'s GOLDEN
column, which the handover wrongly files as a QMP probe artifact. A pre-existing
outage and a migration regression are the same screenshot: **get an operator
decision on `amiga` before migrating it**, and take its BEFORE frame from a
healthy bookworm fixture, not a cold start.

**Two verdicts in the plan doc are stale — do not re-audit them:**

- **`amiga`'s headline blocker is already solved.** `bridge-base.sh` installs
  `libgl1-mesa-dri` explicitly on trixie, and the wave-0 base build log shows
  `25.0.7-2+deb13u1` installed with `STATUS … fsuae=yes`. `amiga.sh`'s own apt
  line is a no-op (`command -v fs-uae` short-circuits). The tile is mechanical.
- **`nextstep`'s recommendation is to change nothing.** Keep the pinned SDL3
  3.4.14 source build. Trixie's `libsdl3-dev 3.2.10` clears Previous 4.4's floor
  but is not the version the builder's documented workarounds were derived on.
  Say so in your commit message so the next agent does not reopen it.

---

## 2. The remaining 13 — blocker, risk, and what a correct AFTER frame shows

Risk classes: **mechanical** = run it. **needs-work** = a known, small fix
first. **risky** = prove it on a `/data/vms/soltest/` clone before the tile.

The acceptance signal is the important column. It is what stops you accepting a
GRUB console as a booted machine — which already happened: `mpf2`'s readiness
predicate is `warning_pixels == 0 && pixels_nonblack > 100`, and on trixie it
returned while the screen still read `Loading Linux 6.12.101+deb13-amd64 ...`.

| Tile | Risk / blocker | ACCEPT — and REJECT |
|---|---|---|
| **alto** (w3) | **mechanical.** Self-contained .NET 8 publish; no external media, neither distro end constrains it. Self-bakes. | **ACCEPT:** a PORTRAIT **608×808** frame, black-on-**white**, the Alto Executive's two dense banner lines across the top with a `>` prompt below and an empty body. Dark `ink` in rect (0,88,608,40) between **1500 and 6000**. `xdpyinfo` = `608x808`. **REJECT:** a black frame (measures 24320 ink there), Bravo's command bar (12175), any visible Avalonia menu bar or window offset. |
| **amiga** (w3) | **mechanical** *once the outage above is resolved*. Mesa fix already in the base. Does **not** self-bake — `--bake` is a separate operator step. | **ACCEPT:** an FS-UAE **window, 720×568, centred on the black 1024×768 root** — not fullscreen (SDL real-fullscreen renders black under std-VGA capture). Inside it Workbench 1.3: grey/blue two-tone, `Workbench1.3` disk icon top right, `Ram Disk` below it, free-memory figure in the title bar, **no CLI window open**. Audio is load-bearing: capture a WAV through the AC97 path and measure RMS above the silence floor. **REJECT:** a solid black 1024×768 frame with a healthy log and exit 0 — that is the Mesa failure this whole check exists for. |
| **amstradcpc** (w3) | **mechanical.** cap32 from source; deps fine. Self-bakes behind a real colour gate. | **ACCEPT:** Locomotive BASIC 1.1 ready screen, **yellow on blue**, in a scale-3 SDL window on the black root. CPC blue (0,0,127) **> 700 000 px** AND yellow (255,255,0) **> 10 000 px in the same frame**. The unaltered Amstrad copyright string legible (licence condition), `Ready` with the block cursor. **REJECT:** blue alone (empty window). |
| **c64** (w4 leftover) | **risky.** Overlay is **DETACHED** — flattened 2026-08-07, standalone 5.24 GiB, no backing file. `migrate-tile.sh` refuses it by name. Full rebuild, **no automatic rollback**. Emulator question is closed (wave 4). | **ACCEPT:** the GEOS 2.0 deskTop **finished** loading off `GEOS.D64` through true-drive emulation (60–90 s): C64 blue border, white menu bar `geos file view disk special`, disk notepad pane right, trash icon. Then move the browser pointer and confirm the 1351 arrow tracks (`pointer_mode rel`; wave 4 proved nothing about mouse). Non-silent SID. **REJECT:** `**** COMMODORE 64 BASIC V2 ****` / `READY.` (autoboot did not take); `?DEVICE NOT PRESENT ERROR` (missing `-truedrive`); any half-painted desktop. |
| **daybreak** (w5) | **needs-work.** `openjdk-17-jre` gone; `default-jre` → `openjdk-21-jre`. Change `daybreak.sh:361`, then prove Dwarf actually paints under 21 on a clone (Swing/AWT + the no-WM focus dance: set X input focus AND synthesise one click, or every keystroke is silently dropped). Keep processor id `10-00-FE-31-AB-21` — the ViewPoint options are bound to it. Manual `--bake`. | **ACCEPT:** the ViewPoint 2.0.5 **desktop** — dithered grey desk filling the frame, `NNNNN Free Disk Pages` in the message area, Directory icon bottom right. Silent exhibit; do not look for audio. **REJECT:** the LOGGED-OFF screen (small bouncing keyboard on black, `8000` in the status bar — MP 8000 is Pilot's normal run state, not a hang, and it appears ~90 s into every boot); the Logon Option Sheet; the "Clearinghouse is down" / "new Desktop?" panels. |
| **nextstep** (w5) | **mechanical.** Change nothing (see §1). Self-bakes. Operator-stopped — do not start it during a quiesce. | **ACCEPT:** the NeXTSTEP 3.3 Workspace filling the **full 1120×832** root — mid-grey edge to edge, black Dock down the RIGHT edge, and **nothing black outside it**. Then prove the tablet: an absolute move puts the arrow at the requested spot 1:1. **REJECT:** black margins — the wmless-borders patch is not holding, Previous resampled to 1088×808, and it screenshots as a perfectly plausible NeXT desktop; a white full page of text (ROM monitor / panic); a small grey card on dark grey (boot panel). |
| **apple2** (w5) | **risky.** Trixie's `libsdl1.2-dev` is **sdl12-compat over SDL2**, not the SDL 1.2 LinApple was written against — and `linapple=no` on **both** bases, so its build is a pre-existing flake. Prove on a clone: (a) it compiles under g++ 14 (`Video.o` is the historic failure), (b) the patched `Frame.cpp` still gets motion + buttons with no grab, (c) the MouseInterface delta path still tracks 1:1. Re-assert the slot map (clock in **slot 5**, mouse in slot 4). | **ACCEPT:** the Apple GEOS deskTop booted off the ProDOS HD image, windowed (`Fullscreen=0`): menu bar `geos file view disk special`, disk icons, trash can, and **no dialog of any kind**. Then `cdrv.py <qmp> abs 16000 12000` must land the GEOS arrow at ≈(500,375). Non-silent //e power-on beep. **REJECT:** any "No mouse card found" / "No interrupt source" panel — slot 4 has been clobbered again; **fix it, never dismiss it**. An arrow that will not move, one that flies to a corner, and one that vanishes after the first click are three different sdl12-compat regressions and look identical in the logs. |
| **star** (w6) | **risky.** `nuget` is absent from trixie (no backports, no `msbuild`/`dotnet-sdk` either); `star.sh:425` installs it and `:171` runs `nuget restore D.sln`. Bootstrap `nuget.exe` under mono or vendor the restored packages; prove `xbuild /p:Configuration=Release D.sln` on a clone first. Keep all three Linux fixes and the `star.cfg` TOD pin at **1997/12/01** (the software is time-locked). Operator-stopped. First boot is **22 min and interactive**. | **ACCEPT:** the ViewPoint 2.0 **user** desktop on an **1088×860** root: grey stipple desk, `NNNNN Free Disk Pages` with a Help button, Directory icon bottom right. Also check the chrome — `launch.sh` moves the 1091×915 WinForms window to (0,−29) so Darkstar's System Menu / System Status bars sit off-screen; if either is visible the geometry is wrong. After `loadvm`, assert `info status` = **running**. **REJECT:** the Pilot Set Time Utility banner (~5 min in); the bouncing-keyboard LOGGED-OFF screen at MP 8000 (~14 min); the Workstation Administration desktop; the Logon Option Sheet. MP 7600 sits 6–8 min on a blank white page with no disk I/O — slow, not hung. Silent exhibit. |
| **sinclairql** (w7) | **risky.** Pins guest-apt `mame 0.251`, absent from trixie (0.276, not in backports); `sinclairql.sh:207` dies by design. Re-derive the four `(name, sha1)` pairs for the default `js` BIOS from **0.276's own `-listxml`** and re-run `assert_romset` against the **shipped** binary. Re-check that `hal16l8.ic38 NOT FOUND (NO GOOD DUMP KNOWN)` is still the *only* complaint, and that the warning panel is still dismissed by a **letter** (`x`; ret/spc/esc leave it up). Full golden re-bake. | **ACCEPT:** the QL in **monitor** mode (F1 at its own `F1...monitor / F2...TV` chooser): window #2 **white > 250 000 px** AND window #1 **red > 250 000 px** in the same frame, AND the command window **clean — fewer than 48 green (0,255,0) px** (one glyph is 96 px; any green means a dismissal keystroke leaked into SuperBASIC and the golden is contaminated). **REJECT:** MAME's navy imperfect-dump panel (~(15,15,45), >50 000 px); the QL's own chooser (green ≈9 980 px + a red bar ≈20 100 px); the RAM-test confetti between them. |
| **zxspectrum** (w7) | **risky.** Same 0.251 pin; `zxspectrum.sh:475` dies by design. Re-derive the `-bios en` sha1 from 0.276's `-listxml`. `-verifyroms spectrum` is **not** the gate and never was (31 alternative BIOS entries are unstaged, so it reports "bad" on a hash-perfect ROM). Verify on a real framebuffer that `spectrum` is still `status="good"` in 0.276 — this tile ships stock MAME with **no** skip-warnings patch. Full re-bake. | **ACCEPT:** the 48K power-on screen — **white paper** filling the frame with `© 1982 Sinclair Research Ltd` in black across the bottom. Paper (each channel 190–220) **> 600 000 px** AND ink (each channel < 40) **> 300 px**. The copyright string must be **unaltered** — that is the licence condition and the exhibit's whole compliance story. Keyboard proof: a single `b` at the K cursor puts the whole word `BORDER` on screen. **REJECT:** any MAME nag panel; paper alone. |
| **mpf2** (w2 rollback) | **needs-work.** MAME exits after the **second** cold boot, though the first drew the real banner. Trixie binary is already built and installed. Three cheap fixes on a clone, shared with `kc854`: (1) add stderr capture to the kiosk launcher — `.xinitrc` execs `launch.sh` which execs MAME with **no redirect**, so there is no diagnostic at all; (2) replace the point-sample `pgrep` with a **windowed** assert sampling frame + process together for ≥60 s (`.xinitrc` EXECs the emulator, so a death tears down X and getty relaunches it — a restart loop passes the frame poll and fails `pgrep`); (3) read `systemctl show getty@tty1 -p NRestarts` in-guest to tell a loop from a single death. Plus rewrite the predicate at `mpf2.sh:199-218`. | **ACCEPT:** the MPF-II's own Applesoft-clone power-on — banner line and `>` prompt at the left margin on a 560×192 composite picture aspect-corrected to fill the frame, in the 6-colour artifact palette and nothing else. Assert the palette IS present and the lit region has the banner's two-line shape. **REJECT:** **any Linux text at all** — a GRUB menu, `Loading Linux 6.12.101+deb13-amd64 ...`, a kernel console (the overlay quiets that whole path on purpose, so one line of it is a failure); MAME's known-problems dialog (mostly RGB (191,114,37)); a mostly-black frame with a few hundred lit pixels, which is exactly what the old predicate licensed. |
| **kc854** (w2 rollback) | **needs-work.** Identical shape and the same three fixes as `mpf2`; batch them. Trixie MAME 0.289 already built and installed. Not the suite, not the chroot. | **ACCEPT:** the KC 85/4's own **CAOS 4.2 power-on menu** (that menu is the fixture and its own launcher), aspect-corrected 4:3 filling the 1024×768 root — 320×256 is the pixel count, **not** the picture's shape; do not force `-resolution` to it (that is what left `mpf2` a narrow strip in a black surround). Bright px (R,G,B all >96) **> 20 000** (trixie measured 27868) AND nag-red (R>140, G<90, B<90) **< 2000** (measured 0). Keyboard proof: unshifted `basic` works (MAME declares `PORT_CHAR('B')` before `'b'`) and HC-BASIC clears the menu asking `MEMORY END ?`. **REJECT:** a full-screen red "THIS SYSTEM DOESN'T WORK" panel — the skip-warnings patch was lost and you are about to ship an error message as an exhibit. |
| **indyr4400** (unwaved) | **needs-work, and last.** No package blocker — trixie actually *simplifies* it (host and guest are both glibc 2.41, so `iris` builds with the host cargo and the throwaway debootstrap goes away). Gates are procedural: operator-stopped, never part of the apt sweep (unassessed, not clean), and a new `iris` binary **forces** a golden re-bake (a bridge golden holds the running emulator in RAM). **Also fix the builder's closing instruction first** — it says bake with the IRIX login showing; `docs/guests/indyr4400.md:165-168` says the golden is the Indigo Magic Desktop and the login is explicitly *not* in it. | **ACCEPT:** the IRIX 6.5 Indigo Magic Desktop of the `demos` session at exactly **1280×1024, no black border**: 4Dwm up, Toolchest docked upper-left, the demos/fsn/buttonfly icon column down the right edge, nothing else open. **REJECT:** the graphical login box; a bare blue root with REX3 frozen (the jitv2 wedge signature — CP0 Status `00000081`, every interrupt masked — not a slow boot); any frame showing Iris's own HUD (`18.5 MIPS … LED:`) or a 1282×1040 / 1288×1024 geometry — the root is pinned to 1280×1024+0+0 to clip the HUD and 2 overscan columns, so a visible HUD means the visitor is looking at the emulator instead of the machine. Audio is off by design. |

Two cross-cutting facts for the manual-bake set (`amiga`, `apple2`, `c64`,
`daybreak`, `star`, `indyr4400` — six of these 13):

- `migrate-tile.sh`'s inline bake **omits the `info status | grep running`
  assertion** that the shared `lib/bridge-bake-golden` makes. A golden baked
  while the VM was stopped restores **paused** — which screenshots perfectly,
  passes every mechanical check, and is dead. Assert it yourself.
- `MIGRATE_BAKE_SETTLE` (default 180 s) is one global number applied to exactly
  the tiles whose readiness no builder can check. A too-short settle bakes a
  mid-load frame as the permanent fixture every visitor resets to. Watch the
  frame; do not trust the timer.

`mpf2` and `kc854` have a loose end to close whichever way they go: their
**trixie** MAME binaries are installed in the production asset dirs
(`/data/vms/streamhost/assets/{mpf2,kc854}/mame/`) beside the renamed
`.bookworm-bak` originals, while both overlays are rolled back to bookworm. A
re-run of either builder on the bookworm suite would stage a glibc-2.41 binary
into a Debian 12 guest. `bridge-suite-status.sh` cannot see this — it reads
overlay backing files, not assets.

---

## 3. Non-negotiable, each with the incident that bought it

- **Never start a tile the operator stopped.** `indyr4400`/`star`/`nextstep`
  were quiesced to free the box; starting one during someone's timing run
  corrupts their numbers. `amiga` is down *undeclared* — that is a question for
  the operator, not a licence.
- **Never `pkill -f` from `ssh lab`.** The remote shell's own command line
  contains the pattern, so it matches itself and the session dies with exit 144
  that reads like a network fault. The same self-match ruins process *scans* —
  resolve each hit through `/proc/<pid>/exe`.
- **Kill clones only via `clone-guard kill-pidfile`.** The
  `${D:-/data/vms/streamhost/tiles/…}` default footgun in a clone launcher once
  reached the live `solaris` tile.
- **Mount chroot API filesystems only via `chroot-guard`.** A hand
  `mount --rbind /dev` made the chroot's `/dev/pts` a *peer* of the host's and
  the teardown propagated back out, killing every new interactive login on the
  box — while non-interactive `ssh lab '<cmd>'` kept working, so no automation
  noticed. Five of the 13 remaining tiles are chroot builds.
- **Never modify `/data/vms/bridge/bridge-base.qcow2` or
  `bridge-base-trixie.qcow2`.** An overlay names its backing file *by path*;
  rebuilding one breaks every overlay on it simultaneously, and the failure
  surfaces as a corrupt boot, not a clean error.
- **Never claim visual acceptance from a log, an exit code, or an assertion.**
  A tile can be healthy in all three and render black (`amiga`/Mesa) or show a
  GRUB console (`mpf2`). `tile-accept.sh` gives you numbers; the identity
  judgement — *is that the machine's own screen?* — is still yours.
- **Teardown is part of done, and is stated in the report.** A detached builder
  that outlived its driver re-baked a golden into a live overlay three times in
  one day. Kill by pidfile, verify through `/proc/<pid>/exe`, release every
  claim (chroot claim, displays, taps), and say so.

---

## 4. When a tile fails: roll back, diagnose, MOVE ON

**Six tiles with one clean failure beats one tile fixed and five unattempted.**
Rollback is cheap by design — the bookworm base was never touched and the
driver moves the overlay to `overlay.qcow2.bookworm-bak` rather than deleting
it. A failed mechanical check restores it automatically and leaves the attempt
beside it as `overlay.qcow2.trixie-failed` for the postmortem.

1. Let the driver roll back. Confirm it did (`bridge-suite-status.sh` clean).
2. Keep the evidence: the failed overlay, the build log, both PNGs.
3. Write **one paragraph** into `registry/bridge-suites.json` `_notes.<tile>` —
   what was reached, what failed, and whether the emulator or the plumbing is
   implicated. That is what turned `mpf2`/`kc854` from "trixie broke it" into a
   diagnosed, three-line fix.
4. Leave the ledger entry at `bookworm`. That is the correct state.
5. **Go to the next tile.** Do not open a second investigation inside a wave.

A tile you never attempted is not a failure. A tile you half-migrated and left
undeclared is.

---

## 5. How to report, so the orchestrator merges without re-deriving anything

Report exactly this, in this order:

1. **Branch name.** One branch per wave.
2. **Per-tile verdict table** — tile · MIGRATED / ROLLED-BACK / REFUSED /
   NOT-ATTEMPTED · one-line reason · duration. `migrate-wave.sh --json` emits
   this; paste it rather than retyping.
3. **Evidence paths**, absolute, per tile: BEFORE PNG, AFTER PNG, build log.
   Say explicitly which frames a human still owes a look at.
4. **Gate results** — the four you owe:
   `shfmt -d` + `shellcheck` over `$(scripts/lint/shell-sources.sh)`,
   `ruff check scripts && ruff format --check scripts`,
   `node scripts/check-file-size.mjs --strict`, `make tile-registry-check`.
   Plus `scripts/dev/bridge-suite-status.sh` (needs the box; not a CI gate).
   Red is not done — report **BLOCKED**, not done.
5. **Box-sync line.** `verify-box-sync.sh` clean, or which rows you pushed with
   `box-sync-push.sh --apply`.
6. **Teardown line.** What was released and the check that proved it: no
   surviving builder process groups (resolved through `/proc/<pid>/exe`, not
   `pgrep` on a pattern), no QEMU under any `/data/vms/soltest/migrate-*`, the
   chroot claim released, no clones alive. "Done" without this line is not done.

---

## 6. What will conflict when your branch merges, and how it must be resolved

Waves collide by construction. Every one of these was hit on 2026-08-10.

**`registry/bridge-suites.json` — resolve as a UNION, per key, never by side.**
Two waves flipping *different* tiles on *adjacent* alphabetical lines is a git
conflict, and "take ours" / "take theirs" silently reverts a whole wave's work.
Merge key by key: a tile changed on one side takes that side's value; a tile
changed on both sides to the same value is fine; only a genuine both-sides
disagreement is a conflict. Afterwards **count the `trixie` entries and confirm
the total is at least the larger of the two sides** — that assertion is the only
thing that makes a bad resolution loud. Do not reach for `merge=union` on this
file: it produces duplicate JSON keys that parse cleanly and silently take
whichever line sorts last. Also: the `_note` strings carry a hand-typed count
("20 live overlays") that every wave rewrites and that is *derivable from the
tiles map twelve lines below*. Recompute it; do not pick a side.

**Generated files — regenerate, never merge.** `registry/index.json`,
`scripts/serve/webroot/gallery-manifest.json`, `spa/src/three/archetypeRegistry.ts`
and the rest are outputs. Edit `registry/tiles/<tile>.json`, run
`make tile-registry-generate`, and let `make tile-registry-check` be the proof.
Hand-resolving one of these is always wrong, even when it merges cleanly.

**`docs/lab/BRIDGE-TRIXIE-MIGRATION.md` — the union is right, but read it.**
Every wave appends a `### Wave N` section at the same anchor and edits the same
two summary tables; today that was one 109-line conflict hunk. Both sides are
usually correct and independent.

**`scripts/dev/migrate-tile.sh` — do NOT edit it from a wave branch.** Two
agents wrote the *same two fixes* to it concurrently and produced 72 conflicted
lines in the script whose bugs had already damaged three live tiles. Wave agents
*run* the driver. If you find a real driver defect, stop, report it to the
orchestrator, and let it land alone on `main` so every in-flight wave rebases
onto one version. The file is also at 607 L against a 600 L bash cap, so a fix
costs a size-exclusion negotiation on top of the fix.

**Your own new prose.** Put a wave write-up in its own file rather than
appending to the plan doc where you can help it, and touch `registry/local.env`
never — it is gitignored operator-local.
