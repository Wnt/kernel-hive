# NeXTSTEP 3.3 — live streamhost station `nextstep` (udp 54134)

**Status: LIVE, HOST-NATIVE since 2026-08-25.** The captured Debian kiosk is
gone. The museum's fork of the **Previous** emulator runs directly on labhost as
an unprivileged account under SDL's dummy video and audio drivers — no X server,
no window, no guest Linux — as a **colour NeXTstation** (Motorola 68040 at
25 MHz, 32 MB, ROM Rev 2.5 v66) booting **NeXTSTEP 3.3 for m68k**. It publishes
its own three planes to the streamhost daemon, it is on the museum's retronet at
`10.99.0.25` browsing the period corpus with **OmniWeb 2.7b3**, and its reset is
a **CRIU restore** of a checkpoint of the emulator process.

| | |
|---|---|
| Emulator | `github.com/Wnt/previous`, branch `kernel-hive` at **ad73344** (Previous SVN r1847 = 4.4 + the museum's nine patches), built `-DCMAKE_BUILD_TYPE=Release -DENABLE_RENDERING_THREAD=1` |
| Launcher | [`streamhost/stations/nextstep/x11-runtime.sh`](../../streamhost/stations/nextstep/x11-runtime.sh) — the name is the daemon's fixed contract for `SH_STATION_RUNTIME=x11`; there is no X here |
| Scene builder | [`scripts/build-guests/nextstep/nextstep-scene.py`](../../scripts/build-guests/nextstep/nextstep-scene.py) |
| Golden | [`scripts/build-guests/nextstep/nextstep-bake-golden.sh`](../../scripts/build-guests/nextstep/nextstep-bake-golden.sh) |
| Retronet | [`docs/lab/retronet/WEB-STATION-nextstep.md`](../lab/retronet/WEB-STATION-nextstep.md) |
| Colour machine | [`docs/lab/research/nextstep-color-machine.md`](../lab/research/nextstep-color-machine.md) |

## 1. Why this is a NeXT and not an Intel PC

`NeXTSTEP 3.3 for Intel` cannot be installed or run on a modern QEMU — the
historical section at the end of this file records that in full, and it still
stands. Previous emulates the real machine instead, the disk image is
pre-installed so there is no 1994 installer to drive, and the NeXT ROMs ship
inside the Previous source tree. It is also the better exhibit: a matte-black
NeXT is the machine Tim Berners-Lee wrote the first web browser on.

## 2. The three planes

Zero streamhost code was written for this station. The fork's control socket
speaks `mamectl/1` **verbatim** — the same wire the daemon's `mamesock` sink
already drives MAME's ctlsock module with — so integration is env only.

| plane | emulator env | streamhost env |
|---|---|---|
| frames | `PREVIOUS_SHM_PATH` | `SH_CAPTURE=shm`, `SH_SHM_PATH`, **`SH_SHM_DAMAGE=0`** |
| input | `PREVIOUS_CTL_SOCK` | `SH_INPUT_BACKEND=mamesock`, `SH_MAMECTL_SOCK`, `SH_MAMESOCK_KEYMAP` |
| audio | `PREVIOUS_AUDIO_FIFO` | `SH_AUDIO_SOURCE=fifo`, `SH_AUDIO_FIFO` |

Each repaint is diffed against a private shadow and only the changed region is
copied, with a REAL dirty rect in the header — which is why the daemon must not
re-derive one (`SH_SHM_DAMAGE=0`). Measured on an idle Workspace: 10,200
repaints, 646 published, 27 MB copied.

What the daemon never interprets is the `KEY` verb's (port, field) pair, so the
fork defines it as the NeXT KMS space: port `kms` with a hex NeXT scancode, port
`mod` with a modifier by name — a NeXT keyboard's modifiers are a MASK carried
with every edge, not keycodes. `streamhost/stations/nextstep/nextstep.keymap` is
that map, 80 rows, every one driven through the live socket. Leave
`SH_MAMESOCK_PTR_GRID` unset: this server states targets in screen pixels.

**The emulator runs as an unprivileged account (`nsexhibit`), and that is a
requirement, not hygiene.** SDL3's dummy video driver still opens
`/dev/input/event*` and `/dev/input/mouse0` for its evdev input source, and
**criu cannot dump a character-device fd** — `Can't dump file 4 of that type
[20660] (chr 13:65)`, and `--external dev[…]` does not rescue an already-open
one. Those nodes are `root:input 0660`, so an account outside the `input` group
never opens them and the checkpoint becomes possible. The launcher creates the
account on first run. It is the same shape as MAME's `/dev/snd/seq` +
`-midiprovider none`.

## 3. The machine: a COLOUR NeXTstation

`nMachineType = 2`, `bColor = TRUE`, `bTurbo = FALSE`, `bNBIC = FALSE`, memory
banks `8/8/8/8` = 32 MB, the **same** stock `Rev_2.5_v66.BIN`. The **same,
unmodified disk image** boots colour with no in-guest change of any kind:
NeXTSTEP 3.3 probes the framebuffer at boot and the WindowServer comes up on the
colour one by itself. The display stays **1120x832** — `NeXT_SCRN_W/H` are
`const`, and colour only changes which blit fills the same-sized texture — so
the geometry and the 1:1 pointer map are untouched.

Colour is free: 148.5% of a core against mono's 146.3%, and boot is if anything
a hair faster. Turbo buys nothing and costs ~11% CPU, needs a second ROM, and
changes the keyboard-controller revision and the ADB configuration under a
proven input path. `bNBIC` and the 8 MB bank quantum are FORCED by Previous on
`NEXT_STATION`; the launcher writes the corrected values so the file on disk is
the truth. Full measurement:
[`docs/lab/research/nextstep-color-machine.md`](../lab/research/nextstep-color-machine.md).

The colour framebuffer is 16 bpp big-endian RGBX 4-4-4-4 — 4096 colours, every
channel value a multiple of 17. The captured desktop uses 602 of them; the root
is `#555577`, NeXTSTEP's blue-grey, not the mono `#555555`.

## 4. Input: an absolute pointer, and a keyboard that must be paced

Previous emulates a SummaGraphics MM 1201 digitiser on the NeXT's **SCC serial
port B** (`src/tablet.c`), and NeXTSTEP 3.3 ships the matching driver on the disk
(`/NextAdmin/InstallTablet.app`, setuid root, 21 Oct 1994). With the driver
attached AND STREAMING, a `MOVEA` is one `tablet_pen_move()` and the cursor lands
on the commanded pixel at any speed.

**Measured on the colour machine, 2026-08-25:** 6 of 6 commanded absolute
targets landed at **0 px**, and 4 of 4 again after a CRIU restore.

**What the golden carries, and what a cold boot does not.** The disk carries an
`/etc/rc.local` hook (`kl_util -l tablet` + `kl_util -a …/tablet_reloc`) that
LOADS the kernel server on every boot, and loading it swaps the kernel's
low-memory pointer vectors. That is necessary and **not sufficient**: nothing on
a plain boot puts the digitiser into SummaGraphics **stream mode**, which is the
edge that sets `bTabletEnabled` in the emulator. Measured on this machine, three
ways — a cold boot with the server Loaded, a mid-session unload/reload, and
`PREVIOUS_CTL_PTR=tablet` forcing the route — the pointer stays dead reckoned
until `InstallTablet.app`'s **Install** button is actually pressed. (Forcing the
route is worse than useless: the guest ignores a stream it never asked for and
the cursor stops moving at all.)

So the STREAMING tablet lives in the checkpoint, in both halves of it — the
guest's driver state in emulated memory and `bTabletEnabled` in the emulator
process — and the checkpoint is what every visitor and every reset gets. **A
cold boot is a degraded exhibit** and the launcher says so out loud. This is the
one place where the previous (kiosk) revision of this document was optimistic:
it recorded the cold-boot asymmetry as CLOSED on the strength of the rc.local
hook, and on the colour slab it is not.

**Before the tablet, the pointer walks in ONE PIXEL steps.** NeXTSTEP
accelerates a single event superlinearly (a 24 px step measures ~2.3x) and the
curve keys off event timing as well as size, so no calibrated step survives a
differently-loaded box. A 1 px step is the one input the curve cannot amplify:
gain 1.000, and `nextstep-scene.py`'s `walk()` puts the pointer on the Install
button from 726 px away in one round.

**Buttons carry a minimum hold, and it is a CEILING as well as a floor.** A
~12 ms press is sampled away entirely — a menu item highlights and never fires.
The fork's `PREVIOUS_CTL_BTN_HOLD` holds an early RELEASE in the queue so a
visitor's quick click cannot be lost. But two presses cost `hold + gap`, and
NeXTSTEP stops scoring them as a double click above **440 ms** — swept on a rig
against the guest's own verdict, 240/260/320/380/440 ms press-to-press all score
DOUBLE and 450 ms and up all score two singles. The fork's own 400 ms hold
default therefore leaves a visitor unable to open anything from the File Viewer.
**The station runs 200 + 40 ms**: single clicks land, double clicks open, and
200 ms of margin is left under the guest's threshold.

### The lost release that made every double click a single

**A button edge is a REPORT on a serial device, and the hold alone guaranteed
that two of them landed in one drain pass.** This is the third instance of the
one-report-register family this campaign has found — after `kms_mouse_button()`
below and the keyboard's in §5.1 — and it is the one that survived longest,
because every test that ever exercised it used an ACKING control-socket client,
which cannot put two edges in one pass and therefore cannot see it.

The shape: the first click's release waits out `PREVIOUS_CTL_BTN_HOLD` at the
queue head; when it finally applies, the drain loop takes the very next entry —
the SECOND PRESS — in the same pass. On the tablet route `summa_pen_button()`
ends in `tablet_send_data(5)`, which only assigns `tablet.count` and schedules
`EVENT_TABLET_IO`; two calls in one pass are microseconds apart with no emulated
cycles between them, so the second rewrites the buffer before one byte of the
first has gone out. `tablet.flags` is a level, so the release is not truncated —
it is **never transmitted**. The guest sees one long press: a select, never an
open; a caret, never a selected word.

Proven three ways on 2026-08-25:

* **On the live wire**, with `SH_MAMESOCK_TRACE=on` and a real `page.mouse`
  double click through the deployed client: the daemon received four separate
  button events (`rx seq=10 btn=1`, `11 btn=0`, `12 btn=1`, `13 btn=0`) and sent
  all four verbs, so nothing coalesced anywhere in the SPA or the daemon — and
  `ack 17 rtt_us=200856` (the first release, held) and `ack 19 rtt_us=199852`
  (the second press) are the same instant, one microsecond apart.
* **On a rig**, with the pre-fix binary: a pipelined `DOWN1 UP1 DOWN1 UP1`
  SELECTED `OmniWeb.app` and never launched it, while an acking client launched
  it from the same pixel.
* **On the same rig with the fix**: the pipelined pair launches OmniWeb and
  selects a word in a text field, single click and click-drag are unchanged, and
  pipelined typing still lands 19/19 at 0 ms.

The fix is `PREVIOUS_CTL_BTN_GAP` (40 ms, fork commit `ad73344`): a button edge
waits at the queue head until that long after the last input report of ANY kind.
It shares the keyboard's clock because without the tablet it is literally the
same one-report register.

### Keyboard: the NeXT KMS space, and the dwell floors it needs

The browser's XT set 1 scancodes are mapped by
[`nextstep.keymap`](../../streamhost/stations/nextstep/nextstep.keymap) onto two
ports the fork defines — `kms` with a NeXT scancode, `mod` with a modifier bit by
name — because a NeXT keyboard is not a matrix: it is a serial device whose
modifiers ride as a MASK with every edge. A scancode with no row is REJECTED, not
guessed, which is why Caps Lock, the function keys and the navigation cluster are
deliberately absent.

**Every key edge is one KMS report, and the KMS holds exactly one.**
`kms_km_receive()` writes each report into `kms.kmdata` and raises `KM_OVERRUN`
if the guest has not read the previous one; NeXTSTEP's driver then discards the
pair. Two edges applied in the same `CtlSock_Drain()` pass are microseconds
apart, so the first is always lost.

That is not a theoretical window, because **a browser is not a keyboard**. A
phone's soft keyboard stamps the press and the release with the SAME
millisecond — the live station's own `serve/clientlog.jsonl`, 2026-08-25:
`d,23855755,1787632819332,2d;u,23855755,1787632819332,2d` — and the daemon's
`mamesock` writer drains its send queue without waiting for acks, so both edges
reach one drain pass. The operator's report was **about one keystroke in ten**,
with the pointer perfect throughout; that asymmetry is the same one the mouse
bug had, and for the same reason.

Measured on a rig, typing `the quick brown fox` (19 characters) as pipelined
edges, one dwell varied at a time:

| hold | landed | | gap | landed |
|---|---|---|---|---|
| 0 ms | 0/19 | | 0 ms | 1/19 |
| 1 ms | 5/19 | | 2 ms | lossy |
| 3 ms | 14/19 | | 5 ms | 18/19 |
| 5 ms | 19/19, but 8 ms 17/19 | | 8 ms | 19/19 |
| 12 ms and up | 19/19 | | 12 ms and up | 19/19 |

Both dwells are real — it is one serial channel, so a release-then-next-press
adjacency overruns exactly like a press-then-release one — and the 5 ms/8 ms
non-monotonicity is the 200 Hz drain jittering across the tick boundary.

So the floors live at the injector, the way `MAME_CTL_KEY_EXCL` does for the
matrix guests: `PREVIOUS_CTL_KEY_HOLD` holds a release until its OWN press has
been down long enough, and `PREVIOUS_CTL_KEY_GAP` spaces consecutive keyboard
reports. Only the queue HEAD is ever examined, so arrival order is never broken
and modifiers stay LEVELS — a deferred key edge carries exactly the mask that was
in force when it arrived. **The station runs 40/40**, three times the measured
floor and the same numbers as the daemon's `SH_KEY_MIN_*` gate, which does NOT
run on this backend (`mame_sock.rs`); `station.env` states them as
`SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` and the launcher reads them from there.
A visitor who really holds a key pays nothing.

### The one-report controller, three times

**`kms_mouse_button()` sent one KMS report per button, so setting the pair —
which is what any injector with a button mask does — put two reports into the
controller back to back, the second landed before the guest had read the first,
`kms_km_receive()` raised `KM_OVERRUN`, and NeXTSTEP's mouse driver discarded
both.** The symptom is precise and misleading: motion through the very same path
works perfectly (one report per move), the control socket acks every verb, and
the guest simply never sees a button. A held left button produced no highlight,
no menu track and no rubber band. The fork now has `kms_mouse_buttons()`, which
reports both buttons in the single byte pair a real NeXT mouse uses.

The keyboard defect above is the SAME controller telling the same lie a second
time, three hours later, to a different plane. The lost double-click release
(§4) is the third, five hours after that, and it is not even the same device —
the SummaGraphics tablet on SCC port B has its own one-packet engine
(`tablet_send_data()`), and it fails identically. All three were hidden by
planes that pass their own smoke test. The lesson to carry to the next change
anywhere near this injector: **anything that can put two reports into ANY of the
guest's serial input devices in one drain pass is broken until it is measured
with a pipelined sender at zero spacing.** Acking clients hide it perfectly: a
rig that waits for each ack serialises the edges itself, and typing at "0 ms"
then lands 26 of 26 characters while the live station loses nine in ten — and a
double click launches an app on the rig while the exhibit only selects.

## 5. Reset: a CRIU restore, not a reboot

`SH_RESET_MODE=relaunch` → `systemctl restart streamhost@nextstep` → the unit's
`ExecStartPre` re-runs the launcher, and for this station a launch is a **CRIU
restore** of the golden against the disk image reflinked inside the very freeze
window the memory image was written in.

| | measured |
|---|---|
| bake freeze | 1.24 – 1.27 s |
| restore, kill to serving | **2.8 – 3.0 s** (cold boot: ~135 s) |
| image | 68–71 MB apparent, 14 MB on disk, + a reflinked 2 GB disk |
| framebuffer after restore | **md5-identical to the bake**, proven from a drifted live picture |
| pointer after restore | 0 px on every commanded target |

There is no `loadvm` here — Previous has no savestate — and NeXTSTEP's root is
UFS, so a hard-killed one is not to be trusted. The restore IS the reset. A cold
boot is the bounded fallback: after **two** restore launches that never got a
verb acknowledged, the next launch cold-boots, loudly. A restore that gets its
post-restore verb acked clears the counter — a mamectl verb is acknowledged by
the EMULATION thread after it is applied, so an OK means the restored 68k is
running its queue, not merely that a process exists.

### Four things that pass a smoke test while being broken

1. **criu cannot dump libpcap's `AF_PACKET` socket.** `getsockopt(SOL_SOCKET,
   SO_PASSCRED)` on it answers EOPNOTSUPP and the whole dump aborts
   (`sockets.c:628 Can't get 1:16 opt`). Reproduced on a bare Python process
   holding nothing else. The fork therefore has `NETDOWN`/`NETUP` control verbs
   that close and reopen the HOST side of the emulated NIC with the guest's own
   NIC state — which lives in emulated memory — untouched; the bake says
   `NETDOWN`, and the launcher says `NETUP` after every restore.
2. **The veth must be dumped as EXTERNAL.** Without
   `--external veth[nextrn1]:nextrn0` the restore dies on `net.c:1469 Unknown
   peer net namespace`. With it, criu deletes and re-creates the pair at restore
   — new ifindex, host end BARE — which is exactly why `rn-tapnet.sh up` is the
   post-restore hook as well as the first-time setup, and why the launcher
   deletes the pair before calling criu.
3. **The framebuffer mapping and the diff shadow drift apart.** criu never
   copies the shm file (same inode, same address) but it DOES carry the
   publisher's private shadow. So a restored emulator believes the reader is
   already showing the baked frame, publishes nothing, and **the reader keeps
   streaming the pre-kill picture forever** — under a live guest whose cursor
   still moves, with a valid header and a healthy everything. Measured: a
   restore from a drifted live page returned the drifted page. The fork's
   `FBSYNC` verb republishes one whole frame and the launcher sends it after
   every restore, unconditionally. This is the shm cousin of the
   delete-and-re-create-`fb.shm` trap in
   [`irix-criu/README.md`](../../scripts/build-guests/irix/irix-criu/README.md).
4. **A connected client blocks the dump.** A dump succeeds with the control
   socket merely LISTENING and fails while a client is CONNECTED (`unix: Unix
   socket … not found`; `--ext-unix-sk` does not rescue it). Every driver must
   disconnect before a bake; `mamesock` reconnects forever with backoff, so the
   daemon costs nothing.

Also: **the golden is not portable between paths.** The image records the
absolute path of every open file — the disk, the log, the binary — and the
network namespace by name, so a golden baked on a bring-up rig cannot be copied
onto the station. Bake it where it will run.

**Provenance is a triple.** `state/golden/provenance.md5` carries the emulator
binary's md5 and the launcher refuses a restore that does not match, because a
rebuild orphans every image: golden + binary + device set are ONE combination.
A mismatched (memory, disk) pair is invisible to criu, to the guest and to
`fsck` — the machine serves stale data behind a healthy desktop — so safety is
construction (paired naming, reflinked inside the freeze), never detection.

## 6. The scene, and how it is built

The acceptance scene is the colour Workspace on its blue-grey root, the File
Viewer open on the home directory, **OmniWeb 2.7b3 in the Dock** and its window
open on the 8 May 1998 `www.apple.com` from the retronet corpus, fetched over the
guest's own veth. `nextstep-scene.py` builds it headless, using only the shm
framebuffer and the control socket:

1. probe whether the boot is already absolute (it is, after a restore);
2. symlink `/NextAdmin/InstallTablet.app` into `/me` over telnet, refresh the
   File Viewer with **Command-u (View → Update Viewers)**, type-select
   `Install`, RETURN;
3. walk the 1 px pointer onto the panel's Install button and click it;
4. prove the absolute map, quit with Command-q, drop the symlink, Command-u;
5. type-select `omni`, RETURN, wait for the page, miniaturise the bookmarks
   window OmniWeb opens at every launch.

Three things in that list are load-bearing and were each found the hard way:

- **Command-u, not a double click.** The Workspace does not re-read a directory
  because its contents changed. Double-clicking the `me` row in the browser
  column does re-open it — but the scene builder runs before the tablet exists,
  so its pointer is dead reckoned, and a double click it aims by dead reckoning
  that lands one row off SELECTS something instead, leaving the type-select
  silently one edit behind. That failure is indistinguishable from a keyboard
  that is not working. Command-u needs no pointer at all, which is the whole
  point before the tablet exists. (Double-clicking the identical-looking house
  on the SHELF never re-opens anything; it only selects.)

  Until `PREVIOUS_CTL_BTN_GAP` landed there was a second reason, and it was the
  real one: the injector destroyed the first click's release, so a double click
  through this socket was *never* scored as one unless the sender waited for
  each ack (§4). The scene builder's own `Rig.click()` is an acking client, which
  is exactly why it never noticed.
- **RETURN does not press the Install button**, even though it is drawn with the
  default-button glyph. Tested, not assumed: the framebuffer is unchanged. The
  pointer really is the only way in.
- **OmniWeb's FIRST load after a launch stalls**, reliably: the window settles
  blank with the status line still reading `SGMLToRTF: Running`, while the
  corpus answers 200 to the same request throughout. Pressing **Home** fetches
  it correctly, sometimes on the second press. The scene builder retries.

## 7. Standby

`SH_IDLE_PAUSE_SECS=60` with `SH_IDLE_PAUSE_PIDFILE` and
`SH_IDLE_PAUSE_PROC_MATCH=assets/nextstep/previous`. **Without the pidfile the
daemon cannot pause a non-QEMU station at all** — `idle.rs` never infers a
signalling freezer — and an unwatched Previous burns 150% of a core for nobody.
Measured: SIGSTOP → `/proc/<pid>/stat` state `T`, **0 jiffies over 5 s**;
SIGCONT → `R`, 771 jiffies over 5 s. The launcher also freezes the guest a few
seconds after launch, covering the daemon's own start-up grace.

## 8. Operator notes

- **`labctl exec nextstep` has no channel here.** The NeXT's own exec is telnet,
  `me` (no password) then `su` (no password), driven by
  `scripts/build-guests/nextstep-nstel.py`:

  ```bash
  ssh lab 'NSTEL_HOST=10.99.0.25 NSTEL_PORT=23 \
    python3 /data/kernel-hive/scripts/build-guests/nextstep-nstel.py me "hostname"'
  ```

  Root's shell is `csh`: every command is one line and `2>&1` is a syntax error
  there. `ping` takes no `-c` — it is `ping host [datasize] [npackets]`. GUI apps
  cannot be launched from it (`DPS client library error: Could not form
  connection`): a telnet login is not in the console session's window-server
  namespace.
- NeXTSTEP logs in automatically as `me`. There is no password prompt in the
  scene.
- `/etc/inetd.conf` is trimmed to **telnet only** (the stock file exposes ftp,
  shell, login, exec, finger, tftp, comsat, talk/ntalk, the
  echo/discard/chargen/daytime/time pairs, the remote window server and six RPC
  services, all behind passwordless accounts). `printer` (lpd) and `smtp`
  (sendmail) are started from `/etc/rc`, not inetd, and survive the trim; they
  are left on deliberately, the same trade every station on this bridge makes.
- Rebuilding the emulator orphans the golden. Re-bake: cold-boot the station
  (`x11-runtime.sh --cold`), run `nextstep-scene.py`, then
  `nextstep-bake-golden.sh bake`.

## 9. Proven through the deployed client

`tests/e2e-live/nextstep-abs-probe.mjs` drives real `page.mouse` input at the
live gallery — browser → WebTransport → streamhost → `mamesock` → the emulator's
control socket → its tablet → NeXTSTEP — while a poller reads the NeXT arrow out
of the shm framebuffer. Measured 2026-08-25:

```
move guest 1000,700   ->  arrow (1000, 700)
move guest 300,200    ->  arrow (300, 200)
drag (button held) to 450,500  ->  arrow (450, 500)
```

The drag is the interesting one: it is the two-packet KMS fix (§4) travelling
the whole visitor path. The **first** move of a fresh session can land short —
the session's wake and the sink's resync preamble share that moment — and every
move after it is exact.

**Typing, 2026-08-25 (the keyboard fix, §4).**
`tests/e2e-live/nextstep-key-probe.mjs` drives real `page.keyboard` input at the
live gallery into OmniWeb's editable URL field, and the guest's own framebuffer
is read for the answer:

```
delay 0 ms    "the quick brown fox"        19/19 characters (19 chars in 131 ms)
delay 120 ms  "The Quick Brown Fox 12+34"  25/25, capitals and the shifted + exact
```

The 0 ms case is the one that matters: Playwright stamps the press and the
release in the same tick, which is what a phone's soft keyboard does and what
was losing nine keystrokes in ten. Note the probe's own trap, written into the
file: the grey strip at guest y=227 is OmniWeb's READ-ONLY location display and
swallows every keystroke silently — the editable field is the white one at
y=149, and aiming at the wrong one reads exactly like a broken keyboard.

The gallery's own reset button was exercised the same day:
`POST /restore/nextstep` → `systemctl restart streamhost@nextstep` →
`nextstep: restored state=golden` in 3 s, 13 s end to end including the unit's
own stop grace, and the scene came back exactly (`evidence/live-after-ui-reset.png`).

## 10. Rollback

The kiosk is shelved, not deleted: `qemu-streamhost.sh.debridged-bak` and
`overlay.qcow2.debridged-bak` in the station directory, plus `ROLLBACK.md`. See
`docs/lab/DEBRIDGE-ROLLBACK.md` for the three-move restore; the repo side is a
`git revert` of the conversion commit followed by `make station-registry-generate`
and a re-emit.

## 11. Open items — stated honestly

- **A cold boot has a relative pointer** (§4). The fix belongs in the guest —
  something that puts the tablet into stream mode from `/etc/rc` without the GUI
  — and nobody has found it. The reloc's own load commands end in
  `CALL tablet_attach`, which swaps the vectors but sends no SummaGraphics
  command; the mode selection `InstallTablet.app` makes is not visibly persisted
  anywhere on the disk.
- **The corpus has `www.next.com` (1996-11-12) and the station does not use it.**
  NeXT's own home page of that date is a single image map whose hero JPEG was
  never archived, so it renders as an empty page in OmniWeb — checked on the
  framebuffer. `http://www.apple.com/` (8 May 1998) renders in full and is the
  home page; the NeXT pages one hop down (`/HotNews/` and friends) do have all
  their images and are reachable by typing.
- **Stream cost after the colour swap is unmeasured.** The exhibit went from a
  4-grey framebuffer to a 602-colour one over the same 1120x832; nothing about
  the emulator got more expensive, but the encoder now has real chroma. Worth
  one look at the station's bitrate.
- **Guest-input latency has not been re-measured** on the host-native path.
- **The keyboard floors are an injector workaround, not a model of the wire.**
  The honest fix is in `kms.c`: a real KMS is a serial link whose reports are
  physically spaced, so the emulator could QUEUE reports and release the next
  only when the guest has cleared `KM_RECEIVED` — which would need no magic
  numbers and would cover the mouse too. That is a `cycInt`-scheduled change
  inside the emulated device and it was not the right thing to land against a
  live exhibit on the day the bug was reported. 40/40 costs a real typist
  nothing; a station that ever wants faster machine-driven typing should do the
  queue instead of lowering the floor.
- **`ss` cannot see a connected peer on the control socket from outside its
  netns**, so the bake script's "no client" check reports 0 endpoints and is
  informational only. The real guard is procedure: disconnect before baking.
- **The control socket serves ONE client at a time.** While the daemon is up its
  `mamesock` sink is that client, and any tool that connects simply waits in the
  backlog and times out on a HELLO banner nobody sends. Every bake therefore
  runs with the unit STOPPED (the procedure is in the bake script's header).
  Making the server accept a second client, or preempt the first, would make the
  station reachable the way `labctl` reaches a MAME station; nobody has.
- **The button floors are the same injector workaround as the keyboard's.** The
  `kms.c` queue described above would cover them too — and so would the tablet's
  own `EVENT_TABLET_IO` chain, which already knows when a packet has finished
  shifting out and could simply refuse a new one until it has. Either would
  replace `PREVIOUS_CTL_BTN_HOLD`/`_GAP` with something that needs no numbers.
  Nobody has; the numbers work and they are measured.
- **`PREVIOUS_CTL_BTN_HOLD` and `_GAP` are read at `CtlSock_Init`**, so a restore
  brings back the environment the checkpoint was baked with and **every
  button-timing change costs a golden re-bake**. Diagnose on a rig first; the
  rig's cold boot has no tablet, but both routes have the same one-report
  failure, so the mechanism reproduces and only the exact device differs.
- **A synthetic ROLLOVER burst can leave the guest believing Shift is down.**
  `key-replay.py --type ... --cps 12 --hold-ms 200` (hold longer than the
  inter-key period, so three keys are down at once — something a NeXT keyboard's
  one-key-at-a-time reporting never sees) left the next line typed entirely in
  capitals; it cleared itself on the next real modifier edge. Every character
  was correct, so this is a modifier-LEVEL desync in the guest, not a lost key,
  and no browser produces the input that causes it. **The cheap hardening is now
  in** (fork `ad73344`): `CTL_RELEASE` sends `kms_keyup(0, NEXTKEY_NONE)`
  unconditionally instead of only when the injector itself thinks a modifier is
  held, so every reconnect resynchronises the guest's belief — and it queues the
  two button releases as separate entries so the floors pace all three reports
  apart instead of stacking them into one apply. The desync itself has not been
  re-provoked to confirm the hardening clears it; nothing a browser sends
  produces it, so it is not worth a live experiment.
  (`key-replay.py`'s own shift windows overlap above ~5 cps at hold 60 ms, which
  makes a run of capitals come out `AND` -> `And`. That is the synthesizer, not
  the guest: at `--cps 4 --hold-ms 40` every capital lands.)
- Only `nTabletType = 2` (SummaGraphics MM 1201) was ever tried.

---

# HISTORICAL — the Intel/QEMU-10 dead end (2026, pre-bridge architecture)

*Kept verbatim in substance because it is hard-won and would otherwise be
re-derived. It describes the previous attempt at this station: NeXTSTEP 3.3 for
**Intel**, installed by QEMU directly, streamed by the retired docker-compose
/ neko stack on port 8109. Both the OS variant and the streaming architecture
are different from what ships today.*

## TL;DR

NeXTSTEP 3.3 for Intel **installs and runs only on QEMU ≤ 0.9.x** (the
busmouse-patched Michael Engel build) or under **Previous**. On QEMU 10.0.8 the
install gets as far as the NeXT Mach kernel booting and **detecting both drives**
(the CD labelled `NEXTSTEP_3.3` and the IDE hard disk), then dies the moment it
starts real bulk I/O:

```
sd0: Bus Reset Detected; FATAL            <- SCSI CD  (lsi53c810)
hc0: interrupt timeout, cmd: 0xc4 ...     <- IDE disk (PIIX3)
hc0: ATA command c4 failed. Retrying..
Load of /etc/mach_init failed, errno 5    <- EIO; installer aborts
Load of /etc/init failed, errno 5
```

Root cause: NeXTSTEP 3.3's 1994-era SCSI/IDE drivers do not get reliable
completion **interrupts / DMA** from QEMU 10 once sustained transfers begin.
Reproduced under **both TCG and KVM**. This matches the public record (gunkies,
emaculation, 86Box #356, PCem, QEMU LP#1471904): "install fails right after the
floppies are read in."

No pre-built NeXTSTEP/OPENSTEP **Intel** disk image exists on archive.org (only
the install media), and a pre-built image would hit the same runtime I/O wall.

## Intel media (unused by the current station)

Item `NeXTSTEP33CISC` (https://archive.org/details/NeXTSTEP33CISC):
`NeXTSTEP_3.3_User_(i386_m68k).iso` (~356 MB, a 4.3BSD-FFS disc, **not**
ISO-9660 — label `NEXTSTEP_3.3`, 2048-byte blocks) plus the floppies
`3.3_Boot_Disk.img`, `3.3_Core_Drivers.img`, `3.3_Beta_Drivers.img`,
`3.3_Addl_Drivers.img`. No NeXT ROM is used or needed on the Intel path.

## The one QEMU-10 recipe that reached hardware detection

```
qemu-system-i386 -machine pc,acpi=off -cpu pentium -m 64 \
  -rtc base=1995-06-15T12:00:00,clock=vm \
  -drive file=ns33.qcow2,format=qcow2,if=ide,index=0,media=disk \      # HD on IDE
  -device lsi53c810,id=scsi,romfile= \                                 # CD on SCSI
  -drive file=NeXTSTEP_3.3_User.iso,format=raw,if=none,id=cd0,readonly=on \
  -device scsi-cd,bus=scsi.0,scsi-id=0,drive=cd0 \
  -fda 3.3_Boot_Disk.img -boot a -vga std -net none
```

Installer driver selection (framebuffer-validated `sendkey` macro): English(1) →
prepare(1) → insert **Core** (blank list) → insert **Additional Drivers** →
CD-ROM = **Symbios Logic 53C8xx** (page 3, opt 3) → HARD DISK = **IDE Disk
Controller** (page 3, opt 5) → continue(1). The Mach kernel then prints
`sd0: … NEXTSTEP_3.3` and `hd0: … 499 MB`, and then the I/O death above.

Key gotcha: the installer's **CD-ROM** driver menu lists *only* SCSI adapters;
the EIDE/IDE "hard-disk controllers" are hidden there and appear only on the
**HARD-DISK** menu. That is why the CD had to go on SCSI and the disk on IDE.

## Every controller/driver permutation tried

| CD-ROM bus / NS driver | Hard disk bus / NS driver | Result on QEMU 10 |
|---|---|---|
| am53c974 (both devices, 1 target) | am53c974 | phantom 8-LUN scan; **READ CAPACITY = 0 KB**; also QEMU option-ROM exec bug LP#1471904 (dodge with `romfile=`) |
| lsi53c810 (both devices) | lsi53c810 | correct sizes; **reads ~35k blocks then `Bus Reset Detected` → FATAL** |
| lsi53c895a | — | NS **`SYM53C8: Can't find this PCI device; ABORTING`** — PCI id 0x0012 too new for NS driver v3.33 |
| IDE ATAPI (CD) + IDE (disk) | "EIDE and ATAPI Device Ctrl" | detects both, then **hangs for ever at `hc0: Resetting drives..`** |
| **lsi53c810 (CD)** | **IDE "IDE Disk Controller"** | **furthest**: both detected, IDE reset OK, then **IDE `interrupt timeout` + SCSI `Bus Reset FATAL`** → `errno 5` |

Also tried with no effect: TCG vs `-enable-kvm`; a fixed 1995 `-rtc` date (the
`preposterous time in Real Time Clock` warning is cosmetic). Disk kept under
504 MB to avoid NS large-disk CHS traps.

*The retired proposal in this document's earlier revision — a `neko-qemu`
docker-compose service on port 8109, VMID 1040, `NEKO_EPR 53320-53339` — is gone
with the architecture it belonged to. The gallery has run the Rust `streamhost`
daemon with per-station systemd units since; there is no compose stack to wire into.*
