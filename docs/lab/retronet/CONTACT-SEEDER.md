# The retronet ICQ contact seeder — as built

**Status: LIVE (server-side SSI). All 5 live accounts cross-listed 2026-08-21.**
Every live ICQ station carries every *other* live station + the bot in its
contact list, with the bot showing as **HiveBot**, not `10000`. The **primary**
path is now **server-side SSI/feedbag**: one write per account on the gateway
cross-lists the whole live fleet, and an SSI-aware client (climm; the upgraded
ICQ) reads it on next login — **no per-client UI automation, no golden
recapture**. Roster-driven and idempotent: adding a station is one row in
`roster.json` plus a re-run. Parent:
[`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md); server is
[`GATEWAY.md`](GATEWAY.md); the pathfinder station is [`ICQ-STATION.md`](ICQ-STATION.md).

Files, all under `scripts/retronet/icq/`:

| File | What |
|---|---|
| `roster.json` | the single source — bot + every station's UIN, display nickname, client kind, and `onboarded` (=live) flag |
| `seed_contacts.py` | the tool: roster logic, the **SSI population + proof**, nicknames, the client-UI fallback, idempotency, an offline `selftest` |
| `icq2000b-add.macro.json` | the ICQ 2000b Add-by-UIN input macro for the **fallback** client-UI path (uncalibrated) |

The SSI write lives in the gateway's own `rn-tool.py` (`ssi-seed` / `buddies`);
`seed_contacts.py` orchestrates it across the live fleet. Both run **on labhost**
(invoke via `ssh lab`): the tool needs `pct exec 951` (the gateway's management
API and its SQLite are CT-loopback-only) and, for the end-to-end proof, a socket
to the gateway.

## The primary path — server-side SSI / feedbag (SNAC 0x13)

open-oscar-server stores a **server-side buddy list** (the OSCAR SSI / "feedbag"
service) per account and serves it to a client on login: the client sends
SNAC `13,04` "request list" and the server answers `13,06` with every item.
Writing this list on the gateway is all it takes — the station shows its
contacts on next sign-on, with the display name carried **in the roster item
itself**, so there is nothing to drive in the client and nothing to re-bake.

**Which clients read it.** climm (with `climm-0.6.4-ssi-login.patch`, see
[`ICQ-STATION-solaris.md`](ICQ-STATION-solaris.md)) and the upgraded ICQ client
are **SSI-aware** and sync the server roster on login. Stock **ICQ 2000b keeps
its list client-local** (`buddyListMode.useFeedbag = 0`) and ignores SSI — for it
the client-UI path below stays as the fallback.

### The item layout — decoded from the live climm stations

The feedbag rows climm itself wrote for solaris (`30000`) and tru64 (`64000`)
were the reference; the seeder writes byte-identical items:

```
PDINFO  classID=4 groupID=0 itemID=nz name=''                    attrs=TLV(0x00CA = pdMode)
GROUP   classID=1 groupID=G itemID=0  name='contacts-icq8-<uin>' attrs=empty
BUDDY   classID=0 groupID=G itemID=nz name='<buddyUIN>'          attrs=TLV(0x0131 = nick)
```

- A feedbag item's **attribute BLOB** is a `uint16` byte-length prefix + a TLV
  list (`TLV = type u16 | len u16 | value`). open-oscar-server stores it exactly
  as it goes on the wire, so the DB blob and the `13,06` item body match.
- The buddy's **display name travels in its `0x0131` "local alias" TLV** — so the
  SSI roster is self-describing: a client shows `HiveBot` for UIN `10000` with
  **no ICQ-directory lookup**. (The directory nickname is still set too, for the
  non-SSI fallback; see below.)
- `pdMode = 4` ("block deny list" → allow-all with no denies) is climm's default
  and the museum's intent (everyone sees everyone).

### `ssi-seed` — an idempotent, atomic reconcile

`rn-tool.py ssi-seed <uin> <buddyUIN>=<nick> …` reconciles one account's feedbag
to exactly the given buddies, in a single SQLite transaction:

- **One contact group.** If the account already has one (climm's), its **groupID
  and name are kept** so an already-synced client sees a minimal delta; otherwise
  one is created. Stray extra groups are collapsed into it.
- **Buddies** are keyed by UIN (the item `name`): present ones are updated
  in place (item ID preserved), missing ones inserted with a fresh unique item
  ID, and any not in the list removed.
- **PDINFO** is created if the account has none, and left alone if it has one.

So a re-run is a no-op, and re-running the whole fleet after a station joins only
adds the newcomer. Proven on solaris/tru64: the seed **reused** climm's original
groups (`24676` / `31798`) and its `HiveBot` items, and added the four new
station buddies — no duplicate `HiveBot`.

**Why a direct SQLite write** (not the management API, not driving a client): the
management API has no feedbag endpoint, exactly as it has none for ICQ
permissions — so this writes the table directly, the same pattern as
`rn-tool.py user-open`. It is safe: SQLite is multi-process safe, and the server
reads the roster **fresh on each `13,05`/`13,04` request** (no cache), so the
write takes effect with no restart and does not disturb a client that is already
signed on — that client simply reads the fuller roster on its next login. This
is a **server-side** change only: no station VM is touched, no session displaced.

### The proof the server *serves* it — `verify-ssi`

The SSI analogue of `verify-nick`. It creates a **throwaway** account, writes it
a known roster via the same `ssi-seed` path, signs in as it over real OSCAR,
requests the list (`13,04`), parses the `13,06` reply, and reads the buddies
back — then deletes the throwaway. It touches **no real account**, so no live
climm/ICQ session is displaced. It prints:

```
server-side SSI proof — throwaway account, real OSCAR sign-in, SNAC 13,04 -> 13,06:
  a client receives buddy 10000 as 'HiveBot'
  …
PASS — a directly-written feedbag roster is served on login (3 buddies)
```

That closes the loop the `buddies` DB read leaves open: not just "the row is
set" but "a signing-in client receives it".

### Live state — all 5 accounts populated + verified (2026-08-21)

`seed_contacts.py ssi --apply` wrote the server-side roster for every live
account; `rn-tool.py buddies <uin>` shows each carrying the other four + HiveBot:

| Account | UIN | server-side SSI roster |
|---|---|---|
| win98se | 98980 | HiveBot, win2000, nt4, solaris, tru64 |
| win2000 | 20000 | HiveBot, win98se, nt4, solaris, tru64 |
| nt4     | 40000 | HiveBot, win98se, win2000, solaris, tru64 |
| solaris | 30000 | HiveBot, win98se, win2000, nt4, tru64 |
| tru64   | 64000 | HiveBot, win98se, win2000, nt4, solaris |

`win95` (`95000`) and `macos753` (`75300`) are `onboarded: false` in the roster,
so they are excluded from every list until their stations are live.

## Adding a station — the whole flow

1. Add **one row** to `roster.json` with the station, UIN, `nick`, `client`, and
   `onboarded: true` (an account whose station is not yet finalized stays
   `false`, so it is kept out of everyone's list until it is live).
2. Ensure its account exists on the gateway (`rn-tool.py user-set` /
   `user-open`, done by the station's bring-up agent).
3. `seed_contacts.py ssi --apply` — populates **every** live account's
   server-side SSI, picking the newcomer up everywhere and giving it the full
   list, in one pass. (Dry-run first with no `--apply`.)
4. Done. **No golden recapture.** Each SSI-aware station syncs the new roster on
   its **next login** — for climm that is its own ~30 s reconnect on wake
   ([`ICQ-STATION-solaris.md`](ICQ-STATION-solaris.md) §reconnect); the
   per-station agents confirm the client-side display.

That is the entire contact-change workflow now: a `roster.json` edit + one
re-run. Contrast the old client-UI path (below), which needed a live station, a
calibrated macro, and a golden recapture per change.

## HiveBot by name — how the name lands

- **SSI clients (primary):** the name is in each buddy item's `0x0131` alias TLV,
  written straight from `roster.json`'s `nick`. `10000` renders as `HiveBot`, and
  every station renders by its name, with nothing fetched at add time.
- **Non-SSI ICQ 2000b (fallback):** the name comes from the account's
  **server-side ICQ directory nickname**, fetched on add-by-UIN.
  `rn-tool.py nick <uin> <name>` sets it (`10000 → HiveBot`, done);
  `seed_contacts.py verify-nick <uin>` proves a client receives it via the exact
  ICQ Meta short-info round-trip (`0x04BA`/`0x0104`).
  `seed_contacts.py nicknames --apply` sets every account's directory nickname.

## The fallback path — ICQ 2000b, drive the client's own Add flow

For a **non-SSI** client (stock ICQ 2000b on win98se/win2000/nt4, until they are
upgraded), SSI does not display, so contacts are added by driving the client's
own *Add-Contact* wizard over the exec channel + framebuffer (`labctl`). This
path is **not** used once a station runs an SSI-aware client.

Why drive the client rather than edit its store: ICQ 2000b's contact list is a
**proprietary, undocumented, per-UIN binary DB** (`C:\Program Files\ICQ\<UIN>\`)
that only materialises after a user registers — there is no safe reference copy
to reverse-engineer against (the sole populated instance is the live golden,
off-limits), so an offline write is unprovable and risks corrupting the DB.
Driving the client makes **it** write its own DB, fetch the directory nickname,
and register the buddies server-side. The primitives are the fleet toolchain
(`labctl type`/`key`/`exec`/`shot`/`assert`); win98se is a keyboard+exec+
framebuffer tile, so the macro is keyboard-first and every step ends in a
framebuffer `assert`.

- **Idempotency** reads the server's `clientSideBuddyList` shadow — the record
  open-oscar-server keeps of what a non-SSI client pushed at sign-on —
  via `rn-tool.py client-buddies <uin>`, skipping a UIN already added.
- `seed_contacts.py seed <station> --apply` is the LIVE pass and is **gated**: it
  refuses until `icq2000b-add.macro.json` is calibrated on the real wizard
  (`calibrated: true`). It runs `labctl reset` from golden, replays the macro per
  missing UIN (each step framebuffer-verified), then recaptures the golden with a
  safe snapshot order (`savevm golden-seeding` → `delvm golden` → `savevm golden`
  → `delvm golden-seeding`). Calibration + the LIVE apply are deferred (need a
  live, non-contended station).
- **Mac AIM** (macos753, when it lands) is an **AIM** client — no ICQ directory
  lookup — so its display name is a client-local **alias**; its buddy list lives
  in `System Folder:Preferences`. Designed, deferred until media.

Note `buddies` vs `client-buddies`: `rn-tool.py buddies <uin>` shows the
**SSI/feedbag** roster (primary, `<uin> <nick>` per line); `client-buddies <uin>`
shows the legacy `clientSideBuddyList` shadow (the fallback idempotency oracle).

## Operating it

```bash
RN=/data/kernel-hive/scripts/retronet/icq/seed_contacts.py

# the roster + each station's live cross-list
ssh lab "python3 $RN roster"

# populate every live account's server-side SSI (dry-run, then apply)
ssh lab "python3 $RN ssi"
ssh lab "python3 $RN ssi --apply"
ssh lab "python3 $RN ssi win2000 --apply"     # or scope to one station

# PROVE the server serves a written feedbag (throwaway acct, real 13,04 -> 13,06)
ssh lab "python3 $RN verify-ssi"

# what an account's server-side roster is (the primary contact store)
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 98980'

# offline checks, no gateway needed
python3 scripts/retronet/icq/seed_contacts.py selftest

# fallback (non-SSI ICQ 2000b): server directory nickname + client-UI drive
ssh lab "python3 $RN nicknames --apply"
ssh lab "python3 $RN verify-nick 10000"
ssh lab "python3 $RN plan win98se"            # client-UI plan (dry-run)
```

`rn-tool.py` deploys into the CT with the rest of the gateway via
`provision-gateway-ct.sh install`.

## Proven vs deferred

**Proven + live** (server-side, no station touched):

- `ssi-seed` writes byte-identical feedbag items; the reconcile preserves an
  existing climm group + item IDs, adds/removes buddies, and is idempotent.
- All 5 live accounts' server-side rosters populated and read back with
  `buddies` — each carries the other four + `HiveBot`, named.
- `verify-ssi`: a directly-written feedbag roster is **served** to a signing-in
  client (real OSCAR `13,04` → `13,06`).
- Bot nickname `10000 → HiveBot` set server-side; `verify-nick` proves a client
  receives it.
- Roster logic + the SSI parser + the live-cross-list rule (`selftest`, offline).

**Deferred** (owned by the per-station agents / awaiting media):

- Live-client confirmation that each SSI-aware station **displays** the synced
  roster on next login (climm; the upgraded ICQ) — the framebuffer proof.
- Calibrating `icq2000b-add.macro.json` and the gated client-UI `seed --apply`,
  for any station still on stock (non-SSI) ICQ 2000b.
- The `mac-oscar` (macos753) seeder — designed, waiting on media.
