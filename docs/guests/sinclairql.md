# sinclairql — Sinclair QL (1984), MAME `ql` in a Debian kiosk

Status: **LIVE production station** (built 2026-08-09). Kiosk: a captured
Debian 12 kiosk runs MAME's `ql` driver; streamhost captures the Linux
framebuffer + AC97 audio, exactly like c64/vic20/plus4/mpf2
(`streamhost/docs/BRIDGE.md`).

| | |
|---|---|
| public id / stationDir | `sinclairql` / `sinclairql` |
| slot / UDP | 133 / 54133 |
| VMID label / kiosk SSH | 236 / 127.0.0.1:5836 (bridge key) |
| builder | `scripts/build-guests/tiles/sinclairql.sh` (`--force` rebuilds the overlay) |
| disk | `overlay.qcow2`, a THIN overlay on the frozen `/data/vms/bridge/bridge-base.qcow2` |
| reset | `loadvm` of the INTERNAL `golden` checkpoint |
| pointer | none — keyboard-only exhibit (`--pointer none --input-backend disabled`) |
| RAM | 768 MB (measured MemAvailable with the emulator running: **374 536 kB**) |

## The machine

Motorola 68008 at 7.5 MHz, 128 KB RAM, QDOS + SuperBASIC in 48 KB of ROM, two
Microdrives, 512×256 monitor mode at 50.08 Hz. No pointing device.

## Media and licence

One preservation-source input, recorded in
[`docs/lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md) and gated by
`scripts/build-guests/check-assets.sh`:

- `ql-mame0224-merged.zip`, sha256
  `c4c39530c7abe6518f90b0df9d4eec9201434a905c77f05f490137007e420b03`, 499 412 B,
  from `archive.org/download/MAME_0.224_ROMs_merged/ql.zip`, staged at
  `/data/assets-staging/sinclairql/`.

**Amstrad's Sinclair permission does not cover the QL.** That grant is read as
covering the ZX Spectrum line and the machines Amstrad built; Amstrad acquired
the QL rights and sold them on, and no published emulator permission for the QL
ROM was found. Treated as preservation-source with unclear terms: private
exhibit only, bits never committed and never served.

### The romset is assembled by SHA1, and `-verifyroms` is not the gate

The builder rebuilds a four-member `ql.zip` **in the guest, keyed by SHA1** —
MAME renames and re-splits members between versions, so filenames prove
nothing:

| member | size | sha1 |
|---|---|---|
| `ql.js 0000.ic33` | 32768 | `59fd4372771a630967ee102760f4652904d7d5fa` |
| `ql.js 8000.ic34` | 16384 | `b8c9203026a7de6a44bd0942ec9343e8b222cb41` |
| `ipc8049.ic24` | 2048 | `fcb1c97ee7c66e5b6d8fbb57c06fd2f6509f2e1b` |
| `bql010-sqpp` | 16384 | `ba94bdad2303a263008b6ea744669a19938d9998` |

`assert_romset` then re-derives that list **from the shipped binary's own
`-listxml ql`** (default BIOS must still be `js` v1.10) and compares sha1s.
`-verifyroms ql` is deliberately not used: it reports "bad" purely because the
seven alternative BIOS entries (FB/PM/AH/TB/JM/Tyche/Minerva) are absent, which
is what a default-BIOS-only set is supposed to look like.

`hal16l8.ic38 NOT FOUND (NO GOOD DUMP KNOWN)` prints on **every** boot. That PLD
has never been dumped anywhere; `assert_expected_nodump_only` asserts that it is
the *only* thing MAME complains about.

## Which MAME, and why

The station ships the bridge guest's own Debian 12 package, pinned to
**`mame 0.251+dfsg.1-1`** and asserted with `dpkg-query` at build time.

- Not the host's 0.276: that binary is built against trixie's glibc/libstdc++
  and cannot run on the bookworm bridge.
- Not a chroot-built subtarget like mpf2's 0.289: mpf2 needed a source build for
  its warning-suppression patch, this station answers the same warning with one
  keystroke before the checkpoint is captured, and `ql` is a `status="good"` driver.

If the pin is ever moved, `assert_romset` will re-verify the set against the new
binary — that is the whole point of deriving it from `-listxml` rather than from
a table in the script.

## Device set and the captured canvas

QEMU device set is the bridge standard (`pc-i440fx-11.0,vmport=off`, IDE
overlay, `-vga std`, dbus display, AC97, e1000 with hostfwd 5836→22, no tablet),
with `-m 768`. The launcher is
`streamhost/stations/sinclairql/qemu-streamhost.sh`.

The kiosk X root is the bridge seed's stock **1024×768**, and that is the lucky
size for this machine: the QL's 512×256 monitor mode scales to it by exactly 2×
horizontally and 3× vertically, so every QL pixel is one identical 2×3 block and
the picture keeps the 4:3 shape the real monitor drew. `-prescale 2` was tried
and removed — it prescales to 1024×512 and then stretches 1.5× vertically, the
one factor that makes the 10-pixel-tall QL font uneven.

## Three traps this build paid for

1. **MAME ran at 41% of realtime and ate keystrokes.** With `-video soft` alone,
   MAME's own `-seconds_to_run 20` report under X (host load average ~62,
   2026-08-09) was:

   | flags | average speed |
   |---|---|
   | `-video soft` | 41.9 % |
   | `-video soft -sound none` | 45.3 % |
   | `-video soft -frameskip 2` | 43.3 % |
   | `-video accel` | 69.5 % |
   | `-video soft -autoframeskip` | **103.4 %** |
   | `-video accel -autoframeskip` | 101.9 % |

   At 42% an 80 ms keypress is ~33 ms of *emulated* time, under two QL frames,
   and single keys typed seconds apart were still lost (4 of 20). `-autoframeskip`
   drops drawn frames, never emulated ones, so the QL keyboard keeps being
   scanned 50 times a second whatever the host is doing. `-video accel` was
   rejected despite being faster: in the kiosk it ran for minutes with **no X
   window at all** and a black captured root.
2. **SDL silently chose a driver with no window.** Twice, MAME sat at 139% CPU
   with `xwininfo -root -children` reporting zero children and the root pure
   black. The launcher now pins `SDL_VIDEODRIVER=x11` (as vic20's does) and the
   builder asserts the window exists (`assert_emulator_window`).
3. **"Press any key" does not mean any key.** `ret`, `spc` and `esc` leave MAME's
   imperfect-dump warning up; a plain letter dismisses it. The builder sends `x`,
   and retries — a lone injected key is occasionally never sampled — then asserts
   the QL's chooser in the framebuffer.

Two smaller ones: the frame predicates must match colours with a tolerance
(`accel` renders the UI navy as 14,14,44 where `soft` gives 15,15,45), and
`assert && die` under `set -e` exits the script silently on the passing branch.

## Checkpoint scene

`savevm golden` inside `overlay.qcow2`, captured from an untouched cold boot after
exactly two keystrokes:

1. a letter, to clear MAME's imperfect-dump warning (emulation has not started
   at that point, so it cannot reach the QL);
2. `F1`, to answer the QL's own `F1...monitor / F2...TV` chooser.

The scene is the 80-column monitor-mode SuperBASIC screen: white window #2 on
the left, red window #1 on the right, an empty black command window along the
bottom. **Nothing is typed into it**, and that is asserted rather than assumed —
the QL prints command-window text in green, so a clean scene has fewer than
half a glyph's worth of green pixels (`command_window_clean`).

The capture runs under `-audiodev none` and is then re-proved under the production
`-audiodev dbus` launcher with `-loadvm golden`: the guest-visible AC97 is
identical, only the host backend differs, and `production-loadvm.png` is the
proof. The build backend exists because with `-audiodev dbus` and no streamhost
attached nothing drains the ring, the guest's ALSA escalates to
`ALSA write failed (unrecoverable): Input/output error`, and MAME **exits** —
taking X with it and leaving getty@tty1 to relaunch the kiosk every ~90 s.
`-audio_latency 5` in the launcher buys the deepest buffer MAME will ask for.
In production streamhost registers a dbus audio listener at startup, so the sink
always drains.

Evidence in `/data/vms/streamhost/stations/sinclairql/evidence/`:
`mame-warning.png`, `chooser.png` (the poster frame), `monitor-mode.png`,
`golden-restored.png`, `production-loadvm.png`, `keyboard-print-7.png`,
`golden-restored-after-keyboard.png`.

## Key pacing

The `ql` screen runs at 50.08 Hz (19.97 ms), so the playbook's two-frame floor is
40/40. Measured on a **clone** of this station's checkpoint (2026-08-09, production
station stopped so only the clone was running; a 40-character line typed with
explicit press/release pairs, counting the characters that actually landed):

| hold / gap | characters landed |
|---|---|
| 40 / 40 | 36 of 40 |
| 80 / 80 | 40 of 40 (×3 runs) |
| 120 / 120 | 40 of 40 (×3 runs) |

So the station ships:

    SH_KEY_MIN_HOLD_MS=120
    SH_KEY_MIN_GAP_MS=120

80/80 also measured clean, and 120/120 is a deliberate extra frame of margin:
the QL's keyboard is not read by the CPU at all but scanned by a separate 8049
IPC and relayed to the 68008 over a serial link, so a keypress has to survive
two sampling stages rather than one, and the losses this station showed while
labhost was busiest were the worst of any kiosk measured so far. The cost is
typing at ~4 characters a second instead of ~6.

Two traps in the measurement, recorded so nobody repeats them:

- `scripts/dev/emu-key-pacing-bisect.py`'s default line is the vic20's and is
  **useless on a QL**: its reference pass at 250/250 itself came back as
  `print chr147intrnd1`, i.e. every shifted character missing. Set `PACE_LINE`
  to an unshifted string. (The script now also takes `PACE_PAIRS`, and resolves
  its out-dir to an absolute path — `screendump` is relative to QEMU's cwd, not
  the harness's, so a relative one made it die reading its own frames back.)
- **Slower is not always better.** At 250/250 only 26 of 40 characters landed,
  repeatably, where 120/120 landed all 40. The cause was not chased; the ladder
  this station ships on is measured, and 250 ms holds are not on it.

On the **live** station the same 6-character line lands complete
(`evidence/live-typed-dirty.png`) — but only after the daemon's idle auto-pause
is lifted. With no viewer attached the VM is `paused` after 60 s, injected keys
go nowhere at all, and the frame does not change; that reads exactly like a dead
keyboard and is not one (`labctl` resumes automatically, raw QMP does not).

## Operating it

- `ssh lab 'labctl shot sinclairql'` — the framebuffer, the only proof.
- `ssh lab 'labctl exec sinclairql "<cmd>"'` — reaches the **Debian kiosk**, not
  the emulated QL. Drive the machine with `labctl type/key` and read it with
  `labctl shot`.
- `ssh lab 'labctl reset sinclairql'` / `POST /restore/sinclairql` — `loadvm golden`.
- UI keyboard: `sinclairql` profile in `spa/src/ui/keyboard/keyboardProfiles.ts`
  (MODE 8 / MODE 4 / CLS, F1–F5, BREAK = Ctrl+Space). The QL's idle screen says
  nothing at all, so those buttons are the exhibit's only invitation.

## Rollback

`overlay.qcow2` holds the checkpoint; never delete or recreate it except through
`sinclairql.sh --force`, which rebuilds the whole station from the frozen seed in
about ten minutes. The shared seed is never written.
