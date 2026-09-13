# PERQ wave — Three Rivers PERQ 1A, POS G.7 (2026-09-13)

Station `perq`: PERQemu 0.9.5 on Mono, in a systemd-nspawn sandbox, showing
**POS G.7** — the native operating system of the first commercial graphical
workstation. Boot, login, keyboard and pointer are all proven on the
framebuffer — the `listing.state: hidden` block is removed as of the
`perq-ptr` stream's two-target pointer readback below.

## Ledger

| | |
|---|---|
| slot | 198 |
| UDP | 54198 |
| VMID | 198 |
| X display | `:98`, root 768x1048x24 (Xvfb **inside** the container) |
| container uid base | 2359296 |
| retronet | none — POS G.7 has no TCP/IP stack, and the container is `--private-network` |
| emulator | PERQemu 0.9.5, upstream release zip (github.com/skeezicsb/PERQemu), GPLv3 |
| media | `/data/assets-staging/perq/` on labhost; `perqemu0.95.zip` 44 605 339 B |
| machine | PERQ-1A, 2 MB, CIO + OIO (Link/Ether/Tape), Portrait display, Kriz tablet, 14-inch Shugart |
| disks | `g7.prqm` = POS G.7 · `s6lisp.prqm` = Accent S6 + Spice Lisp (the `accent` station, not built) |

## Proven on the framebuffer

Frames under `/data/vms/sandbox/perq/frames/` (rig, display `:98`):

| frame | what it proves |
|---|---|
| `01-pos-boot.png` | POS G.7 boots: `LogIn version 3.10 / POS G.7 / a-boot`, the disk mounted, the partition table (boot/accent/paging/user), `Enter time as HH:MM or full date:` |
| `02-after-return.png` | XTEST Return reaches the guest — the date prompt is accepted, `Please enter your name:` appears |
| `04-shell.png` | `guest` typed at 80 ms/char, 4/4 characters, no drops |
| `06-guest.png` | empty password accepted: `Initializing for user: Guest / Reading profile file >Default.Profile` |
| `07-shell.png` | the POS shell: status line `sys:User>Guest>  POS G.7  a-boot  28 Dec 22 21:22:28` with the clock running, and the `>` prompt. This frame is the hero (`spa/public/posters/perq/desktop.webp`). |

**Login**: press Return at the date prompt, then user `guest`, empty password.
`user` is NOT an account (`** Invalid user or password.`).

**Keyboard**: PASS. XTEST via `xdotool type --delay 80` on `:98`, drop-free.
Not measured below 80 ms.

**Pointer**: PASS (`perq-ptr` stream, 2026-09-13) — see §Pointer below.

## §Pointer

The premise in the earlier draft of this doc — "POS's login shell is a
character console with no cursor to aim at" — was wrong, and cost nothing to
disprove: POS draws its own arrow-shaped mouse pointer sprite directly on the
character console, with no graphical program needed. It is visible in the
existing hero frame `spa/public/posters/perq/desktop.webp` (the arrow at
roughly (390, 530)) and in every frame from `Reading profile file
>Default.Profile` onward — the golden scene already shows the cursor.

Rig: `/data/vms/sandbox/perq-ptr/rig/` (own `base/`, `x11/` socket dir, display
`:199`), same read-only `rootfs`/release tree as the lead's rig
(`/data/vms/sandbox/perq/rootfs`, `/data/vms/sandbox/perq/media/perqemu0.95`),
uid base 2359296. Booted POS G.7 fresh (`g7.prqm`), logged in as `guest` with
an empty password exactly as documented above.

**Method**: `xdotool mousemove X Y` on `DISPLAY=:199` (XTEST absolute motion
against the X root, the same call the daemon's `x11test` backend makes) reaches
PERQemu — no XI2/raw-motion workaround was needed, unlike the wall this brief
warned about. The one trap: **PERQemu's SDL window is clocked by the CLI's
`GetLine()` poll loop (see §Walls #3), so a screendump taken immediately after
the warp can show the pointer BEFORE PERQemu has polled the new position** —
measured directly: a `mousemove 600 800` frame grabbed with 0 delay was
byte-identical to the prior frame at (200,300) even though `xdotool
getmouselocation` already reported the X server's root pointer at 600,800. A
**2 s settle** after each warp was enough in every trial; the daemon's own
input path already settles on its render cadence so this is a rig-only
caveat, not a production risk.

**Two-target readback**, root 768x1048, frames under
`/data/vms/sandbox/perq-ptr/rig/frames/`:

| target (root px) | frame | cursor sprite bbox (top-left) | offset from target |
|---|---|---|---|
| (200, 300) | `08-target-200-300.png` | (200, 299) – (215, 314) | (0, -1) |
| (600, 800) | `09-target-600-800.png` | (600, 799) – (615, 814) | (0, -1) |

Measured with a 60×60 crop around each commanded point, diffed against the
prior frame (`np.any(a != b, axis=2)`, bounding box of the changed pixels) —
`scripts/dev/cursor-locate.py`'s automatic two-frame `learn` was tried first
and rejected the pair as **AMBIGUOUS**: the status-line clock (`HH:MM:SS`,
ticking every second) and a 1-pixel window-border column both changed between
frames and either bridged into the cursor's bounding box or matched as their
own spurious templates. Cropping the top 30 rows and left 12 columns before
`learn`/`find` still produced one AMBIGUOUS background-colour template; the
manual crop-and-diff above is what actually isolated the sprite. A future
pass could feed `cursor-locate.py --at X,Y` (which skips its own bbox search)
instead — untried here, time-boxed out.

**Mapping: 1:1 identity, no offset, no scale.** The sprite's top-left lands
within 1 px (y) of the commanded root coordinate at both ends of the screen —
this is despite the PERQ window sitting at `768x1024+0+12` inside the
768x1048 root (§Walls #4): X delivers window-relative motion from a
root-absolute XTEST warp automatically, so no offset compensation is needed
at the fixture level. `stream.pointer.offset` stays `[0, 0]`,
`stream.pointer.scale` stays `1.0`.

**Fixture**: `streamhost/stations/perq/station.env.fixture` already carried
`SH_X11TEST_ABS=1`, `SH_X11TEST_BUTTONS=xtest`, `SH_X11TEST_KEYS=1` (copied
from the `lisa` shape at scaffold time) — no change needed there. Buttons are
untested: POS's shell prompt has nothing to click that shows on the
framebuffer, and no button-holding-a-widget scene exists yet (see Open).

**Boot time**: login prompt ~20 s after power-on, shell ~45 s. PERQemu 0.9.5 has
**no save state** (checked: `Settings` offers autosave of media only, there is no
`loadvm`/checkpoint equivalent), so reset = relaunch from a pristine copy of
`g7.prqm` and the golden IS the disk plus the boot script. ~45 s is above the
60 s bar only in aggregate with container start; it is acceptable, but it is the
reason `resetMode` is `relaunch` and not a snapshot restore.

## Walls (all three cost the first lead its whole session)

1. **SDL2-CS is not the wall it looked like.** NuGet's SDL2-CS 2.0.0 is too old
   for PERQemu, and a source build was the assumed fix. It is not needed: the
   **upstream 0.9.5 release zip already ships `SDL2-CS.dll` with a `.config` that
   maps to the system `libSDL2`**. The tile builder fetches the release, installs
   `libsdl2-2.0-0` and `mono-runtime-sgen` in the rootfs, and that is all.

2. **`MemoryController`'s type initializer throws on a read-only tree.** PERQemu
   opens its ROMs with `new FileStream(path, FileMode.Open)` — whose default
   access is **ReadWrite** — and it computes its `BaseDir` from
   `Assembly.GetExecutingAssembly().CodeBase`, which Mono canonicalises **through
   a symlink**. Symlinking `PERQemu.exe` into the `--bind-ro` release tree
   therefore moved the whole working directory onto the read-only mount, and
   power-on died with:
   ```
   The system could not be initialized:
   The type initializer for 'PERQemu.Memory.MemoryController' threw an exception.
   ```
   Fix: `perq-inner.sh` **copies** the release tree (~1.5 MB without the docs)
   into the writable `/work/perq`. Copying `PROM/` alone is not enough — measured.

3. **PERQemu needs a TTY, and the first lead's header says the opposite.**
   `CommandProcessor.Run()` calls `_editor.GetLine()`, and **GetLine is the
   emulator's clock**: it runs the `HighResolutionTimer` loop between keystrokes,
   so every CPU and SDL tick comes from inside it. With stdin/stdout not a TTY,
   Mono installs the `NullConsoleDriver`, `Console.BufferWidth` is 0,
   `CommandPrompt` divides by it, and `Run()`'s catch-all prints `Attempted to
   divide by zero` and loops forever. The machine never ticks and the log grows
   ~25 MB/min (the first rig's was **1.2 GB** after 48 minutes of a black screen).
   Fix: `exec script -qfec "stty rows 50 cols 132; exec mono ..." /dev/null <&3`,
   with `TERM=xterm` and stdin from a FIFO held open read-write so the pty never
   sees EOF and no keystroke is ever delivered. `script` shows up in the
   container's process list — that is expected, see the audit.

4. **Geometry**: the PERQ portrait screen is 768x1024, but PERQemu sizes its
   window to SDL's usable display bounds minus 24 lines, so a root exactly 1024
   tall yields a 768x1000 window that **pans**. The root is 768x1048; the PERQ is
   the top 1024 lines and the bottom 24 stay black. A capture crop knob is open.

## Cost: PERQemu idles at 200% of a core

Measured 2026-09-13 on the rig: with POS sitting at its shell prompt and nothing
happening, `mono` holds **~202% CPU** — two busy threads, the CPU/microcode loop
and the CLI's `HighResolutionTimer` spin (`rate limit None` in the settings, and
`GetLine` polls rather than blocks). It does not settle. Two instances at once
put labhost's 1-minute load over 50, which is what the load rule exists for.

The fleet answer is the daemon's freezer, and the launcher already arms it:
`SH_IDLE_PAUSE_PIDFILE` + `SH_IDLE_PAUSE_SECS`, plus a `PERQ_STANDBY_DELAY_S`
(default 120 s) SIGSTOP on the pid in `mame.pid` once the boot has settled —
the same shape medley uses. **Never run this station unfrozen and unattended**,
and never run two. Whether `rate limit CPUSpeed` in `.PERQemu_cfg` would also
cap it while a visitor is connected is untested, and worth a measurement.

## §Sandbox

Verdict: **host application → systemd-nspawn**, on the lisa/medley shape. The
launcher line is in `streamhost/stations/perq/x11-runtime.sh`: `--private-users=2359296:65536
--private-users-ownership=off --private-network --read-only --tmpfs=/var/tmp
--drop-capability=…13 caps… --no-new-privileges=yes --system-call-filter='~@mount'
--as-pid2 --keep-unit --register=no`, with the release tree `--bind-ro` at
`/opt/perqemu`, one writable bind (`work/`), and the X socket dir bound out to
`/tmp/.X11-unix` with a host symlink to the socket FILE.

Audit from the running rig (payload = PERQemu's host pid 3387240):

```
--- ns ---
pid  host=pid:[4026531836]  payload=pid:[4026537062]
mnt  host=mnt:[4026531832]  payload=mnt:[4026537059]
net  host=net:[4026531833]  payload=net:[4026537063]
user host=user:[4026531837] payload=user:[4026537058]
ipc  host=ipc:[4026531839]  payload=ipc:[4026537061]
uts  host=uts:[4026531838]  payload=uts:[4026537060]
--- status ---
Uid:	2359296	2359296	2359296	2359296
CapEff:	0000000015808dff
NoNewPrivs:	1
--- ps ---
    PID TTY          TIME CMD
      1 ?        00:00:00 (sd-stubinit)
      2 ?        00:00:00 script
      5 ?        00:00:04 Xvfb
     32 pts/0    00:08:03 mono
--- ip link ---
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 …
--- ls /dev ---
char core fd full fuse mqueue net null ptmx pts random shm stderr stdin stdout tty urandom zero
--- mount attempt ---
mount: /mnt: permission denied.
rc=32
```

All six namespaces differ, the payload runs as the mapped uid 2359296 with
`NoNewPrivs=1`, the container holds only the init stub, `script`, Xvfb and mono,
the only interface is `lo`, `/dev` has no disks, and mount is refused even as
root inside. **PASS.**

## Open

- **Pointer buttons** — untested (see §Pointer). Only motion has a two-target
  proof; no click target exists on the framebuffer yet.
- **`accent`** — the same machine booting `s6lisp.prqm` with `bootchar z`, a
  second registry entry at uid base 2424832. Not started; the assets are already
  staged and `perq-inner.sh` takes `PERQ_BOOTCHAR` for exactly this.
- **`/os/perq` smoke publish** — `scripts/dev/smoke-rig.sh perq --like lisa`.
- **Capture crop** — the 24 dead lines at the bottom of the root.
- **`scripts/build-guests/tiles/perq.sh` IS STILL THE SCAFFOLD** — it `die`s
  rather than lying, but nothing yet reproduces what runs. It must do, in order:
  fetch the 0.9.5 release zip by URL and sha256 into `assets/perq/perqemu`;
  `debootstrap --variant=minbase trixie` a rootfs with `mono-runtime-sgen`,
  `libsdl2-2.0-0`, `xvfb`, `xdotool`, `bsdutils` (for `script`) and the audit
  tools; `chown -R` it ONCE to 2359296; and stage `g7.prqm`/`s6lisp.prqm`. The
  tree that runs today was built by hand — `/data/vms/sandbox/perq/rootfs`,
  log `rootfs.staging.log`, release in `/data/vms/sandbox/perq/assets/perqemu`.
  There is NO SDL2-CS source build and no `xbuild` step: wall 1 explains why.

## Teardown

The first lead's container (nspawn 2528279, mono 2528371, Xvfb 2528377) was
killed by exe and its stale `/run/systemd/nspawn/unix-export/kh-perq` cleared.
The rig documented here is `/data/vms/sandbox/perq/smoke`; kill it with the
launcher's own reaper or by `/proc/<pid>/exe` = `/data/vms/sandbox/perq/rootfs/usr/bin/mono-sgen`.

The `perq-ptr` pointer-proof rig (`/data/vms/sandbox/perq-ptr/rig/`, display
`:199`, its own container `kh-perq-ptr`) was torn down after the two-target
readback: `mono` (pid 3969991), `Xvfb` (3969884), `script` (3969877), the
`sd-stubinit` PID 2 (3969831) and `systemd-nspawn` (3969817) all killed by
signal (TERM first, KILL where TERM did not land — matches §Sandbox's report
that this build sometimes ignores TERM), confirmed by `/proc/<pid>` gone for
all five and `machinectl list` reporting `No machines.`. The host symlink
`/tmp/.X11-unix/X199` and the rig's `work/` were removed. A second, unrelated
rig (`kh-perq-prove`, nspawn pid 34421, under `/data/vms/sandbox/perq-build/`,
display `:198`) was running concurrently during this stream — **not touched**,
per the rule against killing another session's rig; it belongs to whichever
stream is proving the `perq.sh` tile builder (§Open).
