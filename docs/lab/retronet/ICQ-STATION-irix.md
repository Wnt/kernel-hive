# irix ICQ — gaim 0.64 works, and takes the emulator down

**Status: BLOCKED, not shipped.** The client is built, installed, configured
and **proven to sign in**: gaim 0.64 authenticates UIN `65000` against the
gateway, downloads the server-side SSI roster, and the greeter bot messages it.
And then, **~30 seconds after the OSCAR session establishes, MAME exits** —
reproducibly, three runs out of three. The station therefore stays on the
web-plane golden **v12**; the ICQ golden **v13** is staged and immutable beside
it, and `retronet.planes` stays `["web"]` with the roster row `onboarded:
false`.

Parents: [`WEB-STATION-irix.md`](WEB-STATION-irix.md) (the web plane, live),
[`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md), [`GATEWAY.md`](GATEWAY.md),
[`BOT.md`](BOT.md).

## The blocker, precisely

Controlled observation, station restarted clean, `demos` logged in at the
chooser so gaim starts from `.sgisession`, MAME sampled every 15 s:

```
05:28:43  logged in as demos
05:29:21  mame=RNl rss=719756k oscar_conns=0 gaim=1     <- gaim up, connecting
05:30:29  mame=RNl rss=719756k oscar_conns=2 gaim=1     <- SIGNED IN
05:30:52  mame=RNl rss=719756k oscar_conns=2 gaim=?     <- guest stops answering
05:31:07  *** MAME GONE (pid 146058) ***
```

- `mame.log` ends **mid-heartbeat with no error line** — `ctlsock: hb frames=4169
  … mtime=142.200` and then nothing. No assertion, no SDL message, no stack.
  That is what a signal looks like, not a crash MAME noticed.
- **RSS is flat** at 719 MB across the whole run: not a leak, and `dmesg` shows
  no OOM kill.
- `dmesg` records `vmbr-rn: port 18(irixrn0) entered disabled state` at the
  moment of death — that is MAME closing the tap as it exits, i.e. an effect,
  not a cause.
- Reproduced **three times**: two ad-hoc runs and this controlled one. Each
  time the gap between "two ESTABLISHED connections to `10.99.0.2:5190`" and
  MAME's disappearance was 20–40 s.

**It is not the bridge, and not bulk traffic.** The web plane has run for hours
on this same `irixrn0` tap — Netscape fetching the corpus, and an **83 MB HTTP
transfer at ~300 KB/s** through the emulated SEEQ without a hiccup. What is new
in the ICQ case is a long-lived OSCAR session: keepalives, presence SNACs, an
SSI roster download and an inbound IM. Something in that pattern reaches the
`indy_4610` SEEQ 80C03 / `taptun` path and ends the process.

That next step was taken, twice over: the parallel instrumentation run caught
the exit itself (a SIGSEGV inside MAME's MIPS3 recompiler — its report has the
backtrace), and the trigger bisect below cleared every traffic pattern the
session contains. The v13 golden reproduces in ~5 minutes from a cold start —
the fastest reproduction in the station's history, unlike most of what
`irix-closed-register.md` documents.

## The trigger bisect: no traffic class kills it (rn-irix-dbg2)

Run on a rig clone — tap `irixdbg2`, guest re-addressed to `10.99.0.27`, PROM
`eaddr` patched to `08:00:69:12:34:d2` — so every result below is independent of
the production launcher, the production tap and the exhibit's address. The exit
**reproduces on a bare rig**: v13, gaim sign-in, MAME gone. That alone clears
the streamhost daemon, the idle-pause machinery and everything else that only
the live station has.

The reproduced death, frame-accurate (tcpdump on the clone's own tap):

```
07:37:12  BOS connection ESTABLISHED (auth conn 1 s earlier)
07:37:15-30  SSI roster download, presence — all quiet after
07:37:42.27  the greeter bot's inbound IM (FLAP written byte-wise:
             1,1,2,2,150-byte TCP segments); guest ACKs every one
07:37:44.29  last frame ever — gaim still rendering (X11 traffic)
07:37:44-46  MAME gone
```

Death is **~2 s after the first inbound IM**, and the guest's stack ACKed the
IM fine — whatever died, died *after* delivery, in the guest's handling of it.
The +30 s from session establishment is not a protocol timeout: it is
`RN_BOT_GREET_DELAY=30`, the greeter's own schedule.

Then every network pattern the OSCAR session contains was replayed in
isolation, **without gaim**, and none of them kill:

| # | test (v13 clone unless noted) | pattern | verdict |
|---|---|---|---|
| T0 | gaim sign-in, greeting arrives | full OSCAR session | **DEAD** +2 s after the inbound IM (+32 s after establishment) |
| T1 | perl socket → labhost:7070 | long-lived idle TCP, 1 byte/30 s, guest-initiated | alive 25+ min |
| T3 | labhost pushes 1-byte writes into a guest-held connection | **unsolicited inbound runt frames** (55 B on the wire, the greeter's exact byte-wise FLAP shape) | alive 6+ min |
| T5 | perl socket → gateway:5190, hold+read | real OSCAR port, server hello, then idle | alive 5+ min |
| T2 | `playaiff` on a clone with **no network device** | guest audio → emulated HAL2 under `-sound none` | alive 15+ min (the writer blocks — audio never drains — but nothing dies) |
| T6 | gaim sign-in, sounds disabled, **no greeting arrived** (bot skipped this sign-on) | signed-in session: keepalives + zero-length ACK pairs, 10 min | alive 10+ min |

So: not idle long-lived TCP, not unsolicited inbound, not runt/short frames,
not the OSCAR port, not audio, and not a signed-in session as such. The only
thing that has ever killed MAME is **gaim executing its first-inbound-IM path**
(conversation window; a large, cold, never-before-executed pile of code) — and
T6, where the IM never came, is the signed-in control that survived.

That is exactly the shape of the root cause the parallel instrumentation run
pinned: **MAME SIGSEGVs in its own MIPS3 dynamic recompiler**
(`drcfe.ipp build_sequence`: a branch-likely at the last word of a page whose
delay slot faults on a non-resident page loses its END_SEQUENCE marker). The
packets were only ever the stimulus that drove gaim through cold code for the
DRC to compile; there is no killer packet, which is why the web plane — hot,
already-compiled paths — ran for hours on the same NIC, tap and bridge.

**Minimal reproducer, honestly stated:** there is no packet- or socket-level
reproducer, because no traffic pattern is the trigger. The smallest reliable
kill remains: boot v13, launch gaim (auto-login), let the greeter's IM arrive —
dead in ~5 min from cold boot, ~30 s from sign-on. Any change that makes gaim
execute fresh code paths at the fatal page alignment could substitute; nothing
cheaper than "receive the first IM" was found.

Three traps for whoever rigs this station next: (1) every clone inherits the
PROM `eaddr` `08:00:69:12:34:56` from the shared nvram — on `vmbr-rn` that is
an L2 collision with the LIVE exhibit; patch the clone's copy of `rtc` (the MAC
sits at offset 0x13A) and pass the same value as `IRIX_RIG_TAP_MAC`, and IRIX
boots and uses it, no checksum complaint. (2) Do not boot a v13/v12 clone while
its tap is already enslaved to the bridge: the guest configures the baked
**10.99.0.24 — the live exhibit's address** — before you can re-address it;
boot with the tap unenslaved (or absent), `ifconfig ec0 inet 10.99.0.27`, only
then `rn-tapnet.sh up`. (3) `ss` on labhost cannot see guest↔CT flows — they
are pure L2 through the bridge; the clone's own tcpdump is the only honest
view of the OSCAR session.

## What DOES work (all of it verified)

| | |
|---|---|
| Client | **gaim 0.64**, SGI Freeware, `/usr/freeware/bin/gaim`, 772 776 bytes. `ldd` = 28 libraries, **zero unresolved** |
| Persona | UIN **`65000`**, directory nickname `irix`, opened for unattended contacts. Password box-local in `registry/local.env` `RETRONET_ICQ_IRIX_PASS` |
| Server-side auth | `rn-tool.py login 10.99.0.2 5190 65000 …` → **`PASS 65000 authenticated`**, BOS advertised, 256-byte cookie |
| Client sign-in | two **ESTABLISHED** connections `10.99.0.24:*` → `10.99.0.2:5190` (auth + BOS), and gaim's window is the **Buddy List**, not the Login window |
| **SSI roster** | **works unpatched** — see below |
| Greeting | `retronet.bot INFO GREETED 65000 (irix)` — *"hey! someone's online :)"* and *"hi there - what machine is that?"* on two separate sign-ons |
| Config | `/.gaimrc` → `ident { 65000 } { … }`, `proto_opts { 10.99.0.2 } { 5190 }`, `alias { irix }`, auto-login + remember-password, copied to `demos`/`guest`/`chronic` and chowned |

### gaim 0.64 does server-side ICQ rosters WITHOUT a patch

Worth recording, because the fleet's other Unix desktop client needs surgery for
this. `tru64` runs **Gaim 0.59.9**, whose OSCAR plugin gates the feedbag request
and its parse behind `if (!odata->icq)` — it *refuses* SSI on ICQ accounts — so
that station carries `gaim-0.59.9-icq-ssi.patch` to remove both gates
([`ICQ-STATION-tru64.md`](ICQ-STATION-tru64.md)).

**0.64 needs none of it.** After `seed_contacts.py ssi irix --apply` wrote the
11-contact roster server-side, gaim downloaded it on the next sign-on and the
Buddy List rendered `Orphans (1/22)` with **HiveBot listed by name**, not as a
bare UIN. That matters here more than anywhere else in the fleet: **this station
has no compiler**, so a client that needed patching could not be used at all.

(The group shows as *Orphans* because the seeded items carry no group row that
gaim recognises. Cosmetic, and untouched — the station is blocked for other
reasons.)

## Why the client had to arrive prebuilt

The fleet's Unix answer to ICQ is **climm built from source**, which
[`solaris`](ICQ-STATION-solaris.md) and [`tru64`](ICQ-STATION-tru64.md) both did
with a compiler already on the guest. **This guest has no compiler at all.**
Measured, not assumed:

```
which cc gcc c89 CC   ->  nothing in /usr/local/bin /usr/sbin /usr/bsd /sbin /usr/bin /etc /usr/etc
/usr/bin/cc, /usr/bin/gcc   ->  do not exist
/usr/bin/ld, /usr/bin/as, /usr/bin/ar   ->  do not exist
/usr/include/stdio.h, /usr/lib/crt1.o   ->  do not exist
/usr/freeware/bin   ->  empty
versions -b  ->  compiler_eoe (base headers+libs) installed; c_dev is NOT
```

MIPSpro was a separately licensed product and is not in this image. There is no
assembler and no linker, so installing `gcc` alone would not help either, and
cross-compiling has no system headers to compile against. **Only a prebuilt
binary can work**, which is why SGI Freeware — not source — is the supply.

Two candidates exist there: **gaim 0.64** (AIM/**ICQ**/MSN/IRC/Jabber) and
**licq 1.2.6** (ICQ, Qt). gaim was chosen: same lineage as tru64's client, a
real desktop app rather than a terminal, and a GTK2 dependency set that is all
prebuilt on the same mirror.

## The install recipe (this is the reusable part)

Media: **21 packages, 83 MB**, walked from `fw_gaim`'s own product descriptor,
archived whole as one blob — sha256
`da1e53c5192c7f8f14044925619a299f036ecf3c4548befcdfa3ff0ffac6da0d` — plus a
second batch (`fw_libpng`, `fw_common`, `fw_esound`). Source:
`https://ftp.zx.net.nz/pub/archive/sgi-freeware/{cd-1..cd-4}/dist/`.

**Delivery.** The guest has no compiler but it does have `perl`, `tar`, `gzip`
and `inst`. A bake clone gets a host-only /30 (`tapnet.sh claim`), the media is
served by `python3 -m http.server` bound to the host end, and a **perl socket
one-liner in the guest** pulls it down at ~300 KB/s. IRIX's perl predates
3-argument `open`, so it is `open(O,">/var/tmp/fw.tar.gz")`.

**The `inst` recipe, and the two things that make it work:**

```sh
inst -a -f <dist>/<product> -I <product> -K '*.man.*' -K '*.sw64.*' -K '*.src.*'
```

1. **Point `-f` at a PRODUCT FILE, never the directory.** Given a directory,
   `inst` asks *"Do you wish to run the optional installation startup script?"*
   — and under `-a` it answers itself and **exits `rc=0` having installed
   nothing**. Naming one product skips that path entirely. This single detail
   cost more time than the rest of the install together.
2. **`-a` needs no tty.** `inst` reads its prompts from the **terminal**, not
   stdin, so a redirected command file is silently ignored (again `rc=0`,
   nothing installed). Driving it through the console getty works but is
   fragile: the console's guest→host direction is not byte-clean (see
   `irix-serial-install.sh`), so prompts cannot be read back reliably, and
   **killing a process on that console hangs the pty up** (`stty` reports
   `speed 0`) leaving `inst` orphaned and unrecoverable.
3. The `-K` exclusions drop the 64-bit and man subsystems, whose prerequisites
   (`eoe.sw64.lib`, `compiler_eoe.sw64.lib`, `fw_common.man.legal`) are not in
   this distribution and would otherwise raise conflicts nothing can resolve.

**Install order** (leaves first): `fw_libz fw_libpng fw_libjpeg fw_expat
fw_freetype fw_freetype2 fw_fontconfig fw_gettext fw_glib2 fw_atk fw_xrender
fw_xft fw_pango fw_tiff fw_gtk2+`, then the three gaim itself names —
`fw_audiofile`, `fw_libao` and `fw_perl` — then `fw_gaim`.

Three prerequisite traps, all found by inst and all real:

- **`fw_libpng` is missing from `fw_gaim`'s descriptor walk** but
  `fw_gtk2+.sw.lib` — the GTK2 library gaim links against — requires it. Walking
  the descriptors is not sufficient; the conflicts are the real dependency list.
- **Install at SUBSYSTEM granularity where a product pulls in more than you
  need**: `-I fw_esound.sw.lib` (not the whole product, whose daemon subsystem
  wants `fw_tcp_wrappers`), and `-I fw_perl.sw32.perl -I fw_perl.sw.common` (not
  `threaded_perl`, which wants `fw_db3.sw.eoe`).
- **Never answer conflicts with a blanket `a`.** Choosing "do not install" for
  everything declines `fw_gtk2+.sw.lib` itself. Choose `b` — "also install the
  prerequisite" — whenever that prerequisite is a package the distribution
  actually ships.

## Why `.sgisession` and not a signed-in scene

The rest of the fleet captures its checkpoint with the messenger **connected**,
and the greeting rides the client's reconnect on wake. This exhibit rests at the
**iconlogin chooser** — nobody is logged in when the checkpoint is captured — so
there is no session to hold a connected client. gaim therefore starts from each
account's `.sgisession` when a visitor begins a desktop session, and the
greeting follows its sign-on ~30 s later.

Capturing a **logged-in** scene instead (`capture-checkpoint.sh --login demos`)
would match the fleet and put a connected Buddy List in the restored frame. It
also changes what the exhibit rests at, which is an operator decision. It is
moot until the blocker above is fixed.

## Rollback / current state

- **LIVE: v12** (web plane only), `IRIX_NET_MODE=retronet`, checkpoint
  recaptured against it. This is the state before any ICQ work.
- **STAGED: v13** — `irix65-apps-v13.chd`, md5
  `319cff007fcc71d3d009e6cce51f34f0`, 444 + immutable. gaim installed,
  configured and auto-started. **Do not make it live** until the emulator exit
  is understood; a visitor logging in is enough to trigger it.
- Gateway state is harmless and left in place: UIN `65000` exists, is open, is
  nicknamed `irix`, and has its 11-contact SSI roster. The greeter bot's
  `RN_BOT_PERSONAS` was re-rendered while the roster row was flipped and now
  lists `65000:irix`; with the row back to `onboarded: false`, re-running
  `scripts/retronet/bot/install-bot.sh --apply` drops it again.
