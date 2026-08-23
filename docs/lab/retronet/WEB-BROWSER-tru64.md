# tru64 retronet web browser — Netscape Communicator 4.76, made discoverable

**Status: script written + proven on a sandbox clone (2026-08-23); NOT yet
applied to the live golden.** The idempotent installer is
[`streamhost/stations/tru64/install-webbrowser.sh`](../../../streamhost/stations/tru64/install-webbrowser.sh).
It is a coordinated follow-up: apply it to the **Gaim-fixed** tru64 golden, then
re-bake the checkpoint (see [Applying to the golden](#applying-to-the-golden)).

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

## Applying to the golden

A coordinated follow-up **after the Gaim fix lands** (that agent owns the live
station + golden — this work touched neither). On the live/golden guest:

1. deliver + run the script (exec channel or in-guest `httpfetch`), as root:
   `RN_HOME=http://search.retronet/ /bin/ksh install-webbrowser.sh`;
2. arrange the scene (open Netscape at the corpus home if the checkpoint should
   ship with a browser window), then **re-bake the checkpoint** from a session
   started after the script ran (the standard es40 serial-menu save-and-exit —
   [`docs/guests/tru64.md`](../../guests/tru64.md) "Checkpoint restore");
3. `box-deploy` + restart the station; acceptance = the Web icon on the restored
   panel and Netscape rendering the corpus.

Rollback: remove `/etc/dt/appconfig/types/C/RetronetWeb.{dt,fp}` and
`/etc/dt/config/C/sys.dtwmrc`, restore the previous `webbrowser`/`preferences.js`,
reload the panel.
