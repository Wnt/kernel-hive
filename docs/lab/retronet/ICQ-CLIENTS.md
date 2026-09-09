# ICQ clients that work on the retronet, by era

**Pick the client from this table before you spend an agent looking for one.**
Every row was installed, signed in and framebuffer-proven on a real station; the
"how it got in" column is the whole procurement answer, and the "reconnect after
restore" column is the one that decides whether the exhibit actually works.

The server is the retronet gateway in CT 951 (10.99.0.2, [`GATEWAY.md`](GATEWAY.md)).
It serves **three doors**, and which one a client uses is a property of the
client's age, not a preference:

| Door | Protocol | Who uses it |
|---|---|---|
| `10.99.0.2:5190` TCP | **OSCAR** (FLAP/SNAC/TLV) — the modern one, with a server-side SSI/feedbag roster | Gaim, Kopete, mICQ 0.4.12, climm, ICQ 2000b/2001b |
| `10.99.0.2:4000` UDP | **pre-OSCAR Mirabilis v5** | micq 0.4.3, GnomeICU 0.90b, os2warp |
| `10.99.0.2:4000` UDP | **v4 direct flow** | GtkICQ 0.60 |

**OSCAR cannot traverse slirp.** That is the gating fact of this whole plane and
it is why every ICQ station has a bridged tap on `vmbr-rn`
([`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md); the tap is rendered by
`scripts/retronet/rn-onboard.sh`). The legacy v4/v5 UDP door is reachable **only**
from a bridged station too.

## The matrix

| Client | Station(s) | Toolkit / era | Door | How it got in | Contact list | Reconnect after `loadvm` restore |
|---|---|---|---|---|---|---|
| **Gaim 1.0.0** | `ubuntu` 4.10 | GTK2, 2004 | OSCAR | Warty's own archive | **server-side SSI** — HiveBot by name, nothing added by hand | **signs off at ~80 s with a dialog.** Being fixed with the autorecon plugin |
| **Gaim 0.59.9** | `redhat62`, `tru64`, `irix` | GTK+1.2, March 2003 — the LAST GTK1 release | OSCAR | built from source in the guest, + `streamhost/stations/tru64/gaim-0.59.9-icq-ssi.patch` | **server-side SSI** | **reconnects at ~3 min** on the core autorecon path |
| **mICQ 0.4.12** | `netbsd14` | plain C over libc, no GUI toolkit at all | OSCAR (`type icq8`) | built from source; `build-im.sh` pins URL + sha256 | client-local `micqrc` `[Contacts]`; SSI seeded anyway for what OTHERS see | **reconnects by itself, ~70 s** (`Scheduling v8 reconnect in 10 seconds`). No watchdog needed |
| **micq 0.4.3** | `slackware` 3.4 | libc5, C89, December 1999 | **v5 UDP** | built INSIDE the guest by its own `gcc 2.7.2.3` | client-local `~/.micqrc`, written by `compose.sh` from `roster.json` — a roster change needs a compose + re-bake, not a seeder run | **exits on disconnect**, so `/usr/local/bin/icq-session` (an exit-driven `until` loop) re-logs in within ~1 min |
| **GtkICQ 0.60** | `suse64` | GTK+1.2 | **v4 direct flow** | SuSE 6.4 **CD2** `suse/xap1/gtkicq.rpm` — the only IM package on either CD | client-local, and only addable through *Add Contact* | **never re-logs in, and LIES about it** — see §The frame is not the proof. Needs an in-guest restart wrapper |
| **GnomeICU 0.90b** | `debian22` | GNOME 1.0 panel applet | **v5 UDP** | potato **CD1** `main/net/gnomeicu_0.90b-1.deb` | client-local, and **Add-Contact segfaults** on the UIN search — HiveBot is still not listed | unproven |
| **Kopete 0.12.7** | `pcbsd` | KDE 3.5 | OSCAR | `kdenetwork-kopete-0.12.7`, already on the PC-BSD media | server-side SSI | unproven |
| **Kopete 0.9.1** | `freebsd411` | KDE 3.3 | OSCAR | `kdenetwork-3.3.2` from the 4.11 package archive (not on `disc1-kde`) | server-side SSI (`ssi-seed` already run) | **OPEN — it has never opened a socket to the gateway at all.** Start the next pass with a capture on the tap, not more UI |
| **ICQ 2000b / 2001b** | `win98se`, `win2000`, `nt4`, `win95` | Win32 | OSCAR | the sourced Windows installer | **client-local, in a proprietary per-UIN binary DB** — seeded by driving the client's own Add-Contact flow (`CONTACT-SEEDER.md`) | see `ICQ-STATION.md` |
| **climm 0.6.4** | `solaris` | curses | OSCAR | built from source (`/usr/sfw/bin/gcc` 3.4.3) | dotfiles | unproven |
| **ICBM** | `beos` | BeOS native | pre-OSCAR | shipped with the guest | client-local | **no auto-reconnect** (the gap micq 0.4.3 also has) |
| **Netscape AIM 1.0.414** | `win311` | Win16 | **AIM, not ICQ** | bundled with Netscape | via `retronet-aim-bridge` | `ICQ-STATION-win311.md` |

Two clients are proven NOT to fit and are recorded so nobody re-tries them:
potato's own `gaim` is 0.9/0.10, far older than the 0.59.9 that builds cleanly;
and a GTK+1.2 client has nothing to link against on NetBSD 1.4.1 (XFree86 3.3,
no GTK anywhere), which is why that station took mICQ.

## The frame is not the proof — a restored client lies

The same lie appears without any restore: an idle-paused station sends no
keepalives, the gateway reaps its session, the client keeps its green icon, and
on wake it must re-login (debian22's GnomeICU did so unaided in ~2 min; a
client without a reconnect path needs the wrapper below). Proof after a wake is
the same journal line.

**Every visitor arrives through `loadvm golden`, not a cold boot.** A restored
vmstate carries a TCP socket the gateway forgot hours ago, so "signed in when we
baked it" says nothing about "signed in when a visitor looks at it". This has
already produced a false pass on a real station: after a reset, `suse64`'s
GtkICQ showed its contact list **Online** while CT 951 answered every packet from
it with `unknown session, NOT_CONNECTED`. The client was painting the last state
it knew.

**The proof is two things together**, and neither alone counts:

1. a **NEW** `login successful uin=<uin>` (or `user authenticated successfully`)
   line in CT 951's `retronet-oscar` journal, dated **after** the reset, and
2. a framebuffer frame showing the client signed in with HiveBot listed.

`rn-verify.sh` gates the first half for you:

```sh
ssh lab 'labctl reset <id>'
python3 scripts/dev/fb-wait.py --settle …        # awake; then ~90 s for the redial
ssh lab '/data/kernel-hive/scripts/retronet/rn-verify.sh --since "@<reset epoch>" <id>'
ssh lab 'labctl shot <id>'
```

A client that fails this is not a footnote — it is a station that shows visitors
a signed-out IM window. The three fixes, in order of preference: the client's own
auto-reconnect (mICQ 0.4.12, Gaim 0.59.9's autorecon), a plugin or option that
turns it on (Gaim 1.0), or a guest-side wrapper that restarts the client when it
exits or wedges (`icq-session` on slackware; GtkICQ needs one and does not have
one yet).

## The account, server-side

`rn-onboard.sh --apply` runs all four, in this order:

```sh
rn-tool.py user-set <uin> <pass>     # 6-8 chars, [a-z0-9] — the gateway rejects longer
rn-tool.py user-open <uin>           # NOT optional: without it the account refuses
                                     # unattended contacts and HiveBot cannot add it back
rn-tool.py nick <uin> <station>      # the ICQ directory nickname, which is where a
                                     # client gets a NAME instead of a number
rn-tool.py ssi-seed <uin> 10000=HiveBot
```

The password lands in the BOX-side `registry/local.env` as
`RETRONET_ICQ_<ID>_PASS`. The fleet-wide cross-list
(`seed_contacts.py ssi --apply`) is a **single run by the coordinator at the
end**, gated on `onboarded: true` in `roster.json` — which means "a frame shows
this client signed in", not "the account exists".

**A v4/v5 client is not SSI-aware**, so `ssi-seed` does nothing for micq 0.4.3,
GnomeICU or GtkICQ: what the seeder writes is what the OSCAR stations see of
them, not what they see. Their own contact list is a guest-side file and changes
to it need a compose and a golden re-bake.

## Driving a client that has no config file

Half the clients above are configured only through their own GUI. The technique
below is the one that works on every station that has an X server, and it was
independently re-derived by three waves before it was written down.

**Motion and button come from two different channels.** The rig's QMP PS/2
pointer is *relative* and cannot be positioned: a click aimed at a dialog field
lands on the root window and takes focus off the dialog.

```sh
python3 scripts/dev/x11ptr.py 127.0.0.1 <the rig's X forward port> X,Y q
# then a button-only QMP input-send-event: btn left, down then up, NO motion
```

`XWarpPointer` with `dst-window = root` makes the coordinates absolute,
`XQueryPointer` reads them back, and the button then lands wherever X thinks the
pointer is. The framebuffer is the coordinate space 1:1, so coordinates are read
straight off a PNG. Every menu click in the pcbsd, suse64 and freebsd411 waves
was made this way, first try.

Four traps around it:

- **`-display dbus,p2p=on` (the shipping backend) swallows a button-only QMP
  event.** The keyboard is unaffected. So on a rig that must match the shipping
  backend, drive dialogs with keys and keep `-display none` for the windows where
  you need to click.
- **X's root cursor parks at screen centre after `startx`** and will fool a
  pixel-diff pointer proof. Move it to a corner first and prove two targets.
- **`qmp-type.py` decodes `\n` and `\t` by contract**, so a typed
  `printf 'a\nb'` or a typed heredoc lands as ONE line — which is how three
  stations got a broken `kopeterc`, autostart file and desktop launcher. Write
  multi-line files as `sh -c '{ echo l1; echo l2; } > f'`, or pass `--raw`.
- **A station with no viewer idle-pauses after ~2 min**, and a paused QEMU
  answers no TCP — the guest's X server "stops working". Hold a wake lease or
  keep an `/os/<id>` view open.

Two client-specific wizard facts worth carrying across:

- **KWallet drops the password if you cancel it.** Kopete ignores
  `kwalletrc [Wallet] Enabled=false`. Run the first-use wizard through to its
  *Password Selection* page and Finish with "use the KDE wallet" **UNCHECKED**;
  Kopete then prompts once and "Remember password" lands it in `kopeterc`.
- **Kopete's Add-Account wizard has a focus chain you will not guess.** The UIN
  field is reachable only as `shift-tab` **from** the Remember-password
  checkbox; `tab tab` from the UIN skips Password entirely. Verify every field by
  frame (digits in the UIN, one asterisk per password character), and make the
  wizard's Back/Next/Finish buttons visible before trusting an accelerator — on
  freebsd411 they sat below the 1024x768 frame and the wizard closed without
  creating the account.

## Adding a client to this table

A new client earns a row when it has: a sign-in frame, a gateway journal line, a
restore proof (§The frame is not the proof), and a `roster.json` `client` key. The
key names the seeding driver, not the product — `gaim0599`, `micq043`, `icq2001b`
— so `seed_contacts.py` knows which fallback path applies when SSI does not.
