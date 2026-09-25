# Nokia 9300 shell detail — EikSrv, application keys, the SDK-emulator oracle

Sibling of [`candidate-symbian-s80.md`](candidate-symbian-s80.md) §H7. Holds
the mechanism-by-mechanism detail, the wall evidence and the SDK-emulator
trace facts that would otherwise bloat the main document. Facts from agents
B1 and X1's full reports (2026-09-24), and B4's and B6's full reports
(2026-09-25: the third-app deadlock fix and Desk's main pane). B5 (the ROM's
own boot chain), B7 (the ROM's own Eikon server) and N7 (Opera's home page)
have no written report seen by this fold; their facts are relayed here
through the coordinator, marked **as of 2026-09-25 07:00 UTC**, and a
resumer should ask the coordinator to confirm before relying on the exact
wording. Nothing here is disassembly or a ROM byte dump — mechanisms and
traces only, per the repo's abandonware rules.

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
| i | **Run the ROM's real Eikon server**: `EKA2L1_ROM_EIKSRV=1` skips the HLE EikAppUiServer, Notifier and ViewServer; Desk's connect then summons `eiksrvs.exe`, which creates `EikAppUiServer`, `ViewServer`, `AlarmServer`, `AlarmAlertServer`. | **ADVANCED, not station-safe (B7, branch `s80-rom-eiksrv`)** — Desk now paints completely, with the ROM's own status pane; see "The ROM's own Eikon server" below | it gives the six generic buttons, the Menu-hold task list and the status pane from ROM code — once it can run for more than ~2.5 minutes |
| i' | **Start `Starter.exe` / `SysAp` with a trimmed start list.** Starter, SysAp and `Startup.app` all reach the DOS server (phone link); this needed an HLE DOS server before it could run at all. | **IN PROGRESS (B5, branch `s80-hle-dos`)** — see "The ROM's own boot chain" below | the HLE DOS server now exists; the chain runs past `eiksrvs` and the phone server, to a new, concrete, named wall |
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
3. **The ROM's real Eikon server and Desk's status pane — ADVANCED, not
   station-safe.** See "The ROM's own Eikon server" below: Desk now paints
   completely, with the ROM's own status pane, but the emulator cannot stay
   up on this path for more than a few minutes yet.

## The ROM's own Eikon server: a full Desk, not station-safe (agent B7, branch `s80-rom-eiksrv`, in flight as of 2026-09-25 07:00 UTC)

B7 took the `EKA2L1_ROM_EIKSRV=1` shortcut (mechanism i) from "Desk stays
black behind it" to a fully painted Desk. Three additions: a **pre-start
mechanism for ROM executables at boot** (`EKA2L1_PRESTART`, defaulting to
SecurityServer), an **EKA1 duplicate server-name check** (closing exactly
the gap Y2's sweep had flagged as still open — see the main document's
§Prior work found — so a native EikSrv can no longer silently coexist with
the HLE stub instead of failing loudly), and a diagnostic server stub. With
those in: **Desk paints completely, with the ROM-drawn status pane** (skin,
network and battery indicators), and the application keys are handled by
the ROM's own Eikon server through the AppList server — op 5 with the app's
UID, then op 7 — exactly as X1's independent SDK-emulator trace shows the
real platform doing it (below). A window-shape fix (a shaped window's
visible region had been the shape alone, not the shape intersected with the
window) made the narrow status strip inside application views paint too.
**Not station-safe yet:** with no value from Starter for the system state,
the ROM's own alarm server loops, and the emulator crashes after about
2.5 minutes. That crash is the wall to clear before this path can replace
mechanism ii as what a station actually ships.

## The ROM's own boot chain (agent B5, branch `s80-hle-dos`, in flight as of 2026-09-25 07:00 UTC)

A fuller alternative to the `EKA2L1_ROM_EIKSRV=1` shortcut (mechanism i):
rather than skip straight to `eiksrvs.exe`, this boots the ROM's own
`Starter.exe` chain, which mechanism i' above found blocked on the phone-link
DOS server. B5 built an **HLE DOS server**, and the chain now runs:

**Starter → SharedData → the HLE DOS server → splash → SecurityServer
(unblocked once ETel op 14 is answered) → the Eikon server → the phone
server → …**

— materially further than either mechanism i on its own or mechanism i' as
it stood before this branch (dropped for lack of a DOS server). The phone
server itself now answers requests: Telephone passes its own phone request
through it, though Telephone does not paint yet — its next wall is the ETel
phone-opcode table (agent A3, main document's app-coverage section). The
chain currently **exits by its own decision**, right after a round trip
through the cover-display notifier; the suspect is the missing **cover-UI
window server** (Starter's `CuiStarter` item) — in flight. This is the
thread to pull on next for a real, ROM-code Desk with its status pane, the
Menu-hold task list and `CaptureLongKey` all working the way the device does
them — none of which the HLE app-key switch (mechanism ii) implements, by
design.

## Opera's home page — RESOLVED (agent N7, branch `s80-opera-home`, as of 2026-09-25 07:00 UTC)

The blank home page was not, in the end, mainly the ViewServer message
layout. **The real cause: EKA2L1 launched every EKA1 app with the "create
document" command, where the device's own application buttons use plain
"run."** On Series 80, a create-document launch that names no document now
becomes a run launch — matching the device — so Opera loads its built-in
Nokia home page (`Z:\Documents\WWW\Home.html`) the way the real buttons do,
and File manager, which shared the same launch-command bug, now paints too.
A separate, real bug — the HLE ViewServer's `ActivateView` message (op 6)
parsing a later-firmware 16-byte layout while the ROM sends an 8-byte view
id + custom-message id + empty descriptor — was also fixed, as a
correctness fix in its own right (a ROM-accurate `ActivateView` argument
layout), but it was not the cause of the blank page. **Notes and Sync are
still under investigation** — they may or may not share a cause with the
launch-command bug; unconfirmed.

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
the prior-work sweep's chimera patches directly.

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
