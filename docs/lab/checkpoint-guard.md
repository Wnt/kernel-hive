# checkpoint-guard — recapturing a checkpoint without ever being one step from losing it

**Source of truth:** `scripts/lib/checkpoint-guard.sh` (repo) == `/usr/local/bin/checkpoint-guard`
(labhost), kept **byte-identical** via the box-sync pair table. It runs on labhost as
root: the station `qmp.sock` files are root-only there.

It is one tool in three files, each answering one question, all four rows in the
pair table and all deployed together — the guard refuses to run if any is missing,
because a guard that cannot prove a restore, or cannot tell which disks hold the
checkpoint, must not delete one:

| File | Answers |
|---|---|
| `scripts/lib/checkpoint-guard.sh` | what is safe to delete, and when |
| `scripts/lib/checkpoint-guard-proof.sh` | does this checkpoint actually restore (rule 9) |
| `scripts/lib/checkpoint-guard-disks.sh` | which files hold this station's checkpoint |
| `scripts/lib/cpg-mask.py` | which pixels a declared mask excludes from the comparison |

This is the tool named by AGENTS.md's rule *"Never retire a golden before its
replacement is proven"*, in the same idiom as [`clone-guard`](clone-guard.md) and
`chroot-guard`: an operation that has already caused damage gets wrapped once,
centrally, fail-closed.

Vocabulary is [`docs/GLOSSARY.md`](../GLOSSARY.md)'s: a **checkpoint** is the captured
full machine state; `golden` is the opaque stored **label** it lives under;
**recapture** is the act. The old word for it was "re-bake".

## The incident it prevents

2026-08-24, `win95`. An agent recapturing the checkpoint typed the folklore by hand:

```
delvm golden          # from here on the station has NO checkpoint
savevm golden         # ...and the agent was killed before this ran
```

An API error landed **inside that window**. The result was a LIVE, listed station with
no checkpoint at all — `labctl reset` had nothing to restore. It was recoverable only
because a byte-copy backup happened to exist. The window is seconds wide and the
failure is total.

The safe sequence was known; it was just folklore, retyped from brief to brief, and one
agent got it wrong under pressure. This makes it one command.

## Use it

```bash
ssh lab 'checkpoint-guard recapture <station>'   # THE command
ssh lab 'checkpoint-guard status   <station>'    # journal + snapshot inventory
ssh lab 'checkpoint-guard resume   <station>'    # finish an interrupted run
ssh lab 'checkpoint-guard rollback <station>'    # put the verified byte copy back
ssh lab 'checkpoint-guard prune    <station>'    # drop the backup once you are happy
```

`recapture` captures the station's **current live state** as the new checkpoint. Curate
the scene first — the guest is captured as it stands.

**Curating the scene is not only the picture.** What the guard proves is that the
checkpoint RESTORES: the framebuffer moves off a reference and comes back to it. It
cannot prove the restored exhibit is USABLE, and the two came apart on `aix432`,
2026-08-31. That recapture passed every gate here, and it baked a Netscape whose HTML
content area no longer takes keyboard focus: a visitor could click a form field, see
the caret blink, and type into a void. The screenshot was perfect. The interaction
state that made it useless is in the vmstate, so it came back on every restore, and a
month of input-plane debugging could not have touched it.

So for any station whose exhibit is an APPLICATION a visitor drives, add one manual
step the guard cannot do for you, AFTER the run: restore the new checkpoint into a
sandbox clone (`clone-guard`-linted launcher, same device set) and drive the thing the
visitor drives — click the field, type, read the characters back out of a screendump.
If that is not done, "restore-proven" means only that the pixels come back.

`aix432` closed that loop on 2026-08-31: the repaired scene was captured, the
acceptance clone was booted from the NEW checkpoint, and typing into the page's
form field was read out of a screendump before the run was called done. That
station also needs a `CPG_DIRTY_CMD` (its registry notes carry the exact one):
with a freshly started browser and no window yet clicked, `CPG_DIRTY_TEXT` and
the `tab`/`esc` fallback both change **0 px** and the guard refuses — correctly,
and without deleting anything.

Knobs, all env: `CPG_LABEL` (default `golden`), `CPG_STAGING_LABEL` (default
`cpg-staging`), `CPG_DIRTY_TEXT`, `CPG_SSIM_MIN` (default `0.999`), `CPG_IDLE_SECONDS`,
`CPG_SETTLE`, `CPG_STATIONS_ROOT` (point it at a sandbox to exercise the guard on a
clone), `CPG_MASK` and `CPG_MASK_MAX_FRACTION` (below).

## What it guarantees

1. **Backup first, hashed with the guest STOPPED.** Every checkpoint-bearing qcow2 is
   byte-copied and SHA256-compared while the vCPUs are halted. A running guest writes
   its active layer, so a live hash proves nothing. A mismatch aborts before anything
   is captured.
2. **Capture under a different label.** The new state is written as `cpg-staging`. The
   live `golden` is not touched.
3. **Prove the restore on the framebuffer.** Reference shot (asserted stable), dirty the
   guest so the framebuffer demonstrably moves, `loadvm`, and require the framebuffer
   back at the reference. Comparison is byte-identical first, then SSIM ≥ `CPG_SSIM_MIN`
   — the same two-step and threshold `checkpoint-verify.sh` already uses.
4. **Assert the restored guest is RUNNING.** A checkpoint captured while stopped
   restores *paused*: the screenshot looks perfect and the station is dead to every
   visitor. `bridge-bake-golden` learned this the hard way; the guard re-learns it on
   every run.
5. **Only then promote.** `delvm golden`, `savevm golden`, and the whole framebuffer
   proof again on the promoted label.
6. **A failed run deletes nothing.** Every refusal message says so explicitly.
7. **It holds streamhost's wake lease** for the run, so the idle-pause reconciler
   cannot re-freeze the guest in the middle of a capture.

### The rollback is only as real as the journal's `backups` array

`cpg_rollback` restores from the rows recorded in `.checkpoint-guard.json`, and
**nothing else on disk tells it anything.** A `.cpg-bak-<stamp>` file sitting
next to the station's qcow2 is not a rollback target until a row names it, with
its `sha256`.

Two things follow, both found on `aix432` on 2026-08-31 by checking a reported
rollback against the tool instead of taking it on trust:

- **A resumed run used to ERASE the rows.** `cpg_journal_write` re-renders the
  whole journal from the in-memory `CPG_BACKUPS`, and `cpg_resume` never runs
  `cpg_backup` — so each of the four journal writes a resume performs replaced a
  populated array with `[]`. The backup FILE was fine; the only record of where
  it was, and what it should hash to, was gone. `cpg_resume` now calls
  `cpg_journal_load_backups` before its first write, and
  `scripts/test_checkpoint_guard_rollback.py` fails if that ordering is ever
  undone.
- **Zero rows is now a REFUSAL.** Every loop in `cpg_rollback` is a `while read`
  over those rows, so with none of them it verified nothing and printed *"Every
  recorded backup verified, so the rollback is available"*; under
  `CPG_ROLLBACK_CONFIRM=1` it restored nothing, deleted the journal, logged
  *"ROLLED BACK to the pre-recapture disks"* — **and exited 0.** A false success
  on the incident path ends an investigation instead of starting one. It now
  refuses, names the `*.cpg-bak-*` files still on disk, and says how to
  re-record one. Belt and braces behind that: a restore loop that copied zero
  disks refuses to delete the journal or claim a rollback.

**Sweep result, 2026-08-31.** Of the five stations holding a guard journal,
`aix432` and `sunos414` both had `"backups": []`; `hpuxvue`, `macos9` and `win95`
each had their row. `aix432`'s is now registered. **`sunos414`'s is deliberately
NOT**: its journal is stamped 08:09 and its lone `cpg-bak-20260831T073623Z` has a
10:36 mtime, while the live `golden` was captured at 11:08 — so that file cannot
be shown to be the copy the current checkpoint replaced, and registering it would
manufacture exactly the false confidence this section is about. It belongs to the
`sunos414-abs` stream, whose own recapture is still pending. With the fixed guard
that station's rollback refuses loudly and names the file, which is the correct
state for an unproven backup.

**The journal is line-oriented.** `_cpg_journal_backup_rows` reads the array with
a `sed`, so each row must sit whole on ONE line exactly as `cpg_journal_write`
prints it. Pretty-printed JSON parses fine as JSON and reads as **zero rows** —
which is the silent-empty state above. If you ever hand-record a row, match the
writer's format and then prove it by running `checkpoint-guard rollback <station>`
WITHOUT `CPG_ROLLBACK_CONFIRM`: that verifies every recorded sha256 against the
file and then refuses, touching nothing.

### Which disk it backs up, and how it knows

It asks the running QEMU (`query-block`), not the launcher: that resolves whatever
the process actually opened, whatever shell variables built the path. The launcher
scrape is only the fallback for a **stopped** station, and it reads the launcher
with comments stripped, so a prose line like `# runs WITHOUT -snapshot` is not
mistaken for a flag.

**The scrape used to fail exactly when it mattered (fixed 2026-09-14).** Nearly
every station launcher writes

```sh
D=/data/vms/streamhost/stations/rhapsody
...
  -drive file=$D/rhapsody-golden.qcow2,format=qcow2,if=ide,index=0 \
```

and the scrape did not expand `$D`. So for a stopped station it produced the
literal string `$D/rhapsody-golden.qcow2`, which of course does not exist, and
`cpg_resolve` refused with *"launcher references disk '$D/...', which does not
exist"* — for `rollback`, `status` and `prune`, the three subcommands whose whole
reason to exist is a station whose guest is **down**. `rollback` therefore failed
in precisely the situation you reach for it in.

`_cpg_expand_leading_var` now resolves a leading `$VAR/` or `${VAR}/` against the
launcher's **own** assignment of that name — and only a *literal absolute* one. A
value built by `$(...)` or a backtick is not statically knowable, and a name
assigned two different literals is ambiguous; in both cases the token is left
untouched and the guard refuses loudly, naming the variable, rather than guessing
which disk holds a checkpoint. Requiring the `/` after the name is what keeps
`$D/` from matching inside `$DISK/`.
`scripts/test_checkpoint_guard_rollback.py` pins the stopped-guest rollback and
both refusals.

### Why the staging label is not `golden-new`

This one is load-bearing, and the folklore had it wrong. Every station launcher probes
for its checkpoint with:

```bash
qemu-img snapshot -l "$DISK" | grep -qw golden && LOADVM="-loadvm golden -S"
```

**`grep -qw golden` matches `golden-new`** — `-` is not a word constituent. So in the
interrupted state where `golden` is gone but a `golden-new` staging label remains, that
probe answers *yes*, the launcher adds `-loadvm golden` for a snapshot that does not
exist, and **QEMU refuses to start**. The folklore's own staging label turns a
recoverable interruption into a station that will not boot.

`cpg-staging` is invisible to that probe, so the interrupted state cold-boots instead:
degraded, but up. The guard also refuses any `CPG_STAGING_LABEL` that `grep -qw
$CPG_LABEL` would match, so the hazard cannot be reintroduced by env.

The guard matches snapshot tags **exactly** (awk on the tag column) rather than with
`grep -qw`, for the same reason: getting it wrong inside the guard would make `resume`
believe the promote had finished, delete the staging label, and leave the station with
no checkpoint at all — precisely the outcome the tool exists to prevent.

## When typing cannot dirty the guest

The restore proof needs the framebuffer to **move** before the `loadvm`, or a
matching "restored" shot proves nothing. The guard's default way of moving it is
to type `CPG_DIRTY_TEXT` and, failing that, `tab`/`esc`.

**Typing needs KEYBOARD FOCUS, and focus is a property of the guest AND of the
scene** — not something the guard can assume. `sunos414` is the case that proved
it: OpenWindows runs with `OpenWindows.SetInput: select` (click-to-focus), so a
restored golden in which no window has ever been clicked swallows every
keystroke. Measured on the live station, with the wake lease held and the guest
confirmed `running`: typing `checkpoint-guard-dirty` changed **0 pixels**.

That is not a fault to work around. It is a fact about the guest, so the station
supplies the action that moves *its* framebuffer:

```sh
CPG_DIRTY_CMD='labctl exec sunos414 "echo checkpoint-guard-dirty > /dev/console"'   ssh lab 'checkpoint-guard recapture sunos414'
```

`CPG_DIRTY_CMD` runs only after the keystroke attempts have failed, and whatever
it does is discarded by the `loadvm` that immediately follows — so it is free to
be loud. If it is set and the framebuffer *still* does not move, the guard
refuses exactly as before: the hook adds a way to succeed, never a way to skip
the proof.

## Masking a region that never idles

The idle-stability check in `cpg_reference` — two shots `CPG_IDLE_SECONDS` apart
must agree — is what stops a half-drawn golden, and it stays. But it made a whole
class of **period-correct scenes unbakeable**. `www.apple.com`'s 1998 homepage
carries a 37-frame animated GIF ticker (`home/images/ticker.gif`), so that
framebuffer *never* idles: the guard reported `SSIM 0.996854 < 0.999` and
refused, correctly and repeatedly, and `rhapsody` shipped `www.wired.com`
instead of the thematically exact Apple page.

A **mask** declares rectangles that are excluded from every framebuffer
comparison in the run, so a scene that is stable everywhere except a known
animating region can still be proven stable. `rhapsody` is the worked example,
and it is the real declaration, measured on that station's own framebuffer:

```sh
# in the station's station.env (the declared home — it is deployed from the
# committed fixture, so the exemption is reviewable):
CPG_MASK="175,489,604x29 home/images/ticker.gif, the 37-frame Hot News Headlines animated GIF on the 1998 www.apple.com homepage: it loops forever and cannot be parked"
```

With it declared, the recapture that refused at `0.996854` passes at
**`SSIM 1.000000 (masked 2.5%, 4 tiles, worst tile 1.000000)`**.

**Measure the rectangle; never guess it.** The number above came from two
independent measurements that agree, and both are cheap:

1. Union the framebuffer diffs over a window long enough to cover the
   animation's whole cycle — for rhapsody, 72 s of screendumps put *all*
   motion inside `x 391..725, y 498..509`.
2. Find the animating element's own extent in the rendered frame. rhapsody's
   ticker sits at `x 177..776, y 491..514`, which is exactly the
   `WIDTH=600 HEIGHT=25` its page declares for the image.

Then declare **the element, not the motion**, plus a small margin. Those two
numbers are different on purpose: only the headline text band moved during the
measurement, but the GIF cycles headlines of different lengths, so a later frame
can use the image's full 600 px. A mask fitted to the observed band would pass
today and refuse later, which is the worst of both worlds — an exemption that
is simultaneously too clever and not durable.

Entries are separated by `;`; each is `X,Y,WxH` followed by whitespace and a
free-text **reason**. Coordinates are guest pixels in that station's own
framebuffer. `$CPG_MASK` in the environment overrides `station.env` for clone
work, and the two are labelled `env (ad-hoc)` versus `station.env (declared)`
everywhere the mask is shown, so nobody mistakes an experiment for a declaration.

Four properties are what make this an exemption you can trust, and each of them
is a refusal rather than a convention:

- **Declared, never inferred.** There is deliberately no "ignore whatever moves"
  mode. That would not narrow the check, it would delete it.
- **Every rectangle carries a reason,** and one without a readable reason is
  refused. An exemption nobody can read the *why* of is how this check quietly
  stops meaning anything.
- **The rest of the frame faces the same threshold.** This is why `cpg-mask.py`
  **crops** rather than blanks. Painting the masked region black in *both* frames
  is the obvious implementation and it is wrong: the region then matches
  perfectly and *inflates* a whole-frame SSIM, buying slack for the rest of the
  picture — a mask over 6% of the screen would let the other 94% score 0.99894
  and still "pass" at 0.999. Here the masked pixels are not compared at all, and
  the reported number is the area-weighted mean of **ffmpeg's own SSIM** over the
  tiles that remain: the same engine and the same bar, applied to a smaller area.
- **A mask covering most of the screen is refused** — `CPG_MASK_MAX_FRACTION`,
  default 0.25. Past that it is not a narrowed stability check, it is no
  stability check.

Two more refusals worth knowing: a rectangle that does not fit the station's
current framebuffer is refused rather than clamped (the declaration was written
for another resolution and would mask the wrong place), and anything that is not
an actual comparison — a missing or failing `ffmpeg` — exits **>1**, never 1,
because the proof half reads exit 1 as "the frames differ" and "differ" is
precisely what licenses it to believe the framebuffer moved.

**Where the mask shows up.** In the run log, in the journal's `mask` field, and —
because `prune` consumes the journal and an exemption that disappears with the
paperwork is an invisible exemption — in `<stationdir>/.checkpoint-mask.json`,
written beside the checkpoint on promote and **removed** by a later maskless
recapture so it can never over-claim. `checkpoint-guard status` prints it loudly:

```
mask       ACTIVE, from station.env (declared)
    rect 90,32 180x96  -- boot-sector ticker, rewritten every CPU pass: ...
mask-baked THIS CHECKPOINT WAS BAKED WITH A REGION EXCLUDED:
    {"label": "golden", "ts": "...", "ssim_min": "0.999", "mask": {...}}
```

**The mask does not blind the check**, and that is measurable rather than
asserted: on the proof rig, the same two frames scored **0.940672 (exit 1,
refused)** with the mask moved off the animating region onto a static one, and
**0.999638 (exit 0)** with the real declaration. Masking moves *where* the guard
looks; it never changes *how hard* it looks.

### Why there is no built-in mouse wiggle

The obvious general fallback — jiggle the pointer, every graphical guest has a
cursor — was measured and rejected. `_cpg_same` accepts **SSIM >= 0.999** as
"unchanged", and on `sunos414` moving the cursor alone scores **0.999756**: the
guard would judge the wiggled frame identical and refuse anyway. A large pointer
excursion scored 0.998128 only because it dragged 8-bit colormap focus across
window boundaries and repainted ~1000 px, which is luck, not mechanism. A
built-in wiggle would therefore be a placebo that passes on some stations and
silently fails on others. Writing to a console scores **0.984**, comfortably
clear of the bar.

The general lesson for anyone choosing a dirty action: **the bar is not "some
pixels changed", it is SSIM below `CPG_SSIM_MIN`.** A few hundred changed pixels
in a 1024x768 frame does not clear it.

### An interrupted run needs `resume`, not `recapture`

If a previous attempt refused at the proof, the journal is left in state
`captured` with the staging snapshot on disk — correct, and `golden` is
untouched. A second `recapture` will refuse to start on top of it. Finish it
with the hook supplied:

```sh
CPG_DIRTY_CMD='...' ssh lab 'checkpoint-guard resume sunos414'
```

## The residual window, stated honestly

QEMU has no snapshot rename. Making the new state answer to the label `golden` is
necessarily `delvm golden` then `savevm golden`. **The guard cannot remove that window.**
What it removes is the window being fatal: throughout it, the restore-*proven*
`cpg-staging` snapshot is still in the same qcow2, the SHA256-verified byte copy is
still on disk, and the journal names the state so `resume` finishes it in one step.

## Killed at each step — what is on disk, and why it is recoverable

The journal (`<stationdir>/.checkpoint-guard.json`) is written **write-ahead**: before
the step it names, so the recorded state is always at-or-ahead of what happened on disk,
never behind it. Written to a temp file and `mv`'d, so it is never half-written.

| Killed here | Journal | On disk | Recovery |
|---|---|---|---|
| Before the backup finishes | `backup` | `golden` untouched and authoritative. A partial `.cpg-bak-*` may exist. | `prune`, then re-run. `resume` refuses this state on purpose and says why. |
| Backup done, before `savevm cpg-staging` | `captured` | `golden` untouched. Verified backup present. | Re-run `recapture` after `prune`, or `resume` (it promotes from the staging label once one exists). |
| During `savevm cpg-staging` | `captured` | `golden` untouched. A partial/absent staging label. | Same. Nothing of value can be lost here. |
| Staging label captured and proven, before `delvm golden` | `captured` | **Both** labels present. Launcher still finds `golden`. Station fully normal. | `resume` — promotes from the proven staging label. **Proven on the clone.** |
| **Inside `delvm golden` → `savevm golden`** (the incident's window) | `promoting` | `golden` gone; **proven `cpg-staging` present**; verified backup present. Launcher's probe correctly finds no `golden`, so the station **cold-boots** — degraded, bootable, not destroyed. | `resume` — one step, `loadvm cpg-staging` then re-promote. **Proven on the clone.** |
| After `savevm golden`, before `delvm cpg-staging` | `promoted` | Both labels present, `golden` is the new one. | `resume` detects the promote landed and just finishes cleanup. |
| During cleanup | `cleanup` / `done` | `golden` correct. Staging label may linger. | `resume`; a lingering `cpg-staging` is harmless (invisible to the launcher probe). |

In every row the guest may be left **stopped** — the guard halts vCPUs for the backup.
That is the same condition as idle-pause: `labctl` (or the next visitor) resumes it, and
`resume`/`rollback` leave it running.

The wake-lease refresher watches its owning shell and exits with it, so a `kill -9`
cannot orphan a loop that pins the station awake.

`rollback` re-verifies each backup's SHA256 *before* trusting it, refuses while the
guest's QEMU is alive, and requires `CPG_ROLLBACK_CONFIRM=1`.

## Runtimes covered, and refused

**Covered: QEMU vmstate stations** (`SH_RESET_MODE=loadvm`) — the 34 stations whose
checkpoint is an internal qcow2 snapshot labelled `golden`.

**Refused, loudly, rather than half-covered:**

- **es40 `.axp`** (`w2kalpha`, `tru64`). The checkpoint is a savestate written by the
  emulator's own `SAVEST` verb, paired with a disk image frozen in the same `SIGSTOP`
  window. Not a QMP snapshot; there is no framebuffer channel the guard can prove a
  restore on; and `tru64`'s binary does not implement `SAVEST` at all. Half-covering
  this would produce a guard that reports success on an unproven pair.
- **MAME `.sta`** (`irix`, the de-bridged VICE/MAME stations). Checkpoint is a savestate
  paired with a CHD copied inside a `PAUSE` window, plus a provenance md5 binding both
  to the emulator binary. `scripts/build-guests/irix/irix-savestate/capture-checkpoint.sh`
  is the tool for that path.
- **Iris snapshot directories** (`indyr4400`, once it is host-native). The checkpoint is
  `saves/<name>/` — a manifest, per-device state, the COW overlay's dirty-sector set, and
  RAM/framebuffer chunks in a shared content-addressable store — captured and restored
  *in-process* by the emulator through its `mamectl/1` socket (`SAVEST` / `LOADST` /
  `RESET`). There is no QMP monitor and no qcow2 label for the guard to reach, the CAS
  store is shared between snapshots so no single file *is* the checkpoint, and the
  provenance that binds state to binary lives in the snapshot's own
  `kh-provenance.toml`, checked by the emulator on every restore. The tooling for that
  path is `scripts/build-guests/irix/iris-golden/` (`prove-reset.py`, `irisrig.py`).
- **`SH_RESET_MODE=restart`** — the boot artifact *is* the reset source; there is no
  checkpoint to recapture.
- **`SH_RESET_MODE=pve-rollback`** — a PVE snapshot, not a qcow2 label.
- **A launcher running QEMU with `-snapshot`** — guest writes never reach the qcow2.
- **An unidentifiable runtime.** A guard that guesses the runtime is worse than no guard.

The savestate paths are file-based, which means a *better* guard is possible for them
than for QEMU: write the new state under a temp name, prove it, then `mv` it over the
old one — an atomic rename, with no window at all. That is the shape any future
extension should take. It is not in this guard because it could not be proven tonight
without touching `w2kalpha` and `tru64`, which other streams own.

Iris is the first runtime to ship that shape rather than describe it: its `SAVEST`
captures into `saves/<name>.new`, stamps the sidecar, then renames `<name>` to
`<name>.prev` and `<name>.new` into place, so a crash mid-capture leaves the old
checkpoint untouched and a bad bake is one `mv` from being undone. A guard extension
for the other savestate stations has a working precedent to copy now.

## Proof

Run on a namespaced clone of `freedos` under `/data/vms/sandbox/golden-guard/stations/`
(`CPG_STATIONS_ROOT` pointed there), never a live station:

- **Happy path** — full recapture, framebuffer-proven at SSIM 0.999594 both before and
  after the promote, guest running, backup kept.
- **Refusal is a no-op** — an early strict-byte-compare run refused on FreeDOS's
  blinking cursor; `golden` was still the original 2026-07-17 snapshot afterwards. (That
  refusal is what motivated adopting the fleet's existing SSIM tolerance: a guard that
  refuses on healthy stations is a guard that gets loosened until it proves nothing.)
- **`kill -9` between capture and delete** — `golden` survived intact, `loadvm golden`
  restored a *running* guest with a real framebuffer, and `resume` then completed the
  recapture.
- **`kill -9` inside the `delvm`→`savevm` window** — too fast to win the race, so the
  exact on-disk state was constructed deterministically (journal `promoting`, `golden`
  deleted, proven staging label present). The launcher probe correctly reported no
  checkpoint (cold-boot, not a failed start), the staging label still loaded, the backup
  still verified, and `resume` restored a proven `golden` in one step.
- **`rollback`** — refused with the guest up; with it down, restored the pre-recapture
  disk, SHA256-verified it, and the station relaunched to a running guest.

Re-proven 2026-09-14 for the mask and the stopped-guest rollback, on a sandbox rig
under `/data/vms/sandbox/cpg-mask/rig/stations/` — a 512-byte boot-sector guest
whose only moving parts are one 20x6-cell ticker rewritten every CPU pass (the
stand-in for `ticker.gif`) and a separate block repainted on keypress, so
`CPG_DIRTY_TEXT` can still move the framebuffer *outside* the mask:

- **Without a mask, `recapture` refuses** — idle SSIM 0.945946 < 0.999, exit 7,
  nothing captured or deleted.
- **With the mask declared in `station.env`, it succeeds** — restore proven at
  masked SSIM 0.999638 (6.1% excluded, 4 tiles) both before and after the
  promote, guest running, mask recorded beside the checkpoint.
- **The mask over the wrong region still refuses** — 0.940672, exit 1.
- **A stopped guest rolls back** — the pre-fix `/usr/local/bin/checkpoint-guard`
  refused at exit 5 on `$D/rig-golden.qcow2`; the fixed guard verified the
  backup's SHA256, refused without `CPG_ROLLBACK_CONFIRM`, restored on confirm,
  and the station relaunched to a running guest with a live framebuffer.
