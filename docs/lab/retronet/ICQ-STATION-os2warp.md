# os2warp ICQ station — the bridge as-built (ICQ/2 1.503i, legacy v5)

**Status: LIVE.** `os2warp` (IBM OS/2 Warp 4.52 /
MCP2) signs in to the retronet gateway as UIN **`23000`** with **ICQ/2 beta
1.503i**, a native OS/2 **Presentation Manager** client from 1999, over the
**pre-OSCAR Mirabilis v5 door on UDP 4000** — the same door `beos` uses, and
reachable here for the same reason: this station is on a **real bridge**, not
behind a TCP-only slirp `guestfwd`.

Read [`ICQ-STATION.md`](ICQ-STATION.md) for the shared bridge/DHCP/containment
design and [`WEB-STATION-os2warp.md`](WEB-STATION-os2warp.md) for this station's
network stack — **the network half was already done and nothing here changed
it**. This doc records the ICQ half: which client, why, and the one thing that
does not work.

## Why this client — and what the OS/2 world actually had

This was the wave's only station with no pre-chosen client. The decisive source
is a **period review**: OS/2 e-Zine, 16 September 2000, *"ICQ for OS/2"* by
Christopher B. Wright (`http://www.os2ezine.com/20000916/icq.html`), which
surveys everything an OS/2 user could actually run. It names four — Mirabilis'
own Java client, **ICQ/2**, **IceCQ**, **PWICQ** — plus Licq (Russian-only
documentation) and unreviewed text-mode clones.

**No native OS/2 client ever spoke OSCAR with a server-stored SSI roster.** The
OS/2 ICQ scene stopped at the Mirabilis UDP protocol. That negative is the
single most useful fact in this document: it means the fleet's ICQ-2001b/SSI
standard is structurally unreachable on OS/2, and a client-local roster is not a
shortcut but the only option — the same conclusion `beos` reached, for the same
kind of reason ([`STATION-beos.md`](STATION-beos.md)).

| Candidate | Protocol | Roster | Verdict |
|---|---|---|---|
| **ICQ/2 1.503i** (Ed Ng, 1999-10-27) | **v5, UDP 4000** | client-local `ICQLIST.DAT` | **CHOSEN.** Native PM, 32-bit, multithreaded, VisualAge-built with **no external DLLs**, freeware, all-8.3 filenames |
| pwICQ 2.0 preview (Perry Werneck, 2002) | OSCAR (`plugins/icqv7.dll`) | client-local | **BLOCKED by FAT16** — see below. The only native-PM OSCAR client that exists |
| IceCQ 02.00.08a | v2 | client-local | Rejected: shareware **demo capped at 10 contacts**. A crippled client is not an exhibit |
| PWICQ 0.28h (1999) | v5 | client-local | Rejected: the period reviewer could not run it **twice** — crashes and hangs on every restart. Fatal for a station that restarts constantly. (Unrelated to pwICQ 2.0 above, despite the name) |
| SIM 0.9.4.3 (2007) | OSCAR, **confirmed SSI** | server-stored | Rejected: Qt3 + kLIBC 0.6.3 on a 1996 Warp exhibit is an anachronism, and its own readme warns the Warp 4 style crashes it |
| Mirabilis **ICQ Java Client 0.981a** (1998) | v2/v5 | client-local | Rejected on optics, recorded for provenance. The *genuine* Mirabilis product, and IBM Java is already on the image (`C:\JAVA11`) — but the period reviewer's own verdict was "sluggish", and an always-on Java AWT client trades the responsive native desktop this exhibit is about for authorship provenance |
| MICQ 0.43 | v5 | client-local | Text-mode. Direct ancestor of the **climm 0.6.4** the lab builds for `solaris`/`tru64`, but **no prebuilt OS/2 climm 0.6.x exists anywhere** — that ideal would cost a full EMX toolchain, for a VIO client |
| Mr. Message (2009) | OSCAR | — | Wrong identity model: **AIM screennames, not ICQ UINs** |

There is **no OS/2 TOC client at all**, so the gateway's TOC door on 9898 is not
reachable from this guest by any client.

### FAT16 constrains ALL software on this station, not just ICQ

**This is the most reusable finding here.** `os2warp`'s `C:` is FAT16, so OS/2
enforces **8.3 filenames**, and the root directory is additionally **full** (431
`EA*.CHK` chkdsk husks in a 507-entry root table, so `mkdir C:\ANYTHING` fails
with ENOSPC). Together those two facts decide what can be installed on this
guest at all:

- any archive containing a name longer than 8.3 **cannot be unpacked** here;
- anything that insists on its own top-level directory **cannot be installed**
  in the conventional place, and must go under an existing directory such as
  `C:\GALLERY\`.

Check both before sourcing software for this station. Lifting either limit means
an HPFS/JFS volume — a second disk — which is a **device-set change** and
therefore a full cold golden rebuild.

### pwICQ 2.0 is blocked by that, not by the protocol

pwICQ 2.0 preview was the better candidate on paper — native PM *and* on the
proven OSCAR/TCP-5190 plane. It cannot be installed on this station, and the
reason has nothing to do with ICQ:

**`C:` is FAT16, so OS/2 enforces 8.3 filenames.** pwICQ's RAR self-extractor
ships `eventhelpers/`, `samples/icqsetmode.cmd`, `pwicq2sdk.zip` and long-named
skin bitmaps (`titlebar-rightcorner.bmp`, …). Run in-guest it created the
8.3-safe directories, then stopped dead:

```
Extracting  samples\icqsetmode.cmd
Cannot create  samples\icqsetmode.cmd
Write error
```

**Zero files were extracted** — RAR aborts on the first write error, so nothing
after it lands either. Making pwICQ 2.0 work needs long filenames, i.e. an HPFS
or JFS volume, i.e. a **second disk** — a device-set change, which invalidates
`loadvm golden` and forces a full cold golden rebuild. Recorded as the upgrade
path to the OSCAR plane; not attempted in this wave.

## The wiring, at a glance

| | |
|---|---|
| Client | **ICQ/2 beta 1.503i**, `C:\GALLERY\ICQ2\ICQ2.EXE` (119 732 bytes). Internal build name "Homer" — that is what the title bar says |
| Why not `C:\ICQ2` | **the FAT16 root directory is FULL** (431 `EA*.CHK` chkdsk husks in a 507-entry root table), so `mkdir C:\ICQ2` fails with ENOSPC. Pre-existing debt, documented in [`WEB-STATION-os2warp.md`](WEB-STATION-os2warp.md); the installer's destination field accepts any path, so everything lives under `C:\GALLERY\` |
| Persona | UIN **`23000`**, nick `os2warp`. Password in gitignored `registry/local.env` as `RETRONET_ICQ_OS2WARP_PASS`; account opened with `rn-tool.py user-open 23000` so contacts and presence work unattended |
| Server | **literal `10.99.0.2` port `4000`**, set in the client's *Configure → ICQ Config* tab. ICQ/2 ships pointed at `icq1.mirabilis.com`, which the retronet's wildcard DNS also resolves to the gateway — but the literal removes the moving part, as on win98se/win2000 |
| Protocol | **Mirabilis v5 over UDP 4000.** ICQ/2's own `whatsnew.txt` records the jump: *"upgraded from ICQ protocol V2 to V5"* in this very build |
| Roster | **CLIENT-LOCAL** (`C:\GALLERY\ICQ2\ICQLIST.DAT`), seeded with **HiveBot only** — exactly the `beos` precedent. os2warp's roster row is nonetheless `onboarded: true`, because that flag governs whether os2warp appears in **other** stations' rosters, and it is live. Its own server-side SSI list will be written by the cross-list seeder and simply **never read**. That is harmless and intended — **do not "fix" it** |
| Config store | `C:\GALLERY\ICQ2\CONFIG.DAT` — nick, UIN, saved password, server host/port. **Written to the process's WORKING directory, not the install directory** (see the gotcha below) |
| Autostart | `C:\STARTUP.CMD`, after the existing 60 s WPS settle, so the PM client finds a live Workplace Shell |
| Golden | internal snapshot `golden`, captured on the bring-up rig with ICQ/2 signed in and the chat window closed, then promoted |

## Acceptance, on the framebuffer

Everything below was watched on the framebuffer, never inferred from a log.

- **Cold boot → autostart → silent sign-in.** `STARTUP.CMD` launches ICQ/2 after
  the WPS settles; it signs in from its saved config with **no password prompt**,
  status button reads *Online*, HiveBot in the contact list.
- **HiveBot greets, unprompted, in a window that opens itself.** The first
  greeting arrived as *"hey! someone's online :)"* in a *Received Message from:
  HiveBot* window. Once HiveBot is a known contact, later greetings land in
  ICQ/2's **split-pane "Messaging with: HiveBot" conversation window** — the one
  feature the period reviewer singled out as better than every other OS/2 client
  and the contemporary Windows one: the window **stays open**, so a reply lands
  in the same place instead of spawning a new box.
- **Contacts render by name, not as a UIN.** ICQ/2 queries the server directory
  for a stranger's nickname, so HiveBot displayed as *HiveBot* **before** it was
  added to the list. This is why `rn-tool.py nick 23000 os2warp` matters in the
  other direction too.
- **The gateway names the protocol version.** `user authenticated successfully
  svc=ICQLegacy uin=23000 version=5`. Before this station, the legacy door's
  "v2–v5" support in [`GATEWAY.md`](GATEWAY.md) was exercised only by `beos`,
  whose version was never written down. **v5 is now proven by name. v2 is still
  not.**

## The client cannot reconnect — and how the golden solves it

**ICQ/2 1.503i never reconnects by itself.** Its own `whatsnew.txt` lists
*"fixed auto-relogin (?)"* — with the author's question mark. The question mark
was earned.

Measured on the rig, reproducing exactly what idle-pause does to this station:
pause the guest past the gateway's 120 s `ICQ_LEGACY_SESSION_TIMEOUT`, then
resume. The client's keepalives arrive at a server that has forgotten it:

```
V5 packet from unknown session, sending NOT_CONNECTED  uin=23000 command=0x042E
V5 packet from unknown session, sending NOT_CONNECTED  uin=23000 command=0x051E
```

ICQ/2 handles this **honestly and uselessly**: the status button flips to
`OFFLINE`, the contact greys out — and the client then **stops transmitting
altogether and never retries** (watched for 3.5 minutes). It is not wedged and
it is not lying; it is simply passive. Recovery is one click — status button →
*Online/Connect* re-authenticates in under two seconds from the saved password —
but an exhibit should not require it.

### The re-create path is real; it is just not universal

[`STATION-beos.md`](STATION-beos.md) documents the server **silently re-creating
a reaped session** from a stale client's keepalive, with measured timestamps, and
that is exactly how `beos` comes back after an idle pause without
re-authenticating. **That documentation is correct — do not "reconcile" it.**
os2warp is the second, independent legacy client on that door, and it shows the
path is **command-code-specific**: ICBM's keepalive is in the re-create path,
ICQ/2's `0x042E` / `0x051E` are not, so those get `NOT_CONNECTED` instead.

Teaching the legacy door to re-create on more command codes is the known cure and
would fix every future legacy client at no CPU cost. It is **deliberately not
done**: the gateway is **Open OSCAR Server 0.24.0, a statically linked upstream Go
binary installed from a pinned release tarball whose sha256 is verified before
every install** ([`GATEWAY.md`](GATEWAY.md)). Changing it means forking and
building a dependency the lab pins precisely to avoid that. Recorded as a
fleet-wide follow-up for the operator, not a step inside one station's wave.

### What ships instead: the golden is captured BEFORE the client starts

`C:\STARTUP.CMD` sleeps in a **golden-capture window** and only then launches
ICQ/2. The `golden` snapshot is taken *during* that sleep, with ICQ/2 **not yet
running**. Every restore-from-golden therefore resumes mid-sleep and launches a
**fresh** client: a clean v5 login and a new HiveBot greeting, every visit. The
client's inability to reconnect never comes up, because it never has to —
it is always a new process talking to a server that has never heard of it.

**Idle-pause stays ON** (the fleet default, 60 s). The alternative — disabling it
so keepalives never stop — was measured at **10.1 % of one core, continuously**,
and was rejected: that cost compounds across a fleet of 61 for a reconnect.

**Measured, via the production `labctl reset os2warp` path, on the live station:**

| | |
|---|---|
| reset → ICQ/2 signs in | **27 s** (`user authenticated successfully … version=5`) |
| reset → HiveBot greeting rendered on the framebuffer | **57 s** |
| password prompt | **none** — saved credentials, silent |
| contact list | HiveBot, **by name** |

### The residual gap, stated plainly

A visitor who stays connected, idles long enough for the station to pause past
the 120 s reaper, and then comes back **mid-session** — without a reset — sees an
`OFFLINE` client until someone clicks *Online/Connect*. That window is the honest
cost of shipping a 1999 client with no auto-relogin, and it is narrow: every
normal arrival begins from golden.

**Why there is no in-guest watchdog.** `beos` heals itself with
`icbm-watchdog.sh`, a 10 s loop in the guest. That shape cannot be copied here,
for two independent reasons:

1. **os2warp has no exec channel at all** — the only in-guest agent is warpd on a
   COM1 unix socket, a fire-and-forget *pointer* path, not a shell.
2. **OS/2 Warp 4 ships no `kill` utility.** REXX can *start* ICQ/2 but cannot
   restart it, and running two copies is explicitly unsupported by the author.

## Gotchas specific to this client

- **ICQ/2 writes `CONFIG.DAT` and `ICQLIST.DAT` into its WORKING directory, not
  its install directory.** Launch it with the wrong CWD and it finds no config,
  re-prompts for UIN and password, and then tries to write into `C:\` — whose
  root directory is full. `STARTUP.CMD` therefore does
  `call DIRECTORY('C:\GALLERY\ICQ2')` **before** the `start`, and restores `C:\`
  after. This is the single easiest way to break this station.
- **The password is stored in cleartext** in `CONFIG.DAT`, and the credentials
  dialog shows it unmasked while typing. Keep rig screenshots out of the repo.
- **Enter does not send a message**; the reply box is multi-line. Use the *Send*
  button (or Tab to it, then space). Typing into what looks like a shell while
  the chat window has focus silently fills the reply box instead — it does not
  send, but it is confusing.
- **The status button is a menu**, not a toggle: it opens *Online/Connect*,
  *Away*, *N/A*, *Occupied*, *DND*, *Privacy (Invisible)*, *Offline/Disconnect*.
- **Chat and file transfer do not work** in this build and are not wanted here:
  the gateway runs with `ICQ_LEGACY_DIRECT_CONNECTIONS=` empty, so peer-to-peer
  is off by design.
- **The golden is captured with the chat window CLOSED**, so each wake produces a
  fresh self-opening greeting rather than showing a stale one.

## Two findings that are not this station's to fix

- **The gateway logs ICQ passwords in cleartext, at INFO level.** Every legacy
  sign-on writes the actual password into the CT's journal:

  ```
  level=INFO msg="V5 login attempt" svc=ICQLegacy uin=23000 password=<the real password> port=1537 …
  ```

  Every legacy station's credential is therefore sitting in
  `journalctl -u retronet-oscar`. The retronet has no WAN and the journal is
  root-only, so this is a footgun rather than a breach — but it is a real one,
  and it is upstream gateway behaviour, not lab code. Raised with the operator.
- **`scripts/retronet/bot/bot.py` has no `GREETINGS` / `STATION_BLURB` row for
  `os2warp`**, so HiveBot greets this station with the `_default` line
  (*"hey! someone's online :)"*). Acceptance passes either way; an OS/2-flavoured
  row is a one-line wave-end edit, deliberately batched with the other stream
  that needs the same shared file.

## Where the client came from

`ICQ2_1-503i.zip` (299 300 bytes) — a 5-file archive whose `install.exe` is a
native PM install wizard. Sourced from the **`hobbes.os-2.in`** mirror of the
Hobbes OS/2 Archive; the same bytes are also in the Wayback Machine's copy of
`hobbes.nmsu.edu/pub/os2/apps/internet/chat/icq2b153i.zip` (all five member CRCs
match). **`hobbes.nmsu.edu` is dead and `hobbesarchive.com` serves this host a
ban page**; `hobbes.os-2.in` is a full working mirror with `/browse` and
`/search`, and is the OS/2 supply line worth recording.

The binaries are **never committed**. They live in the stream sandbox at
`/data/vms/sandbox/icq-os2warp/media/`.

[`../research/vom-reference.md`](../research/vom-reference.md) has **zero hits**
for "OS/2" or "Warp" — the Virtual OS Museum says nothing about this guest, and
the lab had never sourced an ICQ client for it before. This inventory is new
ground.

## Operating it

```bash
# is the persona signed in, and on which protocol version
ssh lab 'pct exec 951 -- journalctl -u retronet-oscar --no-pager | grep "uin=23000" | tail -5'
ssh lab 'pct exec 951 -- python3 -c "import urllib.request;print(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read().decode())"'

# the framebuffer is the only proof
ssh lab 'labctl reset os2warp && sleep 90 && labctl shot os2warp'
```
