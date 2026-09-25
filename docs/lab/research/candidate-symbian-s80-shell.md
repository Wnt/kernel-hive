# Nokia 9300 shell detail — EikSrv, application keys, the SDK-emulator oracle

Sibling of [`candidate-symbian-s80.md`](candidate-symbian-s80.md) §H7. Holds
the mechanism-by-mechanism detail, the wall evidence and the SDK-emulator
trace facts that would otherwise bloat the main document. Facts from agents
B1 and X1's full reports (2026-09-24), B4's and B6's full reports
(2026-09-25: the third-app deadlock fix and Desk's main pane), B7's, B5's
and N7's own full written reports (`B7-rom-eiksrv.md`, `B5-hle-dos.md`,
`N7-opera-home.md`), and — a sixth pass, 2026-09-25 through 17:0x UTC —
T1's, M1's, I3's, S1's and S2's own full written reports
(`T1-telephone.md`, `M1-messaging.md`, `I3-integration.md`,
`S1-status-pane.md`, `S2-rom-mode-soak.md`). **Telephone's black first
screen is FIXED** (agent T1) and **Messaging now reaches its folder list**
(agent M1); both are merged, with I3's proof, onto `s80-integration` @
`3f8b52782`. **The Series 80 status pane now also paints on the station's
own HLE-Eikon path** (agent S1), pixel-identical to the ROM-EikSrv oracle
below. **The ROM's own Eikon server (below) is confirmed NOT
station-ready**: agent S2's soak found a deterministic host SIGSEGV in it
that HLE-Eikon mode does not have. Station branch `nokia9300` has been
re-pinned and re-baked five times as the integration head moved (agent
D2); as of this fold it tracks `s80-integration` @ `3f8b52782`
(T1 + M1 + I3), is proven end to end, and remains dark-launched. The
operator has since live-tested the station and ruled it stays HIDDEN
("still requires quite a lot of work") — see the main document's status
header and agent U1's forensic/visitor audit for the current punch list.
Nothing here is disassembly or a ROM byte dump — mechanisms and traces
only, per the repo's abandonware rules.

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
3. **The ROM's real Eikon server and Desk's status pane — proven stable in
   isolated soak testing, but NOT station-safe: a follow-up soak found a
   deterministic host SIGSEGV.** See "The ROM's own Eikon server" below:
   Desk paints completely, with the ROM's own status pane, and B7's own
   22-minute / 2,677-spawn soak found no crash — but agent S2, soaking the
   merged `s80-integration` head, found a **deterministic crash**
   (Calendar → Desk → Personal → Esc, 4 of 4 ROM-mode repros, 0 of 3 in
   HLE mode) in `applist_server::pick_icon_pair_by_size`: a registry
   icon's FBS bitmap loses a reference somewhere in Calendar's ROM-Eikon
   launch path, and the next Desk icon lookup that touches the same
   bitmap dereferences it after Desk frees it. The station stays on
   mechanism ii (the HLE app-key switch) for this reason as well as the
   PhoneServer −5 wall below; **the status pane no longer needs mechanism
   i for its own sake**, since agent S1 painted it directly on mechanism
   ii's own path (§below is now superseded for the pane specifically, kept
   for the app-key/AppList mechanism detail).

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
horizontal line **on the ROM-EikSrv chain (mechanism i')**. Its threads'
last IPC: `Telephone`'s own thread parked on a synchronous System Agent
op 5 (NotifyEventCancel) — a notify/cancel loop on a System Agent state,
2,739 sends in one run; `phoneapp` parked on ecomserver op 7; `Main`
parked (by design) on an async BackupServer op 32.

## Telephone — FIXED on the HLE-Eikon path (agent T1, branch `s80-telephone` @ `ce52cb066`, one commit, merged onto `s80-integration` @ `3f8b52782` by agent I3)

T1's own trace of the "op 5 loop" found it was not a loop at all: it is
`Telephone`'s own SystemAgent NotifyEventCancel destructor pair, sent
exactly twice as the app tears down and parks in `User::WaitForRequest`
(IPC watch stack `euser.dll+0x2634` ← `simdata.dll+0x25d4` ←
`cmgrlib.dll+0x33074` ← `dialer.dll+0x38fa`) — the black screen is
Telephone quietly giving up, not an infinite loop. The trace names two
causes, both specific to the **HLE-Eikon path**, since ROM-EikSrv's own
Starter already starts SecurityServer:

1. **No SecurityServer.** The ROM's Starter launches it before Eikon; the
   HLE Eikon server and Telephone itself never do. Setting
   `EKA2L1_PRESTART=Z:\System\Programs\SecurityServer.exe` as the
   HLE-Eikon default (B5's ETel fixes already let it construct) gets
   `Server SecurityServer created`.
2. **No Phone Server.** With SecurityServer up, Telephone starts the ROM's
   own `PhoneServer.exe`, which exits −5 with no modem (B5's open wall,
   above) — and, unlike EikSrvUi, Telephone panics `PhoneServer start 1`
   on that exit rather than continuing. Registering the same **"Phone
   Server" stand-in** B7 uses on the ROM-EikSrv path (answering only the
   sync op 300 Telephone sends it) lets Telephone finish constructing and
   paint: title "Telephone directory", SIM card row dimmed, an empty
   highlighted "No contacts" row, a search field with a cursor, and CBA
   Open (dimmed) / Recent calls / Voice mailbox / Exit. `T1/proof/
   desk-regression.png` confirms Desk is unaffected by the new prestart
   default. Nothing was dialled or pressed; Telephone's own key/CBA
   behaviour past this first screen is untested, and the status pane
   under its title icon does not yet show the S1 pane fix in T1's own
   frame (S1 landed after T1; I3's merged proof does show it).
`EKA2L1_NO_HLE_PHONESERVER=1` leaves the name to the ROM server for anyone
who wants to test against B5's wall directly.

## Messaging — its folder list now opens (agent M1, branch `s80-messaging` @ `17ce651cb`, merged onto `s80-integration` @ `3f8b52782` by agent I3)

The ROM's own MsvServer never runs; EKA2L1 answers "MsvServer" with an
HLE server written for later platforms, whose opcode numbering happens to
match the 7.0s ROM's own traffic (checked against X1's real-boot trace:
op 39 set-as-observer, 49 SetReceiveEntryEvents, 25
FillRegisteredMtmDllArray, 46/47 Get/SetMtmPath, 28 UseMtmGroup). The
failures were in the *data* the HLE returned, found in trace order:

1. **`EMsvGetChildIds` (op 0x2A) was unimplemented** — the client blocked
   in a sync SendReceive. Implemented against a hex dump of a real request
   and the SDK's `MSVIPC.H`/`MSVSTD.H` (packed `CMsvEntryFilter`, 36 B).
2. **The folder cache listed the Deleted folder twice**, and a one-entry
   range's index bug in `add_tons()` dropped its first entry — both fixed
   in `visible_folder::get_children_by_parent`.
3. **Invisible entries leaked into the list** (the hidden Deleted folder,
   the hidden SMS service as a blank row) — both `GetChildren` calls now
   honour `KMsvInvisibleFlag`.
4. **The MTM registry misread caused "Problem starting Messaging
   center" itself.** The HLE wrote the three capability words in
   `CMtmDllInfo` only for epoc ≥ 8.0, but the SDK's own 7.0s
   `MSVREG.H` layout already has them — so every packed record after the
   first was misaligned, no UI MTM ever loaded, and `mcentre` left with
   −1 (traced with a new `EKA2L1_TRAP_TRACE=1` diagnostic to
   `MsgBrowser.dll+0x2867`). Fixed; the UI MTMs now load (Bium, Btu, Imum,
   MmsUiMtm, PushMtmUi, …) and the app reaches its views.
5. `owning_service(root)` returned without setting its out value
   (GetEntry(root) reported service 0) — fixed; did not by itself remove
   the storage note below.

With all four data fixes in, Messaging opens to Inbox/Outbox/Drafts/Sent
with icons and CBA Open folder / Write message / Exit, and Down moves the
selection between folders correctly. **One wall remains, unowned:** a
"Cannot find message storage. Try restoring from a backup." note appears
once at start on every fresh data dir. No IPC call returns an error in
that window (every HLE reply is 0 except `GetMtmPath` op 46, which
correctly returns −5 before the client's own drive/cache scan via op 47
succeeds), so the cause is data the client dislikes, not a failed call.
Ruled out by experiment: moving the mail folder from
`C:\System\Mail\RAE-6\` to `C:\System\Mail\`, pre-creating the root
store `00001000` (a second launch still shows the note), and the
owning-service fix above. Best remaining leads: the real device's message
store root carries visible services `0x100000`/`0x100001…` (X1's
`a-boot.txt` lines 28898–28923) that the HLE store never creates; and
X1's own trace shows op 37 (`GetMessageDirectory`) always carrying
`arg1 = 3` on the real device, which the HLE may not honour. M1 added
`Service.Track:info` log-filter output ("HLE X completed function N with
E") for whoever races this next — the golden's `*:error` filter hides it
by default.

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

## The Series 80 status pane on the station's own path (agent S1, branch `s80-status-pane` @ `ba50d9420`, two commits, merged onto `s80-integration`)

The default station mode is HLE-Eikon (mechanism ii). Before this branch
its status pane was simply never drawn; after it, the pane paints the way
the ROM Eikon server paints it, without needing mechanism i/i' at all:

- A new `s80pane` module (`services/window/s80pane.{h,cpp}`) keeps a map
  from process to the last `SetStatusPaneLayout` (op 7) layout id an app
  sent it — the same IPC a ROM Eikon server would answer — and finds the
  frontmost window group whose owner sent one. Two layout ids are seen in
  practice: `0xD118006` (wide, Desk/Telephone) and `0xD118004` (narrow,
  Documents/Web); any other id paints nothing, the old behaviour.
- It loads the skin bitmaps (`skinappview.mbm`, `skinstatuspane.mbm`)
  from Z: into driver textures, turning the indicators' magenta key
  colour into alpha, and draws the background plus the network-
  unavailable and battery indicators at the ROM's own offsets.
- `screen.cpp` subtracts the pane's rectangle from the region older
  windows are allowed to draw into during the front-to-back visibility
  walk — this removes app bleed-through at its cause, not just its
  symptom — and paints the pane just before the anchor group's own
  windows on the back-to-front draw walk.
- **The clock** is a CLOCKA `RDigitalClock` at (16,38), 60x26, drawn with
  the 9300 GDR's System bold, metric index 3 (the only one of four raced
  candidates — 1, 8, 13, 3 — that gives 0 px difference from the ROM
  oracle; A2's earlier CLOCKA anim trace supplied the format sections).
  It forces a full redraw on every new minute. Since `wserv` owns no
  fonts of its own, a new `fbs::live_fonts()` accessor lets it borrow the
  System bold face the running apps already hold.
- Time shown = universal time + the guest locale's `universal_time_offset_`,
  plus one hour when the home zone's DST bit is set — the same rule
  `TLocale::UniversalTimeOffset` gives the ROM server (see L1's locale fix
  below for what actually sets that offset).

Compared pixel-for-pixel against ROM-EikSrv's own frames in the same
minute: Documents' narrow strip, Desk's lower-left pane including the
clock, and the same pane one minute later with no input — **0 px differ
in every comparison**. The change needs no data-dir file, no env var and
no guest binary, and does nothing on ROM-EikSrv or on other devices,
since only the HLE EikAppUiServer records layouts. Op 6
(SetStatusPaneFlags) is accepted and still does nothing, so apps cannot
hide the pane. Remaining gap: the clock format ignores `TLocale`'s
12/24-hour bit (it always draws in a fixed 24 h face; with the 24 h
default from L1's fix below this does not currently show).

## ROM-shell mode's blocking crash (agent S2, soak on `s80-integration` @ `3f8b52782`, no code changes)

Everything else about ROM-shell mode (mechanism i/i') is better than
HLE-Eikon: the status pane draws (now matched by S1's HLE-path fix
above), nothing bleeds through, every app key works, a 30-minute
soak (samples every 60 s cycling all seven app keys) showed no crash, CPU
stayed at 2.6 % of a core, RSS was flat, and reset (SIGKILL + `cp -a` the
golden) took 6 s. **But** ROM mode has a deterministic host crash HLE
mode does not: from a fresh data dir, `F11` (Calendar) → `F5` (Desk) ->
`F1` (Open → Personal) → `Escape` crashes the emulator with SIGSEGV
(rc=139) every time (4 of 4 ROM-mode runs, including the 30-minute soak's
tail and 8-minute app/Exit churn runs; the same or longer sequences
survive every time in HLE mode, 3 of 3). Without Calendar in the mix,
there is no crash in either mode.

gdb (Release binary) puts the crash in
`applist_server::pick_icon_pair_by_size`, called from `get_app_icon`,
called from a `CallSVC`-driven `session_send_sync_eka1`. The IPC log
shows the last request before the crash is Desk asking AppList for
Clock's icon (0x10000080) at 20x25 — Esc repaints top-level Desk, whose
icons include Clock — right after Desk sent about 20 FBS "close handle"
messages tearing down the Personal folder's icons. Reading: a registry
icon's `fbsbitmap*` in `apa_app_icon` is left dangling — something in
Calendar's ROM-Eikon launch path leaves Clock's applist-owned icon
bitmap with one FBS reference too few, and when Desk later closes its own
folder handles the bitmap is freed out from under the next lookup. Not
proven to a one-line fix (candidates: FBS refcounting of applist-created
icons on `obj_table_.add` vs `fbs_close`, or ecomserver/Calendar-side
handle traffic); a next agent can log `fbsbitmap` refcounts for the icon
ids, or make `read_icon_data_aif` take a permanent reference. This is our
emulator code (HLE applist + FBS), **not** a ROM defect, so it is a fork
wall to clear, not evidence against ROM-shell mode's design — but it is
why the station keeps shipping mechanism ii until it is fixed.

Also confirmed by this soak, in both modes: F4 (Exit) does not end any
app — apps stay in `ekactl list` and no `apprun` is respawned — and after
an app is exited the Desk left pane can go unpainted until the next F5
(worse in HLE mode, with no strip at all, than in ROM mode, with a stale
icon remnant); neither is specific to ROM-shell mode.

## Typing at visitor speed: two independent causes, both fixed (agent K3)

U1's visitor audit found typing corrupted at ordinary visitor speed
(60-170 ms/key): Shift leaked onto following letters and doubled letters
swapped order. K3 found **two independent causes**, one in the fork and
one in the station daemon — neither in the K1 keymap translator, which
was checked and cleared (it ships each host edge's Shift/Chr/key entries
as one ordered batch on the frontend thread, so nothing interleaves
there).

1. **Fork: the client event FIFO silently dropped characters when full.**
   `event_fifo::do_purge()` erased every other `EEventKey` event (the
   characters themselves) once the 32-entry queue filled, keeping their
   up/down pairs and skipping the event right after each erase — the old
   `assert(false)` / "Unhandled purge of event type 2/3" path. Fixed on
   branch `s80-typing` @ `35ed38e42` (base `s80-integration` @
   `d26b08ff1`): the purge now frees one slot at a time, cheapest first
   (null, pointer move/drag, pointer enter/exit, a focus lost/gained
   pair, a repeated switch-on), and never purges a key or pointer
   press/release; the queue grows to a 4096-entry hard cap before it
   would ever drop a keystroke. A second, smaller bug in the same area:
   Qt6/xcb flagged a same-X-timestamp key release as auto-repeat when a
   press of the same key was already queued behind it, silently merging
   doubled letters (`aa` → `a`) at 0 ms pacing; fixed by treating a
   release under 150 ms after its own press, paired with that press, as a
   real keystroke (a genuine host repeat, which only starts after the X
   repeat delay, is still ignored — the station also runs `xset r off`).
2. **Station daemon: the x11test pacer reorders edges across keys
   whenever hold/gap is nonzero.** `x11_keys::Pacer` orders edges within
   one X keycode only ("edges of OTHER fields flow freely past a waiting
   one" — its own module doc and test,
   `modifier_press_flows_past_another_keys_dwell`, both confirm this by
   design). With any nonzero dwell, a released Shift can sit in its dwell
   while the next letter's press passes it and lands with Shift still
   down in X — that is the Shift leak; a doubled letter's second press
   can similarly pass its own predecessor's release — that is the
   transposition. This rule is correct for the MAME/SDL 50 Hz guests it
   was written for, and wrong for an event-queue emulator whose text
   depends on X's live modifier state. **Fix is a station config change,
   not code:** `SH_KEY_MIN_HOLD_MS=0` and `SH_KEY_MIN_GAP_MS=0` in
   `streamhost/stations/nokia9300/station.env.fixture` (`0` is accepted
   by `config/backends.rs`'s `key_floor`); with a zero dwell, `drain()`
   never blocks and edges leave in strict arrival order. The fleet
   default of 40/40 still corrupts text on this station; only 0/0 is
   safe.

**K1's and K2's "150 ms between key events" pacing rule is obsolete** for
a binary built from `s80-typing`, and actively harmful at any nonzero
dwell on the daemon path. Through X directly (xdotool/XTEST in order),
0 ms pacing is safe: a 271-character burst arrived exact with zero
purges. K3's `sim-pacer.py` replays the daemon's own `Pacer::drain` logic
against a live display for anyone who wants to re-verify a pacing figure
without a full station rebuild.

## Locale: home city, date format, clock format (agent L1, branch `s80-locale` @ `27bc9f952`, one commit, merged onto `s80-integration`)

R3's fidelity survey found the Desk header drawn month-first with no
device-matching date order, the pane clock 24-hour with no AM/PM option,
and Clock's home city stuck on the ROM's own "New York, NY" default no
matter what a visitor picks in Change city. L1 traced this to two walls.

**Wall 1 — SVC 0xC00049 was unimplemented, and it is `CTimer::At`, not a
generic locale setter.** The pre-fix log reads `Unimplement system call:
0xC00049! thread Clock ... (euser.dll+0xA0A8 ord 107+0x2C)`; the S80 SDK's
own `EUSER.lib` import-library names give ordinal 107 as
`CTimer::At(const TTime&)` (106 is `User::At`, 108 `RTimer::At` — the
fork's other exec tables already map 0xC00049 correctly on 8.0/8.1a, only
the 7.0s table was missing it). Clock's world-server path arms this timer
before it ever saves the chosen city, so without it Change city silently
never commits. With it registered, the full chain runs: `TLocale::Set`
with the new zone and DST bit → `BaflUtils::PersistLocale` writes
`C:\System\Data\LOCALE.D00` (280 B) → the world server writes
`C:\System\Data\Wldsvr.dat` (177 B) and `nitzlookup.db` (99,956 B) → a
"time will change by N hours" confirmation. On EKA1 the kernel keeps
*home* time, and `TLocale::Set` on Series 80 now moves it to the new
zone's effective offset (zone + 1 h when the DST bit and zone flag both
say daylight saving applies) — this reaches `User::HomeTime`, every
`RTimer::At` and the S1 pane clock above, all through the same rule.

**Wall 2 — nothing loaded the persisted locale at boot, and there was no
Series 80 default.** The 7.0s persistence is a raw `TLocale` struct in
`C:\System\Data\LOCALE.D<nn>` (via BAFL, not SharedData — `bafl.dll` in
the ROM carries the exact path string). The ROM writes `LOCALE.D00`
itself after Change city, but nothing read it back: the emulator's
`get_locale_info()` hard-coded `date_format_america`,
`time_format_twenty_four_hours` and a fixed -14400 s offset for every
platform. Fixed: on EKA1 Series 80 only,
`init_services_post_bootup` now loads `LOCALE.D<language>` then
`LOCALE.D00` into `LOCALE_DATA_KEY` and the kernel's home-time offset, the
way `BaflUtils::InitialiseLocale` would — proven by patching a
LOCALE.D00 to American format and watching the Desk header flip back to
month-first (`frames/proof-locale-file-loaded-american-variant.png`).
When no file exists, a new `get_s80_default_locale()` gives Finland
(country 358), day-first dates, `/`/`:` separators, Monday-first weeks,
EU summer-time rules and **24-hour clock** (the SDK's own reference
LOCALE.D00 actually says 12-hour; 24 h was chosen as the briefed Finnish
default — a golden file can still ship 12 h if that is later preferred).

**Golden deliverable** (data, not committed — `L1/golden-helsinki/` in
the job directory, for `EKA2L1/data/drives/c/System/Data/`):
`Wldsvr.dat` (177 B, home city Helsinki/Finland +120 min — independently
reproduced byte-identical on a second run), `LOCALE.D00` (280 B: country
358, +7200, EU summer time on, day-first, 24 h) and `nitzlookup.db`
(99,956 B, written alongside). **Without `Wldsvr.dat` specifically, the
new default already gives the right date order, 24 h and Helsinki time
until the first Telephone or Clock start — the ROM's New York home city
then wins again once the world server runs.** After the fix, a Desk
frame right after a Telephone round reads "Friday 25th September 2026"
at Helsinki summer time (UTC+3); before the fix, the same sequence read
"Friday September 25th 2026" at New York time.

**Left open:** the S1 pane clock's digits ignore `TLocale`'s 12/24-hour
bit (fixed English 24 h face regardless of the setting; does not show
under the new 24 h default); Control panel → Regional settings' Date tab
was not reached (joystick moves the value, Tab/Ctrl+Tab open the choice
list) and its Currency tab draws two rows below the dialog (a
window-server issue); Desk's F5 after opening Clock from Desk brings
Clock back to front instead of Desk (B1/K1's app-switch logic, "app is
running, bringing group 85" in the log); both world-clock faces still
show offset 0 (A2's known item).

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
