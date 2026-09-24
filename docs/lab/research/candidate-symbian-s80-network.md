# Nokia 9300 network detail — ESock, RConnection, CommDB, Opera

Sibling of [`candidate-symbian-s80.md`](candidate-symbian-s80.md) §H3. Holds
the opcode table, the IPC trace evidence and the theories that were raced and
ruled out, so the main document can state the conclusion without the working.
Facts only, from agents N1, N2 and the coordinator's relay of N5's proof
(2026-09-24); protocol facts (opcode numbers, argument order, server order)
only — no disassembly, no ROM bytes.

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

## Where Opera stalls, and why it is above the socket layer

The trace is unambiguous (log-ipc plus per-request tracing on, both agents
independently): on "Go to", Opera loads the HTTP framework's filters via
ECom (`httpfilterauthentication.dll`, `httpfiltercommon.dll`, …), does POSIX
and file-server I/O, then sends **exactly two ESock ops**: `0x3F` `ECNCreate`
(`RConnection::Open`) and `0x43` `ECNStart` (the *default* `Start` — Opera
passes **no** `TCommDbConnPref`). Both complete `KErrNone`. **After `Start`,
Opera issues no IPC to any server except the window server's idle/text-cursor
loop** (the same `Unimplemented window group opcode 0x2F` noise the shell
work already knows about, ~33 % CPU). No `RHostResolver` (0x28/0x3E), no
`RSocket` (0x06/0x3D), no `Connect` (0x13), no `GetIntSetting`/`GetDesSetting`
(0x4C/0x4E), and no DBMS/CommDB reopen. DBMS *is* present and HLE'd — a
transient DBMS session opens and is torn down during Opera's *startup*
CommDB read, well before `Start` — so the CommDB path itself works; Opera
simply never returns to it afterwards.

Three theories were raced, not bisected serially (rule 14):

- **T1 — async progress ordering.** A real NIFMAN completes `Start` as
  "started" and then delivers `KConnectionOpen`/`KLinkLayerOpen`
  *asynchronously* via `ProgressNotification`; the HTTP transport might only
  submit once it sees the link up. The fallback instead advances the state
  *synchronously during* the `Start` call — if the framework registers a
  `ProgressNotification` (0x47) afterwards and asks for a specific
  intermediate stage, the request could park against a state that has
  already moved past it. **Against it:** Opera never issues a
  `ProgressNotification` call at all, so there is nothing registered to
  starve. Ruled out.
- **T2 — the transaction lives on another active object inside Opera.**
  Opera may submit the HTTP transaction before or around the connection and
  wait on a different active object entirely; the window-server spin would
  then just be its idle UI loop. **This is the one standing**: every ESock
  op Opera issues completes correctly, and the racing proof (agent N5, next
  section) shows the identical protocol sequence working end to end when
  driven directly, so the wall is inside Opera's own HTTP transport handler
  (`oprbridge.dll` / the Symbian HTTP framework), not the protocol.
- **T3 — a leaked in-guest CommDB/proxy read.** `oprbridge` reads the
  Proxies view via in-guest `commdb.dll` after `Start`; with no
  `LANService`/Proxies row in `Cdbv3.dat`, that read could leave and abort
  the fetch silently. **Against it:** the trace shows **no DBMS traffic at
  all** after `Start`, so Opera has not even reached the proxy read. Ruled
  out.

## Opera's path to a connection (agent N2)

1. **Opera on the 9300 is "Opera 6.0 for Symbian OS"** (build 543; 556 on
   9300i/9500). Its network I/O originates in the **Symbian HTTP framework**
   (`httpclient.dll`, `http.dll`, `inetprotutil.dll`, filter plug-ins), not
   in Opera's own code. HTTP rides `RConnection`.
2. **No network at start.** Launching Web paints Opera's home page (a local
   `file://` page) with the CBA column "Open Web address / Back / Bookmarks
   / Exit". No ESock call, no CommDB read.
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
that service — answered by the `start()` fallback above.

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

## The end-to-end proof (agent N5)

A plain Symbian 7.0s console client, built with a Linux-hosted EKA1 ARMI
toolchain and run against the real 9300 ROM (branch `s80-esock-70s` @
`92f600bf5`), drives the full stack directly: `RSocketServ::Connect`,
`RConnection::Open` (0x3F), `Start` with a `TCommDbConnPref` for IAP 1
(0x44), `RHostResolver::Open` on the connection (0x3E), `GetByName` (0x29),
`RSocket::Open` (0x3D), `Connect` (0x13), `Write` (0x0E),
`RecvOneOrMore` (0x0C) and `Close` — every call returns `KErrNone` — and an
HTTP/1.0 GET to a test server on the host returned "200 OK" text that was
rendered on the emulated 9300's own screen. The implicit-connection path
(0x28/0x06/0x09/0x0D, where a plain `RSocket::Open` with no explicit
`RConnection` picks a default one) works too. On the pre-fix reference
binary, 0x3F and 0x28 both hang forever — the same hang `is_oldarch()`
caused for Opera.

**Conclusion: the socket layer is proven end to end.** Opera's remaining
stall is on Opera's own side of a successful `Start` (T2 above), not in
ESock.

**Two EKA1 gaps found along the way, still open:** `RThread::ExitReason`
(exec 0x3E) and `ExitCategory` (0xC0003F) are unimplemented.

## Keymap and DNS notes for whoever resumes

- **URL entry (test-only, not committed).** EKA2L1's HLE window server maps
  scan codes 0x1D–0x5F to themselves as key codes, so a host key bound to
  `target == ASCII` types that character. N1's own data-dir copy bound Qt
  keycodes to identity scan codes for `A`–`Z` (0x41–0x5A), `.` (46), `:`/`;`
  (58/59), `/` (47), `-` (45), `,` (44) and space (32) so a URL could be
  typed at all for testing; digits and `.`/`:` already worked via the
  numeric block. **K1/K2 own the real, committed keymap** — this is a test
  convenience only, and was not carried into any golden.
- **Host-name / DNS mapping.** EKA2L1's inet HLE resolver first consults
  `config.yml`'s `hosts:` map (an exact name, or a `*.suffix` wildcard, to a
  `host[:port]`), then falls back to the host's own `getaddrinfo`. So the
  retronet station can point Opera at a corpus host name either through a
  `hosts:` entry in the device's `config.yml`, or by running the emulator in
  a network namespace whose resolver already answers retronet's wildcard
  DNS. No proxy is needed either way (`Opera.def`'s
  `[Proxy] Use Automatic Proxy Configuration=0`, no proxy host).

## Frames (evidence, in the job's tmp directories)

`N1/`: `web6-02-dialog.png` ("Go to address" dialog open) ·
`web6-03-typed.png` (a loopback test address typed into the field) ·
`web3-keytest2.png` (letters typed, proving the test keymap above) ·
`web6-go02-33.7s.png` (blank page after "Go to" — the stall).
`N2/runs/`: `web3-start-29.0s.png` (Opera home, no network) ·
`web3-dialog-40.7s.png` ("Go to address" dialog) ·
`web3-typed-51.9s.png` (URL in the field) ·
`web3-go1-66.4s.png` … `web3-final-blank-461.0s.png` (blank page after a
successful, silent connection); reference-binary hang: `web0.log`.
