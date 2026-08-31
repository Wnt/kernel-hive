# checkpoint-guard — recapturing a checkpoint without ever being one step from losing it

**Source of truth:** `scripts/lib/checkpoint-guard.sh` (repo) == `/usr/local/bin/checkpoint-guard`
(labhost), kept **byte-identical** via the box-sync pair table. It runs on labhost as
root: the station `qmp.sock` files are root-only there.

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

Knobs, all env: `CPG_LABEL` (default `golden`), `CPG_STAGING_LABEL` (default
`cpg-staging`), `CPG_DIRTY_TEXT`, `CPG_SSIM_MIN` (default `0.999`), `CPG_IDLE_SECONDS`,
`CPG_SETTLE`, `CPG_STATIONS_ROOT` (point it at a sandbox to exercise the guard on a
clone).

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

### Which disk it backs up, and how it knows

It asks the running QEMU (`query-block`), not the launcher. Most stations build the disk
path from a shell variable (`-drive file="$DISK"`), which no static parse can resolve —
`win95` is one. The launcher scrape is only the fallback for a stopped station, and it
reads the launcher with comments stripped, so a prose line like `# runs WITHOUT
-snapshot` is not mistaken for a flag.

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
- **`SH_RESET_MODE=restart`** — the boot artifact *is* the reset source; there is no
  checkpoint to recapture.
- **`SH_RESET_MODE=pve-rollback`** — a PVE snapshot, not a qcow2 label.
- **A launcher running QEMU with `-snapshot`** — guest writes never reach the qcow2.
- **An unidentifiable runtime.** A guard that guesses the runtime is worse than no guard.

Both savestate paths are file-based, which means a *better* guard is possible for them
than for QEMU: write the new state under a temp name, prove it, then `mv` it over the
old one — an atomic rename, with no window at all. That is the shape any future
extension should take. It is not in this guard because it could not be proven tonight
without touching `w2kalpha` and `tru64`, which other streams own.

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
