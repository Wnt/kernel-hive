# Nokia 9300 network detail — ESock, RConnection, CommDB, Opera

Sibling of [`candidate-symbian-s80.md`](candidate-symbian-s80.md) §H3. Holds
the opcode table, the IPC trace evidence, the CommDB patch-DLL detail and the
toolchain that proved it all, so the main document can state the conclusion
without the working. Facts only, from agents N1, N2, N3, N4, N5 and N6
(2026-09-24 21:00 UTC through 2026-09-25 04:45 UTC, across a 5-hour
usage-limit pause); protocol facts (opcode numbers, argument order, server
order, header names) only — no disassembly, no ROM bytes. The Opera
home-page resolution ("Still open" §1, below) is agent N7's finding,
relayed through the coordinator as of 2026-09-25 07:00 UTC with no written
report seen by this fold — see
[`candidate-symbian-s80-shell.md`](candidate-symbian-s80-shell.md) for the
mechanism.

## Status: the network wall is closed

Opera 6.0, running from the real 9300 (RAE-6, firmware 05.22) ROM under
EKA2L1, now fetches a page from a host web server on "Go to" and renders its
heading, body text and a coloured table (agent N6, frame
`opera-page-rendered-after.png`). **No network code changed to close it.**
Every ESock/CommDB fix below (N1, N2) was already enough on its own; the
missing piece was a window-server bug entirely outside the network stack —
see "Why Opera stalled" below. The station needs exactly two branches for
this: `s80-esock-70s` (this document) and `s80-wserv-leftovers` (W2's
redraw-spin fix, detailed in
[`candidate-symbian-s80-shell.md`](candidate-symbian-s80-shell.md)), the
latter including commit `a1ebfc046` so dialog text is legible. No proxy, no
extra NIC and no retronet netns work is needed beyond the `hosts:` map
already documented below. Both branches, plus every other network-relevant
fix, are merged onto fork branch `s80-integration` @ `e43db215e` (agent I2),
where Opera fetches and renders host pages exactly as described here — this
document's proof is not stranded on a side branch. **The station now has
a network plane, and it carries retronet, not a `hosts:` map (agent N8,
2026-09-25, ~15:35–19:00 local / 18:35–19:00 UTC).** Rather than a
`config.yml` `hosts:` entry, the whole nspawn container joins
**retronet's web plane** through a dedicated network namespace: a veth
pair (`nokia9300rn0` on the host bridge, `nokia9300rn0g` inside the
namespace), a static retronet address claimed atomically for the
station's own session, no default route, a fail-closed guard chain
(`NOKIA9300RN-IN`) installed at `INPUT` and read back from the kernel to
confirm it, and `/etc/netns/.../resolv.conf` pointed at the retronet
gateway's own DNS — so `GetByName` resolves a corpus host name the
ordinary way (EKA2L1's ESock is HLE, using host sockets and
`getaddrinfo()` directly; DNS does all the naming, and `config.yml`'s
`hosts:` map is deliberately left empty). **Trap found on the rig, worth
recording for any future nspawn station on retronet:** nspawn's own
`--network-namespace-path` fails under `--private-users` with "Operation
not permitted" — nspawn tries to join the namespace from inside its own
new user namespace, but the target network namespace belongs to the
*init* user namespace. Fixed by starting nspawn under `nsenter
--net=<netns path> -- systemd-nspawn ...` instead; because `nsenter`
execs into nspawn, `$!`/`/proc/<pid>/exe` identity checks still resolve
correctly. A Restore (in-process relaunch) keeps the same container and
therefore the same network namespace, proven live: a new emulator PID
after a Restore showed the same namespace inode, and a corpus page still
rendered right after.

**Opera needed zero settings changes to use this plane** — no proxy
(`Opera.def` still has none; Opera's own HTTP/1.1 `Host:` header does
the rest), no CommDB IAP entry (N2's HLE `Start()` fallback, above,
still answers), no golden change, and N4's CommDB patch DLL is not
needed either. **Proven live, on the real deployed station:** Opera
renders AltaVista, Netscape and Yahoo from the corpus, including
immediately after a Restore. **Negative test, from inside the guest's
own network namespace:** the only route present is the retronet subnet
itself; a non-corpus IP and a DNS resolver outside the namespace both
fail outright (no route, so no packet even forms); the gallery's own
management port times out (the guard chain drops it); only the retronet
gateway's own DNS and HTTP answer. In the framebuffer, Opera at a
non-corpus/nonexistent address (e.g. an address with no corpus entry)
correctly shows "System: Unspecified error" — the same message this
document used to cite as evidence of "no network plane at all"; it now
means "no route to that specific address", which is retronet's intended
containment, not a station defect. **One corpus content gap, not a
station bug:** AltaVista's own archived page embeds at least one image
at a literal IP address (not itself in the corpus; the archived source
page's own address, which stays out of this doc per rule 1 — any address
cited here is a scrubbed `192.0.2.x`-style placeholder, never the real
one), so that image draws as a broken-image box — a gap in the corpus,
flagged for whoever curates it next, not something to fix on this
station. The "Nokia.com mobile" link
on Opera's own home page still cannot be focused or followed with the
keyboard — open, unrelated to the network plane, not investigated by N8.

New docs from this pass, outside this file: `docs/lab/retronet/
WEB-STATION-nokia9300.md` (the station's own retronet write-up) and
`docs/guests/nokia9300.md`'s new §Network/§Sandbox sections and
`hosts:` line — cross-reference these rather than duplicating their
content here.

## The 7.0s ESock opcode table (agent N1, branch `s80-esock-70s`)

**Result: the 7.0s client opcode table is EKA2L1's own pre-reform
`socket_opcode` enum, op for op** — `RSocketServ`, `RSocket`,
`RHostResolver`, `RServiceResolver`, `RNetDatabase`, and the whole
`RConnection` block 0x3F–0x56 (plus sub-connection 0x57–0x66, `__Dbg*`
0x67–0x6F, exclusive-mode 0x3E8/0x3E9, Query 0x3EA/0x3EB). Derived from the
9300 RAE-6 ROM's `esock.dll` (build 187): each exported function sets a
register to the function number right before the import stub of EUSER's
`RSubSessionBase::DoSendReceive`; names came from the SDK's ARM import
library `ESOCK.lib`. Cross-checked three ways: the SDK's WINS x86
`ESOCK.DLL` (same values on x86), Symbian^3's public `SOCKMES.H` ordering,
and live IPC traffic from the real Opera client (0x3F is Opera's first ESock
message, 0x43 its second — confirming the `RConnection` numbering against
real ROM traffic, not just the derivation).

Values that differ from the 6.1 table EKA2L1 was using for 7.0s before this
fix: `Connect` 0x13 (was 0x0F), `Send` 0x09/0x08, `Recv` 0x0B/0x0A/0x0C,
`GetByName` 0x29 (was 0x25), and the entire `RConnection` block, which the
6.1 table does not have at all.

7.0s already packs arguments as the EKA2-style `TIpcArgs` block (`iArgs[4]` +
a 3-bit-per-slot type word), in the order the pre-reform handlers read:
`Connect` `[&addr]`; send with no length `[flags, 0, &desc]`; send/receive
with length `[&TSockXfrLength carrying flags, 0, &desc]`; `GetByName`
`[&name, &TNameEntry]`; `Start(pref)` `[&TConnPref]`; `GetIntSetting`
`[&name, TPtr8(&value)]`; `RSocket::Open(…, RConnection&)`
`[TPtrC8 over {fam, type, proto, conn, 0}]`.

The bug was a single predicate: `socket_client_session::is_oldarch()`
(`socket/server.cpp`) gated on `< epoc81a`, so `epoc7` fell through to the
6.1 numbering, and the pre-reform session's `fetch()` had no `cn_open` case
for the oldarch branch at all — the 7.0s opcode fell through to
`LOG_ERROR "Unimplemented opcode for Socket server 0x.."` with no
`complete()`, so the client's synchronous `Open` parked its thread forever.
Fixed by moving the gate to `< epoc7`, and adding the pre-reform
`SendTo`/`RecvFrom` (0x0F–0x12) and `CancelIoctl` (0x1F) dispatch entries the
table had but the switch was missing.

## Code landed

| Commit | Branch | What |
|---|---|---|
| `623d96312` | `s80-esock-70s` | `is_oldarch()` moved to `< epoc7`; pre-reform `SendTo`/`RecvFrom`/`CancelIoctl` dispatch added. Fixes the `RConnection::Open` (0x3F) hang. |
| `3ededa65e` | `s80-esock-70s` | Cherry-pick of the `RConnection::Start` EKA1 host-access-point fallback, owned by the `s80-commdb` branch (below) as `4deb3dc77`. |
| `92f600bf5` | `s80-esock-70s` | Trace every request reaching the socket server and its subsessions (log-ipc only prints synchronous sends by default; ESock is mostly async) — this produced the "where Opera stalls" evidence below. |
| `4deb3dc77` | `s80-commdb` (N2) | `RConnection::Start`/`Start(TCommDbConnPref)` EKA1 fallback: takes the requested IAP + network (or 1), needs no agent/NIF/dialog, advances `KConnectionOpen` (3500) then `KLinkLayerOpen` (7000) at once, completes `KErrNone`. `GetIntSetting` answers `IAP\IAPService`/`IAP\IAPBearer` = 1; `GetDesSetting` answers `IAP\Name` = "Host network", `IAP\IAPServiceType` = "LANService", `IAP\IAPBearerType` = "LANBearer"; any other name logs then returns `KErrNotFound`. EKA2 behaviour is unchanged. |

These four make every ESock/CommDB call Opera or PuTTY issues return
`KErrNone`. They were never the whole story — the redraw-spin fix below is
what let those completions actually reach the thread waiting on them:

| Commit | Branch | What |
|---|---|---|
| `7e6564ac6` | `s80-wserv-leftovers` (W2) | The window-server redraw-spin fix. **This is what closes the network wall** — mechanism below, full detail in [`candidate-symbian-s80-shell.md`](candidate-symbian-s80-shell.md). |
| `a1ebfc046` | `s80-wserv-leftovers` (W2) | Dialog-text/font fix. Needed so a rendered dialog (including any future connection-error dialog) is legible, not a black box. |
| `0d651414f` | `s80-putty-proof` (N3) | `SetOpt(KSoTcpOobInline)`/`KSoTcpKeepAlive` answered instead of `KErrGeneral`. Needed by PuTTY's EKA1 build only. |
| `53a49931d` | `s80-socktest` (N5) | `RThread::ExitReason()` (exec 0x3E) implemented. Needed by the SockTest test tool only. |
| `30c3eff3d` | `s80-commdb-patchdll` (N4) | Guest CommDB patch DLL — a real, ROM-UI-visible "Host network" access point. Optional fidelity, not required for Opera or PuTTY. |

## Why Opera stalled, and why it does not any more (agent N6)

The redraw-spin bug (`s80-wserv-leftovers`, commit `7e6564ac6`) let a
zero-area window's invalid rectangle sit in its region forever, so every
`EndRedraw` re-queued another redraw. That kept the Web thread's redraw
active object — priority 50 (`EActivePriorityRedrawEvents`) — permanently
ready. EKA1's active scheduler always runs the highest-priority ready object
first, so nothing at priority ≤ 0 ever ran, including the HTTP framework's
continuation after `RConnection::Start`, which N5 measured at
`EPriorityStandard` (0). **Opera was not stuck in its own code; it was
correctly waiting its turn and never getting it.** With the redraw bug
fixed, the Web thread idles at 1% CPU and the continuation runs the instant
`Start` completes.

This replaces the earlier theory (T2) that blamed Opera's own HTTP
transport handler (`oprbridge.dll`). T2 was right that the wall sat above
ESock and that every socket-server call Opera issued completed correctly;
it was wrong about the cause being inside Opera's own code. Two independent
confirmations rule out anything Opera-specific: N5's path F parks the ROM's
own HTTP framework with a synthetic priority-100 spinner in the same thread
and resumes it the instant the spinner stops, using no Opera code at all;
and N3 found PuTTY for Series 80 v2 stuck the identical way, starved at an
even lower priority (PuTTY's connect flow runs from a `CIdle`, i.e.
`CActive::EPriorityIdle`) — same fix, same result.

The other two raced theories stay ruled out. **T1** (Opera waits on a
`ProgressNotification` stage that never arrives) — Opera does call
`ProgressNotification` (0x47), but only once starvation ends, and the HLE
`start()` completes it at once; `connection.cpp` needs no change. **T3** (a
leaked CommDB/proxy read after `Start`) — the trace shows no DBMS traffic at
all after `Start`, so Opera never reaches that read.

**The ESock sequence once it runs** (fix build, "Go to" pressed at 52.2 s,
page on screen by 63.9 s):

| # | op | call | detail | result |
|---|---|---|---|---|
| 1 | 0x3F | `RConnection::Open` | subsession created | 0 |
| 2 | 0x43 | `RConnection::Start()`, default | host access point up, IAP 1, network 1 | 0 |
| 3 | 0x47 | `ProgressNotification` | first op after `Start` — where Opera parked before the fix | completes at once |
| 4 | 0x4C | `GetIntSetting("IAP\IAPService")` | | 0 |
| 5 | 0x4F | `GetDesSetting("IAP\IAPServiceType")` | "LANService" | 0 |
| 6 | 0x47 | `ProgressNotification` again | waits for the next stage change | pending (none follows) |
| 7 | 0x02 | `RSocketServ::FindProtocol` | | 0 |
| 8 | 0x3E | `RHostResolver::Open(…, RConnection&)` | | 0 |
| 9 | 0x29 | `GetByName` | resolved via the `hosts:` map below | 0 |
| 10 | 0x3D | `RSocket::Open(…, RConnection&)` | TCP | 0 |
| 11 | 0x13 | `Connect` | | 0 |
| 12 | 0x2F | `RHostResolver::Close` | | 0 |
| 13 | 0x0E | `Write` | the GET request | 0 |
| 14 | 0x0C | `RecvOneOrMore` ×3 | page body | 0 |
| 15 | 0x1D | `Close` | | 0 |

This matches N5's path E (the ROM's own HTTP framework on its own
connection), op for op after 0x43. Opera issues **no `SetOpt`**, so N3's
`KSoTcpOobInline` fix is not needed for Opera.

**The request on the wire.** Opera identifies itself with a fixed
User-Agent the station can key retronet content negotiation on:
`Mozilla/4.0 (compatible; MSIE 5.0; Series80/2.0 Nokia9300/05.22
Profile/MIDP-2.0 Configuration/CLDC-1.1)`. It also sends
`Accept-Encoding: gzip,deflate` and an `x-wap-profile` header pointing at
Nokia's UAProf XML.

## Proof: a Linux-built test client drives the whole stack (agent N5)

A rule-14 racer, run in parallel with N6. A plain 7.0s console client (mine,
built with a Linux-hosted toolchain — see below) drives six paths against
`s80-esock-70s`:

| Path | What it drives | Result |
|---|---|---|
| A | Plain sockets with an explicit `RConnection` (Open 0x3F, `Start(pref)` 0x44, resolve, connect, write, `RecvOneOrMore` to EOF, close) | every call `KErrNone`; the HTTP/1.0 reply rendered on the 9300's own screen |
| B | Plain sockets with no explicit `RConnection` (implicit connection) | same |
| C | `RConnection::Open` + default `Start()` (**Opera's own call shape**) + progress notification + `GetIntSetting`/`GetDesSetting` + `EnumerateConnections` | every call `KErrNone` |
| D | The ROM's own HTTP framework (`http.dll` + ECom filters) on my app's connection | `OpenL` (2.5–3.0 s, ECom load) → `GotResponseHeaders` **200** → body → `Succeeded` |
| E | The HTTP framework opening its **own** connection — Opera's exact shape | `0x3F`, `0x43`, then `0x02 FindProtocol`, `0x3E`, `0x29`, `0x3D`, `0x13`, … → **`Succeeded`** in under a second |
| F | E, plus a deliberate priority-100 active object spinning in the same thread for 20 s after `SubmitL` | **zero ESock requests** while the spinner runs, then the whole sequence and `Succeeded` the instant it stops — the starvation mechanism, reproduced synthetically |

On the reference binary and on `s80-commdb` alone, every path stops dead at
`RConnection::Open` (0x3F) or, for the no-`RConnection` paths, at the
equivalent implicit-open. On `s80-esock-70s`, paths A–F all complete. Path
E's trace is exactly the protocol sequence Opera's own trace stops after
(0x3F, 0x43) — the next op Opera never reaches is `0x02 FindProtocol`.

**Toolchain** (reusable; full recipe, traps and a GUI-app variant are in the
job's `N5/toolchain.md`): a Linux-hosted EKA1 ARMI toolchain — razvang-dev's
`Nokia-N-Gage-SDK-Toolchain` v1.0.1 (GCC 2.9-psion-98r2, `petran`, `rcomp`,
`makesis` — Nokia's actual 7.0s-era ARM compiler, not a modern
cross-compiler) — plus the Series 80 DP 2.0 SDK's ARMI `.lib`s and headers,
builds and links a 7.0s EXE that the ROM loads and runs as-is, with no SIS
or installer needed (7.0s has no platform security). Two SDK-header fixes
are required first: convert CRLF to LF (GCC 2.9 on Linux does not treat
`\`+CR+LF as a line continuation, so every multi-line macro fails) and build
a case-correcting symlink farm (the headers `#include` each other under
inconsistent case). The same toolchain built N4's CommDB patch DLL below and
is the base for any future guest-side test or patch binary. Fork branch
`s80-socktest` @ `8f44f8263` carries the reusable tool under
`tools/s80-socktest/` (source and a generic build script; no SDK or
toolchain material — those keep their own licence terms and are never
committed).

Two EKA1 gaps surfaced building the test app itself (neither needed by
Opera, PuTTY or the CommDB patch DLL): `RThread::ExitReason()` (exec 0x3E)
was unimplemented — **fixed** on branch `s80-socktest` @ `53a49931d`.
`RThread::ExitCategory()` (exec 0xC0003F) is still unimplemented and faults
the caller; fixing it needs an exit-category accessor on `kernel::thread`
(the member is private) plus a registration with the EKA1 argument order,
left open because it forces a wide rebuild.

## Proof: PuTTY confirms the same starvation mechanism (agent N3)

PuTTY 1.5.2 for Series 80 v2 (`s2putty`, MIT) runs its whole connect path on
the real 9300 ROM once the redraw-spin fix is in — including the default
`RConnection::Start` (0x43), the same call Opera uses. PuTTY starts its
connect flow from a `CIdle` (`CActive::EPriorityIdle`, lower even than
Opera's `EPriorityStandard`), so it is even more exposed to the redraw bug:
on the pre-fix binary it sends **zero** SocketServer messages, ever — the
profile dialog never even appears, because the `CIdle` that would show it
never runs. With `7e6564ac6` cherry-picked, the profile dialog appears
10.5 s after launch and Connect runs its full sequence: `RConnection::Open`,
default `Start()`, `RHostResolver::Open`/`GetByName`/`GetByAddress`
(`KErrNotSupported`, which PuTTY expects and treats as "no reverse DNS"),
`RSocket::Open`, two `SetOpt` calls, `Connect`, then `Send`/`RecvOneOrMore`
pairs carrying PuTTY's identification line and a 616-byte KEXINIT — bytes
confirmed both ways on the host server's own log. Every op completes; no
request parks.

One emulator gap needed a fix: `SetOpt(KSoTcpOobInline)` was unhandled and
returned `KErrGeneral`, which PuTTY's EKA1 build (`#if !defined(EKA2)` in
`epocnet.cpp`) treats as fatal and aborts the connection on. Fixed on branch
`s80-putty-proof` @ `7132fbd09`, commit `0d651414f` (also answers
`KSoTcpKeepAlive`). The same branch carries W2's `7e6564ac6` and a GC
brush-pattern fix (`5bafcbd11`, built but not run before the coordinator
called an early stop) needed to render the server's banner text instead of
a black dialog box — the same brush-pattern gap behind the station's black
title bars and status panes.

PuTTY is homebrew, not a built-in Series 80 app, and is not part of the
station's exhibit; it matters here only as a second, independent EKA1
client that hit and passed through the exact same starvation wall as Opera,
which is what rules out an Opera-specific cause.

## A real access point inside the ROM's own CommDB (agent N4, branch `s80-commdb-patchdll`)

Optional fidelity work, not required for Opera or PuTTY (both already work
through N2's emulator-side HLE `Start()` fallback above). N4 built a guest
**patch DLL** — `commdb_v7.dll`, loaded by EKA2L1's own patch mechanism in
place of the ROM's `commdb.dll` ordinal 153 (`CCommsDatabase::NewL()`) —
that inserts a real LANService/LANBearer/IAP/Proxies/ConnectionPreferences
record set into the guest's own `C:\System\Data\Cdbv3.dat` the first time
any app opens CommDB. Proven on the real 9300 ROM: the phone's own Control
panel › Connections › Internet setup applet lists **"1 Host network"** — the
ROM's own UI reading real on-disk records, not an emulator answer — and
Web's "Go to" goes straight to "Connecting…" with no "Select an access
point" prompt, because a real IAP now exists before any prompt would be
needed.

The schema is 7.0s-specific — 7.0s's `IAP` table has no `Modem` column, so
the existing 6.1-era patch DLL this was modelled on does not apply — derived
by reading the column set straight out of the ROM's own `DefaultCdbv3.dat`
and confirmed by a dynamic trace showing ordinal 27
(`NewL(TCommDbDatabaseType)`) is a thin wrapper that itself calls ordinal
153, so patching 153 alone covers every caller. The values match N2's HLE
answers on a fresh 9300 C: (IAP id 1, name "Host network", service type
"LANService", `DialogPref` DoNotPrompt) with one exception: `IAPBearer` is
**3** on-disk (every ROM has WLANBearer = 1 and RndisBearer = 2, so "Host
network" as LANBearer lands at 3), where N2's HLE constant answers 1. The
fix is to change N2's `EKA1_HOST_SERVICE` constant for `IAPBearer` to 3; no
traced client reads that field today, so it is cosmetic until one does. On
the 9300i/9500, which ship their own WLAN IAPs 1–5 in the ROM defaults, the
patched IAP lands at a different id (6) and every HLE constant above would
disagree with it — also cosmetic only, and out of scope for the 9300
target. Branch `s80-commdb-patchdll` @ `30c3eff3d` (on `fork`), built with
the same N5 toolchain; merges cleanly with N2's `s80-commdb` (neither
touches the other's lines). Nothing is placed on the guest drives by hand —
the patch DLL ships next to the emulator binary and the Qt frontend copies
it into each data dir's `patch/` folder at every start, so a golden only
needs a binary built from a branch carrying this commit; the records
themselves live in the guest's own `C:\System\Data\Cdbv3.dat` and are
created on the first CommDB open after boot (Web at app start, or Control
panel when Internet setup opens) — for a golden, either let the first boot
write them or pre-seed from a finished run.

**Side notes (agent N4).** The Control panel crash some earlier passes
fixed is unrelated to this DLL or its map file: it was the `ecam_general.dll`
patch replacing Series 80's `ecam.dll` (a host SIGSEGV under dynarmic,
`KERN-EXEC 3` under dyncom), fixed by C1's `a3350568c` + `3052b31c5`.
PuTTY for S80v2 has no in-app IAP chooser — its S80 build does not link
`commdb.lib` and asks `RConnection::Start` for the system prompt instead, so
the phone's own Internet setup list (above) is the only IAP-list proof for
it. Internet setup greys out "Edit" for "Host network" because
`iapwlan.dll` looks up a `WLANServiceTable` row for the service and finds
none — a cosmetic gap the museum does not need closed. The Lua breakpoint
hook used to trace the CommDB calls above (`n4_commdb_trace.lua`) names
every `CCommsDatabase` factory and table/record call with its thread and LR,
and is reusable for tracing any other patch DLL's guest-side behaviour —
but it must not be active while a patch DLL sits on ordinal 153, since the
trampoline occupies that entry.

## Opera's path to a connection (agent N2)

1. **Opera on the 9300 is "Opera 6.0 for Symbian OS"** (build 543; 556 on
   9300i/9500). Its network I/O originates in the **Symbian HTTP framework**
   (`httpclient.dll`, `http.dll`, `inetprotutil.dll`, filter plug-ins), not
   in Opera's own code. HTTP rides `RConnection`.
2. **No network at start.** Launching Web paints Opera's home page (a local
   `file://` page, currently blank — see "Still open") with the CBA column
   "Open Web address / Back / Bookmarks / Exit". No ESock call, no CommDB
   read.
3. **"Open Web address"** (CBA key F1 = `EStdKeyDevice0`) opens the "Go to
   address" dialog with buttons "Go to / History list / Cancel"; typing goes
   into the field, and "Go to" (F1 again) submits.
4. **On submit**, the HTTP framework opens `RConnection` (0x3F) and starts it
   (0x43). On the **real device**, a `ConnectionPreferences.DialogPref =
   Prompt` would raise the "Network connection — Select an access point"
   notifier (confirmed on the SDK-emulator oracle: GSM Data / Easy WLAN, then
   "Connecting…" 19 s → silent fail → re-prompt, because that VM has no
   packet driver). Under EKA2L1 there is no NIFMAN and no connection
   notifier, so nothing is drawn; the HLE ESock answers `Start` itself.
5. **With the redraw-spin fix in place**, the HTTP framework's continuation
   runs the instant `Start` completes and proceeds through resolve, connect,
   write and read to render the page (above). Without that fix, the
   continuation is starved and nothing after `Start` is ever sent — which is
   exactly the "0x3F, 0x43, then silence" trace this section used to end on.

**Opera's settings store.** ROM default:
`Z:\System\Apps\Opera\Opera.def` — `Home URL=z:\Documents\WWW\Home.html`,
`Enable Cookies=3`, `Scripting=1`, `Disk Cache Size=600`,
`[Proxy] Use Automatic Proxy Configuration=0`, no proxy host/port keys.
Writable copy: `C:\System\Data\Opera\Opera.ini` (Opera writes it on first
run, same shape as the SDK emulator's — `[User Prefs] Warn Insecure
Form=0`, `[EPOC] ZoomSetting=100`); `Home URL` here overrides `Opera.def`.
The proxy is per-IAP in CommDB, not in `Opera.ini`: after `Start`,
`oprbridge.dll` reads `GetIntSetting("IAP\IAPService")` +
`GetDesSetting("IAP\IAPServiceType")` and opens the CommDB Proxies view for
that service — answered by the `start()` fallback above (or, with N4's
patch DLL, by a real on-disk row).

## The C: drive recipe (agent N2, `cdrive-recipe.sh`)

Seeds a data dir's C: so Opera goes straight to `Start` with a visitor
reaching a start page with no typing required:

1. `C:\System\Data\Cdbv3.dat` = the ROM's `Z:\System\Data\DefaultCdbv3.dat`,
   copied the way the guest's CommDB does on first open (11,553 B,
   byte-identical to what Opera's first CommDB open creates). **No IAP row
   is needed on the EKA2L1 route** — the HLE ESock answers `Start` directly,
   bypassing CommDB. (The RAE-6 default CommDB ships the table schema plus a
   Dialout ISP record and Default-GPRS globals, but no populated IAP or
   ConnectionPreferences rows — those are created on a real device by
   first-boot/operator settings.)
2. `C:\System\Data\Opera\Opera.ini` with `Home URL=<start-url>` (LF line
   endings, as Opera itself writes it).
3. `C:\System\Data\Opera\urlhistory.dat` pre-seeded with the start URL (an
   externalised 8-bit descriptor with a `TCardinality` length header) so
   "Open Web address → History list" offers it without typing.

This recipe is still correct, but Opera does not yet act on the `Home URL`
at startup — see "Still open" below. Until that lands, the visitor path is
"Open Web address" (F1) → type or pick the seeded URL from "History list" →
"Go to", which works end to end today.

## Keymap and DNS notes for whoever resumes

- **URL entry.** K1's real keymap — a run-time port of the ROM's own
  EKTRAN/EKDATA translation tables, frame-proven (v3) for mixed case,
  digits, the full UK punctuation set, Chr legends and accent cycling,
  Ctrl-code entry, Shift+Backspace, Menu, the command buttons, the joystick
  and key repeat, from any host keyboard layout (branch `s80-keymap`, pushed
  at `d66e4ae87`) — replaces the crude data-dir key-binding workaround
  earlier tests here used just to type an address at all. The interim
  bindings branch, `s80-bindings-stopgap` (agent K2), is superseded on
  Series 80 now that K1 has landed. See the main document's §H4 for the
  keymap itself; nothing network-specific remains once a station bakes it.
- **Host-name / DNS mapping.** EKA2L1's inet HLE resolver first consults
  `config.yml`'s `hosts:` map (an exact name, or a `*.suffix` wildcard, to a
  `host[:port]`), then falls back to the host's own `getaddrinfo`. So the
  retronet station can point Opera at a corpus host name either through a
  `hosts:` entry in the device's `config.yml`, or by running the emulator in
  a network namespace whose resolver already answers retronet's wildcard
  DNS. No proxy is needed either way (`Opera.def`'s
  `[Proxy] Use Automatic Proxy Configuration=0`, no proxy host).

## Diagnostics for future stalls (agent N6, branch `s80-opera-trace` @ `d2108f404`)

A per-thread SVC/IPC/completion tracer, off by default (one static load per
SVC when disabled) and built for exactly this class of bug: a wall that is
not a server request. `EKA2L1_DIAG_THREADS=<substring>` matches thread or
process names and logs every SVC (caller resolved to `module+offset`),
every IPC send (with descriptor bytes), and every completion reaching the
thread on all four delivery paths (HLE server, guest server, `RThread::
RequestComplete`, timer/logon `notify_info`). `SIGUSR1` (or
`EKA2L1_DIAG_DUMP_MS=n`) dumps every guest thread's state, wait object and
call stack, plus — for matching threads — the full active-scheduler queue:
vtable, `iStatus`, `iActive` and priority for every pending active object.
This is what turned "Opera is silent" into "the priority-50 redraw object is
permanently ready and priority-0 never runs." Integrating it is optional; it
is inert unless the environment variable is set. It is the single
diagnostics commit on top of `s80-esock-70s`, so it carries the whole
network fix with it.

## Still open

1. **Opera's home page — RESOLVED, not by the ViewServer theory.** The
   ViewServer's `ActivateView` message (op 6) really was parsing a
   later-firmware 16-byte layout while the ROM sends an 8-byte view id +
   custom-message id + empty descriptor, and that is now fixed as a
   correctness matter — but it was not why the page stayed blank. The actual
   cause: EKA2L1 launched every EKA1 app with the "create document" command,
   where the device's own buttons use plain "run"; a create launch that
   names no document now becomes a run launch on Series 80, so Opera loads
   its built-in Nokia home page (`Z:\Documents\WWW\Home.html`) the way the
   device does (agent N7, branch `s80-opera-home`). File manager, which
   shared the same launch-command bug, now paints too. Write note and Sync
   reach their first screen since the 7.0s ViewServer ActivateView layout fix
   (N7); Presentations on the 9300 is still open. Full detail in
   [`candidate-symbian-s80-shell.md`](candidate-symbian-s80-shell.md).
2. **`RThread::ExitCategory()`** (exec 0xC0003F) is still unimplemented;
   faults a caller that asks for it. Not hit by Opera, PuTTY or the CommDB
   patch DLL.
3. Six EKA1 locale SVCs (0x800061–0x800066: day/month names, date suffix,
   AM/PM) go unanswered on N6's own build, called about 200 times during
   Opera startup with no visible effect (the names stay empty). Already
   fixed on C1's `s80-app-fixes` branch (`330e998e7`); the two branches
   merge cleanly, and I1's integration branch carries both.
4. Opera's behaviour on a genuine connection *failure* is untested on
   EKA2L1 — the fallback above always succeeds silently. The SDK-emulator
   oracle shows the real device's cycle instead: "Connecting…" for about
   19 s, a silent failure, and a re-prompt with no error dialog.
5. **RESOLVED: `nokia9300rom` joined retronet as its own web-plane station**
   (agent N9, 2026-09-25) — see "`nokia9300rom` on retronet" below for the
   recipe and the trap it found. The ESock/RConnection fixes above are
   HLE-side and apply unchanged to the ROM-window-server station; nothing
   about the ROM track changes ESock itself — see "The ROM track:
   `nokia9300rom`" in the main research doc for what does and does not run
   there.

## `nokia9300rom` on retronet (agent N9, 2026-09-25)

`nokia9300rom` (the ROM window-server station, hidden at
`/os/nokia9300rom`) now joins retronet the same way `nokia9300` does —
Opera opens `www.yahoo.com` from the corpus through the real station page,
and a negative test confirms no route out beyond retronet's own subnet.
`nokia9300` itself was **not restarted** to do this; its own cage is
unchanged.

**Why it needed a fix at the root, not a copy.** The `rn-netns.sh` script
that both stations emit (from `streamhost/stations/nokia9300/`) had
`nokia9300`'s netns name, veth pair, address and MAC **hard-coded**; run
as-is for the sibling station it would have collided with `nokia9300`'s own
network identity (same derived tap name minus the suffix, same fallback
address). The fix derives every name from the station itself
(`RN_STATION`, passed through as `$SH_STATION`): netns `rn-<station>`, veth
`<station>rn0`, the guest-side end cut to `IFNAMSIZ`
(`nokia9300romrng`), iptables chain `<STATION>RN-IN`, and a per-station MAC
variable `RN_<STATION>_MAC`. The station's retronet address comes from a
fixture value, `RN_GUEST_IP` (mapped from `NOKIA_RN_IP` in this station's
fixture) — the previous default address exists **only** for `nokia9300`,
so a sibling station with no `RN_GUEST_IP` of its own now refuses to start
networked at all (checked: exits 1, "no RN_GUEST_IP for nokia9300rom")
rather than silently reusing `nokia9300`'s address. `nokia9300`'s own
derived values were checked unchanged against its live cage before the
unit restart, and the new netns was exercised standalone (rules read back,
no default route, retronet gateway reachable, no route to `1.1.1.1`, DNS
resolves through the retronet resolver) before ever touching
`streamhost@nokia9300rom`.

**Addressing (own claims, permanent, under session `nokia9300rom`):** its
own retronet address, tap, iptables chain and slot/port/VMID (reused from
the existing dark-launch claim). Real values live only in the box's
gitignored `registry/local.env`; the committed MAC is the scrubbed
placeholder. Registry additions: the emitted `rn-netns.sh`, a `network:
host-only` note, and a `retronet:` block (web, static address, the veth
name, the iptables chain, the join date) — this repo's rule 15 means no
`rn-tapnet.sh` is committed for this station shape.

**Incident, self-inflicted and repaired.** `station-up.sh`'s manifest
republish step runs from *its own repo root*; run once from the shared
clone at a stale branch, it republished all five runtime manifests from
that old tree and dropped `nokia9300rom` from them (signal/restore both
404) for about two minutes, before being re-run from current `main` and
restoring all five. The lesson generalizes beyond this station: **run
`station-up.sh` only from a checkout at current `main`**, never from an
older branch or a stale worktree, because its manifest step reads from the
tree it runs in, not from the target station's own directory.

## Frames (evidence, in the job's tmp directories)

`N6/`: `opera-page-rendered-after.png` (the proof — a rendered page, title
bar text, table) · `opera-blank-before.png` (the same run on the pre-fix
binary, blank and black) · `opera-startup-no-homepage.png` · `runs/` (every
per-run frame and log: `opA`/`opB`/`opC`/`opE-before`).
`N5/runs/`: `ref1-a.png`/`ref2-ce.png` (reference binary hangs at 0x3F) ·
`n1h-f-park3.png` → `n1h-f-resumed.png` (path F: parked, then resumed) ·
`own-ef-park.png` → `own-ef-resumed.png`.
`N3/frames/`: `1-n1bin-putty-starved-40s.png` (pre-fix, greyed terminal) ·
`2-w2fix-select-profile-10.5s.png` (post-fix, profile dialog) ·
`3-after-connect-black-error-box.png` (the brush-pattern gap).
`N4/runs/`: `cp3-iapsetup-124.9s.png` ("1 Host network" in Control panel) ·
`w5-typed-then-go4.png` (Web skips the access-point prompt).
`N1/`: `web6-02-dialog.png` / `web6-03-typed.png` / `web6-go02-33.7s.png`.
`N2/runs/`: `web3-start-29.0s.png` … `web3-final-blank-461.0s.png`;
reference-binary hang: `web0.log`.
