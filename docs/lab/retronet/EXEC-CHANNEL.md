# win98se exec channel — `labctl exec` into Windows 98 SE

**Status: LIVE.** `ssh lab 'labctl exec win98se "<cmd>"'` runs a command inside the
live Windows 98 SE station and returns its stdout and exit code. The agent is
baked into the station's checkpoint, so every wake has exec available with no
warm-up. Retronet PoC [stream A](POC-PLAN.md); wave 2 installs ICQ over this.

```
$ ssh lab 'labctl exec win98se "ver"'
Windows 98 [Version 4.10.2222]
$ ssh lab 'labctl exec win98se "sol"'      # launches Solitaire, visible on the exhibit
```

## The design in one paragraph

win98se already had everything needed except a listener: a working SLIRP netdev
(`n0`, guest `10.0.2.15`) with the MSTCP stack bound to its PCnet adapter. So the
channel is **the win95 warpd agent, rebuilt on a second port**. `warpnet.c` grew
an `E` verb framed byte-for-byte like `solaris/warpd.py`, which means the host
side is entirely off-the-shelf: `exec_kind: "warpd_e"` in the registry and the
existing `/root/gexec.py` client that `labctl exec` already dispatches to. No new
exec kind, no new host client, no new protocol. win98se points with a usb-tablet
and needs no pointer agent, so this binary exists **only** for `E`; it is built
`-DWARP_PORT=7788` so it can never collide with win95's live pointer listener on
`:7777`. Transport is a `hostfwd` appended to the station's EXISTING
`-netdev user,id=n0` — a netdev *backend* property, not a `-device`, so the
emulated device set is unchanged and `loadvm golden` stays valid.

| thing | value |
|---|---|
| guest agent | `C:\WARPNET.EXE` (19,968 bytes, `warpnet.c` built `-DWARP_PORT=7788`) |
| guest listener | TCP `:7788` on `10.0.2.15` |
| host endpoint | `127.0.0.1:57792` (hostfwd on `n0`, in `qemu-streamhost.sh`) |
| `exec_kind` / `exec_port` | `warpd_e` / `57792` (`registry/stations/win98se.json`) |
| host client | `/root/gexec.py` (from `streamhost/guest-agents/solaris/gexec.py`) |
| autostart | `C:\WINDOWS\Start Menu\Programs\StartUp\WARPNET.EXE` |
| agent log / scratch | `C:\WARPNET.LOG`, `C:\WNEXEC.OUT` |

Wire protocol (`E` only; `M/P/R/B` are the pointer verbs win98se never uses):

```
E <cmd>   ->  O <base64 of stdout, first 16 KB>\n X <exit code>\n .\n
V         ->  (no reply) force a display-mode reset — see "the DOS-box wedge"
```

## The golden backup — how to undo all of this

The checkpoint was recaptured on **2026-08-20 20:03:55** with the agent running
inside it. The previous checkpoint (`golden`, 86.3 MiB, 2026-07-27 01:31:36)
lives in a byte-copy of both station disks, taken with QEMU stopped and no
process holding either image:

```
/data/gallery-guests/Win98SE/golden-backup-retronet-20260820/
    win98se-kvm.qcow2     b3fcd63a1b75934e0ed8ddbb9d51a12e4559a18c7359bcd931dc8121379677f9
    win98se-games.qcow2   9bfc838ee3b055665c68cddf8f7e7af97af03dec88878b189d59993f523db138
    SHA256SUMS
```

To roll the station all the way back: `systemctl stop streamhost@win98se`, copy
both files back over `/data/gallery-guests/Win98SE/`, revert the launcher's
hostfwd and the registry's `exec_kind`/`exec_port`, `labctl gen`, start the unit.
Nothing else was touched — no other station, no host service.

## How a command actually runs

1. `labctl exec win98se "<cmd>"` reads `exec_kind: warpd_e` + `exec_port: 57792`
   from the labctl matrix and runs `python3 /root/gexec.py 57792 "<cmd>"`
   (`scripts/labctl.d/guest.py`, the `warpd_e` arm).
2. `gexec.py` connects to `127.0.0.1:57792`, which SLIRP forwards to the guest's
   `:7788`, and sends `E <cmd>\n`.
3. The agent runs `%COMSPEC% /c <cmd> >C:\WNEXEC.OUT` with `CreateProcess`,
   waits up to 120 s, forces a display-mode reset, reads the file back and
   replies `O <base64>\n X <rc>\n .\n`.
4. `gexec.py` prints the guest's stdout and exits with the guest's exit code.

Two Win9x limits, both structural:

- **stdout only.** `COMMAND.COM` has no `2>&1` — that is an NT `cmd.exe` feature.
  DOS tools write most errors to stdout anyway.
- **no `>` of your own.** The agent appends its own redirect, and `COMMAND.COM`
  gives the last redirection on the line to stdout, so a second `>` silently
  swallows your output. Write to a file with a `.BAT` you deliver, or read
  `C:\WNEXEC.OUT` back with a second command.

Launching a Windows GUI program works and returns immediately — Win9x's command
interpreter hands a Win32 executable to the shell and does not wait. That is how
the acceptance shot was taken (`labctl exec win98se "sol"`).

## The DOS-box wedge — the one hazard, and why the agent resets the display

**Measured on the live station, 2026-08-20.** Any *transient* DOS box on this
guest — `COMMAND.COM /c …` — leaves the guest's VBE-miniport display driver with
a misprogrammed CRTC. QEMU then reports a garbled **1600x176** framebuffer
instead of the 1600x1200 desktop, and it never recovers on its own. The exhibit
is dead until something re-programs the video mode.

What it is **not** (each ruled out by experiment on the live station):

| tried | result |
|---|---|
| `SW_HIDE` on the child | wedges |
| `SW_SHOWMINNOACTIVE` on the child | wedges |
| launched by `CreateProcess` from the agent | wedges |
| launched from Start > Run | wedges |
| launched through `C:\WINDOWS\command.PIF` | wedges |
| a **persistent** box (`command`, no arguments) | **does not wedge** |

So it is the transient VDM's video grab, not the window style and not the
launcher. Only a real mode program fixes it, so the agent calls
`ChangeDisplaySettingsA(NULL, CDS_RESET)` the moment the child is reaped.
`CDS_RESET` is the load-bearing part: without it Windows compares the requested
mode against what it *believes* is current, finds no difference, and does
nothing — while the hardware is actually wrong. With it, five consecutive
`labctl exec` calls left the framebuffer at 1600x1200 and **byte-identical** to
the checkpoint fixture.

If a framebuffer ever wedges anyway (some other full-screen DOS program):

```
printf 'V\n' | nc 127.0.0.1 57792         # over the wire, no GUI needed
```

or, from the framebuffer: Start > Run > `command` (a persistent box is safe),
**Alt+Enter twice** — full screen, then back to a window, which makes Windows
reprogram the VGA — then `exit`. `loadvm golden` also fixes it but discards
everything done since the checkpoint.

## Rebuilding the agent

```
make -C streamhost/guest-agents win9x-exec     # -> win9x/warpnet7788.exe
```

Both win9x recipes share `W9FLAGS` so they cannot drift:
`-O2 -s -mwindows -march=pentium -mtune=pentium -Wl,--no-insert-timestamp`.
`-march=pentium` is required, not cosmetic — mingw's default i686 target emits
`CMOV`, which win95's `-cpu pentium` does not implement (`docs/guests/win9x.md`).
`-mwindows` keeps the agent out of the taskbar; the timestamp suppression makes
repeated builds byte-identical.

## Installing it into the guest (live, no cold boot)

The station's checkpoint is an internal qcow2 snapshot, so `loadvm golden`
reverts **the disk as well as RAM**: a file written offline into the image with
`qemu-nbd` is simply discarded at the next reset, and the first post-injection
boot would have to be a cold one (~70 min re-bake, `golden-bake.sh`) to be
captured at all. So the agent is delivered **live**, into the running guest,
through the guest's own network — which preserves the curated Notepad fixture
exactly. Win98 has no `smbd`, no CLI HTTP client and no `tftp`, but it has IE5
and SLIRP puts the host at `10.0.2.2`:

1. Serve the binary from labhost, loopback only:
   `cd <dir with WARPNET.EXE> && python3 -m http.server 58799 --bind 127.0.0.1`
2. In the guest (QMP `sendkey`, `sk.py`): Start > Run >
   `iexplore http://10.0.2.2:58799/WARPNET.EXE`
3. **File Download** dialog → `Alt+S` (Save).
4. **Save As** → type the full destination and Enter. Saving *straight into the
   StartUp folder* is what makes it autostart, in one step and with no registry
   edit and no DOS box:
   `C:\WINDOWS\Start Menu\Programs\StartUp\WARPNET.EXE`
5. **Download complete** → `Alt+O` (Open). That runs the agent for this session;
   the dialog closes itself and the desktop returns to the fixture untouched.
6. Prove it: `labctl exec win98se "ver"`.
7. Recapture with the agent running: QMP `delvm golden` then `savevm golden`.
   Compare the framebuffer against the pre-change checkpoint first — a
   caret-sized delta (2x15 px at the Notepad caret) is the only allowed
   difference.

`loadvm golden` is the undo button for every step before 7: it reverts RAM *and*
disk, so a failed attempt costs one reset and a re-run, not a re-bake. The whole
sequence above is a couple of minutes and was scripted end-to-end during
bring-up.

**Cold boot** (after a host reboot or a rebuild) does not use the checkpoint, and
that is what the StartUp-folder copy is for: Explorer runs the `.exe` there at
logon and the channel comes back by itself. The checkpoint path is the one that
matters day to day — the agent is already running inside it, so a visitor wake
has exec immediately.

## What is deployed where

| repo path | live path | how |
|---|---|---|
| `streamhost/guest-agents/win9x/warpnet.c` | (source only) | `make win9x-exec` |
| `streamhost/stations/win98se/qemu-streamhost.sh` | `/data/vms/streamhost/stations/win98se/qemu-streamhost.sh` | `box-deploy.sh --apply` |
| `registry/stations/win98se.json` | labctl matrix | `box-deploy.sh --apply` then `labctl gen` |

A launcher change needs no restart to be *correct* — the hostfwd is already live
on the running QEMU — but the next `systemctl restart streamhost@win98se` must
find it in the installed launcher, or the channel comes back up without its
forward. That is why the hostfwd is in the launcher and not added by hand.

## Scope

Wave 1 only: the exec channel. The guest→server `guestfwd` for ICQ
(`10.0.2.100:5190`) and the ICQ install are wave 2 (`POC-PLAN.md`), and both ride
this channel plus the same `n0` netdev — again options-only, so still
`loadvm`-safe.
