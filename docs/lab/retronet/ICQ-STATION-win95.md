# win95 ICQ — signed in, keep-alive set, and STILL not reconnecting

**Status: NOT ONBOARDED, and the reason is no longer the one this doc used to
give.** `win95` runs **ICQ 2002a build 3728**, signs **UIN `95000`** into the
retronet OSCAR gateway, draws its **server-side SSI roster by name**, and is
greeted by HiveBot. *Keep connection alive* — the setting three streams chased —
**is now reachable, is set, and ships in the golden.** It does not help.

The station still cannot survive a `labctl reset`, and the cause has been
measured rather than inferred: after the gateway has dropped the session, the
restored guest **does** probe its stale socket, the gateway **does** answer
`RST`, and **ICQ 2002a ignores it** — no reconnect, no error, the panel keeps
showing *Online* with a full roster. Because a `*-icq-nudge` exists purely to
deliver that same `RST`, **a `win95-icq-nudge` would not fix this station
either**; that option is retired on evidence, not on remit.

Until an ICQ-side answer exists the station stays `retronet.planes = ["web"]`
and its [roster](../../../scripts/retronet/icq/roster.json) row stays
`onboarded: false`.

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
  SNAC error. (The client does not visibly surface the message.)
- **`Keep connection alive` is set.** Reached through the registration wizard
  (below), ticked on the framebuffer, and `UseFirewallSessionTimeout=1` verified
  offline in `95000.dat`. It ships in the golden — it simply does not fix the
  reset.
- **Containment re-proven 2026-08-24.** From inside the guest: gateway
  `10.99.0.2` 0% loss; labhost `10.99.0.1` 100% loss; `1.1.1.1` 100% loss;
  `route print` shows **no `0.0.0.0` default route**.

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

## Keep connection alive: how to reach it, and why it is not the fix

### The route — the registration wizard, not Preferences

Preferences really is unreachable (see the table below), but it is **not the
only door**. ICQ 2002a's *registration wizard* carries the same Server/Firewall
page, and that page has the **`Keep connection alive`** checkbox at its
bottom-left. The page is reached from the wizard's **connection-failure**
screen — *"Can't establish connection"* — via its **`Connection Settings`**
button.

That screen only appears if the registration attempt genuinely fails to reach
the gateway, so it has to be provoked. The reliable way, with no host
networking touched and no shared infrastructure involved:

1. Stop the station, clear the per-UIN DB (below), cold boot. ICQ starts into
   the wizard.
2. *Existing User* → `95000` + `RETRONET_ICQ_WIN95_PASS`.
3. **Park the pointer on `Next` while the link is still up** (warpnet `M 845 690`),
   then `set_link pcnet.0 off` over QMP and click with `input-send-event`
   alone. The pointer agent lives on the guest's own NIC, so **once the link is
   down warpnet is unreachable** — pre-positioning is what makes this work.
4. Wait ~110 s for ICQ's connect to time out, then `set_link pcnet.0 on`.
   Restore the link too early and registration simply succeeds, silently
   leaving keep-alive OFF.
5. *Connection Settings* → tick *Keep connection alive* → *Next*. Registration
   retries over the restored link and completes **with the flag set**.

Verify offline, exactly as `w2kalpha` does:

```bash
strings "/mnt/w95/PROGRA~1/ICQ/2002a/95000.dat" | grep -c UseFirewallSessionTimeout   # 1
```

`UseFirewallSessionTimeout=1` is present in the DB that ships in today's golden.

### Why it does not help — measured on the wire

Acceptance was run properly: idle-paused until `95000` **disappeared** from the
gateway session list (confirmed by three independent samples), *then*
`labctl reset win95`.

`tcpdump` on `win95rn0`, within three seconds of the reset:

```
14:33:56  10.99.0.13.1034 > 10.99.0.2.5190: Flags [.], ack ...   (keepalive probe)
14:33:56  10.99.0.2.5190 > 10.99.0.13.1034: Flags [R]            (gateway RST)
14:33:59  10.99.0.13.1034 > 10.99.0.2.5190: Flags [P.], length 6
14:33:59  10.99.0.2.5190 > 10.99.0.13.1034: Flags [R]            (gateway RST)
```

The socket is probed, and it is **reset by the server** — the exact event a
nudge manufactures. `95000` still never returned to the session list, and the
framebuffer still showed *Online* with the full roster. The guest's networking
was fine throughout (control: guest pings `10.99.0.2` at 0% loss after the
reset). **ICQ 2002a simply does not act on the dead connection.**

The guest also carries an OS-level backstop, added while testing this:

```
HKLM\System\CurrentControlSet\Services\VxD\MSTCP
  "KeepAliveTime"    = "60000"
  "KeepAliveInterval" = "5000"
```

(Win95 defaults `KeepAliveTime` to 2 hours, which is why an earlier 7-minute
watch saw **zero** packets.) It works — it is what produced the probe above —
and it still does not make ICQ reconnect. Leave it; it costs nothing and it is
what turns "silent" into "provably answered with RST".

### The Simple-Mode chrome — confirmed dead, with the safe input path

Re-tested with the `M x y` + real-PS/2-button combination (the one that does
**not** corrupt the owner-drawn panel), not just the `mouse_event` path:

| Route | Result |
|---|---|
| `Main` button | no menu — confirmed again |
| Scrolling the panel to *To Advanced Mode* (down-arrow ×6) | list does not scroll at all |
| Clicking the *Offline* group header to shorten the list | does not collapse |
| *To Advanced Mode* while the IMPORTANT NOTICE is up | the notice is **modal**; the click is swallowed |
| *To Advanced Mode* immediately after dismissing the notice | too late — sign-in and the SSI fetch complete **behind** the modal, so dismissing it paints the full roster at once and the entry is already clipped |

Contact rows *do* open their own context menu under this input path, so the
panel receives clicks; it is ICQ's chrome that refuses. **There is no timing
window** — the earlier hope that one existed was wrong.

## The failure mode that will eat your afternoon: a dirty ICQ database

**ICQ 2002a hangs at startup whenever its per-UIN database was left dirty**, and
it looks exactly like a wedged guest: a tray flower appears, no window ever
does, `Ctrl+Alt+Del` lists **`Icq [Not responding]`**, and the gateway never
sees a login. Every ungraceful termination re-poisons it. The tell is a
**`95000tmp.dat` / `95000tmp.idx` pair written alongside `95000.dat`** — the
compaction pass it never finished.

**The fix is deterministic**: with the station stopped, delete the per-UIN
database and let the client rebuild it.

```bash
ssh lab 'systemctl stop streamhost@win95'
# qemu-nbd the disk, mount -t vfat, then:
#   rm -f "$M/PROGRA~1/ICQ/2002a/"95000*.*
ssh lab 'systemctl start streamhost@win95'
```

With that done ICQ **cold-boots healthy** and lands in the registration wizard.

> **This is what defeated the account-file transplant.** A predecessor saved a
> natively-created DB that already carried `UseFirewallSessionTimeout=1` and
> cold-booted from it; ICQ hung on the *"Loading..."* splash for minutes and
> then vanished. The saved copy included the **`95000tmp.*` pair**, so it was
> dirty on arrival. Copy `95000.dat`/`95000.idx` only — never the `tmp` pair.
> The transplant is in any case unnecessary now that the wizard route works.

Nothing is lost by clearing it: the identity lives on the server and the contact
list is **server-side SSI**, so *Existing User* → `95000` re-registers in seconds
and the roster comes back down by itself.

None of this touches visitors: the exhibit is `loadvm`-restored from a golden
captured with ICQ already running, so it never cold-starts the client.

## Disposition — what the box is running

- **LIVE golden:** internal snapshot **`golden`** (71.9 MiB, 2026-08-24 14:31) in
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2` — clean 1280×1024
  desktop, IE 4.01 with the corpus home page, **ICQ 2002a signed in as `95000`
  with the SSI roster drawn and `Keep connection alive` SET**, plus the MSTCP
  `KeepAliveTime` values above. `labctl reset win95` = `loadvm golden`.
- **Byte-copy backup** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-ie401-icq2002a-keepalive-20260824/win95-golden.qcow2`
  (`bc4490d831d833d2e6e96ca4d752ca4320c64d831f1cd02d7ff984c3104b98db`).
- **Rollback to the pre-keep-alive golden** (ICQ online, flag OFF):
  `/data/gallery-guests/Win95/golden-backup-ie401-icq2002a-20260824/win95-golden.qcow2`
  (`0c9f7c5532abaaa1c7dede54325b2ae4d54cb5c18e57b5ba43747c90a454339a`).
- **Rollback to the IE 3.01 / no-ICQ golden:**
  `/data/gallery-guests/Win95/golden-backup-preicq2001b-20260823/win95-golden.qcow2`
  (`0d86c84431a5faba228f03c9a7af4fb83666ee22860e40190797c3a0eea440a5`).
- The station is **listed and live on the web plane only**;
  `registry/stations/win95.json` keeps `retronet.planes = ["web"]` so nothing
  advertises messaging while the reset behaviour is unresolved. The golden shows
  the ICQ window, and after a reset that window says *Online* when the server no
  longer agrees — that is the cost of keeping the working state.
- **A golden can go missing.** This stream inherited the station with **no
  snapshot at all**: a predecessor was killed between `delvm golden` and the
  `savevm` that was to replace it, so `labctl reset win95` had nothing to
  restore. If `qemu-img snapshot -l` on the station disk is empty, copy a backup
  above back over `win95-golden.qcow2` with QEMU **stopped** and re-verify the
  SHA256. Always take the byte-copy backup **before** `delvm`.
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

- **The station idle-pauses within seconds, and a paused guest reacts to
  nothing.** It reads as a wedged guest. `labctl` and `scripts/dev/qmp-type.py`
  wake it, verify it is really running and hold a wake lease for the duration,
  so this no longer needs handling by hand — see
  [`../INPUT-DEBUGGING.md`](../INPUT-DEBUGGING.md).
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
