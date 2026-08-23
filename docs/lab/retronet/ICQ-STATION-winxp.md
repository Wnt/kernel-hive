# winxp ICQ station — the bridge as-built (ICQ 2001b / SSI)

**Status: LIVE.** `winxp` runs **ICQ 2001b (build 3659)** against the retronet
OSCAR gateway over the bridged NIC it already had on `vmbr-rn`. Open the station
and the persona (UIN `51000`) **self-reconnects silently** and the greeter bot
(UIN `10000` = HiveBot) messages it about a minute later. The network half was
already done by [`WEB-STATION-winxp.md`](WEB-STATION-winxp.md); **this wave added
messaging only** — no NIC, MAC, DHCP or guard-chain change.

The recipe is the fleet standard from
[`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md) (read that for the shared
design and for *why* 2001b). This doc records what is **specific to winxp**, and
winxp is the first station in the fleet onboarded as a **fresh 2001b install**
rather than a 2000b→2001b upgrade.

## Why ICQ 2001b — no deviation from the fleet standard

The brief allowed a later ICQ generation on the grounds that winxp is a
2001-era guest. **It was not needed:** ICQ 2001b build 3659 installs and runs on
XP Pro SP3 without a single compatibility prompt, and it is what the rest of the
Windows fleet already speaks. Deviating would have bought nothing and cost the
fleet a second client to reason about. `client` in
[`roster.json`](../../../scripts/retronet/icq/roster.json) stays `icq2001b`.

The requirement that actually drives the choice is **SSI (server-stored
roster)**: the client downloads its contact list from the gateway on sign-on, so
a roster change never needs client-UI seeding or a golden recapture. 2001b is
the first ICQ generation with it. Its own installer says so on the licence page
("ICQ 2001b supports hosting your Contact List on the ICQ servers").

**A fresh install is easier than the upgrade.** The 2000b→2001b migration path
carries 2000b's saved-password bug, so win98se/win2000/nt4 all hit *Password
incorrect* on first login and had to re-enter the password (win98se twice). A
clean 2001b install has no such baggage: **Existing User → UIN + password → the
first login simply succeeds.** There was no password prompt at any point.

## The wiring, at a glance

Everything in [`WEB-STATION-winxp.md`](WEB-STATION-winxp.md) is unchanged. What
this wave added:

| | |
|---|---|
| OSCAR server | gateway CT `10.99.0.2:5190`. ICQ's **Server → Host** is the literal `10.99.0.2`, port `5190` (deterministic; the DNS hijack of `login.icq.com` reaches the same place, but the literal removes the moving part) |
| Persona | UIN `51000`, nick `winxp`; password in gitignored `registry/local.env` `RETRONET_ICQ_WINXP_PASS`. Created with `rn-tool.py user-set 51000 <pass>` + `user-open 51000` (the `user-open` is load-bearing — see BOT.md's "the thing that silently breaks the greeting") |
| ICQ client | **ICQ 2001b build 3659**, `C:\Program Files\ICQ\Icq.exe`. **Keep connection alive = ON**, Auto Save Password = ON, Launch ICQ on startup = ON, Advanced Mode |
| Greeter | the bot only greets UINs listed in `RN_BOT_PERSONAS` in `/etc/retronet/bot.env` on labhost; `51000:winxp` was appended there and `retronet-bot` restarted |
| Golden | internal snapshot `golden`, 284 MiB, 2026-08-23 22:25, in `/data/vms/streamhost/stations/winxp/winxp-golden.qcow2` |

**The gateway account password is 6–8 characters.** Open OSCAR Server rejects
anything longer (`400 invalid password: password must be between 6-8
characters`), so a generated 12-char password fails at `user-set`.

## Delivery: the CD medium, not the IE download

**The installer was delivered by swapping the CD medium, not by downloading it
in IE — and on this station that is the recipe, not a preference.**

winxp already has an IDE CD-ROM in its device set
(`-cdrom /data/gallery-guests/WinXPpro/retro-software.iso`), so QMP
`blockdev-change-medium` on `ide1-cd0` swaps the disc **without changing the
device set**, which is what `loadvm golden` requires. Build a tiny ISO, insert
it, run the installer from `D:`, then put `retro-software.iso` back:

```bash
xorriso -as mkisofs -J -R -V ICQINST -o icq-install.iso isoroot/   # isoroot/ICQ2001B.EXE
# insert
python3 q.py '{"execute":"blockdev-change-medium","arguments":{"device":"ide1-cd0",
  "filename":"/path/icq-install.iso","format":"raw"}}'
# ... Start ▸ Run ▸ D:\ICQ2001B.EXE ... then swap retro-software.iso back
```

**Why not IE.** The win2000 recipe delivers the installer over the bridge from a
temp `python3 -m http.server` in the gateway CT. That fetch *works* on winxp —
IE8 starts the download with no security bar — but **IE8's download window never
paints**. It appears in the taskbar as `0% of ICQ2001b.exe…`, and clicking or
right-clicking its taskbar button, Alt+Tab and Alt+R all fail to bring it up or
focus it (Alt+R goes to IE and opens the Print menu). With no exec channel there
is no way to reach the file it is holding. The CD path sidesteps the whole
dialog: XP auto-mounts the disc as `ICQINST (D:)` and `Start ▸ Run` launches it.

Two tidy-ups the CD path costs you: XP opens an autorun Explorer window when the
disc is inserted **and again when the original disc is put back** — close both
before the golden, or they are baked into the scene.

## Windows Firewall stays ON — the answer is "Keep Blocking"

On first launch ICQ Core triggers *Windows Security Alert — Windows Firewall has
blocked some features of this program*, offering **Keep Blocking / Unblock / Ask
Me Later**.

**Keep Blocking is the correct answer, and it is not a compromise.** XP's
firewall is **inbound-only and stateful**: ICQ's outbound TCP session to the
gateway's OSCAR port is never filtered. The only thing being blocked is ICQ's
*listener* for peer-to-peer direct chat and file transfer — which this exhibit
does not use, because every message is relayed by the gateway. So the museum
loses nothing and the guest gains no inbound hole on a bridge it shares with
real sibling guests.

- **Never choose "Ask Me Later"** — it is not remembered, so the alert would
  return on **every** ICQ start, which on a `loadvm` station means forever.
  "Keep Blocking" is persisted as a disabled exception and never asks again.
- Proven after the fact, in-guest: `netsh firewall show opmode` reports
  `Operational mode = Enable` for the Domain profile, the Standard profile
  (current) **and** `Local Area Connection 2`; and `netsh firewall show
  allowedprogram` lists **only** the stock `xpnetdiag.exe` and `sessmgr.exe` —
  **no ICQ entry at all**.
- `netstat -n` in the guest shows **exactly one** active connection:
  `10.99.0.18:1123 -> 10.99.0.2:5190 ESTABLISHED`. Nothing else, in either
  direction.

## The gotcha that eats a bring-up: idle auto-pause discards QMP input

**This is the winxp-specific trap and it costs hours if you do not know it.**

winxp runs with streamhost's **idle auto-pause ON** (`grace 60s`). With no
visitor session the daemon QMP-`stop`s the guest — and **input events delivered
to a stopped VM are silently discarded**. Symptoms while driving the guest by
hand:

- clicks and keys land *sometimes*, at random;
- the framebuffer stops changing, and the mouse pointer does not move even
  though `query-status`, sampled at the wrong moment, can still say `running`;
- the guest does not answer ping and QEMU burns ~0 CPU.

It reads exactly like a wedged guest. It is not. `journalctl -u streamhost@winxp`
says it plainly: `[idle] no sessions for 60s -> guest paused (resumes on next
visit)`.

**The fix that works: send `cont` and the input events back-to-back on ONE QMP
connection**, so there is no window for the pause to land in the middle. A
separate `cont` followed by a separate `drive.py` call still loses the race, and
a background resume loop only narrows it.

**What you must NOT do is restart the station to clear it.** Setting
`SH_IDLE_PAUSE_SECS=0` needs a restart, and a restart means `loadvm golden` —
which would restore **pre-install RAM on top of a post-install disk**. The
station writes straight to `winxp-golden.qcow2` (no `-snapshot`), so mid-bring-up
that mismatch is a corrupted NTFS waiting to happen. Drive through the pause; do
not restart until the new golden is captured.

Second trap, cheaper: **check the whole 1920×1200 frame, not the region you
expect.** ICQ opens several dialogs (Simple/Advanced Mode Selection, the
firewall alert) **centred on the screen** while the client itself is docked in
the top-right corner. A crop around the ICQ window shows "nothing happened" when
in fact the dialog has been waiting centre-screen for three attempts.

## Measured acceptance — via the production `labctl reset` path

The honest test is **not** `labctl reset` on a station that was online seconds
ago: the gateway still holds that session, the restored socket still matches, and
the persona simply stays online without ever exercising the reconnect. To
reproduce the real "visitor after idle" wake, let the guest sit idle-paused until
the gateway **drops** the session first — measured at **~130–160 s** of paused
guest — then wake it.

Doing that, from the captured golden:

| | |
|---|---|
| before the wake | `51000` **absent** from the gateway's session list |
| `labctl reset winxp` | `loadvm golden` |
| **silent reconnect** | **t+17 s**, no password prompt anywhere on the frame |
| fresh session, not the restored one | `online_seconds: 6`, **new source port 1123** (was 1121) |
| SSI roster | `HiveBot` rendered **by name**, no client-UI seeding |
| **HiveBot greeting** | within ~a minute: *"hey! is that the XP box?"* |

The reconnect mechanism is 2001b's, unchanged from win98se/win2000: the restored
BOS socket is stale, `Keep connection alive` probes it, the socket aborts, and
the client re-signs-in on a fresh port using the saved password. **No nudge timer
exists or is needed for winxp.**

`Keep connection alive` ships **OFF** and is load-bearing — set it in
Preferences → Connections → **Server**. That same tab is where Host becomes
`10.99.0.2`; note the field does **not** honour Ctrl+A, so clear it with `End`
plus backspaces or you get `login.icq.com10.99.0.2`. Applying it raises
*Connection settings have been changed. Disconnect and reconnect for the new
settings to take effect* — do that once and confirm the reconnect is silent
before capturing the golden.

## Containment — re-proven from inside the guest

Unchanged locks (no default route / `retronet-fw` / the `WINXPRN-IN` guard chain
scoped to `10.99.0.18`), re-proven in `cmd.exe` on the framebuffer after ICQ was
live:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR + `:80` origin) | **Reply**, TTL 64, 0 % loss | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` | **Request timed out**, 100 % loss | the `WINXPRN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **Destination host unreachable**, 100 % loss | no default route (Lock 1) |

Plus the two firewall/socket facts above: firewall `Enable` on every profile, no
ICQ program exception, and a single outbound socket to `10.99.0.2:5190`.

Guard chain and tap after the work, from labhost:

```
winxprn0 UP  master=vmbr-rn  disable_ipv6=1
-A WINXPRN-IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A WINXPRN-IN -j DROP
-A INPUT -s 10.99.0.18/32 -i vmbr-rn -j WINXPRN-IN
bridge fdb show dev winxprn0 -> $RN_WINXP_MAC master vmbr-rn
```

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (284 MiB, 2026-08-23 22:25) in
  `/data/vms/streamhost/stations/winxp/winxp-golden.qcow2`, captured with **ICQ
  2001b connected** (UIN `51000`, Server `10.99.0.2:5190`, Keep-alive ON), the
  SSI roster synced, `retro-software.iso` back in the drive and a clean
  1920×1200 frame. `labctl reset winxp` = `loadvm golden`.
- Captured in the safe order — `savevm golden-new` → verify → `delvm golden` →
  `savevm golden` → `delvm golden-new` — so the old golden is never deleted
  before the new one is proven written.
- **Full-disk byte-copy backup of the pre-ICQ golden** (QEMU stopped,
  SHA256-verified `7a2b68c9ae453ee4f672c03ae8be1df7bbdc332d5c01b115dbece03a08c3cd3b`
  on both source and copy):
  `/data/vms/streamhost/stations/winxp/golden-backup-preicq-20260823/`
  (`winxp-golden.qcow2` + `SHA256SUMS`). This is the rollback for the whole ICQ
  change — it holds the web-only retronet golden.
- Older: `golden-backup-prern-20260823/` (pre-retronet slirp + Notepad golden).

**Rollback:**

```bash
ssh lab 'systemctl stop streamhost@winxp
  D=/data/vms/streamhost/stations/winxp
  cp -a $D/golden-backup-preicq-20260823/winxp-golden.qcow2 $D/winxp-golden.qcow2
  systemctl start streamhost@winxp'
```

(The gateway account and the roster row can be left alone; an unused account
serves nothing. Drop `51000:winxp` from `/etc/retronet/bot.env` if you want the
greeter to stop looking for it.)

## The installer

**ICQ 2001b build 3659**, sourced from the Internet Archive item `icq-2001b`
(`https://archive.org/download/icq-2001b/ICQ2001b.exe`), 4,312,600 bytes,
`sha256 3436e607cc2dfde7021f6f50d1f8f20e9da88dcb846d50fa9b88eecb9fa6d511`. The
build is confirmed inside the binary itself — its PE `VS_VERSION_INFO` carries
`FileDescription: ICQ Installation (Ver 2001b Build 3659)` — and again on the
framebuffer, in the installer's own title bar. **The binary is not committed**
(preservation-archive media never is); re-fetch it from that URL and check the
hash.

## Operating it

```bash
ssh lab 'labctl reset winxp'                        # loadvm golden -> silent reconnect, greeting ~1 min
ssh lab 'labctl shot winxp /tmp/x.png'              # the only proof that counts
# is the persona online? (server-side)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 51000'   # the server-side SSI roster
ssh lab 'bash /data/vms/streamhost/stations/winxp/rn-tapnet.sh show'  # tap + guard chain
```

Acceptance shots for this wave live on the box at
`/data/vms/streamhost/stations/winxp/rn-icq-acceptance-20260823/`.
