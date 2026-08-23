# w2kalpha ICQ station — the stock x86 client, transplanted onto the Alpha

**Status: TRANSPLANT PROVEN, UIN `50010` SIGNS IN — station NOT yet onboarded.**
`w2kalpha` (Windows 2000 RC2 build 2128 for
**Alpha AXP**, on the es40 AlphaServer ES40 emulator) carries the fleet's
standard **x86 ICQ 2001b (build 3659)** — the *same binary* the Intel stations
run — executed on Alpha by **FX!32 / Wx86**, Windows NT's x86 emulation layer.
The client was **not installed here**: it was installed on a throwaway x86
Windows 2000 clone and moved across as a finished payload, because the
installer itself is too slow to complete on an emulated Alpha (below). The web
half of this station's retronet membership is
[`w2kalpha-retronet.md`](w2kalpha-retronet.md); the fleet ICQ recipe is
[`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md). This doc records only what is
**different on the Alpha**.

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

The clone is reflink-copied into the sandbox, runs under plain QEMU with **no
network at all** (`-netdev user,restrict=on`, later dropped entirely), and never
touches `vmbr-rn`. Nothing about the live `win2000` station is read or written.

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

Worth knowing before anyone tries to pre-seed an account or move one between
machines. After UIN `50010` signs in, `HKCU\Software\Mirabilis\ICQ` still holds
only **27 keys** — install-level preferences, no `Owners` subtree, no saved
password. The per-account state is **files, inside the program directory**:

| Path (under `C:\Program Files (x86)\ICQ\`) | What |
|---|---|
| `2001a\50010.dat` / `.idx` | the account database — prefs and the saved password |
| `2001a\50010tmp.dat` / `.idx` | its working copy |
| `CL\50010.fb` | the SSI / feedbag contact-list cache |
| `UIN\50010.uin` | the registered-UIN marker |
| `sec\sec.50010.ini` | privacy / security settings |
| `DataFiles\50010`, `Plugins\Info\Info50010.*`, `Plugins\ExtContacts\50010.dat` | per-account plugin state |

The two connection values that *are* in the registry live under
`HKCU\Software\Mirabilis\ICQ\DefaultPrefs`:

```
"Default Server Host" = "login.icq.com"
"Default Server Port" = dword:00001446      (= 5190, already correct)
```

`login.icq.com` resolves to the gateway through the retronet DNS hijack, which is
why the **first login succeeds with no connection settings touched at all**.
"Keep connection alive" has no registry value — it lives in the account DB, so it
must be set through Preferences ▸ Connections ▸ Server in the client UI.

## Driving the client on the framebuffer

The pointer is the problem, not the keyboard. On this station the ctlsock's
absolute pointer does **not** land where asked (a calibration click on a radio
button changed nothing, and `docs/guests/w2kalpha.md` already records `MOVEA`
pinning the cursor to the corner) — so **drive ICQ entirely by keyboard**:

- **`Alt`+`Tab` first.** A window ICQ pops up does not necessarily have focus; its
  title bar renders grey. Tab/Space then go to the *taskbar* instead of the
  dialog, which opens the Start menu and looks like nothing happened. `Alt`+`Tab`
  turns the title bar blue, and only then does Tab reach the dialog's controls.
- **ICQ's skinned buttons do show focus** once the window is active — `EXISTING
  USER` picks up a teal border — so a screendump after each `Tab` tells you where
  you are. From the wizard's first screen it is `Tab` ×2 → `EXISTING USER`.
- `Space` activates; `Enter` takes the wizard's default (`Next` / `Start`).
- **The shm framebuffer does not capture the mouse cursor**, so a screendump can
  never tell you where the pointer is — another reason to ignore it.
- Budget minutes, not seconds, per step: the first launch of `Icq.exe` took
  **~10 minutes** of FX!32 translation before the window painted, with es40
  burning ~1.1–1.35 host cores throughout. It is much quicker once FX!32 has
  cached the translation.

## Bring-up rig — a namespaced clone, never the live station

The checkpoint bake in [`docs/guests/w2kalpha.md`](../../guests/w2kalpha.md)
requires a clone anyway. This one lives under
`/data/vms/sandbox/icq-w2kalpha-b/rig/`, namespaced end to end so it can share
the retronet bridge with the live station without colliding:

| Thing | Live station | Bring-up clone |
|---|---|---|
| veth pair | `w2kalpha-g` / `w2kalpha-h` | `w2kab-g` / `w2kab-h` |
| guest MAC | `52:54:00:52:4e:11` | `52:54:00:52:4e:d2` (outside the reservation scheme) |
| guest IP | reserved `10.99.0.17` | DHCP **pool** address |
| guard chain | `W2KALPHARN-IN` | `W2KABICQRN-IN` |
| es40 serial | 21964 / 21965 | 22016 / 22017 |
| shm / ctlsock | station dir | rig dir |

The clone **cold-boots** (no `golden.axp` in the rig) so its `mac=` is honoured —
a restore would bring back the live MAC and put a duplicate on the bridge.

**The pool address is not predictable — scope the guard chain to the lease you
actually got.** `retronet-dhcp` serves `10.99.0.100–200`; this rig asked for
`.102` and was handed **`.100`**, which left it briefly running with its
containment chain scoped to an address it did not have. Read the real lease off
the bridge before trusting containment:

```bash
ip neigh show dev vmbr-rn | grep -i <rig-mac>
RN_TAP_IF_G=w2kab-g RN_TAP_IF_H=w2kab-h RN_TAP_GUEST_IP=<real-lease> rn-tapnet.sh up
```

`rn-tapnet.sh` hardcodes `IN_CHAIN`, so the rig keeps its own edited copy.

## Persona

| | |
|---|---|
| UIN | **`50010`** (NT 5.0 on Alpha), nickname `w2kalpha` |
| Password | gitignored `registry/local.env` `RETRONET_ICQ_W2KALPHA_PASS` (**6–8 chars** — the server enforces the ICQ-era limit) |
| Server | `10.99.0.2` port `5190` |
| Roster | **SSI / server-stored** — no client-UI seeding, no golden recapture per roster change |

`rn-tool.py login 10.99.0.2 5190 50010 <pass>` completes the real OSCAR BUCP
handshake, which is the check that the account works before any client is
involved. **HiveBot only greets UINs listed in `RN_BOT_PERSONAS`** in
`/etc/retronet/bot.env`; `50010:w2kalpha` is present, and the bot must be
restarted to pick it up.

## Acceptance so far, and what is still owed

**Proven, on the framebuffer and server-side:**

| | Evidence |
|---|---|
| The transplanted x86 client **runs on the Alpha under FX!32** | `ICQ Registration` and then the main client window paint at 1280×1024; the client window's title bar is the literal string **`50010`** |
| UIN `50010` **signs into the retronet gateway** | gateway session list went `['10000']` → `[('10000', …), ('50010', 36)]` |
| **`Auto Save Password` persists** | after a full power cycle, ICQ started with **no password prompt** and `50010` reached the gateway again (`online_seconds` 99) — only the one-time *IMPORTANT NOTICE* stood in the way |
| **Launch on startup works** | the `HKCU\…\Run` value starts `Icq.exe` unattended at logon (once quoted — see the trap above) |
| Registration reports **authorization off** | wizard's Privacy page: *"All users may add me to their Contact List"* |
| Server port already correct | `Default Server Port` = `dword:00001446` = **5190** |

**Still owed before this station can be called onboarded:**

1. **`Keep connection alive` = ON.** It is not a registry value — it lives in the
   account DB (`2001a\50010.dat`) and can only be set through Preferences ▸
   Connections ▸ Server. **This is blocked on the station's known pointer defect**
   (see below), not on anything ICQ-specific. It is load-bearing: without it a
   post-wake ICQ 2001b sits on a zombie socket instead of reconnecting.
2. The `labctl reset` acceptance run — idle until `50010` drops off the gateway,
   *then* reset, and prove a genuinely fresh session (new source port, low
   `online_seconds`), the SSI roster rendered by name, and a HiveBot greeting.
3. Golden re-bake with the **live** MAC, staged into the live asset tree, plus
   the byte-copy backup and the exec-channel / responsiveness re-checks.
4. `roster.json` → `onboarded: true`, and `retronet.planes` → `["web","icq"]`.

### The blocker: this station's pointer is not usable

`docs/guests/w2kalpha.md` records the pointer as "open-loop absolute, NOT yet
pixel-exact", and that is exactly what stopped this stream short. Measured here:

| Requested `MOVEA` | Cursor actually landed |
|---|---|
| `1126, 341` | ~`765, 350` (y right, x short by 361) |
| `1126, 341` (30 s settle) | ~`258, 262` |
| click on a radio button | no effect at all |

So it is not a pacing artefact and not acceleration — the guest's mouse is
already configured 1:1 (`MouseSpeed=0`, `MouseThreshold1/2=0`,
`MouseSensitivity=10`, verified in `HKCU\Control Panel\Mouse`), which is what
`ctlsock.h` says the open-loop tracking requires. The believed position simply
does not track the real one.

And **the keyboard cannot substitute**, because ICQ 2001b's main panel keeps
itself out of the taskbar and so is **not reachable by `Alt`+`Tab`**: once focus
leaves it, Tab goes to the Start button instead. The panel is focusable only in
the moment it first appears. Preferences therefore needs either a working
pointer, or the config transplanted from an x86 sibling where the mouse works.

**The obvious next move** is to configure Server host + Keep-alive on a throwaway
**x86** clone (where QMP drives the mouse reliably), then carry across the account
files listed above plus `HKCU\…\Mirabilis\ICQ\Owners\50010`. That was not
attempted here, so whether ICQ's DB is portable between machines is **unverified**
— do not assume it.

## Operating it

```bash
ssh lab 'labctl exec w2kalpha "ver"'                    # telnet exec over the bridge
ssh lab 'labctl exec w2kalpha "ipconfig"'               # DHCP 10.99.0.17, DNS 10.99.0.2, NO default gateway
ssh lab 'bash /data/vms/streamhost/stations/w2kalpha/rn-tapnet.sh show'
ssh lab 'labctl reset w2kalpha'                         # loadvm golden -> ICQ self-reconnects
# is the persona online? (server-side)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
# the server-side SSI roster 2001b syncs on login
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 50010'
```

**The clean-shutdown rule.** ICQ 2001b writes
`HKCU\Software\Mirabilis\ICQ\Owners\<UIN>` — the marker that says "this machine
has an account" — only when it **exits cleanly**. Kill the emulator with the
client still running and that key is missing on the next boot, so ICQ starts into
the **registration wizard again** as if it had never been configured, even though
all its `50010.*` data files are still on disk. This cost a full bring-up cycle
here. Always let Windows shut down to *"It is now safe to turn off your
computer"* before stopping es40, and only then bake.
