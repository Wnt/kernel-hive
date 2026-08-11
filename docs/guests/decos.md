# DEC PDP-11 — RT-11 / RSX-11M / RSTS/E (udp/54126)

**Guest:** a captured **Debian 13 (trixie) x86_64 kiosk** running **one fullscreen
green-on-black xterm** whose only program is a chooser. Pressing `1`, `2` or `3`
boots **RT-11 V5.3**, **RSX-11M V4.2 BL38** or **RSTS/E V9.6** on a simulated
**DEC PDP-11** under **Open SIMH**. A **kiosk** — streamhost
captures the Linux framebuffer + AC97 audio exactly like every other station. See
**`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base-trixie.qcow2` — does **not** contain
SIMH; see [SIMH is built into the overlay](#simh-is-built-into-the-overlay).
Migrated from the frozen bookworm base on 2026-08-10; see
[The trixie migration](#the-trixie-migration).
**Build script (station):** `scripts/build-guests/tiles/decos.sh` — thin overlay + SIMH
build + media staging + three pack preparations + kiosk + checkpoint capture + a
framebuffer-asserted keyboard proof.
**Station dir (host):** `/data/vms/streamhost/stations/decos/`.
**Registry entry:** `registry/stations/decos.json` (slot 126, udp 54126, VMID 229,
ssh hostfwd 127.0.0.1:5829, 768 MB).

## One station, three operating systems

A visitor cannot tell RT-11's `.` from RSX-11M's `>` from RSTS/E's `$`.
Three stations would have read, on the exhibit floor, as one exhibit cloned by
accident. So this is **one** station with a chooser, and the chooser is the
placard:

```
    d i g i t a l   P D P - 1 1              simulated by Open SIMH
================================================================================

    One machine.  Three of the operating systems DEC sold for it.

      1   RT-11 V5.3      single-user real-time monitor   11/73, RL02, prompt .

      2   RSX-11M V4.2    multi-user real-time executive  11/70, RD52, prompt >

      3   RSTS/E V9.6     multi-user timesharing system   11/70, RD54, prompt $
            its installer's last step wants a second "Library" tape that no
            longer exists anywhere, so it stops short: DCL answers, its
            packaged commands were never wired up.

    Press 1, 2 or 3.        Reset returns you to this screen.
```

The `pdp11-add.md` research note warns that the three "cannot share a golden if
the device set differs". That rule is about **QEMU** device sets and `loadvm
golden`; in the bridge shape the QEMU device set belongs to the Debian kiosk and
is byte-identical whatever SIMH happens to be doing. The three systems differ
only in a `.ini` file.

Each choice runs on a **fresh sparse copy** of its pack under `/tmp`, so a
second visit in the same session starts where the first did and the master packs
(mode 444) are never written.

## Versions — and two places where honesty costs something

**The three versions the operator asked for are exactly the ceilings of the
Mentec hobbyist grant** (see below), which is precisely why they are hard to
find: everything the community mirrors is *newer* than the licence allows.

### RSX-11M is **V4.2**, not V4.3

**V4.3 media is not reachable anywhere today.** `simh.trailing-edge.com`,
`www.trailing-edge.com`, `ftp.trailing-edge.com` and `mini-me.trailing-edge.com`
are all offline (Cloudflare 520/522 or a stock Apache page) as of 2026-08-09;
the Wayback CDX index for `ftp.trailing-edge.com` (3 723 URLs enumerated) has
directory listings but essentially no file bodies; bitsavers carries V4.0 and
V4.2 only; retrolib mirrors index pages whose `.bz2` bodies 404.

What **is** reachable and proven end to end is **V4.2 BL38**, and the exhibit
says `RSX-11M V4.2` on its own placard rather than pretending. The obvious
substitute — `rsx11m.com`'s `PiDP11_DU0.zip` — is **RSX-11M-PLUS V4.6**, which
is *outside* the grant ("RSX-11M V4.3 or prior", "RSX-11M-PLUS V3.0 or prior")
and was rejected for that reason.

### RSTS/E V9.6 was the hard one

**Status: it boots, and the installation stops one documented step short.** The
pack is a genuine RSTS/E V9.6 system: `boot rq0` reaches
`RSTS V9.6-11 SYSGEN (DU0) INIT V9.6-11`, timesharing starts, and the console
lands at a working DCL `$` prompt where `SHOW SYSTEM` prints the configuration
and `DIRECTORY [1,2]` lists 43 files / 3 478 blocks of RSX utilities, MACRO,
LINK, LOGIN, DIRECT, SYSTAT and the rest. The monitor build ran to completion
and the installer reported restoring every package it was asked for (`ALL`):
RSX libraries and utilities, RMS-11, PBS, EDT, TECO, HELP, SORT/MERGE,
BASIC-PLUS, the resident libraries.

**Where it stops, and why.** After the last "Restoring …" line the procedure
asks:

```
Please mount the RSTS/E Library media and enter the
name and unit number of the device.
Valid device types are: 'MM', 'MS', 'MT', 'MU', 'DM' or 'DL'

Library device? <_MT0:> 
?Device offline
?Unable to mount media
```

That is a **second, separate tape** — the RSTS/E Library kit — which is not in
the installation kit and which no reachable archive carries. The prompt has no
"skip" answer, so the builder treats **reaching it as the finish line**
(`AUTO … |Library device`). The visible consequences on the exhibit are two:
the system boots `SYSGEN.SIL` rather than the `RSTS.SIL` it built (both are in
`[0,1]`; `SYSGEN` is what INIT loads), and `[0,1]START.COM` is absent, so the
console prints `?File _SY0:[0,1]START.COM not found` before the `$` and the
packaged CCL commands (`BASIC`, `EDT`, `TECO`) answer `?Command not installed`.
DCL's own verbs work.

**The next concrete step**, for whoever picks this up: get INIT to load
`RSTS.SIL` instead of `SYSGEN.SIL`. INIT's `Option:` menu (answer `NO` to
`Start timesharing?`) offers `REFRESH → FILE`, which changes the characteristics
of a file in `[0,1]` and is where the installed-SIL flag lives; `DEFAULT` is
only swap/memory/clock, `DIRECT` is not a valid option, and from DCL neither
`SWITCH RSTS` nor `RUN $SWITCH` exists on this pack. Failing that, the RSTS/E
V9.6 *System Installation and Update Guide* on bitsavers documents the tail of
the procedure, including whatever creates `START.COM`. **Do not** substitute
RSTS/E V10.1: it is outside the Mentec grant.

Two findings from the way in are worth keeping regardless:

- **The install tape does not boot from a TK50 or a TU81.** `boot tq0` produces
  **zero console bytes** on both, on a tape SIMH scans cleanly as TPC (11 850
  records, 175 tape marks). The image is a **nine-track** tape: `set tm enabled`
  + `set tm0 format=tpc` + `boot tm0` brings up
  `RSTS V9.6 (MT0) INIT V9.6-11` and its `Today's date?` prompt first time.
  Every howto on the internet points at `tq`, and at dead URLs besides.
- **RSTS/E V9.6 will not accept a 21st-century date, and rejects INIT's own
  printed example.** Measured on this media: `7-SEP-85` (the string INIT prints
  in its own error message) is refused; `1-JAN-85` refused; `31-DEC-90`
  accepted. The two-digit year is read as 19xx and anything earlier than the
  kit is refused. `9-AUG-26` is therefore not expressible, and the exhibit pins
  the clock at `9-AUG-90 10:00 AM` rather than inventing a hybrid of today's day
  with a made-up year. RT-11 has no clock at all (`DATE` answers
  `?KMON-W-No date`), and RSX-11M gets the **real** date, from `date(1)` on
  labhost, at every boot.

## Media and licence — the Mentec hobbyist grant

The grant ships **inside the RT-11 kit** at `Licenses/pdp11_license.txt`
(5 273 bytes, dated 1997-07-31) and is reproduced verbatim in
[`decos-mentec-license.txt`](decos-mentec-license.txt) — a licence text is not
licensed software, so it may live in the repo. It is transcoded CP1252 → UTF-8
(three curly apostrophes); the bytes are otherwise unchanged.

> MENTEC grants to CUSTOMER a worldwide, non-exclusive, royalty-free license
> under MENTEC's INTELLECTUAL PROPERTY RIGHTS **to use and copy** the SOFTWARE
> TECHNOLOGY **solely for personal, non-commercial uses in conjunction with the
> EMULATOR.**

**"Use and copy" is not "distribute."** Consequences, and they are absolute:

- The bits are **staged on labhost only**, at `/data/assets-staging/decos/`,
  and are **never committed**. Only the URL, the measured sha256 and the size
  are recorded (see `docs/lab/ASSETS-MANIFEST.md`, class **licensed**).
- Nothing is served from the UI webroot and **the station offers no download
  affordance of any kind**. The exhibit is stream-only pixels.
- The recital names **RT-11 V5.3 or prior, RSTS/E V9.6 or prior, RSX-11M V4.3 or
  prior, RSX-11M-PLUS V3.0 or prior**. RSX-11M-PLUS V4.6 and RSTS/E V10.1, the
  two versions the hobbyist community actually circulates, are **outside it**.

The gallery is a private, passkey-gated, single-operator exhibit; only the git
repo is public. That is what makes running this media fine and committing it
not.

| staged archive | contents | size | sha256 (measured on labhost) | source |
|---|---|---|---|---|
| `rtv53swre.tar.Z` | `Disks/rtv53_rl.dsk` (RL02, RT-11 V5.3 distribution) + `Licenses/` | 1 373 083 | `9fdad109…207bc` | `http://simh.trailing-edge.com/kits/rtv53swre.tar.Z` — **host offline**; retrieved through the Wayback raw form (snapshot `20020108101052`) |
| `rsx11m42.zip` | `m42kit.tap` (RSX-11M V4.2 BL38 TK50 kit) + `build.txt` | 6 155 772 | `c8766a53…91ba1` | `https://bitsavers.org/bits/DEC/pdp11/rsx11m/rsx11m42.zip` — live, and re-fetched 2026-08-09 to the same byte count and hash |
| `rsts_v9_6_install.zip` | `rsts_v9_6_install.tap` (RSTS/E V9.6 install tape, TPC) | 8 071 836 | `aaf4aa97…c694f` | `https://ftp.trailing-edge.com/pub/rsts_dists/rsts_v9_6_install.zip` — **host offline**; retrieved through the Wayback raw form |

**Every `trailing-edge.com` host is down** — `simh.`, `www.`, `ftp.` and
`mini-me.` all answer Cloudflare 520/522 or a stock Apache page as of
2026-08-09. They also carry AAAA records while labhost has no working IPv6
egress, so every `curl` at them needs `-4` or it hangs 40 s. Treat all DEC media
as one-shot fetches: stage the bits, never make a builder fetch them at build
time. `decos.sh` reads only `/data/assets-staging/decos/` and dies if it is
missing.

All three blobs are also in the never-evicting media archive
(`/data/media-archive`, `scripts/build-guests/lib/media-cache.sh`) under those
same sha256s — checked 2026-08-10, all three `PRESENT`. So the trixie rebuild
made **no upstream fetch at all**: staged copies in, `sha256sum -c` inside the
guest, archive as the backstop. For two of these three the origin no longer
exists, which is the entire argument for that archive.

## SIMH is built into the overlay

The bridge seed ships VICE, cap32 and LinApple — not SIMH. So,
following the **`amiga.sh` precedent**, `decos.sh` builds **Open SIMH pinned at
commit `a1f57fa3738ed31148d31126ba1a7278ff845c6d`** (2026-07-03 master; there is
no v4 release tag past v4.0-Beta-1, hence the commit pin) *into this station's
overlay*:

```
git init; git remote add origin https://github.com/open-simh/simh.git
git fetch --depth 1 origin a1f57fa3…; git checkout FETCH_HEAD
make pdp11 -j2          # 90 s in the guest; ONE 2.8 MB binary serves all three
install -m 755 BIN/pdp11 /usr/local/bin/pdp11
```

**No `apt` runs at all**: gcc, make, git, pkg-config, `libsdl2-dev`,
`zlib1g-dev`, `libpng-dev` and `libpcre2-dev` are already in the frozen base
because it builds VICE from source there. The makefile auto-detects SDL2 and
compiles `-DUSE_DISPLAY -DHAVE_LIBSDL -DUSE_SIM_VIDEO`; the builder asserts that
by asking the **binary** (`ldd … | grep libSDL2`), not the build log — a no-op
`make` truncates the log to "Nothing to be done" and a grep for `USE_DISPLAY`
then fails on a perfectly good build.

**Do not reach for a packaged `simh`.** On bookworm it was 3.8.1 and built
without SDL video; on trixie the question does not even arise — `apt-cache
policy simh` returns **no candidate at all** on a `main contrib
non-free-firmware` trixie (checked 2026-08-10 on the host, where `vice
3.9+dfsg-1` from contrib does resolve, so the components are not the reason).
The source pin is the only route, on either suite.

For a from-scratch NVMe rebuild, `bridge-base.sh` should capture SIMH in; the
addition is in the build report for this station. `libpcap-dev` is **optional**
(SIMH falls back to TAP + its bundled SLiRP, which is enough for 2.11BSD
networking) and `libvdeplug-dev` is not needed.

## The trixie migration

Migrated **2026-08-10** from the frozen bookworm base onto
`/data/vms/bridge/bridge-base-trixie.qcow2`, in wave 1 of
[`docs/lab/BRIDGE-TRIXIE-MIGRATION.md`](../lab/BRIDGE-TRIXIE-MIGRATION.md). The
overlay was rebuilt from scratch, all three packs re-prepared, the checkpoint recaptured
and `loadvm`-verified, and the chooser re-accepted on a real `labctl shot`. The
**BEFORE and AFTER frames are 0 differing pixels** of 1024×768 — identical PNG
md5 — so the exhibit a visitor sees is unchanged.

**This was the station's first from-scratch build, ever**, and that is not a turn of
phrase. Since the station landed, `install_kiosk` ran one
`install -m 644 a b c /opt/decos/ini/`, which keeps each source's *basename*: the
files arrived as `decos-rt11.ini` while `prep_rt11` and the chooser both read
`rt11.ini`. Nothing in the station could ever have found them. The step carried no
`|| die` and logged "three .ini files installed" unconditionally, so it reported
success while installing nothing usable — for months. The live exhibit worked
only because the real files had been hand-placed during bring-up and were still
sitting in the overlay. The migration was simply the first build to try it from
zero, and it died at `sed: can't read /opt/decos/ini/rt11.ini`. See `73795a5`:
the three files are now committed assets under
`scripts/build-guests/assets/decos/`, installed one explicit destination at a
time, behind a post-condition that asserts all three are non-empty in the
overlay.

The trixie build itself was uneventful, which is the point:

| Step | Result on trixie |
|---|---|
| Open SIMH pin `a1f57fa3` | builds and installs in the overlay under **gcc 14.2.0**, still linking `libSDL2` (`ldd` asserted, not inferred from the log) |
| RT-11 V5.3 pack | prepared, boots straight to `.` |
| RSX-11M V4.2 BL38 pack | restored and boot-verified to MCR |
| RSTS/E V9.6 pack | installed in **~6 min**, against the ~45 min this doc records for the original bookworm build |
| checkpoint | captured at the chooser, `loadvm`-verified, no simulator running |
| keyboard proof | pressing `1` booted RT-11 under SIMH, then `loadvm golden` returned to the bare chooser |

That last row is the strongest statement about the `.ini` fix, because it
exercises `rt11.ini` at **runtime** through the chooser rather than asserting a
file exists. Presence was then confirmed separately, from **inside the running
station** over its production hostfwd rather than from the builder's own log:

```
$ ssh -p 5829 root@127.0.0.1 'sha256sum /opt/decos/ini/*.ini'
db40a858…71740  /opt/decos/ini/rt11.ini     876 B
2f82677a…ab8ee  /opt/decos/ini/rsx.ini      924 B
585ac1d4…cc077  /opt/decos/ini/rsts.ini     751 B
```

— byte-identical to `scripts/build-guests/assets/decos/{rt11,rsx,rsts}.ini`, at
the names the chooser actually reads, with all three packs present beside them
(`rt11.dsk` 10 MB, `rsx.dsk` 31 MB, `rsts.dsk` 159 MB). `/etc/bridge/suite`
reports `trixie` and the guest is `Debian GNU/Linux 13 (trixie)`.

## CPU cost, and the one place `set cpu idle` does not work

| state | host cost |
|---|---|
| checkpoint, nobody watching (**no simulator running**) | 0 |
| RSX-11M V4.2 idle at `>` | 0.7–4 % of a guest vCPU |
| RT-11 idle at `.`, `set cpu idle` only | **99 %** |
| RT-11 idle at `.`, `set throttle 1000K` | 14 % |

SIMH's PDP-11 idle detection fires on the `WAIT` instruction, and its own help
says so outright: *"This will work for RSTS/E and RSX-11M+, but not for RT-11 or
UNIX."* RT-11's keyboard monitor spins. `set throttle 1000K` is the fix and is
not a compromise — a real 11/73 (J-11 at 15 MHz) executed on the order of a
million instructions a second, so the throttled simulator is *closer* to the
exhibited machine than a free-running one.

Related, and paid for twice: **SIMH catches `SIGTERM`**, stops the simulated CPU
and then keeps spinning at 100 %. A `pkill -x pdp11` leaves a busy orphan
(measured: one sat at 100 % for 100 s across an X restart). The kiosk launcher
reaps with `-KILL` before starting xterm.

## Device set, launcher and window fitting

Identical in shape to its kiosk siblings — see
`streamhost/stations/decos/qemu-streamhost.sh`. **768 MB** is the station's memory and
it is ample: the whole exhibit is one xterm plus at most one SIMH process whose
largest configured PDP-11 has 4 MB of core (measured guest RSS 17–82 MB per
simulator, guest total 708 MB with ~415 MB free at the chooser).

The kiosk launcher is:

```
xterm -class DECOS -geometry 80x31+0+0 -fa "DejaVu Sans Mono" -fs 15 \
      -fg '#33ff55' -bg '#000000' +sb -e /opt/decos/chooser.sh
```

on a 1024×768 X root. There is **no window manager** in the bridge seed, so
`-fullscreen` (which needs an EWMH manager to honour it) is not used; the
terminal is sized by `-geometry`. Font size 15 measures **80 columns = x 3…962**
of 1024; size 16 would want 1040 px and clip column 80. That measurement is also
the station's readiness predicate — see below.

The kiosk profile starts X with `-nocursor`: this is a keyboard-only exhibit and
without it the xterm I-beam sits in the middle of the captured framebuffer
forever.

## Keyboard pacing

**No `SH_KEY_MIN_HOLD_MS` / `SH_KEY_MIN_GAP_MS`.** The frame-sampling trap of
playbook §5.1 is an *emulator-frame* problem: MAME and VICE sample the key matrix
once per emulated frame. SIMH has no such loop — its console is a byte stream —
and that was measured, not assumed: a 69-character line written to the console
at a **0 ms** inter-character gap echoed and executed intact, 5 trials out of 5.
What remains is the ordinary QEMU PS/2 → X → xterm path that `alpine`,
`tinycore` and `haiku` already run unpaced, and the exhibit's own input
requirement is **one digit**.

The station does run the **`vic20`/`plus4` canary binary**
(`streamhost-bca88a2b…`), but not for pacing: the promoted fleet binary
(`streamhost-d2652847…`) panics on `SH_INPUT_BACKEND=disabled`
(*invalid SH_INPUT_BACKEND="disabled"; expected dbus-abs|dbus-rel|…*), and this
station's QEMU device set carries no pointing device at all, so naming a dbus
pointer backend the way `c64` does would be a fiction.

## How each system is prepared

| system | preparation | time |
|---|---|---|
| **RT-11 V5.3** | Boot the distribution RL02, answer `NO` to "automatic installation procedure"; DEC's own dialogue then writes the `RT11FB` bootstrap onto the pack, and it boots straight to `.` ever after. **Byte-deterministic** — sha256 `f0521c21…` produced identically on the host and in the guest. | ~20 s |
| **RSX-11M V4.2** | Two-stage restore off the TK50 kit: the tape boots DEC's *Standalone Copy System*, which is told `MU:` → `DU:` and then runs `BRU /REW MU: DU:` onto a fresh RD52. A second run proves the result boots to `RSX-11M V4.2 BL38 124.K MAPPED` and an MCR `>`. | ~30 s |
| **RSTS/E V9.6** | INIT.SYS off the **nine-track** tape (`boot tm0`), `DSKINT` an RD54 (pack `RSTS96`, patterns 0, erase NO), copy the system, reboot from the pack, then DEC's own installation procedure, ending at `Library device?`. Password for `[1,2]` is `SYSTEM` (`credentialsRef: guest/decos`). | ~45 min |

All three are driven at build time by a **forkpty driver** embedded in
`decos.sh`, not by SIMH's `EXPECT`/`SEND`: EXPECT did not fire against the
2.11BSD boot prompt during recon, and a pty is the same byte stream the console
sees. (At *run* time the shipped `.ini` files do use `EXPECT`/`SEND`, which
works fine against the RSX and RSTS boot prompts.) Two driver details worth
keeping:

- SIMH's console emits **LF-then-CR** with `0x7f` padding, not CRLF. Expect-style
  regexes written `\r\n` never match.
- The RSTS/E installation asks about sixty questions whose defaults are the
  documented path, so the driver has an `AUTO` mode that answers a prompt with
  its bracketed default unless an `OVERRIDE` matches. `AUTO` matches overrides
  against the **prompt line only** — matching the whole tail kept
  `Use template monitor?` matching after the dialogue had moved on to
  `Template monitor's name?`, and the installer looped forever while the driver
  cheerfully reported progress. It now aborts after six identical answers.

## Verification (2026-08-09 bookworm, re-run 2026-08-10 on trixie)

Evidence in `/data/vms/streamhost/stations/decos/evidence/`. **The trixie rebuild
regenerated five of these eight** (`cold-boot-chooser`, `ready-before-golden`,
`golden-restored`, `keyboard-1-rt11`, `golden-restored-after-keyboard`); the
other three still date from the 2026-08-09 bookworm build, because the builder's
automated proof only presses `1`. Pressing `2` and `3` was therefore re-done by
hand on the migrated station — see the table below the artifact list.

| Artifact | Shows |
|---|---|
| `cold-boot-chooser.png` | the chooser after a genuine cold boot with the quiet console in force |
| `ready-before-golden.png` | the frame that was captured — the chooser, no simulator running |
| `keyboard-1-rt11.png` | pressing `1` through QMP `input-send-event`: RT-11FB V05.03 and a `.` prompt |
| `keyboard-3-rsts.png` | pressing `3`: RSTS/E V9.6 booting to timesharing and a DCL `$` |
| `golden-restored-after-rsts.png` | reset from inside RSTS/E, back at the chooser with no simulator running |
| `golden-restored.png` | `loadvm golden` returning to the captured chooser |
| `golden-restored-after-keyboard.png` | the same, after the keyboard proof, with no simulator left running |
| `live-tile-chooser.png` | the chooser as the **live `streamhost@decos`** station serves it |

Each chooser frame is asserted, not eyeballed: `pnmcrop -black -verbose` reports
the bounding box of everything lit and the 80-column rule must span
`x = 3…962`. A bare X root, a dead xterm, a font one size too large and a
half-drawn screen all fail it. The keyboard proof additionally requires that a
`pdp11` process exists afterwards and that the frame is no longer byte-identical
to the captured chooser, and that after `loadvm golden` **no** simulator is
running.

### All three chooser entries, re-driven on trixie (2026-08-10)

The builder only presses `1`, so the other two were driven by hand on the
migrated station through `labctl key`, each from a fresh `labctl reset`:

| Key | What the framebuffer showed |
|---|---|
| `1` | RT-11FB and a `.` prompt (the builder's own automated proof) |
| `2` | `RSX-11M V4.2 BL38  124.K MAPPED` and an MCR `>` prompt, with **both** `expect` lines in `rsx.ini` firing — `@RSXDATE@` substituted to the real clock (`TIM 12:45 10-AUG-26`) and the terminal width answered `80.` |
| `3` | `RSTS V9.6-11 SYSGEN (DU0) INIT V9.6-11`, all three `expect` lines answered (`9-AUG-90`, `10:00 AM`, start timesharing), ending at `?File _SY0:[0,1]START.COM not found` and a DCL `$` — the documented missing-Library-tape end state, unchanged from bookworm |

Every one of those frames also carries `Open SIMH V4.1-0 Current  git commit id:
a1f57fa3` in its banner, so the pin is legible on the exhibit itself. After the
last of them, `labctl reset` returned the station to a chooser **byte-identical**
to the pre-migration one (same PNG md5), with no simulator running — which is
both the reset contract and the proof that driving the exhibit cannot leak into
its checkpoint.

## Cold boot and rollback

The checkpoint is the chooser, and a cold boot reaches the same chooser, so a clip's
last frame would hand off to the checkpoint's first frame cleanly. See
`scripts/coldboot/decos-zero-input-prep.md`.

To withdraw the station: `systemctl stop streamhost@decos`, set `enabled: false`,
regenerate, republish the three runtime documents (tiles.json, gallery-manifest.json AND golden-manifest.json — the third is the reset allow-list). To rebuild:
`scripts/build-guests/tiles/decos.sh --force`, which replaces `overlay.qcow2` and so
**destroys the checkpoint and all three prepared packs inside it**. Note that a
plain re-run **deletes the existing checkpoint first**, deliberately: a
`-loadvm` boot restores the snapshot's *disk* as well as its RAM, so a re-run
that skipped that step would install new kiosk files, silently revert them, and
capture the old scene again while reporting PASS. That was measured, once.

Credentials reference only (never values): `guest/decos`.
