# win95 ICQ — signed in, rendering, one switch short of onboarded

**Status: NOT ONBOARDED — one setting away, and that setting is out of reach
from the client's UI.** `win95` runs **ICQ 2002a build 3728**, signs
**UIN `95000`** into the retronet OSCAR gateway, and draws its **server-side SSI
roster by name**. HiveBot greets it on sign-on. What it does **not** do is
survive a `labctl reset`: ICQ 2002a needs **Keep connection alive** to notice
that the gateway timed its session out while the guest was paused, and ICQ
2002a's Simple-Mode menu — the only route to that checkbox — will not open under
this station's synthetic input. Until that is solved the station stays
`retronet.planes = ["web"]` and its
[roster](../../../scripts/retronet/icq/roster.json) row stays `onboarded: false`.

The network half has been done since the web plane shipped
([`WEB-STATION-win95.md`](WEB-STATION-win95.md), the as-built for this station).
This doc is about the client.

## What works, and is proven on the framebuffer

- **ICQ 2002a installs and runs.** No *"failed to Initialize the Communication
  Module"*, no missing-dependency wall.
- **`95000` signs in.** *Existing User* → `95000` + `RETRONET_ICQ_WIN95_PASS`
  (**Auto Save Password** on) → *"Registration Completed Successfully — Your ICQ
  number: 95000"*, and the gateway session list goes `['10000']` →
  `['10000','95000']`, source `10.99.0.13`.
- **The SSI roster renders by name** — *Online: HiveBot*; *Offline: beos, nt4,
  solaris, tru64, win2000, win98se* — pulled from the server with no client-side
  seeding. This is the thing two earlier passes could not get onto the screen.
- **HiveBot greets it.** `retronet.bot INFO GREETED 95000 (win95)`, e.g. *"hey!
  you got your Windows 95 online again? :)"*, accepted by the gateway with no
  SNAC error. (The client does not visibly surface the message — see *Open
  ends*.)
- **Containment is unchanged.** From inside the guest: gateway `10.99.0.2` 0%
  loss; labhost `10.99.0.1` 100% loss; `1.1.1.1` 100% loss; `route print` shows
  **no `0.0.0.0` default route**.

## The client question — three generations, one answer

**ICQ 2000b** never reaches `connect()` on this guest: driven to *Existing User →
UIN → Next* it sits at "Registering User" and emits **zero** packets toward the
gateway, unchanged by Common Controls 5.80, Winsock 2, DCOM95 or IE 5.5.

**ICQ 2001b build 3659 cannot run on Windows 95 at all** — the vendor says so.
ICQ's own download page (Wayback, 2001-12-01) for exactly this build: *"ICQ for
Windows works with Windows 98/2000/ME/NT4/XP. **Windows 95 users - please use ICQ
2000b.**"* Reproduced here with the full prerequisite chain in place: it installs
(107 files, once DCOM95 is present) and then dies on **every** launch with *"ICQ
failed to Initialize the Communication Module"*. It is **not** a missing
dependency — a PE-level audit of the installed tree against the guest's own
system DLLs found **0 absent modules and 0 unresolved imports** across the
transitive closure of `CoolSocket.dll` → `Xprt`/`Xpcs`/`Xptl` and of `Icq.exe` —
and **not** a COM-registration failure. Do not retry 2001b here.

> **Trap.** `regsvr32 C:\PROGRA~1\ICQ\CoolSocket.dll` run from `C:\WINDOWS` fails
> with `GetLastError 0x485` and looks like a smoking gun. It is an artefact: on
> Win9x a DLL's dependencies are searched in the **calling process's** directory,
> so `Xprt.dll` is invisible from there. Copy `REGSVR32.EXE` into the ICQ
> directory and run it there — it reports *"succeeded"*.

**ICQ 2002a build 3728** is the client this station needs. ICQ restored Win95
support in 2002a — its download page (Wayback 2002-06-15 and 2002-08-01): *"ICQ
for Windows works with Windows **95**/98/2000/ME/NT/XP."* It is the same
SSI/feedbag generation as 2001b, so nothing changes on the gateway side (Open
OSCAR's `CLIENT_ICQ.md` covers "ICQ 2001 & 2002" as one).

## Why the contact list draws now: Internet Explorer 4.01

ICQ's own system requirements end with **"Internet Explorer 4.0 and above"**, and
2002a's owner-drawn contact list is built on the IE4-era shell/browsing
components. Under IE 3.01 the window came up as a correct frame with a `95000`
title and **nothing drawn inside** — Winsock worked, drawing did not.

That was never a deviation to agonise over: this guest is **Windows 95 OSR2.5**
(950 C — registry `VersionNumber` `4.00.1111`, `SubVersionNumber` `" C"`), and
its own OEM folder `C:\WIN95\` ships the complete IE 4.01 CAB set. **IE 4.01 is
this machine's stock browser**; IE 3.01 was the anomaly. It is now installed
**Browser Only, no Windows Desktop Update**, from that local media —
[`WEB-STATION-win95.md`](WEB-STATION-win95.md#the-browser-internet-explorer-401-the-oems-own)
has the install recipe and the `IE4SETUP.INI` knob that exposes the Browser Only
option.

With IE 4.01 in place the contact list paints: group headers, the ICQ 2002a
banner, every buddy by name in the right colour, the *Add* / *Find Users* /
*Main* / *Online* controls. **The rendering blocker is cleared.**

## The failure mode that will eat your afternoon: a dirty ICQ database

**ICQ 2002a hangs at startup whenever its per-UIN database was left dirty**, and
it looks exactly like a wedged guest: a tray flower appears, no window ever does,
`Ctrl+Alt+Del` lists **`Icq [Not responding]`**, and the gateway never sees a
login. Every ungraceful termination of ICQ — an End Task, a `systemctl stop`
while it runs, a hard power cycle — re-poisons it. The tell is in
`C:\Program Files\ICQ\2002a\`: a **`95000tmp.dat` / `95000tmp.idx` pair written
alongside `95000.dat`**, which is the compaction pass it never finished.

**The fix is deterministic**: with the station stopped, delete the per-UIN
database and let the client rebuild it.

```bash
ssh lab 'systemctl stop streamhost@win95'
# qemu-nbd the disk, mount -t vfat, then:
#   rm -f "$M/PROGRA~1/ICQ/2002a/"95000*.*
ssh lab 'systemctl start streamhost@win95'
```

Nothing is lost: the identity lives on the server (`95000` +
`RETRONET_ICQ_WIN95_PASS`) and the contact list is **server-side SSI**, so the
next start shows the registration wizard, *Existing User* → `95000` re-registers
in seconds, and the full roster comes back down by itself. This costs about five
minutes and is the standard recovery here.

None of this touches visitors: the exhibit is `loadvm`-restored from a golden
captured with ICQ already running, so it never cold-starts the client.

## The open blocker: Keep connection alive

**`Keep connection alive` ships OFF and is load-bearing.** On a `loadvm golden`
wake the restored BOS socket is stale — the gateway drops the session while the
guest is idle-paused (**measured: `95000` disappears from the session list ~140 s
after the vCPU freezes**) — and with keepalive off the client sits on a half-open
zombie socket, still showing *Online*, and never reconnects. Measured on this
station: after `labctl reset win95` the golden restores perfectly, **no password
prompt, no error dialog**, and `95000` was still absent from the gateway
**10 minutes later**.

The switch lives in *Preferences → Connections → Server*, and **Preferences
cannot be reached**. ICQ 2002a came up in **Simple Mode**, whose only menu is the
`Main` button, and that menu will not open here under any input path tried:

| Route | Result |
|---|---|
| warpnet `C x y` (`mouse_event`) on **Main** | no menu, and it leaves the owner-drawn panel **blank** — this is the "empty shell" earlier passes reported; it never repaints, survives `V`/CDS_RESET and a hide/show cycle, while the client stays online |
| QEMU PS/2 button on **Main** (press+release, and held) | no menu; panel stays correctly drawn |
| PS/2 right-click on the tray icon | no menu (left-click toggles the window, so the icon does receive clicks) |
| Keyboard: `Alt+M`, `Alt+Space`, Tab-to-button + Space | nothing |
| Scrolling the panel to *To Advanced Mode* (arrows, trough, wheel, drag) | the list will not scroll and the window is fixed-size and edge-glued, so the entry stays clipped |

PS/2 buttons are otherwise fine on this guest — they open the desktop context
menu, drive the whole ICQ registration wizard, and work IE 4.01's toolbar and
dialogs — so this is specific to ICQ's Simple-Mode chrome, not to the input path.

**Three ways out, best first:**

1. **Transplant the setting in the account file — the route `w2kalpha` proved.**
   `w2kalpha` hit this identical wall (Preferences unreachable) and solved it:
   *Keep connection alive* is not a registry value, it is the
   **`UseFirewallSessionTimeout` record inside ICQ's per-UIN account database**,
   and that database is **portable between installs when the install path
   matches** ([`ICQ-STATION-w2kalpha.md`](ICQ-STATION-w2kalpha.md)). For win95
   that file is `C:\Program Files\ICQ\2002a\95000.dat` (2001b keeps it under
   `2001a\<UIN>.dat`). So: install ICQ 2002a on a throwaway config bed where the
   menus do open, sign in as `95000`, tick *Keep connection alive*, shut the
   client down cleanly, and copy `2002a\95000.*` onto this guest with the station
   stopped. **This is the recommended next step** — it needs no UI on win95 at
   all, and it is the same trick that took `w2kalpha` from PARTIAL to LIVE.
2. **Find a UI route to Advanced Mode / Preferences** — a fresh profile that
   starts in Advanced Mode, or a supported way to un-glue and widen the window so
   the clipped *To Advanced Mode* entry becomes clickable.
3. **Give win95 the fleet's nudge.** `win98se`, `nt4` and `win2000` already ship
   `*-icq-nudge.{py,service,timer}` in
   [`scripts/retronet/`](../../../scripts/retronet/) — a labhost timer that spoofs
   the gateway's RST so the client's dead 4-tuple aborts and it reconnects. That
   is exactly this failure, and a `win95-icq-nudge` would be a fourth copy of a
   proven mechanism. It was **not** added here because those files are outside
   this stream's remit.

## Disposition — what the box is running

- **LIVE golden:** internal snapshot **`golden`** (72 MiB, 2026-08-24 05:25) in
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2` — clean 1280×1024
  desktop, IE 4.01 installed with the corpus home page, **ICQ 2002a signed in as
  `95000` with the SSI roster drawn**. `labctl reset win95` = `loadvm golden`.
- **Byte-copy backup** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-ie401-icq2002a-20260824/win95-golden.qcow2`
  (`0c9f7c5532abaaa1c7dede54325b2ae4d54cb5c18e57b5ba43747c90a454339a`).
- **Rollback to the IE 3.01 / no-ICQ golden:**
  `/data/gallery-guests/Win95/golden-backup-preicq2001b-20260823/win95-golden.qcow2`
  (`0d86c84431a5faba228f03c9a7af4fb83666ee22860e40190797c3a0eea440a5`).
- The station is **listed and live on the web plane only**;
  `registry/stations/win95.json` keeps `retronet.planes = ["web"]` so nothing
  advertises messaging while the reset behaviour is unresolved. The golden does
  show the ICQ window, and after a reset that window says *Online* when the
  server no longer agrees — that is the cost of keeping the working state, and it
  disappears the moment option 1 or 2 above lands.
- Superseded bring-up disks that can go once the operator is content:
  `win95-icq2002a-wip-20260823.qcow2`, `win95-golden-retronet-wip-20260821.qcow2`,
  `golden-wip-ie401-icq-20260824/`.

## Media

`ICQ2002a.exe` — ICQ 2002a Beta **build 3728**, 4,078,456 bytes, sha256
`fbda7ec34e9790fb4589f486b64273ae025d0a0e496a82fbce8acfbd78bb017e`. Sourced from
[`archive.org/details/install_icq`](https://archive.org/details/install_icq) and
**proven byte-identical** to the vendor original preserved by the Wayback Machine
at `ftp.icq.com/pub/ICQ_Win95_98_NT4/ICQ2002a/icq2002a.exe` (captures 2002-08-02
and 2002-10-24) — unmodified, Wise SFX, no bundler. **Never committed**; same
private-preservation stance as every other row in
[`../ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md) §ICQ. **Internet Explorer 4.01
was not sourced at all** — it came off the guest's own OEM `C:\WIN95\` folder.

## Gotchas this station charges you for

- **The station idle-pauses within seconds and silently discards QMP input.** It
  reads as a wedged guest. Drive it from **one** QMP connection that re-issues
  `cont` immediately before every event; never run two QMP clients at once (the
  daemon already holds one) or `screendump` starts timing out.
- **`systemctl stop streamhost@win95` is a power cut** — ExecStop kills QEMU by
  pidfile. It leaves ScanDisk work for the next boot and re-poisons the ICQ
  database. Shut Windows down from the Start menu first (*Close Program* →
  *Shut Down* also works, and is the only way past a hung ICQ).
- **ScanDisk's *Delete* and *Skip Undo* buttons are disabled** on this guest;
  choose *Save* for lost clusters and press **`s`** at the Undo-disk page, then
  delete the `FILE*.CHK` offline.
- **Never launch a long-lived program through the exec channel.** The agent runs
  `cmd /c <cmd> >C:\WNEXEC.OUT`; a child that outlives the call keeps that handle
  and every later exec fails. Launch from the framebuffer (Start ▸ Run).
- **Do not batch exec calls.** Nine back-to-back `copy` commands exhausted Win95's
  system resources — *"There are not enough system resources available to run this
  program"* — and every launch failed until reboot. Deliver files by mounting the
  qcow2 with `qemu-nbd` while the station is stopped, not by driving the guest.
- **`Ctrl+Alt+Del`'s Close Program dialog is modal to the whole system**, so the
  warpnet exec and pointer agents stop answering while it is up. That is not a
  crash.
- **`labctl key` chords do not reach this guest**; send chords through QMP
  `send-key` with multiple qcodes.

## Operating it

```bash
ssh lab 'labctl exec win95 "ver"'                          # Windows 95. [Version 4.00.1111]
ssh lab 'labctl exec win95 "route print"'                  # no default route == contained
ssh lab 'labctl reset win95'                               # loadvm golden
ssh lab 'printf "V\n" | nc 10.99.0.13 7788'                # un-wedge the display over the bridge
# is the persona online? (server-side)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 95000'   # server-side SSI roster
ssh lab 'journalctl -u retronet-bot -n 40 --no-pager | grep 95000'    # did HiveBot greet?
```
