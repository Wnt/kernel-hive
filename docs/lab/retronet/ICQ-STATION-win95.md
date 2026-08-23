# win95 ICQ — the client question, answered

**Status: NOT ONBOARDED — one documented step away.** `win95` is on the
retronet and has been since the web plane shipped
([`WEB-STATION-win95.md`](WEB-STATION-win95.md), the as-built for this station).
What is still missing is **messaging**. This doc records the client question and
its answer, because that question — *which ICQ client can even run on Windows 95
OSR2.5?* — is what two previous passes actually died on, and it now has a
primary-source answer plus a reproduction.

**The short version.** ICQ **2000b** and ICQ **2001b** cannot work on this
guest, and no amount of runtime retrofitting changes that. ICQ **2002a build
3728** can: it installs, initialises its communication module, and **signed UIN
`95000` into the retronet OSCAR gateway** on 2026-08-23. The one thing it still
needs is **Internet Explorer 4.0+**, which is a documented ICQ requirement this
station does not yet meet — and meeting it changes a decision that belongs to
the web plane, so it is written up here as a decision, not taken unilaterally.

The shipping golden currently carries **no ICQ client** (see *Disposition*).

## What the network side already gives, and it is not the problem

Everything below the client is done and proven — detail in
[`WEB-STATION-win95.md`](WEB-STATION-win95.md). Re-proven on the shipping golden
2026-08-23:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR + `:80` origin) | **Reply, 0% loss** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` | **Request timed out** | the `WIN95RN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **Destination host unreachable** | no default route (Lock 1) |
| `route print` default routes | **0** | DHCP reservation withholds option 3 |

The persona is live on the gateway side too: `rn-tool.py login 10.99.0.2 5190
95000 …` → **PASS**, BOS advertises `10.99.0.2:5190`; the account is **open**
(`user-open`), its directory nickname is `win95`, and its server-side SSI roster
is seeded with HiveBot + the six other onboarded stations. `95000:win95` is
already present in `RN_BOT_PERSONAS` on labhost, so HiveBot will greet it.

**So every "is it the network?" hypothesis is closed.** It never was.

## The client question — three generations, one answer

### ICQ 2000b — never reaches `connect()`

Driven to *Existing User → UIN → Next*, 2000b sits at "Registering User" and
emits **zero** packets toward the gateway. An earlier pass proved this was not
network, config or credentials, and then installed the full win98se-equivalent
runtime stack (Common Controls 5.80, Winsock 2, DCOM95, and finally IE 5.5 SP2)
with the **identical** zero-packet symptom after every one. That pass also
established the standing prohibition below.

> **Do NOT install Internet Explorer 5.5 SP2 on this station.** It makes the
> golden unfit as an exhibit: a multi-minute first-boot finalization, a
> **network-login prompt on every boot** (the shell and `WIN.INI load=` — hence
> both warpnet agents — only start *after* it), and a modernised desktop. This
> prohibition still stands and was respected throughout the 2026-08-23 pass.

### ICQ 2001b — cannot run on Windows 95 at all

The wave's premise was that 2001b, being a different binary, might simply not
have 2000b's bug. It is worse than that: **build 3659 dropped Windows 95
support**, in writing, from the vendor.

ICQ's own download page, Wayback capture 2001-12-01, for exactly this build:

> Download ICQ for Windows **2001b Beta v5.18 Build #3659** … **ICQ for Windows
> works with Windows 98/2000/ME/NT4/XP. Windows 95 users - please use ICQ
> 2000b.**

Reproduced here on 2026-08-23, on a guest carrying the full prerequisite chain
(Common Controls 5.80, Winsock 2, DCOM95 1.3 — all verified in place after a
cold boot):

- 2001b **installs** cleanly (107 files) once DCOM95 is present; without DCOM95
  its installer stops at a *"DCOM Not Detected"* gate.
- Every launch — after install, after a cold boot, and manually — dies with
  **"ICQ failed to Initialize the Communication Module"**, then exits.
- It is **not** a missing or unresolvable dependency. A PE-level audit of the
  installed tree against the guest's own system DLLs found **0 absent modules
  and 0 unresolved imports**, across the full transitive closure of
  `CoolSocket.dll` → `Xprt`/`Xpcs`/`Xptl` and of `Icq.exe`.
- It is **not** a COM-registration failure. The installer's "Not Complete
  CLSIDs" list (11 entries) maps only to *peripheral* plugins (SMS, Hops,
  RandomChat, WhitePages, …), never to the `Cool*`/`ICQCom45` comm family; and
  registering the comm family by hand **succeeds** and changes nothing.

> **Trap worth keeping.** `regsvr32 C:\PROGRA~1\ICQ\CoolSocket.dll` run from
> `C:\WINDOWS` fails with `GetLastError 0x485` (ERROR_DLL_NOT_FOUND) and looks
> like a smoking gun. It is an artefact: on Win9x a DLL's dependencies are
> searched in the **calling process's** directory, not the DLL's own, so
> `Xprt.dll` is invisible from there. Copy `REGSVR32.EXE` into the ICQ directory
> and run it from there — it reports **"succeeded"**. Do not build a diagnosis
> on the first result.

### ICQ 2002a — works, and signed in

ICQ restored Win95 support in 2002a. Its download page, Wayback captures
2002-06-15 and 2002-08-01:

> **2002a Beta Build #3728** … **"ICQ for Windows works with Windows
> 95/98/2000/ME/NT/XP."**

Installed on this guest 2026-08-23, over the 2001b tree, and it **cleared every
wall the older generations hit**:

- the communication module **initialises** — no error dialog;
- the **ICQ Registration** wizard runs, Connection Type already *Permanent
  (LAN, Cable Modem, etc.)*;
- *Existing User* → `95000` + `RETRONET_ICQ_WIN95_PASS` (**Auto Save Password**
  ticked, on by default) → **"Registration Completed Successfully — Your ICQ
  number: 95000"**;
- the gateway session list went from `['10000']` to **`['10000', '95000']`** —
  the persona was genuinely online against `10.99.0.2:5190`, reached via the
  wildcard-DNS hijack of `login.icq.com` with no proxy;
- the server-side SSI roster survived the login intact (7 buddies, checked
  before and after), so 2002a does **not** wipe the fabric-seeded list.

**That is the answer to the wave's question:** 2001b does not clear the 2000b
blocker on win95 — it fails earlier and for a documented reason. **ICQ 2002a is
the client this station needs**, and it is the same SSI/feedbag generation, so
nothing changes on the gateway side (Open OSCAR's `CLIENT_ICQ.md` covers "ICQ
2001 & 2002" as one).

## What still blocks onboarding: the IE 4.0 requirement

2002a runs and connects, but its **main contact-list window renders as an empty
shell** — correct frame, title bar reading `95000`, and *nothing* drawn inside:
no contact names, no button labels, no skin. ICQ's ordinary dialogs (Welcome
notice, registration wizard, installer) render perfectly, so this is not the
guest's graphics: colour depth is fine (360–466 distinct colours measured in
richer frames, so ≥15 bpp), and it is not the roster (server-side roster is
populated and the client authenticated).

The cause is the requirement neither previous pass satisfied. ICQ's own
"Common Questions & Answers" page, in both the 2001b-era and 2002a-era captures,
lists the minimum system requirements as ending with:

> **Internet Explorer 4.0 and above.**

**This station has Internet Explorer 3.01 (build 1158)** — the stock OSR2
browser, and deliberately so: `WEB-STATION-win95.md` records "Nothing was
installed … IE 3.01 runs on stock Winsock 1.1" as the web plane's decision.
ICQ 2002a's owner-drawn UI is built on the IE4-era shell/browsing components
(`SHLWAPI` in particular is an IE 4.0 component; this guest's copy is the
original 36,864-byte 1996 build, with `URLMON`/`WININET` likewise from 1996).
Functionality that only touches Winsock works; everything that draws does not.

### The decision, for the coordinator — not taken here

Finishing win95's ICQ means **installing Internet Explorer 4.01** (Browser
Only / no Active Desktop, so the Win95 shell stays period-correct). That is a
cheap, period-authentic step — Win95 **OSR2.5 normally ships with IE 4.01
integrated**, so it arguably restores this image rather than modernising it —
but it **changes a decision the web plane owns**: `WEB-STATION-win95.md`
documents IE 3.01 as the station's browser, its 1996 UA string, and its
home-page behaviour on the corpus. It also needs IE 4.01 media sourced (none is
staged locally; the desktop's *Internet Explorer 4.0 Setup* shortcut is an
online stub that cannot reach anything from the contained bridge).

So the open question is: **is win95 allowed to become an IE 4.01 machine in
order to gain ICQ?** If yes, the remaining work is small and entirely mapped:
install IE 4.01, re-apply `50comupd.exe` (IE4 setup can put COMCTL32 4.71 back
over 5.80), confirm the 2002a window paints, set Server Host `10.99.0.2` /
port `5190` and **Keep connection alive = ON**, then recapture the golden with
the client connected. If no, this station stays web-only and the roster row
stays `onboarded: false`.

## Disposition — what the box is actually running now

The 2026-08-23 pass ended by **rolling the exhibit back**, on purpose: an
exhibit carrying a client whose window does not draw is worse than one carrying
none.

- **LIVE golden: unchanged from before the pass.** The live
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2` was restored from the
  byte-copy backup and verified **SHA256-identical**
  (`0d86c84431a5faba228f03c9a7af4fb83666ee22860e40190797c3a0eea440a5`), snapshot
  `golden` (ID 1, 57.7 MiB, 2026-08-23 13:01) intact. `labctl reset win95` →
  *"restored to golden snapshot"*, exec answers, containment re-proven (table
  above). **No ICQ client is installed on it.**
- **Backup of that golden** (taken with QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-preicq2001b-20260823/win95-golden.qcow2`
  (+ `SHA256SUMS`).
- **Preserved bring-up disk for the retry** —
  `/data/gallery-guests/Win95/win95-icq2002a-wip-20260823.qcow2` (+ `.sha256`),
  **no `golden` snapshot**. Carries Common Controls 5.80, Winsock 2, DCOM95 1.3,
  ICQ 2001b (broken) *and* ICQ 2002a build 3728 registered against UIN `95000`
  with the password saved. A retry should start from **this** disk, not from
  scratch — it is ~1 h of installer time already spent. Unlike the 2021 WIP
  disk it carries **no IE 5.5 damage**.
- The older `win95-golden-retronet-wip-20260821.qcow2` (the IE 5.5 + 2000b
  laboratory) is superseded by the disk above and can be deleted once the
  operator is content.

## Media

`ICQ2002a.exe` — ICQ 2002a Beta **build 3728**, 4,078,456 bytes, sha256
`fbda7ec34e9790fb4589f486b64273ae025d0a0e496a82fbce8acfbd78bb017e`. Sourced from
[`archive.org/details/install_icq`](https://archive.org/details/install_icq) and
**proven byte-identical** to the vendor original preserved by the Wayback
Machine at `ftp.icq.com/pub/ICQ_Win95_98_NT4/ICQ2002a/icq2002a.exe` (captures
2002-08-02 and 2002-10-24) — an unmodified original, Wise SFX, no bundler.
Staged at `/data/vms/sandbox/icq-win95/media/ICQ2002a.exe`; **never committed**.
Same private-preservation stance as every other row in
[`../ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md) §ICQ.

## Gotchas this pass paid for

- **Deliver installers by injecting them into the qcow2, not through the
  browser.** With the station stopped, `qemu-nbd` + `mount -t vfat` the golden
  and copy the blob to `C:\`. It replaces three fragile IE *Save As* dialogs and
  lets you hash-verify the file in place. The station must be stopped, and this
  is only safe while the `golden` snapshot is deleted (below).
- **A golden rebuild here is cold-boot-only.** `qemu-img snapshot -a golden`,
  then `qemu-img snapshot -d golden` so the launcher cold-boots (it appends
  `-loadvm golden -S` only when the snapshot exists). While no snapshot exists,
  a `systemctl restart` is a *safe* cold boot — which is exactly why you must
  **not** capture an interim golden mid-install: a later restart would `loadvm`
  pre-install RAM onto a post-install disk.
- **The station idle-pauses within seconds of every command**, silently
  discarding input, which reads as a wedged guest. Hold it awake with a
  momentary QMP connect→`cont`→close loop (never a held socket — the daemon
  already holds one), and start every input batch with `cont`.
- **`labctl key` chords do not reach this guest; QMP `send-key` with multiple
  qcodes does.** `ctrl-esc` then `r` is the reliable way to Start ▸ Run.
- **Long installs wedge the S3/VBE display into a striped band.** Recover over
  the bridge with the warpnet **`V`** verb; it is cosmetic and the frame comes
  back clean.
- **Do not run 70 `regsvr32` calls in one batch.** `for %%f in (*.dll) do start
  /w rs32.exe /s %%f` exhausts Win95's system resources and every subsequent
  launch fails with *"There is not enough free memory to run this program"*
  until reboot. It also proves nothing: ICQ 2002a's plugins were never the
  problem (`pl.log`'s `LoadIntegralPlugins … Failed to create Add-on instance`
  entries are **stale, from the 2001b install** — check the timestamps before
  believing that file).
- **`WIN.INI` carried `run=notepad.exe`**, left by an earlier bring-up pass. It
  is invisible on the `loadvm`-restored exhibit but opens a stray Notepad on
  every *cold* boot, so it corrupts any cold golden rebuild. It was cleared on
  the WIP disk. **The shipping golden still has it** (the rollback restored the
  original), so a future rebuild must clear it again: `sed -i 's/^run=notepad\.exe/run=/I'`
  on `WINDOWS/WIN.INI` with the disk mounted.

## Operating it

```bash
ssh lab 'labctl exec win95 "ver"'                         # exec over the bridge (WARPX :7788)
ssh lab 'labctl exec win95 "route print"'                 # no default route == contained
ssh lab 'labctl reset win95'                              # loadvm golden
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 95000'   # server-side SSI roster
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
```
