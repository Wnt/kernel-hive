# w2kalpha ICQ station — the stock x86 client, transplanted onto the Alpha

**Status: LIVE.** `w2kalpha` (Windows 2000 RC2 build 2128 for **Alpha AXP**, on
the es40 AlphaServer ES40 emulator) carries the fleet's standard **x86 ICQ 2001b
(build 3659)** — the *same binary* the Intel stations run — executed on Alpha by
**FX!32 / Wx86**, Windows NT's x86 emulation layer. UIN `50010` signs in
unattended on the saved password, reconnects silently after a `labctl reset`, and
reaches the gateway at the **literal `10.99.0.2:5190`** with no DNS in the path.

The client was **not installed here**: it was installed on a throwaway x86
Windows 2000 clone and moved across as a finished payload, because the installer
itself is too slow to complete on an emulated Alpha (below). The web half of this
station's retronet membership is [`w2kalpha-retronet.md`](w2kalpha-retronet.md);
the fleet ICQ recipe is [`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md). This
doc records only what is **different on the Alpha**.

## Why transplant instead of install

Running the x86 installer under FX!32 on an emulated Alpha is **compute-bound**:
es40 pins ~1.1 host cores while the guest disk grows kilobytes per minute — the
cost is x86 instruction translation, not I/O. A previous session measured the
installer's Red Bend unpack phase at roughly **70 files/hour (~2.8 MB/h)**, and
after **7.5 h** the progress bar was around 40%, the staging dir held ~47 MB
across ~200 files, and the real install into the program directory had **not
started at all**. The rate is too uneven to promise a finish time.

The same installer on an **x86** Windows 2000 guest under KVM finishes in about
**three minutes**. So the client is built there and moved here. **FX!32 is not
the limit — wall clock is**; the translated client itself runs fine.

This is the same offline-copy pattern [`docs/guests/w2kalpha.md`](../../guests/w2kalpha.md)
records for Winamp 2.5e, whose installer likewise will not complete on the Alpha.

## The transplant, as built

### 1. A clean x86 baseline

The payload is built on a **throwaway clone**, never on the live `win2000`
station. The base is a standalone byte-copy backup that predates all ICQ work:
`/data/gallery-guests/Win2000/win2k-pro.qcow2.rollback-20260715T223643Z` — a
Windows 2000 install with **no ICQ and no Mirabilis registry keys at all**. That
matters: the other available backup (`golden-backup-predhcp-20260821/`) already
has ICQ 2000b in it, and its registry would have muddied the delta below into a
2000b→2001b diff instead of a clean-install one.

The clone runs under plain QEMU with **no network at all**
(`-netdev user,restrict=on`, later dropped entirely) and never touches `vmbr-rn`.
Nothing about the live `win2000` station is read or written.

### 2. Make the installer bake the Alpha's paths

The Alpha's x86 program tree is `C:\Program Files (x86)\ICQ`, but an x86 Windows
2000 installs to `C:\Program Files\ICQ`. **Do not rewrite the paths afterwards.**
354 registry values carry the install path, most of them inside `hex(1)`
(UTF-16LE) blobs, and ICQ's own data files carry more; a textual rewrite is a
silent-corruption machine.

Instead, point the *source* machine's program-files root at the Alpha's path
**before running setup**, offline, in the clone's `SOFTWARE` hive:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ProgramFilesDir = C:\Program Files (x86)
```

Setup then offers `C:\Program Files (x86)\ICQ` as its own default and bakes that
path into every value it writes. Verified afterwards: **354 values contain
`C:\Program Files (x86)\ICQ` and zero contain a bare `C:\Program Files\ICQ`.**

(The installer's own destination picker is a dead end — its path field is not in
the tab order, and its directory tree only lists the lineage of the current
default, so a sibling folder cannot be selected by keyboard.)

### 3. Take the payload and the exact registry delta

Hives are copied out of the clone **before** and **after** the install, and the
difference is computed key-by-key *and* value-by-value. The delta is what gets
transplanted — not a whole subtree, which would overwrite the Alpha's own
native COM registrations with an x86 machine's.

What ICQ 2001b actually adds:

| Where | Count | What |
|---|---|---|
| `HKLM\SOFTWARE\Classes\…` | **1043 keys** | COM/ProgID/CLSID registrations, file associations (`.hpf`, `.pnq`, `.scm`, …) |
| `HKLM\SOFTWARE\Mirabilis\ICQ\2001b Beta` | 3 keys | version marker |
| `HKLM\…\CurrentVersion\App Paths\` | 5 keys | `ICQ.exe`, `ActiveListManager.exe`, `ActiveListServer.exe`, `ICQPatchManager.exe`, `NetDetectEdit.exe` |
| `HKLM\…\CurrentVersion\Uninstall\ICQ` | 1 key | uninstall entry |
| `HKLM\…\Internet Explorer\Extensions\{6224f700-…}` | 1 key | IE toolbar button |
| `HKLM\…\CurrentVersion\Shell Extensions\Approved` | values | ICQ's shell extension |
| `HKCU\Software\Mirabilis\ICQ\…` | **~27 keys** | `DefaultPrefs` (218 values), `Agent`, `AddressBooks` |
| `HKCU\…\CurrentVersion\Run` | 1 value | `"Mirabilis ICQ"` — launch on startup |

**Deliberately NOT transplanted**, though the installer writes them: the bundled
`HKCU\Software\America Online\AOD` tree (an AOL promo the exhibit does not want),
the Outlook add-in registration, and the pure session noise a key-level diff
picks up — `TypedURLs`, `RunMRU`, `UserAssist`, Explorer stream/cache state,
`Cryptography\RNG` seed, `Syncmgr`, `WindowsUpdate`. A value-level diff of two
boots of the *same* machine surfaces all of that; none of it is ICQ's.

The program tree itself is entirely self-contained: **275 files / 16 MB, all
under `C:\Program Files (x86)\ICQ`, with nothing under `WINNT`.** Only the
desktop and Start-menu `.lnk` shortcuts live outside it.

### 4. Land it on the Alpha

The Alpha's disk is a **plain raw image** (`assets/w2kalpha/nt.img`, NTFS in
partition 1 at byte offset 16384), so the program tree goes in with a loopback
mount and `cp -a` — no in-guest transfer, no installer, no unpacking:

```bash
mount -t ntfs-3g -o rw,offset=16384 <rig>/img/nt.img /mnt
cp -a payload/ICQ "/mnt/Program Files (x86)/ICQ"
```

The **registry cannot be landed the same way** — see the first trap below. The
`.reg` files are staged as ordinary files and imported *by Windows itself*.

## Four traps, each of which cost a boot

**1. Do NOT write the registry offline with `hivex`.** Merging 1054 keys into the
`SOFTWARE` hive with `hivexregedit --merge` produced a hive Windows 2000 refuses
to load: the guest bugchecks

```
STOP: c0000218 {Registry File Failure}
The registry cannot load the hive (file): \SystemRoot\System32\Config\SOFTWARE
```

A *single-value* offline edit is fine (the `ProgramFilesDir` change above boots
without complaint) — it is growth at this scale that NT 5.0 rejects. Stage the
`.reg` file offline and let in-guest `regedit` write the hive.

**2. `regedit` does nothing over the telnet exec channel.** `labctl exec` logs in
as a *network* logon, which has no window station; `regedit.exe` is a GUI binary,
so `regedit /s file.reg` returns **exit code 0 and silently imports nothing**
(and `regedit /e` writes no file — which is the cheap way to detect it). The
import must run in the **interactive auto-logon session**.

**3. Drive the interactive session from the StartUp folder, not the Run box.**
Typing into Start▸Run over the ctlsock is unreliable here: the Run combo's
autocomplete/MRU dropdown swallows keystrokes, so `icqimp.bat` arrives as `icq`
and the wrong thing executes. `ctltest.py` also cannot type a backslash, so a
full path cannot be typed at all. The reliable mechanism is a `.bat` dropped
offline into

```
C:\Documents and Settings\Kernel Hive\Start Menu\Programs\Startup\
```

which runs automatically, in the right session, as the right user, on next boot.
Have it write a marker file and export a few keys back out so the result is
checkable over telnet afterwards.

**4. The station's interactive user is `Kernel Hive`, not `Administrator`.**
`HKCU` state and the desktop / Start-menu shortcuts must land in that profile
(`Documents and Settings\Kernel Hive\`), while the telnet exec channel logs in as
`Administrator` — the two sessions have different `HKCU`. `Kernel Hive` *is* in
`Administrators`, so it can write `HKLM`. The transplanted values happen to carry
**no profile paths at all** (verified: zero values mention `Administrator` or
`Documents and Settings`), so the HKCU set is profile-independent and moves
across users unchanged.

**Bonus trap, ICQ's own:** the autostart value the installer writes is
**unquoted** —

```
"Mirabilis ICQ" = C:\Program Files (x86)\ICQ\icq.exe -minimize
```

With two spaces in the path, Windows resolves that to the **`C:\Program Files`
folder** and opens an Explorer window at every logon instead of starting ICQ.
Quote it:

```
"Mirabilis ICQ" = "C:\Program Files (x86)\ICQ\icq.exe" -minimize
```

## Where ICQ 2001b keeps account state (it is NOT the registry)

After UIN `50010` signs in, `HKCU\Software\Mirabilis\ICQ` holds only install-level
preferences plus an `Owners\50010` marker. The per-account state is **files,
inside the program directory**:

| Path (under `C:\Program Files (x86)\ICQ\`) | What |
|---|---|
| `2001a\50010.dat` / `.idx` | the account database — prefs, the saved password, **and the connection settings** |
| `2001a\50010tmp.dat` / `.idx` | its working copy |
| `CL\50010.fb` | the SSI / feedbag contact-list cache |
| `UIN\50010.uin` | the registered-UIN marker (plain INI: UIN, nickname) |
| `sec\sec.50010.ini` | privacy / security settings |
| `DataFiles\50010`, `Plugins\Info\Info50010.*`, `Plugins\ExtContacts\50010.dat` | per-account plugin state |

`2001a\50010.dat` is a **named-record store** — `strings` shows the field names
(`HostName`, `PortNumber`, `ConnectionType`, `ResolveIP`, `ContactListOnServer`,
…). Records are written lazily, so a setting that has never been touched has no
record at all, and toggling it makes the name appear. That is how the keep-alive
record was located (below).

Two connection values ALSO live in the registry, under
`HKCU\Software\Mirabilis\ICQ\DefaultPrefs`:

```
"Default Server Host" = "10.99.0.2"
"Default Server Port" = dword:00001446      (= 5190)
```

**These are honoured.** A single-value offline `hivex` edit of the Kernel Hive
`NTUSER.DAT` set the host, and the client's Preferences ▸ Connections ▸ Server
tab then showed `10.99.0.2` — the registry value *is* the client's server host.

## The account is PORTABLE between machines — configure it where the mouse works

**This is the technique that finished the station.** ICQ 2001b's account is
entirely the files above, so it can be carried between an Alpha guest and an x86
guest **in both directions**, as long as the install path is identical
(`C:\Program Files (x86)\ICQ` on both — which is exactly what §2 arranged).

Proven both ways:

- **Alpha → x86.** The `50010` account files plus the `HKCU\Software\Mirabilis`
  subtree were dropped into a throwaway x86 Windows 2000 clone that already had
  ICQ 2001b installed at the same path. ICQ started **as `50010`, with no
  registration wizard**, and its Preferences window was titled *"Owner
  Preferences For: w2kalpha"*.
- **x86 → Alpha.** The settings were made there (below), ICQ was closed with
  **Main ▸ Shut Down**, Windows was shut down cleanly, and the changed files were
  copied back onto the Alpha's disk. The Alpha then signed in with them.

The x86 clone is the **config bed**: it runs under KVM with `-device usb-tablet`,
so absolute pointing works perfectly and the ICQ UI can simply be clicked. Use
QMP `input-send-event` with `abs` axes (0..32767 across the screen) — `qmp-type.py
--mouse` is a *relative* HMP `mouse_move` and a tablet guest ignores it, so the
cursor never moves and every click lands on whatever was already under it.

### `Keep connection alive` = the `UseFirewallSessionTimeout` record

It has **no registry value**; it lives in `2001a\<UIN>.dat` and can only be set
through Preferences ▸ Connections ▸ Server. It ships **OFF** and is load-bearing:
without it a post-wake ICQ 2001b sits on a zombie socket instead of reconnecting.

Located by measurement — the account files were copied out before and after
ticking the box on the config bed:

| File | Result |
|---|---|
| `2001a\50010.dat` / `.idx` | **CHANGED** (same size — in-place record edits) |
| `CL\50010.fb`, `UIN\50010.uin`, `sec\sec.50010.ini` | unchanged, byte-identical |

and the new strings that appeared in `50010.dat` were
`UseFirewallSessionTimeout`, `LastSelectedPreferencesTabClsId`, `NoviceUserTime`,
`Stats_ICQMenuClicks`, `UserCategory` — of which **`UseFirewallSessionTimeout` is
the keep-alive flag** (it sits under the tab's Proxy/Firewall group). So the
whole setting travels in ONE file, and `strings … | grep -c
UseFirewallSessionTimeout` is a cheap offline check that a disk carries it.

## Driving the client on the Alpha

**The pointer works.** An earlier note here said it did not; that was a
tooling artefact, not a station defect — see
[the pointer section](#the-ctlsock-pointer-trap-hold-the-connection-open) below.
Keyboard notes that remain useful:

- **`Alt`+`Tab` first.** A window ICQ pops up does not necessarily have focus; its
  title bar renders grey. Tab/Space then go to the *taskbar* instead of the
  dialog. `Alt`+`Tab` turns the title bar blue, and only then does Tab reach the
  dialog's controls. ICQ 2001b's **main panel keeps itself out of the taskbar**,
  so once focus leaves it, `Alt`+`Tab` cannot get back to it — use the pointer.
- **ICQ's skinned buttons show focus** once the window is active — `EXISTING
  USER` picks up a teal border — so a screendump after each `Tab` tells you where
  you are. From the wizard's first screen it is `Tab` ×2 → `EXISTING USER`.
- **The one-time *IMPORTANT NOTICE*** blocks every cold boot until its *"Don't show
  this message again"* box is ticked, and that box sits at the END of a tab order that
  is not the visual order: `Quit Session` → `I Agree, Start ICQ` → the notice text →
  the checkbox. From the dialog's initial focus, **`Shift`+`Tab` lands on the
  checkbox**; `Space` ticks it, then `Tab` ×2 returns to `I Agree`. It is already
  ticked in the golden.
- **The shm framebuffer does not capture the mouse cursor** on a Windows guest
  drawing a software cursor, so a screendump cannot show you where the pointer is.
  To read the real position back, **press the left button on the desktop and
  drag**: Explorer paints a rubber-band rectangle whose two corners are the true
  press point and the true current point.
- Budget minutes, not seconds, per step: the very first launch of `Icq.exe` took
  **~10 minutes** of FX!32 translation before the window painted. It is much
  quicker once FX!32 has cached the translation — and that cache is on the disk,
  so it survives into the golden.

### The ctlsock pointer trap: HOLD THE CONNECTION OPEN

`MOVEA` on this station is **pixel-exact**, but only from a client that keeps its
connection open. Measured on the live station at 1280×1024, rubber-band readback:

| Client style | `MOVEA 200 150` then drag to `MOVEA 400 300` | Result |
|---|---|---|
| **one connection, held open, 8 s settle first** | band drawn from **(200,150) to (400,300)** | **exact** |
| one-shot per verb (`labctl mctl` ×3) | **no band at all**; cursor parked at **(0,0)** | every move silently dropped |

The cause is in `ctlsock.h`: **every new connection schedules a paced corner-home**
(`m_home_polls = max(w,h)/96 + 4` = 17 poll steps at the gui thread's ~50 Hz, so
roughly a third of a second), and `move_abs` **returns early — dropping the
request — while that home is still pacing, yet `handle_line` still acks `OK`.**
A tool that connects, sends one `MOVEA`, and disconnects therefore has its move
discarded and leaves the cursor wherever the home slam put it. Results look
random because they depend on where the cursor started and how far the home got.

Two consequences worth keeping straight:

- **Visitors are not affected.** The streamhost daemon holds ONE long-lived
  mamesock connection and *resends the current target continuously*, so the first
  post-home move lands and tracking is correct from then on.
- **`labctl mctl` is unusable for pointer work on this station** — one process per
  verb is one connection per verb. Use a held-open client (this stream's
  `ptr.py` pattern: connect, sleep, then send).

The earlier "the believed position does not track the real one" diagnosis, and the
`MOVEA 1126 341` → `765,350` / `258,262` measurements behind it, are explained by
this drop-during-home race; they were taken with one-shot connections. Pointer
**acceleration** was already correctly ruled out (the guest is 1:1:
`MouseSpeed=0`, thresholds 0, sensitivity 10).

**Separately, and still open:** this station's es40 binary
(`assets/w2kalpha/es40`, built 2026-08-16 20:48) **predates fork commit
`936760c`** ("ctlsock: per-guest pointer gain"), which its sibling es40 station
`tru64` runs. `strings assets/w2kalpha/es40 | grep -c ES40_POINTER_GAIN` is **0**;
for `assets/tru64/es40` it is **2**. That commit also fixed PS/2 `0xe6` (Set
Scaling 1:1) recording scaling as 2, and its message names "the same doubling
w2kalpha's pointer showed". The measurement above says the *current* binary
nonetheless lands 1:1 on this guest, so there is nothing to fix urgently — but the
two es40 stations are on different builds, which is exactly the kind of coupling
[`the uncoupling rule`](../../GUEST-TIERS.md) exists to remove. Rebuilding
w2kalpha's es40 **orphans `golden.axp`** and needs a cold re-bake, so it is its
own task.

## Persona

| | |
|---|---|
| UIN | **`50010`** (NT 5.0 on Alpha), nickname `w2kalpha` |
| Password | gitignored `registry/local.env` `RETRONET_ICQ_W2KALPHA_PASS` (**6–8 chars** — the server enforces the ICQ-era limit) |
| Server | **literal `10.99.0.2` port `5190`** — verified, no DNS in the path |
| Roster | **SSI / server-stored** — no client-UI seeding, no golden recapture per roster change |

`rn-tool.py login 10.99.0.2 5190 50010 <pass>` completes the real OSCAR BUCP
handshake, which is the check that the account works before any client is
involved. **HiveBot only greets UINs listed in `RN_BOT_PERSONAS`** in
`/etc/retronet/bot.env`; `50010:w2kalpha` is present in the file, and the bot must
be **restarted** to pick it up (check the running process, not the file:
`tr '\0' '\n' < /proc/$(systemctl show -p MainPID --value retronet-bot)/environ | grep PERSONAS`).

## Acceptance — measured 2026-08-24

**The literal server host is VERIFIED, not inferred.** A `tcpdump` on the host end
of the station's veth (`w2kalpha-h`) across a full cold boot and sign-in shows the
guest send **`10.99.0.17.1029 > 10.99.0.2.5190 [S]`** with **no `login.icq.com`
DNS query anywhere in the capture** — the only DNS at all was `web.icq.com` (the
client's banner/welcome content). So this station does **not** ride the DNS hijack
that first-login used to depend on; it dials the literal address from
`Default Server Host`.

**The `labctl reset` acceptance run** (the fleet's rule: a reset seconds after
sign-in proves nothing, because the server session is still valid — idle out
first):

| Step | Evidence |
|---|---|
| guest idle-paused (`SH_IDLE_PAUSE_SECS=60`), then waited | `50010` **disappeared** from the gateway session list at 00:58:23Z — the server dropped the frozen client |
| `labctl reset w2kalpha` at 00:59:18Z | session list held only `10000` immediately before |
| reconnect | SYN at 00:59:33Z — **15 s** after the reset |
| **fresh session** | new source ports **1031** (auth) and **1032** (BOS); the pre-reset pair was 1029/1030. `online_seconds` **16** |
| **silent** | framebuffer at t+30 s: pristine desktop, ICQ panel titled `50010` reading **Online**, **no password prompt, no dialog** |
| still literal-host | zero DNS packets in the reset capture |

**Also measured:**

| | |
|---|---|
| Telnet exec channel | works — `labctl exec w2kalpha "ver"` returns `Microsoft Windows 2000 [Version 5.00.2128]`; warm round-trips **9.7 / 11.3 / 14.6 s** (that is the telnet re-login cost on an emulated Alpha, not a regression). A **paused** guest cannot answer at all, so wake it (any reset) before an exec |
| Desktop responsiveness | **no regression, measured**: es40 CPU over a 40 s window on the idle desktop is **111.7 % of one core with ICQ online** and **111.7 % on the pre-ICQ golden** — identical. es40 simply runs hot whatever the guest is doing, which is why idle auto-pause exists |
| Registration wizard | does not appear — `Owners\50010` is in the golden's `NTUSER.DAT` |

**NOT yet proven, and why** — both are blocked on wave-end steps this stream is
not allowed to run:

- **SSI roster by name.** `rn-tool.py buddies 50010` returns **empty**: the
  server-side cross-list is seeded once at wave end by
  `seed_contacts.py ssi --apply`. The client's empty contact list is therefore
  consistent with an empty *server* roster, not with a sync failure.
- **HiveBot greeting.** The running bot's environment does not contain
  `50010:w2kalpha` (the file does); it needs `systemctl restart retronet-bot` on
  labhost. Note `51000` (winxp, same wave) has exactly one buddy — HiveBot —
  which suggests the bot adds that pairing when it first greets, so the restart
  likely clears both items at once.

## Golden lineage & rollback (FULL paths)

- **LIVE golden pair** (2026-08-24): `assets/w2kalpha/nt.img` +
  `assets/w2kalpha/golden.axp` — Windows 2000 desktop at 1280×1024 with **ICQ
  2001b connected as `50010`**, keep-alive ON, server `10.99.0.2:5190`.
- **Rollback to the pre-ICQ station**, byte-copy, SHA256-verified **with es40
  stopped**: `assets/w2kalpha/golden-backup-preicq-20260824/` (`nt.img`,
  `golden.axp`, `es40.cfg`, `SHA256SUMS`). Restoring is two `cp`s over the live
  pair and a `systemctl restart streamhost@w2kalpha`.
- Also kept: `nt.img.preicq-20260824` (the disk as it was before the ICQ tree was
  laid in) and `nt.img.bak-icqland-20260824` (the landed-but-not-yet-baked disk).

### How this golden was baked

The documented recipe ([`docs/guests/w2kalpha.md`](../../guests/w2kalpha.md)) is
the serial menu's option 5, *save state and exit* — atomic by construction. **It
is not reachable on a running station**: `pumps.py` owns the first connection to
es40's serial listener and only ever reads, and es40 keeps writing to that first
socket, so a second client to port 21964 gets no menu output and killing the pump
does not hand the port over. Baking a *live* station therefore used the ctlsock
instead, with the pairing enforced by hand:

1. `SAVEST <work>/golden-new.axp` over `ctl.sock` (hold the connection).
2. **`SIGSTOP` the es40 pid the instant the ack returns** — the ack means
   `SaveState` returned, and the freeze makes further guest writes impossible.
   (`SIGSTOP` is safe on this station since fork commit `fc82f05`.)
3. Copy `work/img/nt.img` while it is frozen. That disk + that `.axp` are the
   coherent pair.
4. `SIGCONT`, `systemctl stop`, `mv` the pair into the asset tree, restart, and
   **verify the restore on the framebuffer** — which is what caught nothing here,
   but is the only proof the pair is coherent (an incoherent pair bugchecks
   STOP 0x7B).

**Cold bring-up gotcha: turn idle auto-pause OFF first.** A cold boot with no
visitor gets `SIGSTOP`ped after 60 s (`[idle] no sessions for 60s -> guest
paused`) and never finishes — the first attempt sat at *"Initializing LSI STORAGE
#0"* for five minutes, absorbing a 137 s host freeze. Set
`SH_IDLE_PAUSE_SECS=0` in the station's `station.env`, restart, do the bring-up,
then put `60` back (and diff against the `.bak` to prove you did).

## Operating it

```bash
ssh lab 'labctl exec w2kalpha "ver"'                    # telnet exec over the bridge
ssh lab 'labctl exec w2kalpha "ipconfig"'               # DHCP 10.99.0.17, DNS 10.99.0.2, NO default gateway
ssh lab 'bash /data/vms/streamhost/stations/w2kalpha/rn-tapnet.sh show'
ssh lab 'labctl reset w2kalpha'                         # restore golden -> ICQ self-reconnects in ~15 s
# is the persona online? (server-side)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
# the server-side SSI roster 2001b syncs on login
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 50010'
# does this disk carry the keep-alive flag? (offline, no boot needed)
ssh lab 'strings "/mnt/Program Files (x86)/ICQ/2001a/50010.dat" | grep -c UseFirewallSessionTimeout'
```

**The clean-shutdown rule.** ICQ 2001b writes
`HKCU\Software\Mirabilis\ICQ\Owners\<UIN>` — the marker that says "this machine
has an account" — only when it **exits cleanly**. Kill the emulator with the
client still running and that key is missing on the next boot, so ICQ starts into
the **registration wizard again** as if it had never been configured, even though
all its `50010.*` data files are still on disk. Always let ICQ exit through
**Main ▸ Shut Down** (and Windows through a real shutdown) before stopping the
emulator, and only then bake.
