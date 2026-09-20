# Record wave retro — 2026-09-20

Tracked by #62 (collection epic) and #63 (record-wave coordinator ticket).
Eight stations landed this wave: msx2, cpm22, riscos3, vax43bsd, mvs38,
multics, its, linux012 — four of them (vax43bsd, mvs38, multics, its) a
cluster of pre-1990 timesharing exhibits sharing one runtime contract. This
is a living document — it records what a future wave needs to
know, not a chronology of the day. Rewrite it in place rather than appending
a new section when a fact here goes stale.

## Load and concurrency

Ten concurrent bring-ups drove a 16-core box to a 1-minute load of 226
against the documented cap of 50 (`OPERATING-RULES.md` "The load rule").
Cause: eleven simultaneous MAME builds — every MAME-native station compiles
its own MAME — plus several pre-push gates running at once.
`scripts/lib/load-guard.sh` only guards **starting guests**
(`smoke-rig.sh`, `rig-clone.sh` source it before bringing a guest up);
nothing sources it before a build or a gate, so the cap never fired even
though the box was well past it.

Non-destructive mitigation used this wave: renice the build/gate process
groups to 19, so live QEMU/MAME guests already serving visitors keep the
CPU they need and a background build just takes longer. Resolve the pids to
renice with a **self-excluding** pattern —
`pgrep -f "build-mame-[n]ative\.sh"` (the bracket trick keeps the `pgrep`
invocation itself out of its own match) — never a plain `pgrep -f
build-mame-native.sh`, which also matches the ssh command line running the
sweep and renices or kills the wrong thing. The load rule itself does not
yet cover builds and gates; that gap is still open for the next wave to
close, not solved by this one.

## Workers must checkpoint, not wait

Subagents get no reliable background-task notification — a worker parked on
a monitor waiting for a 30-minute MAME build burned 240k-330k tokens each
and produced nothing until it was converted to a resumable handoff. The
pattern that worked: write `docs/lab/<ID>-WAVE.md` with the allocation row,
every media hash, the exact build paths and an exact resume command, then
stop and let a fresh session (or the same one after a compaction) pick it
up from that file rather than staying attached to the build.

## A station can land black

Two stations landed black — listed, visible to visitors, reacting to
nothing. The cheap proxies all lied:

- **Byte size, `file` output, "unit is active"** all looked fine on both.
  `colors=2` was cited as evidence of a black screen on one of them, but a
  working green-on-black CP/M terminal scores `colors=2` too — it is not a
  black-screen signature.
- **riscos3 passed four separate input proofs** — every ctlsock ack `OK`,
  every pixel diff large, menus genuinely opening — while
  `MAME_CTL_BTN_ACTIVE_LOW` double-inverted the Archimedes' Select button
  (MAME already XORs the active-low bits in; setting the flag inverts the
  module's own press/release), so every click ended held down. Only the
  live frame — a rubber-band selection being dragged by nobody — caught it.

**The only reliable check is to render the PNG and look at it.** Two root
causes are worth naming so the next MAME-native station checks for them
before landing, not after:

- A MAME driver that flags *imperfect sound* (or another imperfect/
  unemulated feature) pops a modal "known problems" panel before the
  machine reaches `machine_phase::RUNNING`. `MAME_NO_UI=1` draws the panel
  as nothing, but the input wait behind it still blocks forever — ctlsock's
  `setup()` never fires and the framebuffer stays black. Check `-listxml`
  for `imperfect_features`/`unemulated_features` before landing an
  audio-off or otherwise imperfect MAME-native station, and carry
  `mame-irix-skip-warnings.patch` + `NATIVE_SKIP_WARNINGS=1` whenever it
  does (domainos, newsos and now cpm22 all needed it for the identical
  reason).
- A terminal station whose one-shot getty banner has already scrolled past
  by the time a visitor connects — the DZ/FNP line printed its greeting
  once, at boot, into a line nobody was watching yet.

## Three infrastructure bugs fixed mid-wave

Each was silently corrupting the wave's own work before it was found and
fixed:

- **`scripts/test_stations_registry_new_like.py`** ran `git checkout --
  <generated files>` against the real repo root in `tearDown`, with no
  isolated tmpdir copy — so any uncommitted regenerated content (scene
  shards, `registry/generated/*`) was silently reverted to the last commit,
  and `git status` read clean afterward. The multics landing hit this
  directly: scene rows it had written and verified were gone by the next
  gate run, reported as "no row for lineup entry ['multics']", with nothing
  between the two points but the repo's own test suite. Fixed by
  snapshotting exact bytes instead of relying on git state (`ddf4e6bc`).
  **Defence for the next wave**: commit generated and scene rows
  immediately after generating them, and re-run
  `make station-registry-check` after any full test run rather than
  trusting an earlier green.
- **Station launchers resolved emulator pids with a per-pid
  `readlink /proc/<pid>/exe` loop**, measured at 13.4 s per scan at ~1300
  pids on a loaded box; the unit's `start-pre` calls it on every start, so
  stations could not restart under load. Fixed across 39 launchers (one
  `find` instead of a per-pid loop) and re-emitted on 31 live stations, all
  verified by frame (`b5bb6310`, `e57bed67`). **Taking effect needs a
  re-emit, not a restart** — the live launcher is a copy installed at emit
  time, so a rebuild alone does not reach a running station. Five launchers
  still carry a lower-severity variant of the same pattern: issue #64.
- **`wave.d/queue.sh`** kept the landing window's authority in a `mkdir`
  plus a `kh-claim` mirror and silently swallowed a failure to write the
  mirror — so `land end` could report RELEASED while `kh-claim` still
  showed the window held, blocking every other wave behind it. Fixed
  (`647f96dc`).

## Rule 5 bit three of ten workers

Citing rule 5 by number ("never `pkill -f`") did not prevent any of the
three hits this wave took — brief the two concrete traps instead of the
rule number:

- One `pkill -x Xvfb` run from `ssh lab` killed the Xvfb of **five** live
  stations at once (medley, lisa, vision, perq, amix) — `-x` matches by
  exact process name across the whole box, not just the one station a
  worker meant to touch.
- Two other workers killed their own ssh session by matching a process by
  its **cmdline** (a `grep`/`pgrep -f` over `/proc/<pid>/cmdline`) — the ssh
  command line itself contains the string being searched for, so the loop
  found and killed its own shell. The multics resume session hit this
  killing its own labrun shell (exit 144) searching for the bake script's
  name. The only safe resolution is `/proc/<pid>/exe`
  (`readlink`/`-lname` against the known binary path), never a cmdline
  match — and the self-excluding `pgrep -f "name-[n]ame"` bracket trick
  above is the same family of fix for a case where `/proc/<pid>/exe`
  is not available (a bash process group, not a single known binary).

## A correction to record

An earlier version of the linux012 record was reported to claim labhost's
clock runs about three hours ahead of CT950. **That claim was not found in
`docs/lab/LINUX012-WAVE.md`, `docs/guests/linux012.md`, or anywhere else in
the repo** at the time this retro was written — a repo-wide search for the
theme (clock/ahead/UTC/local-time confusion) turned up nothing matching.
Either it was caught and reverted before landing, or it never reached a
commit; either way there is nothing left in the tree to fix. If it
resurfaces, the correct fact (both CT950 and labhost read identical UTC;
the earlier mistake was comparing `uptime`'s local-time display against a
UTC shell) is worth landing wherever it does.

## What worked

- **Resuming from a pushed `<ID>-WAVE.md` handoff** let a blocked lane
  restart cheaply instead of re-deriving what a stalled session already
  knew.
- **vax43bsd proved the shared terminal runtime first** — the plumbing to
  run an old-world simulator behind a browser terminal, contained rather
  than bridged: pinning X focus with no window manager present, and gating
  readiness on a console log line instead of a port. mvs38, multics and its
  all reused it directly rather than re-deriving each trap; multics went on
  to contribute three more findings back to the same shared contract
  (`docs/lab/record-wave/shared-terminal-runtime.sh`).
- **`wave.sh`'s landing lock plus `station-land.sh`** removed the human
  "ready to land" / "go" / "landed" relay entirely — the FIFO queue on the
  box is what serialises `main`, not a person watching two sessions at
  once.
