# Nokia 9300 shell detail — EikSrv, application keys, the SDK-emulator oracle

Sibling of [`candidate-symbian-s80.md`](candidate-symbian-s80.md) §H7. Holds
the mechanism-by-mechanism detail, the wall evidence and the SDK-emulator
trace facts that would otherwise bloat the main document. Facts from agents
B1 and X1's full reports (2026-09-24), plus B4, B5, B6 and N7, whose work is
still in flight and is relayed here through the coordinator without a
written report of its own — those facts are marked **as of 2026-09-25
05:00 UTC** and a resumer should ask the coordinator to confirm before
relying on the exact wording. Nothing here is disassembly or a ROM byte
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
| i | **Run the ROM's real Eikon server**: `EKA2L1_ROM_EIKSRV=1` skips the HLE EikAppUiServer, Notifier and ViewServer; Desk's connect then summons `eiksrvs.exe`, which creates `EikAppUiServer`, `ViewServer`, `AlarmServer`, `AlarmAlertServer`. **Desk stays black behind it** — the guest area never paints; the Eikon server thread keeps getting IPC completions, but Desk's first window never draws. | **OPEN as this specific shortcut** — a separate, fuller boot-chain effort is making faster progress; see "The ROM's own boot chain" below | it would give the six generic buttons, the Menu-hold task list and the status pane from ROM code |
| i' | **Start `Starter.exe` / `SysAp` with a trimmed start list.** Starter, SysAp and `Startup.app` all reach the DOS server (phone link); this needed an HLE DOS server before it could run at all. | **IN PROGRESS (B5, branch `s80-hle-dos`)** — see "The ROM's own boot chain" below | the HLE DOS server now exists; the chain runs much further than mechanism i, with a new, concrete, named wall |
| iii | **Desk launching apps itself / the Desk main pane.** Desk paints its own chrome (icon, CBA labels) but the AppList server's contribution to the main pane — the date header, the application-group grid, the wallpaper — was missing. | **RESOLVED (B6, branch `s80-desk-content` @ `1d49e15a6`)** — see below | the 7.0s AppList server table plus seven EKA1 locale calls were the missing piece, not C: state |

### Desk's main pane, filled in (agent B6, branch `s80-desk-content` @ `1d49e15a6`)

The empty main pane was an AppList server table gap, not a C: state problem
— B1 had already ruled out C: state by tracing the file server (Desk opens
`skinerin.rsc`, the `s80*` resources and `desk.aif`, creates `Shortcuts.dat`
and `101f8e4f.ini`, and never even reaches `desk_content.rsc`). B6
implemented the 7.0s AppList server's client table — `GetAllApps` (0),
`GetEmbeddableApps` (1), `GetNextApp` (2), `GetAppInfo` (5),
`GetAppCapability` (6), `StartApp` (7/8), `StartDocument`/`CreateDocument`
(0xe/0xf), `AppForDocument` (0x11), `SetNotify`/`CancelNotify` (0x19/0x1a),
icon-by-size (0x1c), `GetFilteredApps` (0x22) — plus seven EKA1 locale
calls (independently also implemented by C1's branch; the coordinator told
B6 to drop the overlap). With that table answered, **Desk now shows its
date header, the wallpaper, a focus bar, the Clock and nokia.com shortcut
icons, and opens a group** — Personal: Telephone, Contacts, Messaging,
Calendar. Labels and folder icons still render in the wrong font on B6's own
branch; the font fixes that resolve this (`a1ebfc046`, C1's pixel-height
commit `1b9a42b15`) already exist on other branches and are expected to
carry the fix once I1's integration merge lands.

## Walls: resolved this wave, and what is left

1. **The third-app wall — RESOLVED (agent B4, frame-proven).** A third app
   launched at any time alongside Desk and one other used to never finish
   constructing its UI: it connected to every server, got its skin-server
   completions, and then issued nothing more — no panic, no exit. Cause:
   EKA1's `RMutex::CreateGlobal` silently **succeeded** on a duplicate name
   instead of returning `KErrAlreadyExists` (unlike semaphores, which already
   reject a duplicate name correctly), so every app that constructed its UI
   created and owned its *own* skin server instead of sharing the first
   one's. With two mutex fixes plus the redraw-spin fix (`s80-wserv-
   leftovers`), **Desk, Documents and Web now run together, switch by
   application key, and keep each app's own state across every switch.**
   Branch `s80-third-app`, pending push, as of 2026-09-25 05:00 UTC.
2. **The empty Desk pane — RESOLVED.** See mechanism iii above.
3. **The ROM's real Eikon server and a black Desk — IN PROGRESS.** See "The
   ROM's own boot chain" below; still short of a painted Desk, but past
   several walls that used to block it entirely.

## The ROM's own boot chain (agent B5, branch `s80-hle-dos`, in flight as of 2026-09-25 05:00 UTC)

A fuller alternative to the `EKA2L1_ROM_EIKSRV=1` shortcut (mechanism i):
rather than skip straight to `eiksrvs.exe`, this boots the ROM's own
`Starter.exe` chain, which mechanism i' above found blocked on the phone-link
DOS server. B5 built an **HLE DOS server**, and the chain now runs:

**Starter → SharedData → HLE DOS server → splash → SpeDeServer →
SecurityServer (comes up once ETel op 14 is answered) → `eiksrvs` → …**

— materially further than either mechanism i (which starts from `eiksrvs`
directly and stalls with a black Desk for an unidentified reason) or
mechanism i' as it stood before this branch (dropped for lack of a DOS
server). The next named wall is concrete: **the ROM's PhoneServer calls EKA1
executive `0x8000E5` (`MessageGetDesMaxLength`), which is unimplemented.**
Fix in progress. This is the thread to pull on next for a real, ROM-code
Desk with its status pane, the Menu-hold task list and `CaptureLongKey` all
working the way the device does them — none of which the HLE app-key switch
(mechanism ii) implements, by design.

## Opera's home page and the ViewServer message layout (agent N7, in flight as of 2026-09-25 05:00 UTC)

N7 traced why Opera never loads its home page at startup (full symptom in
[`candidate-symbian-s80-network.md`](candidate-symbian-s80-network.md)): the
HLE ViewServer parses the 7.0s `ActivateView` message (op 6) using a
**later-firmware 16-byte layout**, while the ROM actually sends an **8-byte
view id + custom-message id + empty descriptor**. Every view activation on
this ROM therefore starts with a garbage custom message. Opera's view-
server activation event *is* delivered and Opera does re-request the next
one (confirmed in N6's idle-state dump), so the connection to the view
server is fine — it is the message's own bytes past the view id that are
wrong. Fix in progress. This may also explain the File manager and Notes
walls below (§ "no synchronous request outstanding, one async op 4 pending
on a ROM-server session" in the main document's app-coverage table) and the
Sync regression, which share the same shape: a view-server-adjacent app that
gets its early completions and then does nothing further.

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
