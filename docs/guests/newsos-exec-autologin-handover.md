# newsos — exec + non-root login: IN-FLIGHT HANDOVER (2026-08-18)

Working state for the `labctl exec` + non-root-user task on the **newsos**
station (NEWS-OS 4.1R / MAME `nws3260`). Written for pickup after a context
compaction. The **live `/os/newsos` station is UNAFFECTED** by everything
below — all work is on a throwaway scratch clone; the production disk
(`/data/vms/streamhost/assets/newsos/newsos-disk.img`) and binary
(`.../mame-native/newsos`, sha `c6a99fb8…`, dated Aug 18 09:08) were never
touched. Station: `streamhost@newsos` active, slot 148 / UDP 54148,
reset=relaunch cold boot (~90-120s to sxdm), no golden.

## The operator's decisions (already given)

1. **Autologin**: not achievable on this driver — accept **manual `demo`
   login** (sxdm greeter → type `demo`, no password → NEWS Desk desktop).
2. **labctl exec**: **wire it to production** (serial getty on tty00).
3. **Keyboard input** was unreliable (dropped/mis-cased chars) — operator had
   me spawn 3 competing Opus agents to fix it. **DONE — see below.**

## ✅ KEYBOARD FIX — validated, ready to land (the critical enabler)

Root cause (all 3 agents independently agreed): MAME's `news_hid` HLE keyboard
is a `device_matrix_keyboard_interface` that scans 8 rows round-robin (1200 Hz,
full sweep ~6.7 ms) and reports scancodes in **ROW order**, not edge-apply
order. The ctlsock path applies a Shift-make and the character-make in the
**same sweep**; L-Shift is ROW3 while most chars are ROW0-2, so the char's row
is scanned first → guest latches it **unshifted** (`The`→`the`, `#`→`3`,
`&`→`7`, `$HOME`→`$hOME`). Worse in X because the X server rebuilds Shift level
strictly from scancode order. Second cause: the 8-deep key FIFO silently drops
on burst overflow.

**Chosen fix: branch `kbdfix-a` (commit `4c6700e`, pushed to origin).**
`kbdfix-b` (`f777b12`) converged on the *same* device patch independently;
`kbdfix-c` (`50367ab`) did a lighter ctlsock-pacing env `MAME_CTL_KEY_SCAN_MS`
but validated only in the login field. **kbdfix-a is the pick** — device-level
(covers every input path incl. natkeyboard POST), fixes both causes, and I
**re-validated it byte-exact myself**: booted a scratch with kbdfix-a's binary
(`/data/vms/sandbox/kbdfix-a/mame-native/newsos`), opened an xterm, typed
`echo The_Quick-Brown.Fox JUMPED 42 over ok-123` via `nkey.py` at normal
cadence → typed AND echoed byte-exact (uppercase/symbols all correct).

kbdfix-a changes: `scripts/build-guests/patches/mame-news-hid-kbd-order.patch`
(new; buffers a scan sweep's edges, flushes modifier-makes → char-makes →
char-breaks → modifier-breaks, FIFO 8→256) + registers it in
`scripts/build-guests/emulators/native.d/newsos.sh` `NATIVE_EXTRA_PATCHES`.
NOTE: the `origin/main…kbdfix-a` two-dot diff shows sunos414 noise only because
kbdfix-a branched earlier — a real `git merge` keeps main's sunos414 and takes
only the newsos keyboard changes (native.d + the .patch).

### NEXT: land + rebuild
1. Merge `origin/kbdfix-a` into main (merge main first for sunos414/rhapsody/aux;
   the native.d line goes `(mame-irix-skip-warnings.patch mame-news-hid-kbd-order.patch)`),
   `git push origin HEAD:main`.
2. Rebuild the **production** binary: `scripts/build-guests/emulators/build-mame-native.sh newsos`
   (outputs to `/data/vms/streamhost/assets/newsos/mame-native/newsos`).
3. `systemctl restart streamhost@newsos`; confirm `/os/newsos`=200 and a cold
   boot reaches sxdm. (Consider salvaging kbdfix-b/c worktrees with `wt.sh gc`.)

## ⏳ GUEST CONFIG — apply with the fixed keyboard (was BLOCKED, now unblocked)

The keyboard fix removes the blocker. Apply this on a **scratch disk** (copy of
`/data/vms/sandbox/newsos/media/newsos-installed-20260818.img`) booted with the
**patched** binary, at the root xterm (sxdm → `root`/no-pw → Application menu →
Terminal Emulator; pointer gain ≈1.96×, open-loop). Then copy the configured
disk → production. NEWS-OS `mkdir` has NO `-p`; the existing system `news`
user (uid 6, Usenet) collides with `news` — use `demo`. Root shell is `/bin/csh`
(quote `*`). Commands (validated individually):

```
mkdir /usr/people; mkdir /usr/people/demo
echo 'demo::300:300:NEWS Guest:/usr/people/demo:/bin/csh' >> /etc/passwd   # empty pw field
echo 'demo:*:300:' >> /etc/group
cp /.cshrc /usr/people/demo/.cshrc
chown -R 300 /usr/people/demo; chgrp -R 300 /usr/people/demo
# serial-exec getty on tty00 (= MAME serial0):
sh -c 'sed "/^tty00/s/off secure/on  secure/" /etc/ttys > /etc/tn; cp /etc/tn /etc/ttys'
```

Validation already seen (pre-fix, when input happened to succeed): sxdm login
as `demo` (no password) → the sxsession NEWS Desk desktop with "Username: demo"
(non-root ✓). sxdm runs the default `/etc/sxdm/Xsession` (`mwm & sxsession -C`)
for demo — no dotfiles beyond `.cshrc` needed. NO `.login`/`.xinitrc`/gettytab/
DM=none needed (sxdm stays the login).

Then: sync, hard-kill+relaunch MAME (NEVER in-guest `reboot` — the nws3260
reboot bug hangs MAME at the ROM; production reset=relaunch already does a
MAME restart), verify cold boot → sxdm → demo → desktop, and `cp` the scratch
disk over `/data/vms/streamhost/assets/newsos/newsos-disk.img` (back up the
current one first).

## ✅/⏳ labctl exec — transport VALIDATED, host-plumbing TODO

Proven: MAME `-serial0 pty` → getty on NEWS `/dev/tty00` (= serial0, confirmed)
→ root login → command execution with real exit codes over the pty. Root shell
is csh; `exec /bin/sh` for the sentinel protocol (NEWS has no ksh; tru64exec's
ksh→sh fallback would get stuck in csh, so NEWS needs its OWN client). Set
`PATH=/bin:/usr/bin:/usr/ucb:/etc:/usr/etc` after `exec /bin/sh` (default PATH
lacks id/uname). The tru64 `serialcon_e` login/sentinel protocol otherwise
works verbatim.

Host-plumbing to write (all reliable code; model on tru64):
- **Launcher**: `streamhost/stations/mame-native/x11-runtime.sh` — env-gate
  `SH_MAME_SERIAL_EXEC=1`: add `-serial0 pty` to the MAME line, and after MAME
  starts, launch a **pty pump**.
- **New**: `streamhost/stations/mame-native/serial-pty-pump.py` — model on
  `streamhost/stations/tru64/pumps.py` but the emulator endpoint is a **pty**
  (find via `/proc/<mame-pid>/fd/*` → readlink `/dev/ptmx` → `tty-index` in
  fdinfo → `/dev/pts/N`; `stty raw -echo`), bridged to `serial-exec.sock` in
  the station dir, one client at a time, dies with MAME.
- **New client**: `streamhost/guest-agents/newsos/newsosexec.py` — copy
  `streamhost/guest-agents/tru64/tru64exec.py`, but `exec /bin/sh` directly
  (NO ksh), set PATH, same sentinel subshell + exit-code protocol, connect to
  `<dir>/serial-exec.sock`.
- **labctl dispatch**: `scripts/labctl.d/guest.py` cmd_exec — add a branch
  (e.g. `exec_kind == "serialcsh_e"` → `NEWSOSEXEC = /root/newsosexec.py`),
  mirroring the `serialcon_e` (tru64) branch. Additive.
- **Deploy**: add a `box-sync-pairs.sh` entry
  `newsos-exec streamhost/guest-agents/newsos/newsosexec.py /root/newsosexec.py exact repo`
  (like the irix-irixexec pair) so it lands on the box.
- **Registry** `registry/stations/newsos.json` `operator.labctl`:
  `exec_kind=serialcsh_e`, `exec_user=root`, `exec_port=null`; and the fixture
  `streamhost/stations/newsos/station.env.fixture`: `SH_MAME_SERIAL_EXEC=1` and
  add `-serial0 pty` to `MAME_NATIVE_ARGS`. Keep reset=relaunch.

⚠️ Note: the serial getty is a FRESH getty on each cold boot (works). It does
NOT survive a savestate restore (see golden below), but the station is
cold-boot/relaunch so that's moot.

## ❌ FINDINGS — not viable on this driver (don't retry)

- **Autologin**: NEWS-OS 4.1R `login` has NO `-f`; `getty` ignores the `al`
  gettytab capability; exec'ing `login`/`su` from an `/etc/init` wrapper fails
  ("failing, sleeping") — no getty tty setup. Would need a custom autologin
  binary. → operator accepted manual demo login.
- **Golden / instant-restore** (savestate): `nws3260` has no
  `MACHINE_SUPPORTS_SAVE`. SAVEST/LOADST "work" (framebuffer restores to the
  desktop instantly) but the restored machine is **functionally dead** —
  pointer/keyboard dead, ctlsock input commands hang (empty acks vs "1 OK").
  Tested directly. So no golden; station stays reset=relaunch cold boot.

## Scratch / drive reference

- Boot: copy the installed disk, launch the PATCHED binary
  (`/data/vms/sandbox/kbdfix-a/mame-native/newsos` until main is rebuilt) with
  the cfg (SW2 Automatic Boot = value 268435456), `-serial0 pty`,
  `-state_directory`, `-hard1 disk.img`, `MAME_CTL_PTR_PORTS=:hid`. ~100s to sxdm.
- Helpers in `/data/vms/sandbox/newsos/scratch/`: `nkey.py` (KEY-verb typing +
  keymap), `ptr.py` (closed-loop pointer, gain 1.96), `shot.py`. ctlsock verbs:
  `KEY/POST/SHOT/MOVEP/SAVEST/LOADST/KEYDUMP`. Read framebuffer via SHOT→PNG.
- Everything runs on labhost via `scripts/dev/labrun` / `ssh lab`. /data is
  bind-mounted here for file edits; PROCESSES run on the box.
- kbdfix-b found a **Root Menu** opens an xterm without the pointer menu-drag —
  worth using (ask agent kbdfix-b `f777b12` / see its transcript for the exact
  gesture) since the pointer plane is open-loop.

## Open items / next-step order

1. Land kbdfix-a to main + rebuild production binary + restart unit + verify.
2. Apply guest config (demo user + tty00 getty) to a scratch with the patched
   binary; validate demo login→desktop + serial exec; copy disk → production.
3. Write host-plumbing (pump + newsosexec.py + guest.py branch + box-sync +
   registry exec_kind + fixture `SH_MAME_SERIAL_EXEC=1` + `-serial0 pty`).
4. box-deploy --apply, labctl gen, restart unit; verify `labctl exec newsos`
   and the manual demo login. Update `docs/guests/newsos.md`. Green the gates.
5. Teardown scratch; release claims; report.
