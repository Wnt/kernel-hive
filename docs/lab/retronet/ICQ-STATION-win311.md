# win311 IM station — the AIM one, and the bridge it needed

**Status: LIVE (2026-09-01).** `win311` (Windows for Workgroups 3.11, VMID 90) is
on the retronet IM plane with the client that was already on its disk:
**Netscape AOL Instant Messenger 1.0.414** (America Online, 1997, 16-bit),
`C:\Netscape\Comm\Program\AIM.EXE`. It signs the **AIM screen name `win311`**
into the same OSCAR gateway (`10.99.0.2:5190`) the ICQ fleet uses, carries the
whole IM fleet in its contact list, and holds real two-way conversations with
those machines through [`retronet-aim-bridge`](#the-bridge).

Three things make it unlike every other IM station, all of them forced by the
client rather than chosen:

1. **It is an AIM identity, not an ICQ UIN** — the fleet's first.
2. **The golden scene does NOT hold a connected messenger.** Every other IM
   station bakes the client running and signed in; win311 bakes it *closed*. A
   visitor starts it from the Program Manager and it signs itself on.
3. **It needed a protocol bridge to talk to anyone**, because AIM and ICQ
   clients cannot name each other. That is the bulk of this document.

The bridge this rides on was already built by the web-plane join
([`WEB-STATION-win311.md`](WEB-STATION-win311.md)) on 2026-08-25: a real NIC on
`vmbr-rn`, DHCP `10.99.0.27`, guard chain `WIN311RN-IN`. OSCAR cannot traverse
slirp — the gating fact for every other station on this plane — and win311 has
not been behind slirp since August, so **no network work was needed here at all**
and none was done.

## The naming rule, which is the whole story

`WEB-STATION-win311.md` guessed this station would need the gateway's TOC door
(`:9898`) because `AIM.INI` pointed at real AOL hosts. It does not. The client is
a plain **OSCAR** client — `C:\Netscape\Comm\Program\` ships `OSCARUI.DLL`,
`OSCORE.DLL`, `OSCLOGIN.OCM`, `OSCMAIN.OCM`, `OSCONFIG.OCM` — and it shipped
pointed at `login.oscar.aol.com:5190`, a name the retronet's wildcard DNS already
answers with the gateway. **It could reach our OSCAR service with no
configuration at all**, which is what was observed before this work started.

What it *cannot* do is name anybody. Measured, on the real clients:

| | |
|---|---|
| **AIM 1.0.414 refuses an all-numeric screen name** | A name must begin with a letter. Typing `10000` into the buddy list gives *"A screen name in your list is too short or contains invalid characters."*; addressing a new message or even **replying** to one gives *"The screen name '10000' is not valid."* All three paths, client-side, before anything reaches the network. |
| **ICQ 2001b silently discards a non-numeric sender** | Sending to the live win98se (UIN `98980`) from the screen name `rnbridge`: the server accepted and logged the delivery, and **nothing appeared on the guest** — no window, no flash, no "Not In List" entry. The identical message from the numeric `31100` opened a Message Session immediately. |

So a UIN greeter would have left win311 able to *receive* and unable to answer —
a visitor typing a reply gets a STOP dialog. And no server setting fixes it:
Open OSCAR Server has **no alias or rename endpoint** (the management API has
`POST /user`, `DELETE /user`, feedbag and directory routes, and nothing that
gives an account a second name). **One account cannot be addressable by both
client families.** Hence a bridge, not a config change.

## The bridge

`scripts/retronet/aimbridge/aim_bridge.py`, unit `retronet-aim-bridge.service`,
installed by `install-aim-bridge.sh --apply`. It gives every participant a second
identity on the far side of the naming rule and relays between them:

```
   win311  (AIM client, screen name `win311`)
      |  its contact list holds: hivebot, win98se, win2000, nt4, win95,
      |  solaris, tru64, beos, winxp, w2kalpha, os2warp, irix   (ALIAS accounts,
      v                                                          letter-leading)
 [ retronet-aim-bridge ]
      |  speaks to the real stations as UIN 31100, whose ICQ directory nickname
      v  is "win311", so eleven ICQ clients render it as a name
   win98se (ICQ 2001b, UIN 98980)  ... and the other ten
```

- `win311 -> alias win98se` ⇒ bridge sends to UIN `98980` **as `31100`**.
- `UIN 98980 -> 31100` ⇒ bridge sends to `win311` **as alias `win98se`**.

Each hop therefore arrives from a sender the *receiving* client can render.

**Presence is real, not simulated.** `win98se` shows online in win311's list
exactly when the actual win98se station's client is signed on, because the
bridge signs that alias in and out to follow it; `31100` appears to the fleet
only while win311's own AIM is open. A permanently-online stand-in would be a
lie, and this fleet is routinely paused.

**Two watchers, because presence does not cross the AIM/ICQ divide even though
messages do.** Measured: an AIM-type account with an ICQ UIN in its buddy list
is never told that UIN came online, while the ICQ-type greeter watching the same
UIN in the same second was. So the bridge keeps a numeric watcher (`31101`) for
the stations and a named one (`rnbridge`) for win311. They are always on and in
nobody's contact list — presence has to be observed by *somebody* while the
identity that mirrors it is deliberately offline. **Do not merge them into one
account: it will silently see only half the fleet.**

The station list comes from [`roster.json`](../../../scripts/retronet/icq/roster.json),
so adding a station to the fleet adds it to win311's world with no edit to the
bridge. The bridge's accounts are its own — no guest ever signs in as one — and
their passwords live only in `/etc/retronet/aim-bridge.json` (0600), generated
and set on the gateway in the same pass so the two cannot drift.

## The two greeters

`win311`'s roster row carries `greeter: "aim"`, which moves it from HiveBot to a
second greeter instance signed in as the AIM screen name **`hivebot`**
(`retronet-bot-aim.service`, same `bot.py`, same LLM, same cage;
`install-bot.sh --instance aim --apply`). The two instances **partition** the
fleet by that field, so a station is greeted exactly once, by an identity its
client can answer. HiveBot (UIN `10000`) is untouched and keeps its place in all
eleven ICQ stations' baked buddy lists.

## The wiring, at a glance

| | |
|---|---|
| Client | **Netscape AOL Instant Messenger 1.0.414** (16-bit, Feb 1998 build), preinstalled with the Communicator 4.08 shelf; **no media was sourced** |
| Identity | AIM screen name **`win311`**; password in gitignored `registry/local.env` `RETRONET_ICQ_WIN311_PASS` |
| ICQ-side identity | UIN **`31100`**, directory nickname `win311`, held by the bridge — this is the `uin` in `roster.json` and the one the SSI cross-list carries |
| Server | `10.99.0.2:5190`, pinned as a literal in the client (Setup ▸ Connection ▸ Host), with **Keep connection alive** ON |
| Launch | **by hand**, Program Manager ▸ **Internet** group ▸ *AOL Instant Messenger™*. `STARTUP.GRP` is empty and stays empty |
| Credentials | **Save password** + **Auto-login** ticked, so the manual launch signs on with no typing |
| Config on disk | `C:\WINDOWS\AIM.INI` (global: `[Server]`, `[UserDataPaths]`) + per-screen-name `user.ini` under the `Users` tree it creates on first sign-on |
| Contact list | **client-local and baked into the golden** — AIM 1.0.414 predates SSI, so no server push can reach it. 12 entries: `hivebot` + the eleven ICQ stations |
| Greeter | `hivebot` (`retronet-bot-aim.service`) |

## The scene contract — a deliberate exception

The fleet's IM rule is *"the checkpoint holds a connected messenger"*
([`RETRONET-BRIEF.md`](../RETRONET-BRIEF.md) §5). **win311 is exempt, on the
operator's instruction.** The golden holds the Program Manager desktop with AIM
closed, exactly as it did before this work.

Why it is also the better exhibit here:

- It makes the messenger something the visitor *does*. On a 1993 desktop,
  opening AIM and watching it dial in is the period-accurate moment.
- The greeting then lands because the visitor acted, seconds after their own
  click, instead of ~30 s after a wake they never saw.
- It costs nothing in reliability. The reconnect problem that shaped every other
  IM station — a `loadvm` wake restoring a stale BOS socket — **cannot occur if
  no socket is baked.** win311 needs no nudge timer and no silent-reconnect proof.

The cost is that a visitor who never opens AIM never sees the IM plane. That is
the accepted trade.

## Acceptance — what was actually proven, on framebuffers

1. **Auto-login from a cold restore.** `loadvm golden`, then one click + Enter on
   the *AOL Instant Messenger™* icon: the client launched, signed itself on with
   **no typing**, and the server logged `user signed on screenName=win311
   ip=10.99.0.27:1042`. No Sign On dialog, no password prompt.
2. **The greeter reaches it.** `hivebot` greeted the fresh sign-on and the line
   rendered in an AIM window on the guest.
3. **A real conversation with a real station**, both sides on their own hardware:

   | on win311 (AIM) | on win98se (ICQ 2001b) |
   |---|---|
   | `win311: greetings from 1993 - what year are you?` | shown as from **win311** at 11:28 |
   | `win98se: nineteen ninety eight over here. nice to meet you.` | typed there, sent with Alt+S |

4. **The contact list is baked and honest.** After the recapture the buddy list
   reads **Buddies (3/12)** — twelve contacts, three online: `win98se` and
   `os2warp`, the only two stations actually running at that moment, plus
   `hivebot`. Re-verified on the LIVE station after the golden swap.
5. **Presence follows reality.** `labctl reset win311` (AIM closed again) and
   `31100` left the server's session list; the aliases for paused stations stay
   signed off.

## Gotchas specific to win311 IM

- **Do not add AIM to `STARTUP.GRP`.** The empty startup group *is* the feature.
- **The contact list does not survive a reseed.** It is client-local in
  `user.ini` and baked into the golden; `seed_contacts.py ssi` cannot reach it.
  Changing win311's own list means a golden recapture — so a station added to the
  fleet later appears in *everyone else's* list automatically but in win311's
  only after a re-bake.
- **`user.ini` is written when the client exits**, not continuously. Quit AIM
  before `savevm` or the golden can hold a half-written config. (This is also
  why the scene contract and the storage model agree here.)
- **A greeter must never watch the proxy UIN.** `roster_lib.persona_id()` returns
  the AIM screen name for this station precisely so a greeter addresses the guest
  and not the bridge.
- The `qmp-type.py` backslash trap from the web-plane join applies to any driving
  done here: type guest paths as `C:\\dir\\file` through ONE shell layer, and
  check the field — over-escaping silently doubles them.

## Golden lineage & rollback (FULL paths)

- **LIVE golden (2026-09-01 07:56):** internal snapshot `golden` in
  `/data/vms/streamhost/stations/win311/{win311-golden.qcow2,games-golden.qcow2}`
  — AIM configured, credentials saved, 12 contacts baked, client **closed**,
  Program Manager scene (Gallery Games front, Minesweeper selected).
- **Pre-IM backup (the rollback for this whole change):**
  `/data/vms/streamhost/stations/win311/{win311-golden.qcow2,games-golden.qcow2}.bak-preim-20260901`
  + `SHA256SUMS.preim-20260901` beside them, taken with the guest STOPPED.
- Rollback = `systemctl stop streamhost@win311`, copy both `.bak-preim-20260901`
  files back over the live ones, `systemctl start streamhost@win311`. Then
  optionally `systemctl disable --now retronet-aim-bridge` and
  `retronet-bot-aim`; the server-side accounts are inert without a client
  configured to use them. Revert the `roster.json` row to drop win311 and re-run
  `install-bot.sh --apply` so HiveBot's persona list matches.
- The earlier `*.bak-prern-20260825` set (pre-retronet) is the rollback for the
  *network* join and is **not** the target for this change.

## Operating it

```bash
ssh lab 'systemctl status retronet-aim-bridge retronet-bot-aim'
ssh lab 'journalctl -u retronet-aim-bridge -f'            # every relayed line
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py users'   # AIM rows vs ICQ rows
# who is actually signed on right now (stations, aliases, watchers, greeters):
ssh lab 'pct exec 951 -- python3 -c "import http.client,json;c=http.client.HTTPConnection(\"127.0.0.1\",8080);c.request(\"GET\",\"/session\");print(sorted(s[\"screen_name\"] for s in json.loads(c.getresponse().read())[\"sessions\"]))"'
ssh lab '/data/kernel-hive/scripts/retronet/aimbridge/install-aim-bridge.sh'   # plan only
```
