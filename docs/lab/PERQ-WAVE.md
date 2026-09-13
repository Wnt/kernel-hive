# PERQ wave — Three Rivers PERQ 1A, POS G.7 (2026-09-13)

Station `perq`: PERQemu 0.9.5 on Mono, in a systemd-nspawn sandbox, showing
**POS G.7** — the native operating system of the first commercial graphical
workstation. Listed **hidden**: the boot, the login and the keyboard are proven
on the framebuffer; the pointer is not.

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

**Pointer**: OPEN. The Kriz tablet is absolute and PERQemu maps the host pointer
onto it, so `x11-xtest` 1:1 is the right method and it is wired — but POS's login
shell is a character console with no cursor to aim at, so there is no two-target
readback. Next command: bring a graphical POS tool up, then
`python3 scripts/dev/cursor-locate.py` on two commanded targets.

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

- **Pointer** — the two-target readback (above). This is what `hidden` is waiting on.
- **`accent`** — the same machine booting `s6lisp.prqm` with `bootchar z`, a
  second registry entry at uid base 2424832. Not started; the assets are already
  staged and `perq-inner.sh` takes `PERQ_BOOTCHAR` for exactly this.
- **`/os/perq` smoke publish** — `scripts/dev/smoke-rig.sh perq --like lisa`.
- **Capture crop** — the 24 dead lines at the bottom of the root.

## Teardown

The first lead's container (nspawn 2528279, mono 2528371, Xvfb 2528377) was
killed by exe and its stale `/run/systemd/nspawn/unix-export/kh-perq` cleared.
The rig documented here is `/data/vms/sandbox/perq/smoke`; kill it with the
launcher's own reaper or by `/proc/<pid>/exe` = `/data/vms/sandbox/perq/rootfs/usr/bin/mono-sgen`.
