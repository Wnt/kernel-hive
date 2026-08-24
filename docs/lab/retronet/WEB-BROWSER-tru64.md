# tru64 retronet web browser — Netscape Communicator 4.76, made discoverable

**Status: LIVE — applied to the Gaim-fixed tru64 golden and re-baked
(2026-08-23).** The idempotent installer is
[`streamhost/stations/tru64/install-webbrowser.sh`](../../../streamhost/stations/tru64/install-webbrowser.sh).
It was run in-guest as root over the live serial exec channel and the es40
checkpoint re-baked; the restored station now shows a CDE Front-Panel "Web" icon
whose action launches Netscape 4.76 on the corpus, with the Gaim ICQ desktop
(grey chrome, HiveBot online, SSI roster by name) intact. See
[Applying to the golden](#applying-to-the-golden) for the as-run record.

## The browser, and why

**Netscape Communicator 4.76** — the period-correct browser for Tru64 UNIX 5.x
on Alpha. It **ships in the base Tru64 UNIX 5.1B install** at
`/usr/bin/X11/netscape` (`-> netscape4`), runs at the exhibit's TrueColor
1280×1024, and speaks plain **HTTP/1.0 with no TLS** — exactly what the retronet
corpus proxy serves on `:80`. Cross-checks: `hpuxvue` runs Netscape 4.76 too,
the tru64 install history already wired it ([`docs/guests/tru64.md`](../../guests/tru64.md)
"The browser"), and [`docs/catalog/software-catalog.md`](../../catalog/software-catalog.md)
independently names Communicator 4.x "the definitive late-90s web tile".

Rejected alternatives: **Netscape 6** (`/usr/opt/netscape6`) starts, burns CPU
and never maps a window on this box — do not chase it. **Lynx 2.8.9** (built
in-guest, `/usr/local/bin/lynx`) stays as the text fallback. No binary is
installed by this work — Netscape is already present; the script makes the
installed browser **discoverable** and points it at the **corpus**.

## What the script does (idempotent)

Run it **inside the Tru64 guest, as root** (`#!/bin/sh`, re-execs under `/bin/ksh`
because Tru64's `/bin/sh` lacks `$(...)`). Every step is re-runnable:

1. **Verify Netscape** at `/usr/bin/X11/netscape` (if absent, prints the exact
   `setld` recipe to install it from the OS CD at DKA400, then exits non-zero).
2. **Point it at the corpus.** Rewrites `/usr/local/bin/webbrowser` to default to
   `$RN_HOME`, and sets the CDE user's `~/.netscape/preferences.js`:
   `browser.startup.homepage=$RN_HOME`, `browser.startup.page=1` (open at home),
   `network.proxy.type=0` (direct — the seamless DNS route needs no proxy).
3. **Discoverable launcher, three ways:**
   - a labelled **"Web" icon on the MAIN CDE Front-Panel row** —
     `/etc/dt/appconfig/types/C/RetronetWeb.fp` overrides the `Top`-box spacer
     `Blank1` (position 6) with `ICON Netscape`, `PUSH_ACTION RetronetWeb`, so it
     sits among the standard icons instead of buried in a subpanel;
   - a **"Web Browser (Netscape)" entry on the dtwm Workspace (root) menu** —
     `/etc/dt/config/C/sys.dtwmrc` (regenerated from the system default each run,
     so re-running never double-inserts);
   - the stock Personal-Applications subpanel Netscape control is left in place.
   - The action `/etc/dt/appconfig/types/C/RetronetWeb.dt` runs the wrapper.
4. **Clear stale Netscape locks** (`~/.netscape/lock`) left by the pre-retronet
   internet config (a `lock -> 172.31.66.2:<pid>` symlink makes Netscape think it
   is already running).

**Knobs (env):** `RN_HOME` (default `http://search.retronet/` — the
AltaVista/Yahoo-style corpus portal the gateway serves; any corpus site works),
`RN_USER` (default `guest`, the CDE autologin user).

The launcher only appears after the CDE session/panel reloads — restart the
workspace manager, or `/sbin/init.d/xlogin stop && start`, or (the exhibit path)
re-bake the checkpoint from a session started after the script ran.

## Media provenance

Netscape 4.76 is a subset of the **Tru64 UNIX 5.1B Operating System CD** —
the exhibit already runs it, so no separate binary is fetched or committed.

| item | value |
|---|---|
| Medium | Tru64 UNIX 5.1B Operating System CD, ISO 9660 volume `V5.1Br2650_O1` |
| sha256 | `9d1cbf8c50d6d5d94a2790f52334a0967ee60aa939a08a71b723ecdaf780d96c` |
| Size | 676 808 704 bytes |
| Source | Internet Archive item [`tru-64-unix-5.1-b`](https://archive.org/details/tru-64-unix-5.1-b) |
| Staged | `/data/assets-staging/tru64/tru64-os-5.1B.iso` + content-addressed `/data/media-archive/blobs/9d/9d1cbf8c…` |
| Class | contested-commercial (HPE) — private preservation exhibit; **never commit the bits** |

The OS CD is also attached to the running guest at **DKA400**, so a golden that
somehow lacks Netscape can `setld` it in place (step 1 prints the recipe).

## Corpus connectivity (already in place on the retronet golden)

The retronet-finalized tru64 golden already has: DHCP `10.99.0.15`, resolver
`nameserver 10.99.0.2` + `hosts=local,bind`, **no default route**. Every name
resolves to the gateway (`retronet-dns` wildcard) → `:80` origin (`proxy.py`) →
corpus by `Host`. **Netscape needs no proxy** — the seamless DNS route renders
`http://search.retronet/` and any corpus site directly. See
[`WEB-PROXY.md`](WEB-PROXY.md).

## Sandbox proof (2026-08-23)

Proven on an **isolated** clone — reflink of `checkpoint.bak-pregaim-20260822`
under `/data/vms/sandbox/tru64-web-browser/`, es40 restored headless with a
**unique pcap adapter + serial ports** (never `vmbr-rn`, never the live
`tru64-g`/serial pair), on a private **netns `t64web`** whose `10.99.0.2` runs the
shipped `dns.py`/`proxy.py`/`search.py` over a small real corpus copy. Framebuffer
(`shmshot.py`), verified:

- the **"Web" (Netscape N) icon on the main front panel** (not a subpanel);
- the icon's action (`dtaction RetronetWeb`, identical to the panel `PUSH_ACTION`)
  launches Netscape 4.76 at `http://search.retronet/` — the AltaVista-style
  corpus portal — "Document: Done";
- Netscape renders a mirrored corpus **site**, `http://spacejam.com/` (the 1996
  Space Jam starfield home, images and all).

Harness note: a synthesized **mouse click** on the Motif front-panel control is
unreliable via the open-loop absolute pointer (keyboard/`dtaction` are the drive
channels here — see [`docs/guests/tru64.md`](../../guests/tru64.md) "Pointer").
A real visitor's mouse click fires the standard CDE `PUSH_ACTION`; the identical
action was proven via `dtaction`.

## Applying to the golden — as run (2026-08-23)

**`checkpoint-guard` does not cover tru64.** It guards QEMU vmstate stations only.
tru64's checkpoint is an es40 `.axp` savestate paired with a disk image frozen in
the same `SIGSTOP` window — not a QMP snapshot — and this binary does not implement
`SAVEST` at all, so the bake goes through the emulator's **serial menu**:
[`docs/guests/tru64.md` § Checkpoint restore](../../guests/tru64.md#checkpoint-restore).
Do not run the guard here; it refuses, loudly, by design
([`checkpoint-guard.md`](../checkpoint-guard.md)).

Applied to the **Gaim-fixed / black-chrome-fixed** live golden (a coordinated
follow-up after the two prior tru64 agents). The re-bake **is** the deploy — the
checkpoint is a box asset — so **no `box-deploy --apply`** was run (the box was
behind with live win95/winxp/hpuxvue/os2warp onboarding edits; a full apply
would clobber them). Exact sequence on the LIVE es40 station:

1. **Back up the checkpoint first** — byte-copy + SHA256 to
   `assets/tru64/checkpoint.bak-prebrowser-20260823/` (verified identical to the
   pre-browser golden: `tru64.axp`
   `622b9383e60d9c2d5be1e69b42669cf29422b8e16230b7658e78dea360304582`, `tru64.img`
   `d31d820048d283199b39aa662613be249fd7c8f9320ba646d4331d2bc69bb41b`).
2. `SH_IDLE_PAUSE_SECS=0` in the live `station.env`, `systemctl restart` for a
   clean running guest that cannot freeze mid-work.
3. **Deliver over the CT, not labhost.** The guard chain drops guest→labhost, so
   `pct push` the script to the gateway CT `951` and serve it there
   (`python3 -m http.server 8099` on `10.99.0.2`), then in-guest
   `/usr/local/bin/httpfetch 10.99.0.2 /install-webbrowser.sh /tmp/x 8099` and
   `RN_HOME=http://search.retronet/ /bin/ksh /tmp/x` as root over the serial
   exec channel.
4. **Surface the Front-Panel icon** — dtwm only reads `RetronetWeb.fp` /
   `sys.dtwmrc` at start, so the panel must be reloaded. A full `xlogin`
   stop/start works but is the CDE **cold-login** path: it re-runs the fixture
   **and** CDE session-restore, which brings back a *second* gaim plus stale
   `climm`/`dxconsole` windows from an older saved session. The golden's correct
   state is **exactly one `gaim` + one `cmaphold`** (the fixture's), so kill the
   duplicates/leftovers and relaunch the fixture once, as `guest`, with
   `HOME=/home/guest DISPLAY=:0 XAUTHORITY=/home/guest/.Xauthority`
   (`su guest -c` sets neither HOME nor DISPLAY — both must be explicit).
5. **Prove it on the framebuffer** — Web icon on the main panel;
   `dtaction RetronetWeb` (identical to the panel `PUSH_ACTION`) launches Netscape
   4.76 at `http://search.retronet/` ("Document: Done"); Gaim chrome still grey,
   64000 online, roster by name.
   - **TRAP: never drive Netscape/`dtaction` over the serial exec channel.**
     `dtaction` blocks on the long-lived browser and wedges the fire-and-forget
     relay (`tru64exec: could not reach a shell`). Recovery: connect to the LIVE
     `serial-exec.sock` as an ordinary client and send Ctrl-C (`\x03`) — the tty
     line discipline delivers SIGINT even to a blocked shell — then log out so the
     getty returns to a clean `login:`. (Do NOT run a sandbox `pumps.py` at it.)
6. Close Netscape (ship a clean Gaim desktop + a discoverable icon, not a stale
   browser window), delete any stray default routes, then **re-bake**: a
   `Restart=no` systemd drop-in + `daemon-reload`, IAC BREAK (`\xff\xf3`) into
   `serial-exec.sock` → menu option **5** (save-and-exit), stage
   `work/{autosave.axp,img/tru64.img,rom/}` into `checkpoint/` (temp-name + `mv`),
   remove the drop-in, `SH_IDLE_PAUSE_SECS=60`, `systemctl restart`.

**New golden (LIVE):** `tru64.axp`
`030b726af4a644198741e16d9f1d1ee87fdd5827dd692508d46a6855f7debe2d` (274 641 799
bytes), `tru64.img`
`14730c97986a585ce2e09b267bc84f7853a2ee70c5e35611adebcc6c2de4dab1`.
Instant restore re-verified: Web icon present, Gaim chrome grey, 64000 online
with the SSI roster, HiveBot re-greets on wake.

**Rollback:** `systemctl stop streamhost@tru64`, copy
`checkpoint.bak-prebrowser-20260823/{tru64.axp,tru64.img,rom}` over
`checkpoint/`, `systemctl start`. (Finer rollback of just the launcher bits:
remove `/etc/dt/appconfig/types/C/RetronetWeb.{dt,fp}` and
`/etc/dt/config/C/sys.dtwmrc`, restore the previous `webbrowser` /
`preferences.js`, reload the panel — but the checkpoint backup is the whole
rollback.)
