# Nokia 9300 shell detail — EikSrv, application keys, the SDK-emulator oracle

Sibling of [`candidate-symbian-s80.md`](candidate-symbian-s80.md) §H7. Holds
the mechanism-by-mechanism detail, the wall evidence and the SDK-emulator
trace facts that would otherwise bloat the main document. Facts from agents
B1 and X1's full reports (2026-09-24), B4's and B6's full reports
(2026-09-25: the third-app deadlock fix and Desk's main pane), and — as of
2026-09-25 12:00 UTC — B7's, B5's and N7's own full written reports
(`B7-rom-eiksrv.md`, `B5-hle-dos.md`, `N7-opera-home.md`), superseding the
coordinator-relayed facts an earlier fold carried for them. As of
2026-09-25 12:00 UTC, agent M1 is racing Messaging's "Problem starting
Messaging center" wall and a new agent is racing Telephone's black first
screen; the integration head is fork branch `s80-integration` @
`e43db215e`, and station branch `nokia9300` @ `a5a7c0e0` is built from it,
proven, and still dark-launched. Nothing here is disassembly or a ROM byte
dump — mechanisms and traces only, per the repo's abandonware rules.

## The mechanisms (agent B1, fork branch `s80-shell` @ `19308cbd0`)

Who owns the buttons on the real device: the Eikon server's UI library
`EikSrvUi.dll` ("EikAppKey" active object) captures the application buttons'
key ups and downs (`RWindowGroup::CaptureKeyUpAndDowns` is in its import
list) and launches or foregrounds the bound app; `SysAp.app` holds Desk and
"My own" the same way. Before this wave EKA2L1 replaced the Eikon server
with the HLE `eikappui_server` ("EikAppUiServer"), which owned no keys, and
`SysAp` never ran under `--run` — so nobody on the emulator received the
buttons at all.

| # | Mechanism | Status | Why |
|---|---|---|---|
| ii | **HLE in the window server** — `window_server::s80_handle_app_key()` (`window.cpp`): on an S80 device scancodes 0xB4–0xBB are swallowed (the focused app never sees them, as on the device); a key-down schedules `WsS80AppKeyEvent` on the emulator's timer thread → `switch_to_app(uid)`: the app's topmost window group goes to ordinal position 0 and takes focus if it is running, else the app-list server launches it. Table: Desk `0x101F8E4F`, Telephone `0x101F4D0B`, Messaging `0x100053B3`, Web `0x101F4DE8`, Contacts `0x100007ED` (Cmgr), Documents `0x10003A64`, Calendar `0x10003A5C`, My own `0x100007BA` (File manager, the ROM's factory default). The HLE steps aside as soon as any guest holds a `CaptureKey`/`CaptureKeyUpAndDowns` on that key, so a ROM Eikon server takes the buttons over with no further code change. `switch_to_app()` is public, for a future host control channel. | **KEPT — proven, and now runs three apps at once (B4, below)** | it is the device's behaviour minus the ROM code that implements it |
| — | **Captured keys were never delivered**: `io.cpp:198` looked up `key_capture_requests[evt.key_evt_.code]`, and the raw event's code is always 0. Rewritten so a `CaptureKey` request (keyed by translated key code) wins the translated key event and a `CaptureKeyUpAndDowns` request (keyed by scan code) wins the up/down events; winner = highest signed priority whose modifier mask matches, newest on a tie; the winner gets the event **instead of** the focus (nonnga wserv `EVENT.CPP` semantics). Requests are dropped on `CancelCaptureKey*` and in `~window_group`. Written independently, the same shape as EKA2L1-WEB's `dc3344530` key-capture rewrite (see the main doc's §Prior work found). | **KEPT** | prerequisite for the ROM EikSrv ever owning the keys; also fixes S60 CaptureKey users |
| — | Session ops that parked a server forever: `ClearHotKeys` (→ `KErrNone`), `Start/CompleteCustomTextCursor` (→ `KErrNotSupported`), `SetSystemPointerCursor`, `Claim/FreeSystemPointerCursorList`, `Set/ClearDefaultSystemPointerCursor` (→ `KErrNone`). | **KEPT** | the ROM Eikon server issues all of them while constructing (log showed `Unimplemented ClOp: 0x31/0x2f/0x48`) |
| — | chimera-core 0030 (see the main doc's prior-work sweep): a window group remembers its owner process by kernel id and checks it is alive before touching the pointer. | **KEPT** | an app launched from Desk or the buttons outlives its starter |
| i | **Run the ROM's real Eikon server**: `EKA2L1_ROM_EIKSRV=1` skips the HLE EikAppUiServer, Notifier and ViewServer; Desk's connect then summons `eiksrvs.exe`, which creates `EikAppUiServer`, `ViewServer`, `AlarmServer`, `AlarmAlertServer`. | **PROVEN stable, but opt-in and unused by the station (B7, branch `s80-rom-eiksrv` @ `ecd09e3d7`, merged onto `s80-integration`)** — Desk paints completely, with the ROM's own status pane, and the fixed binary ran 22 minutes / 2,677 process spawns with no crash; see "The ROM's own Eikon server" below | it gives the six generic buttons, the Menu-hold task list and the status pane from ROM code — mechanism ii (the HLE switch) is what the station ships instead |
| i' | **Start `Starter.exe` / `SysAp` with a trimmed start list.** Starter, SysAp and `Startup.app` all reach the DOS server (phone link); this needed an HLE DOS server before it could run at all. | **ADVANCED, one wall from Desk (B5, branch `s80-hle-dos` @ `8cbd1b772`, merged onto `s80-integration`)** — see "The ROM's own boot chain" below | the HLE DOS server now answers the ROM's real DOS-server client contract; the chain runs past `eiksrvs` to the phone server, whose exact exit wall is now named and located but not yet fixed |
| iii | **Desk launching apps itself / the Desk main pane.** Desk paints its own chrome (icon, CBA labels) but the AppList server's contribution to the main pane — the date header, the application-group grid, the wallpaper — was missing. | **RESOLVED (B6, branch `s80-desk-content` @ `4a12074c2`)** — see below | the 7.0s AppList server table plus seven EKA1 locale calls were the missing piece, not C: state |

### Desk's main pane, filled in (agent B6, branch `s80-desk-content` @ `4a12074c2`)

The empty main pane was a chain of six failing service calls, not a missing
C: file or a missing shell value — two rival theories that both lost. B1 had
already ruled out C: state by tracing the file server (Desk opens
`skinerin.rsc`, the `s80*` resources and `desk.aif`, creates `Shortcuts.dat`
and `101f8e4f.ini`, and never even reaches `desk_content.rsc`); on a fresh
C:, Desk builds its own state from the ROM's own
`Z:\System\Apps\desk\desk_content.rsc`, and needs no Startup/SysAp/SysState
value either — it writes its own `Desk state` (3). The six links, in the
order they stopped Desk, each proven by the next frame or log: (1) a
synchronous BackupServer `NotifyLockChange` (op 26) that was never
completed — fixed on W2's branch; (2) `AppListServer` op 0, which 7.0s uses
for `GetAllApps` but EKA2L1 treated as a dummy — B6 implemented the full
7.0s AppList table (`GetAllApps` 0, `GetEmbeddableApps` 1, `GetNextApp` 2,
`GetAppInfo` 5, `GetAppCapability` 6, `StartApp` 7/8,
`StartDocument`/`CreateDocument` 0xe/0xf, `AppForDocument` 0x11,
`SetNotify`/`CancelNotify` 0x19/0x1a, icon-by-size 0x1c, `GetFilteredApps`
0x22 — full table in `B6/applist-table.md`, derived from the SDK's WINS
`APGRFX.DLL` export bodies and checked against X1's SDK-emulator trace;
every other op on this level now completes with `KErrNotSupported` instead
of hanging its caller forever); (3) empty dates everywhere — seven EKA1
locale exec calls (day/month names, date suffix, AM/PM), independently also
implemented by C1's branch (the coordinator told B6 to drop the overlap);
(4) 1–2 px tall labels — the 7.0s pixel-font-height bug (C1's fix) plus the
wrong GDR face (W2's fix); (5) blank folder icons — EKA1's `CFbsBitmap::Load`
draws ROM-image bitmaps (UID `0x10000041`) in place after
`RFs::IsFileInRom`, so the bitmap's "handle" is a **ROM address**, which the
window server had only ever looked up in the FBS object table; B6 made the
window server and FBS treat an EKA1 ROM-image handle as a real, readable
bitmap; (6) shortcuts drawn at list size and a tiny Desk title icon —
`GetAppIconByUidAndSize` always returned the AIF's first icon pair; B6 made
it return the exact size asked for, or else the largest that fits.

With all six answered, **Desk now shows its date header, the wallpaper, a
focus bar, the Personal/Office/Media/Tools folders with their icons, the
Clock and nokia.com shortcuts (with the shortcut arrow), the big Desk title
icon, and the command buttons Open / Write note / Note list** — this is
complete on a **fresh C: drive**, framebuffer-exact at 2× (1280×400, 0 of
128,000 2×2 blocks non-uniform), idling at 2% of one core and 231 MB RSS.
**Open** on the focused group enters it: Personal shows Telephone, Contacts,
Messaging and Calendar, with Exit on command button 4. The 9300's firmware
(5.22) shows a third command button, "Note list", that the SDK emulator and
the 2004 9500 lack — a firmware difference, not a bug. An optional golden
optimisation, `B6/apply-desk-state.sh`, pins the three files Desk itself
writes on first launch (`Shortcuts.dat`, `desk.ini`, `101f8e4f.ini`) into a
golden data dir byte-for-byte; it is not required — a fresh golden already
shows this Desk once the binary is built from this branch (or the
integration branch once it carries this commit) — and a golden with the
script applied paints pixel-identical to the fresh-C: case. **Still open,
not Desk-side:** Write note (command button 2) starts Note, which builds its
UI and then panics `USER 30` (`HBufC8::NewLC` with a negative length) in
CONE-path handling; Desk itself returns cleanly. The lower-left status pane
(profile, clock, signal/battery) is EikSrv/wserv territory, not Desk's — see
"The ROM's own Eikon server" below for the status pane and A2's clock-anim
work for the clock face itself.

## Walls: resolved this wave, and what is left

1. **The third-app wall — RESOLVED (agent B4, branch `s80-third-app` @
   `f1422f60f`, pushed, frame-proven). It was two separate bugs, not one.**
   Apps launched **one after another** by app key were simply **starved**:
   the redraw-spin bug below (mechanism behind item 4 of the main document's
   H7) kept the CPU busy, and W2's fix alone un-blocks this case. Apps
   launched **together** (`--run Desk --run Documents --run Web`)
   **deadlocked** for a second, independent reason: the skin client
   serialises "is SkinServer running, else start `skinloaderexe`" on a
   global mutex `SkinServerMutex`, and EKA1's `RMutex::CreateGlobal` silently
   **succeeded** on a duplicate name instead of returning
   `KErrAlreadyExists` (unlike semaphores, which already reject one) — so
   Desk, Documents and Web each created and owned their *own* skin server.
   The three skin loaders then all blocked on `FbsLargeBitmapAccess`, and a
   second, independent kernel bug — the legacy mutex's `signal()` woke a
   waiter without recording it as the new holder — left the count negative
   with nobody left to signal: a genuine deadlock, not just starvation
   (thread dump: three `apprun` threads waiting on "my skin server", three
   `skinloaderexe` threads waiting on the FBS mutex). Either fix alone
   un-deadlocks the triple launch; the duplicate-name fix is the one that
   leaves exactly one SkinServer running. Both are env-gated, on by default.
   **Result:** Desk, Documents and Web (and a fourth process, My own) all
   run together and switch by application key, each keeping its own state
   across every switch; a concurrent triple launch starts one SkinServer and
   all three apps paint. **New walls the same testing turned up, not fixed:**
   Sheet panics `USER 30` if it is running beside Desk when a third app
   starts (a view-server event; the panic stack is EUser ← Cone.dll's
   `CCoeAppUi` view code ← `ViewCli.dll` — plausibly the same class of
   missing-S80-branch bug as the window-server opcode table, §H1); because
   Sheet in that repro was launched with `--run`, its panic **closes the
   whole emulator** (`EXIT_STATUS=0`) — a station cannot depend on a
   `--run` app that can panic, which is why the station's own launcher uses
   the kiosk-home flag instead of `--run` for a fixed app. My own (File
   manager, the ROM's default) never finishes constructing its own UI even
   launched alone — a separate, per-app wall, not a process-count limit.
2. **The empty Desk pane — RESOLVED.** See mechanism iii above.
3. **The ROM's real Eikon server and Desk's status pane — PROVEN stable,
   still opt-in.** See "The ROM's own Eikon server" below: Desk now paints
   completely, with the ROM's own status pane, and the fixed binary has
   run 22 minutes and 2,677 process spawns with no crash — but the path
   stays opt-in, since mechanism ii (the HLE app-key switch) is what the
   station ships.

## The ROM's own Eikon server: a full Desk, proven stable (agent B7, branch `s80-rom-eiksrv` @ `ecd09e3d7`, merged onto `s80-integration`)

B7 took the `EKA2L1_ROM_EIKSRV=1` shortcut (mechanism i) from "Desk stays
black behind it, and the emulator SIGSEGVs after ~2.5 minutes" to a fully
painted, stable Desk. The walls fell in this order (each named from
log-ipc, the IPC watch, or gdb, and each proven by a framebuffer frame —
rule 9):

1. Nobody starts SecurityServer (Starter does it on the device); EikSrvUi's
   connect got KErrNotFound, its error path double-freed (`USER 44`), and
   Desk's re-summoned `eiksrvs` died the same way. Fixed by a **pre-start
   mechanism for ROM executables at boot** (`EKA2L1_PRESTART`, defaulting
   to SecurityServer).
2. ETel CUSTOMAPI / op 14 — B5's fix (merged).
3. EikSrvUi summons `PhoneServer.exe`; it needed exec 0x8000E5 (B5's fix),
   and the ROM's own server then exits −5 (B5's open wall below), panicking
   EikSrv with "PhoneServer start 1". Stood in for meanwhile:
   `EKA2L1_STUB_SERVERS="Phone Server"` — EikSrvUi only sends it ops 0 and
   300.
4. AppList op 7 (StartApp) was unimplemented, so a button press parked
   EikSrv — B6's `s80-desk-content` table, merged.
5. The upper half of the app strip stayed black: a window-tree dump showed
   an app's collapsed left skin panel — a shaped window, now 32×0 — still
   claiming its old 32×100 shape over the status pane window. Fixed: a
   shaped window's visible region is now clipped to the window's own
   extent, not the shape alone — this also paints the narrow status strip
   inside application views.
6. "state.val" (SharedData temp category 0x10005943, set by Starter to 201
   then 203 on the device) was missing; the alarm alert server kept
   refusing AlarmServer with KErrNotFound, restarting it about twice a
   second. Fixed with `tools/s80-sysstate` (a small stand-in `SysState.exe`,
   prestarted by default): the restart rate drops to **zero**.
7. **The actual host SIGSEGV**, found under gdb after 255 spawned
   processes: the multiple memory model never freed a dead process's
   address space, so process 256 got ASID −1 and a null count pointer.
   Fixed: address spaces are released when a process dies — a general fix
   for any long session that starts many processes, not specific to this
   path. **Proven: 2,677 spawns without a crash** (the worst-case run was
   stopped only by a host reboot, not by a fault).

Also fixed on this branch: an **EKA1 duplicate server-name check**
(servers only — the mutex check is B4's), closing exactly the gap Y2's
sweep had flagged as still open (see the main document's §Prior work
found), so a native EikSrv can no longer silently coexist with the HLE
stub instead of failing loudly. With everything above in: **Desk paints
completely** — icon and label, date header, Personal/Office/Media/Tools/
Clock/Nokia.com (needs B6's applist table), and CBA Open/Write note/Note
list — **with the left status pane drawn by the ROM** (skin swoosh, "no
network" antenna, battery). The application keys are handled by the ROM's
own Eikon server through the AppList server — op 5 with the app's UID,
then op 7 — exactly as X1's independent SDK-emulator trace shows the real
platform doing it (below); Documents opens with the title **"Document"**
(not the HLE launch's "cword"), a caret, and the full narrow status strip.
**Remaining differences from the real device:** no clock in the left pane
(that is A2's anim work, proven separately on this same branch tip); no
"Silent" profile text (the device shows none either, in its General
profile); indicators show "no network" rather than signal bars (faithful
to a phone-less device); PhoneServer stays stubbed until B5's TPhoneInfo
fix lands on this path — the 1 s "CuiWs" reconnect retry remains, since
CuiStarter is not run; `--run 0x10000865` (Startup.app as the shell) stops
on its own "Current city" first-boot wizard, which the golden's
`10000865.ini` does not skip on this path; and this branch alone carries
no K1/K2 keymap, so only digits typed into Documents arrived (letters were
lost) — the integration head carries K1's keymap, so this does not apply
to the merged head or the station. **This path stays opt-in and unused by
the station**: mechanism ii (the HLE app-key switch) is what `nokia9300`
ships, since it needs no ROM boot chain at all.

## The ROM's own boot chain (agent B5, model Claude Fable 5.1, branch `s80-hle-dos` @ `8cbd1b772`, merged onto `s80-integration`)

A fuller alternative to the `EKA2L1_ROM_EIKSRV=1` shortcut (mechanism i):
rather than skip straight to `eiksrvs.exe`, this boots the ROM's own
`Starter.exe` chain, which mechanism i' above found blocked on the phone-link
DOS server (Nokia's own SDK emulator swaps in a phone-less `ExampleDSY`
plug-in for the same server, for the same reason).

**The DOS server's client contract is public.** Nokia released the server
under the EPL with Symbian^3 (`SymbianSource/oss.FCL.sf.os.devicesrv`):
the server and client sources, the plug-in interface headers, and the
phone-less `ExampleDSY` stub the S80 SDK itself ships. B5 verified the
2002-era opcode numbering (the 9300's DosServer.exe predates Symbian^3's
renumbering) against a live IPC trace of the SDK emulator's own cold boot
(agent X1). B5's **HLE DosServer** answers exactly that sequence — create
a Helper subsession, `GetStartupReason` → ENormal, `GetSWStartupReason` →
100 (Normal), close — the same three-call exchange the SDK emulator's own
successful phone-less boot makes, and nothing else touches the DOS server
before EikSrv is up, matching the SDK trace. (A second form — running the
ROM's own `DosServer.exe` against a real plug-in — was scoped but not
pursued: the ROM's `Nokia.dsy` immediately opens the unmodelled
`ISA_IF_DRIVER` logical channel and the process dies; the HLE server makes
this unnecessary.)

With the HLE DosServer in place, the chain now runs:

**Starter → SharedData → the HLE DOS server → splash → SecurityServer
(unblocked once ETel ops 11/14 are answered) → the Eikon server (unblocked
by completing the BAFL backup-server protocol, W2's fix, and a stub ETel
CUSTOMAPI subsession) → the phone server (unblocked by registering EKA1
executive 0x8000E5, `MessageGetDesMaxLength`, which PhoneServer.exe calls
and 7.0s's table never had) → …**

— materially further than either mechanism i on its own or mechanism i' as
it stood before this branch (dropped for lack of a DOS server). **The
phone server's own wall is now named and located, not fixed.**
`PhoneServer.exe` always exits with code **−5**, decided inside the ROM's
own 7.0s `customapi.dll`/PhoneServer, right after a successful `CUSTOMAPI`
extension open, from state the emulator does not see. This is not an HLE
refusal: an A/B that instead refuses the `GetPhoneInfo` call to
PhoneServer alone makes it exit **−1** right after that call, proving it
honours the emulator's ETel answers up to that point and decides −5 only
after the extension open succeeds. Fixing `TPhoneInfo::iExtensions` from 0
to the correct `KETelExtMultimodeV1` (3000) and giving the stub TSY four
phone lines (matching Nokia's own PhoneTsy, not one uninitialised line)
did not change the outcome — still −5. Candidates left, in order: a
version/extension check in the 7.0s custom-API client the public
S60-3.x `RMmCustomAPI::Open` no longer has; a `TPhoneInfo` field compared
for equality; FeatureManager. **Until this is fixed, B7's
`EKA2L1_STUB_SERVERS="Phone Server"` stand-in is what the station-safe
Eikon-server path (and the station itself, indirectly, since it does not
use ROM-EikSrv at all) relies on.**

**Telephone** (0x101f4d0b), run past its former ETel block with this
branch's etelmm fixes, reaches a black first screen with one white
horizontal line. Its threads' last IPC: `Telephone`'s own thread parked on
a synchronous System Agent op 5 (NotifyEventCancel) — a notify/cancel loop
on a System Agent state, 2,739 sends in one run; `phoneapp` parked on
ecomserver op 7; `Main` parked (by design) on an async BackupServer op 32.
The next probe is the exact System Agent state UID it cycles on — likely a
completed "no network / no SIM" state. **Handed to a new racing agent as
of 2026-09-25 12:00 UTC.**

**Also open on this chain:** the cover-UI window server (`cuiws.exe`,
Starter's `CuiStarter` item, never reached while EikSrv loops in the
baseline) needs a `CuiLcd` LDD EKA2L1 has no model for — executor 0x5
(AddLogicalDevice) returns −2 without one; a null LDD (chimera's pattern)
is the next step. The `SpeDeServer` panic (−15, unmonitored item) and
`Randsvr`-style case-insensitive name lookups (A3's fix, elsewhere) also
remain on Starter's later items (Sae, CbsServer, SatServer, LightServer,
PhoneApp, SysAp, Watcher, the Sync item).

## Opera's home page — RESOLVED (agent N7, branch `s80-opera-home` @ `edb47ab07`, merged onto `s80-integration`)

The blank home page was not, in the end, mainly the ViewServer message
layout. **The real cause: EKA2L1 launched every EKA1 app with the "create
document" command, where the device's own application buttons use plain
"run."** On Series 80, a create-document launch that names no document now
becomes a run launch — matching the device — so Opera loads its built-in
Nokia home page (`Z:\Documents\WWW\Home.html`) the way the real buttons do,
and File manager, which shared the same launch-command bug, now paints too.
An A/B through `AppRun.exe` on one binary proves the command letter alone
decides the result (`C"opera"` blank, `R"opera"`/`R""` render the home
page), and that the ViewServer fix is not needed for the page at all (a
binary without it still renders once launched with Run).

A separate, real bug — the HLE ViewServer's `ActivateView` message (op 6)
and `CreateActivateViewEvent` (op 13) parsing a later-firmware 16-byte
layout while the ROM's 7.0s client sends an 8-byte view id + a separate
message UID and message — was also fixed, as a correctness fix in its own
right (the old code copied a 16-byte struct out of an 8-byte package,
producing a garbage message UID and length): it is not why the page stayed
blank, but it is the likely fix for the **USER 30 (negative length)**
panic Sheet and Note hit, since their panicking stacks are in
`ViewCli.dll`/`CONE`. **Sync's own separate wall is RESOLVED**: its stray
signal (`E32USER-CBase 46`) was the ROM's AgendaServer, shutting down,
completing a message id whose IPC slot the HLE MsvServer had already
released and answered — one surplus completion the active scheduler
panicked on. Message completion now ignores a message with no references
left, or one whose session belongs to an HLE server or a different
process, and logs a warning instead. With both fixes, Sync now paints its
"PC Suite profile" first screen, and — tested on a local integration tree,
not yet on `s80-integration` itself — Sheet no longer panics when it runs
beside Desk and a third app starts, and Note (via Desk's own "Write note")
opens with no panic, though typed keys did not appear in that test (the
keymap wall on that tree, not present on `s80-integration`, which carries
K1's keymap). **Notes (the standalone app) remains open**: it is not a
device use case on its own — it looks up Desk's own Note window group and
closes itself when the lookup correctly returns none, then hangs in
SkinServer op 7 during its own shutdown; unconfirmed whether that shutdown
hang shares a cause with anything else here.

## Commits on `fork/s80-shell` (all small, cherry-pickable)

| Commit | What |
|---|---|
| `3aa70e9eb` | wserv: Series 80 application buttons switch apps; route captured keys to their capturer (+ `ClearHotKeys` / custom text cursor completions, `EKA2L1_ROM_EIKSRV` switch) |
| `1e92fc0c5` | wserv: a window group may outlive the process that started its owner (port of chimera 0030) |
| `19308cbd0` | wserv: answer the system pointer-cursor session ops so a ROM Eikon server can construct |

Stashed, not pushed: chimera 0021 (EKA1 `bus_dev_open_socket` creates a real
LDD channel) + 0022 (null LDD accepting every request) — they change
`ldd/CMakeLists.txt` (a reconfigure) and matter for the Starter/SysAp path
(mechanism i'), not the buttons; whoever picks that up should take them from
the prior-work sweep's chimera patches directly. Chimera 0021 was later
cherry-picked (unmodified) into `s80-integration`, where it caused the
process-start regression I2 fixed by gating it to epoc ≤ 6 — see the main
document's integration section.

## Commits on `s80-rom-eiksrv` (agent B7, branch `s80-rom-eiksrv` @ `ecd09e3d7`, base: `s80-shell`, merges `s80-wserv-leftovers`, `s80-hle-dos`, `s80-app-fixes`, `s80-desk-content`)

| Commit | What |
|---|---|
| `3519569b5` | EKA1 duplicate server-name check (servers only; the mutex check is B4's); the IPC watch shows message arguments and parked threads' stacks as image+offset; log-ipc names the sender; the HLE AlarmAlertServer is off in ROM mode |
| `67e622a29` | `EKA2L1_PRESTART` |
| `eb7762eb4` | `EKA2L1_STUB_SERVERS` (diagnostic, off by default) |
| `47596b48c` | `EKA2L1_WS_DUMP_SECS` window-tree dump |
| `2ec7c59b6` | shaped window clipped to its extent, not the shape alone |
| `286fbe23b` | address spaces are released when a process dies (the ASID-leak fix; a general fix, not S80-specific) |
| `ecd09e3d7` | `tools/s80-sysstate` plus the `EKA2L1_PRESTART` default; the stand-in binary is not committed — build it with `tools/s80-sysstate/build.sh` |

## Commits on `s80-hle-dos` (agent B5, model Claude Fable 5.1, branch `s80-hle-dos` @ `8cbd1b772`, base: `s80-shell`, merges `s80-wserv-leftovers`, `s80-app-fixes`, `s80-randsvr`, cherry-picks B7's `EKA2L1_STUB_SERVERS`)

| Commit | What |
|---|---|
| `a9f8f2f53` | HLE DosServer + S80 System Agent states |
| `71106ea6d` | ETel legacy ops 11/14 + sender name in log-ipc |
| `ed3671de7` | CUSTOMAPI stub subsession |
| `978fc6754` | exec 0x8000E5 + EKA1 descriptor lengths |
| `54fbbfb95` | etelmm park/cancel + diagnostics |
| `78013da80` | PhoneTsy four lines + killer name |
| `8cbd1b772` | `iExtensions=3000` + refusal switches |

## Commits on `s80-third-app` (agent B4, base: B1's `s80-shell` @ `19308cbd0`)

| Commit | What | Gate |
|---|---|---|
| `55eafd513` | W2's `7e6564ac6` cherry-picked (the zero-area redraw spin) | — |
| `b989dc9da` | `svc.cpp` `mutex_create_eka1`: a global name already taken now returns `KErrAlreadyExists` (the rule `sema_create_eka1` already had) | `EKA2L1_FIX_MUTEX_DUPNAME=0` turns it off |
| `26975fd3d` | `legacy/mutex.cpp`: a free mutex is taken at once; the waiter `signal_impl` wakes becomes the holder | `EKA2L1_FIX_MUTEX_HANDOFF=0` turns it off |
| `2c40ccbd6` | debug aid: `EKA2L1_THREAD_DUMP_SECS=<n>` dumps every guest thread's state/wait/stack | off unless set |
| `f1422f60f` | a guest panic now logs pc, lr and ROM callers | trace level only |

Quality gate: full incremental build green; `ekatests` — all 28,141 assertions
across 283 test cases passed. B7's server duplicate-name check (above)
complements this branch: B4's fixes cover mutexes only, and without B7's
check a hand-off fix alone still lets servers duplicate (three SkinServers
instead of one) even once the deadlock itself is gone.

## Commits on `s80-desk-content` (agent B6, base: B1's `s80-shell` @ `19308cbd0`)

| Commit | What |
|---|---|
| `62a115538`, `4343d64bd` | merge W2's `s80-wserv-leftovers` up to `a1ebfc046`: backup, GC brush, text cursor, EikSrv table, caret, GDR fonts |
| `e61c951ad` | applist: the Symbian 7.0s AppListServer table |
| `1f4f9e171` | kernel: an unimplemented system call now logs thread, r0–r3 and the caller's module/ordinal |
| `a16f69e64`, `1d49e15a6` | C1's EKA1 locale-name and 7.0s pixel-font-height fixes, cherry-picked |
| `26254356e` | applist: `AppIconByUidAndSize` answers with the size asked for |
| `2b7372d60` | wserv, fbs: draw EKA1 ROM-image bitmaps in place |
| `86eb72dcf` | applist: a launch that names a document keeps it (`get_launch_parameter` used to overwrite it with the app's own name) |
| `4a12074c2` | kernel: a thread that panics itself logs its LR and the code addresses on its stack |

## Method notes (so a resumer does not repeat the same traps)

- Kill only PIDs recorded in your own pid files, resolved through
  `/proc/<pid>/exe` — never a cmdline grep or `pkill -f` (rule 5). After a
  relink, `/proc/<pid>/exe` of a running emulator reads
  `.../bin/.mold-XXXX (deleted)`, not `eka2l1_qt`; a kill script matching the
  exe name by string can silently miss it and leave a ghost emulator
  contaminating the next frame set.
- `grep` skips non-UTF-8 logs as binary by default; an empty result on
  `EKA2L1.log` can be wrong — use `grep -a`.
- `--listapp` prints nothing on this build; app UIDs come from the `.app`
  header (`uid3`) and the log, not the CLI.
- A `CMakeLists.txt` touch (even by a stash) re-runs `cmake` and re-clones
  `libuv` from GitHub unless the configure step is overridden.
- Wait for frame changes with a polling `fbwait`-style script (2 Hz,
  compared against the previous frame or a supplied reference), never a
  fixed sleep — a fast app switch is otherwise missed.

## The SDK emulator as a dynamic oracle (agent X1)

Nokia's own Series 80 DP2.0 SDK emulator (`epoc.exe` udeb, Symbian OS 7.0s
build 04423365) runs unmodified on Windows 11 in a `win11` rig clone, boots
the real Series 80 shell to Desk, and runs Documents and Opera. Under
x32dbg, every `RSessionBase::DoSendReceive` and `CreateSession` call is
logged with server name, opcode, the four IPC arguments and the calling DLL
— a dynamic oracle for exactly the facts static disassembly would otherwise
have to supply. Traces are saved as `a-boot.txt` (boot to Desk) and
`b-appkeys.txt` (the application-key press) in the job's `X1/traces/`
directory; they are IPC call logs, not disassembly.

**Rig.** A clone of the live `win11` station (`rig-clone.sh`), qemu-guest-agent
as the driver (a scheduled task with a `BUILTIN\Users` group principal runs
GUI programs in the interactive console session with no keyboard typing of
Win+R needed), the unshield-extracted SDK `Epoc32/` tree copied in as a zip
and untarred to the SDK's documented path (no installer run: `EUSER.DLL`
derives its root from its own path). `epoc.ini` carries the fascia geometry
(640×200 screen, `VirtualKey EstdKeyApplication0-7`/`EstdKeyDevice0-3` click
rects) — the same reference the team's key model already used. `x32dbg`'s
own quirks (a first-run dialog, `SetBreakpointFastResume` resuming before a
log line is written, a locked trace-log file) were worked around with a
pushed-in `.ini`, `guiupdatedisable`, and periodic VSS snapshots of the log
file (`esentutl /y … /vss`) since QGA holds the log open exclusively.

**Real boot creates roughly three dozen servers (X1 counted 36) in this
order:** FileServer, Loader, Fontbitmapserver, Windowserver,
SharedDataServer, DosServer, FLogger, EikAppUiServer, SkinServer,
EtelServer, Comsdbg, RootServer, SimuServer/SimuData, ViewServer,
BackupServer, AlarmAlertServer, ecomserver, `!Notifier`, SystemAgent,
ShutdownServer, LogServ, AppListServer 5.1.117, MsvServer, AlarmServer,
SocketServer, DBMS, DatabaseLockServer, WAPServer, ClkNitzMdlServer,
CommServer, BTManServer, Sdp. Starter's own start-list resource
(`STARTER.RSC`/`STARTER_SHELL.RSC`) gives the item *type* codes: 5 = splash,
1 = exe, 22 = Eikon server (`HandleStartEikon`), 7 = app. The startup
reason for a normal boot is `100`, with `SysState` `201`
(`ESWStateInitialising`) — the same item-22/"HandleStartEikon" shape B5's
`s80-hle-dos` chain above is now reaching independently on the real ROM.

**How an application key is actually handled** (confirms B1's HLE model,
mechanism ii above, from an independent live oracle): the Eikon server's own
thread calls the AppList server's op 5 with the pressed app's UID, then op 7;
the new app's thread then opens its own `EikAppUiServer` session. Frame
evidence: the Documents button paints Documents' editor in the SDK emulator
(CBA "Insert object / Font / Style / Exit"); the Desk button from inside
Documents returns to Desk in about a second (a "back-stepping chain reset");
holding a CBA key 1.5 s opens the task list ("Document / MessageRelayApp
application / PegAgent") — the long-press-Menu behaviour EKA2L1 still has to
implement (`CaptureLongKey`, above); Left Alt is the device's Chr key
(Alt+a/e/o/u → accented letters), and holding Chr alone for 1.5 s opens an
"Insert character" table — the same gesture K1's keymap port now reproduces
on the real ROM (main document §H4).

**Why X1 could not get a post-`Start` Opera network trace.** The SDK
emulator's Ethernet needs Nokia's own 2004-era unsigned 32-bit NDIS driver
chain (not WinPcap), which cannot load on a Windows 11 x64 guest; Windows
Firewall prompts once for the emulator's own listening socket
(Starter/PegAgent or the WINS Ethernet ESock layer) and dismissing it changes
nothing. Opera's own connection attempt in the SDK emulator shows the real
device's dialog EKA2L1 never draws: "Network connection — Select an access
point" (Network / GSM Data / Easy WLAN), "Connecting…" for about 19 s, then a
silent failure and a re-prompt, with no error dialog — because the emulator
VM has no packet driver. A Windows XP rig, which can still load the old NDIS
chain, would be needed to get a real post-`Start` Opera trace from this
oracle. (This is the same "Connecting… → silent fail → re-prompt" cycle the
main document's network detail records as still untested on EKA2L1 itself.)
