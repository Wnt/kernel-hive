# amix boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**, 2026-09-01. No clip has been recorded, there is no
`amix)` arm in `bootrec-tiles.conf` yet, and `spa.bootVideo` is not set in
`registry/stations/amix.json`. This file exists so the cold-boot path is audited
before the tile ships, which is what the playbook requires
([`../../docs/lab/ADD-NEW-OS-PLAYBOOK.md`](../../docs/lab/ADD-NEW-OS-PLAYBOOK.md)
§6.5). Everything below was observed on the bring-up rig at
`/data/vms/sandbox/amix/rig/`; the station itself is a dark launch
(`listing.state: hidden`) and has not been deployed.

**This is the one arm in this directory where a cold boot is not a special
recording mode — it is the station's normal reset.** `amix` is host-native
FS-UAE 3.2.35 with `SH_RESET_MODE=relaunch` and **no statefile anywhere**: every
reset copies `disk/amix-system.hdf.golden` to a fresh work HDF and powers an
Amiga 3000 on from Kickstart. So the sequence a capture records is exactly the
sequence a visitor pays for, and the same rules govern both.

## Zero input is genuine

Nothing waits for a key or a click between power-on and the fixture:

- Kickstart 2.04 r37.175 boots the RDB disk straight through — there is no boot
  menu unless both mouse buttons are held, and nothing holds them;
- AMIX comes up multi-user at run level 2 with **no login**. `/etc/inittab`
  carries the entry `xw` (`respawn`), which runs
  `xinit /etc/kh-xsession -- /usr/bin/X11/X`;
- `/etc/kh-xsession` starts the three fixture clients and `exec olwm`;
  `/etc/kh-shell` prints `uname -a` and `exec /bin/sh`, so the xterm opens on a
  root shell with no prompt to answer;
- there is no first-run panel, no licence screen and no network to time out on
  (`network.status: host-only`, and the install deliberately declined the
  hosts-file step).

**Ready** means the OPEN LOOK desktop fully painted: the grey `olwm` root, an
xterm titled `Amiga UNIX 2.1` showing
`UNIX_System_V amix 4.0 2.1 0800430 Amiga (Unlimited) m68k` over a root shell,
the OPEN LOOK Calculator, and `xclock`.

Canvas is **640x512** — the AMIX Amiga-chipset X server's whole world, and it is
**monochrome, depth 1 StaticGray**, not a downsampling artefact of the capture.
`FSUAE_NATIVE_GEOM=640x512` sizes the pinned Xvfb and the FS-UAE window to the
same number, and `stretch = 1` (`FSE_STRETCH_FILL_SCREEN`) is what stops FS-UAE
letterboxing a 640x512 screen inside its own 640x512 window and putting bars in
the capture. Audio is off (`SH_AUDIO=off`); the fixture is silent.

## Timing

About **two minutes** from power-on to the desktop on a cleanly halted golden —
`mkfs`-free, but a 68030 at 25 MHz emulated on one host core booting SVR4 off a
2 GB UFS root. Set `BR_MAX_MS` well above that; the tier-1 change-fraction
detector will otherwise call the boot finished during one of the long quiet
stretches while the kernel probes.

Do **not** use a settle detector that expects a dead-still field. `xclock` has a
sweeping second hand and the xterm has a caret, so the fixture never stops
changing. When comparing a clip's last frame with the golden's first live frame,
mask the clock and the caret before concluding a seam is real.

## The one thing that will ruin a capture

**The golden must have been baked from a cleanly halted guest.** Halt with the
absolute path `/sbin/shutdown -y -g0 -i0` before copying the golden — note
`/usr/ucb/shutdown` is a different, BSD-flavoured command that rejects those
flags. UFS carries no dirty flag a host tool can repair, so a golden captured
from a killed emulator makes **every** boot run a full fsck: about four minutes
instead of two, with a wall of filesystem text over the console where the clip
expects the desktop. That is a property of the golden, not of the recording run,
so it cannot be worked around at capture time — re-bake first.

## Clone rules

Clone the **golden HDF only**. There is no statefile, no PRAM image and no
second snapshot-capable drive to get wrong; the work HDF is disposable by
construction. The clone must never attach the live
`/data/vms/streamhost/stations/amix/` work disk, and it needs its own Xvfb
display and its own FS-UAE binary path — the station's own copy under
`assets/amix/fsuae-native/`, never `amigaos35`'s. Golden + binary + device set
are ONE combination (AGENTS.md rule 6).

## Pointer

Nothing in a boot capture touches the pointer, and the station's pointer is
**open**: AMIX drives the emulated Amiga mouse hardware rather than registering a
UAE mousehack block, so absolute XTEST motion reaches it as relative,
accelerated deltas (`docs/guests/amix.md`, "The pointer is not 1:1"). A clip's
last frame therefore has the cursor wherever the golden left it, which is where
the live station also starts — the two agree for the same reason, not by luck.

Run `record-boot.sh amix --dry-run` first and read the rewritten clone launcher
before any real capture; follow [`README.md`](README.md).
