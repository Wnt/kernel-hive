# The retronet ICQ contact seeder — as built

**Status: BUILT + PROVEN (server-side), live-application DEFERRED.** The reusable
tool that gives every ICQ station every *other* station + the bot in its contact
list, with the bot showing as **HiveBot**, not `10000`. Roster-driven and
idempotent: adding a station is one row in `roster.json`, then re-run. Parent:
[`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md); server is
[`GATEWAY.md`](GATEWAY.md); the pathfinder station is [`ICQ-STATION.md`](ICQ-STATION.md).

Files, all under `scripts/retronet/icq/`:

| File | What |
|---|---|
| `roster.json` | the single source — bot + every station's UIN, display nickname, and client kind |
| `seed_contacts.py` | the tool: roster logic, nicknames, the client-faithful proof, idempotency, plans, the gated live orchestration, an offline `selftest` |
| `icq2000b-add.macro.json` | the ICQ 2000b Add-by-UIN input macro (labctl steps), **calibrated live** |

The tool runs **on labhost** (invoke via `ssh lab`): it needs `pct exec 951`
(the gateway's management API is CT-loopback-only), `labctl`, and a socket to the
gateway. It extends the gateway's own `rn-tool.py` with `nick` / `nick-get` /
`buddies`.

## HiveBot by name — how the name lands, and the proof

ICQ 2000b keeps its contact list **client-local** (not server SSI/feedbag —
`buddyListMode.useFeedbag = 0`). But the *name* it displays for a UIN is not
local trivia: when you add a contact by number, the client runs an **ICQ Meta
directory lookup** and caches whatever nickname the server returns. So the bar
"never a bare `10000`" is met by setting the account's **server-side ICQ
directory nickname** — and every future add renders it by name for free.

- **Set it:** `rn-tool.py nick <uin> <name>` — a read-modify-write of
  `basic_info.nickname` via the management API's `PUT /user/<uin>/icq`.
  Idempotent. Done for the bot: **`10000` → `HiveBot`**.
- **Proof a client receives it (not just that the DB row is set):**
  `seed_contacts.py verify-nick 10000` signs in as a throwaway account and issues
  the **exact** Meta short-info request (SNAC `0x15/0x02`, subcmd `0x04BA`) that
  ICQ 2000b sends on add-by-UIN, and reads the nickname back from the response
  (`0x15/0x03`, subcmd `0x0104`). It prints:

  ```
  UIN 10000: a client receives nickname 'HiveBot'
  ```

  The throwaway account is created, opened, queried and **deleted** in the one
  call — the gateway is left with exactly its real accounts.

**The client-local alias, and the one contact that needs it.** Setting the
server nickname fixes every *future* add. A contact added *before* its nickname
was set keeps the bare number the client cached — today that is exactly one
contact: the bot on the **existing** win98se golden, added as `10000`. The fix
is a client-local rename, not a server change: at win98se's next golden
recapture the seed pass renames it in-client (ICQ 2000b contact → *Rename* →
`HiveBot`) or re-adds it. Every station onboarded from here shows `HiveBot`
natively because the seeder sets nicknames **before** it adds.

## The method for ICQ 2000b — drive the client, do not edit its store

**Chosen: (b) drive ICQ 2000b's own Add-Contact flow over the exec channel +
framebuffer (`labctl`).** Rejected: (a) offline-mount the disk and edit the
contact store.

Why, from evidence gathered read-only against a golden *backup*
(`golden-backup-netswap-…`, extracted per-snapshot with `qemu-img convert -l
snapshot.name=…`, read with `mtools` on an nbd device — no kernel mount):

- ICQ 2000b's store is a **proprietary, undocumented, per-UIN binary DB** at
  `C:\Program Files\ICQ\<UIN>\`. That folder **only materialises after a user
  registers** — in the `icqinstalled` snapshot the client is fully installed but
  the `UIN\` folder is **empty**.
- There is **no safe reference copy** to reverse-engineer against: the only
  populated instance is the **live** golden, which is off-limits. You cannot
  write a format you cannot test, and a wrong byte corrupts the client's list.
- The build is version-specific (this "2000b" ships DLLs dated **2001-04-04**);
  an offline writer would be pinned to one build.
- Driving the client makes **it** do all three hard things correctly: write its
  own DB, **fetch the directory nickname** (so the contact shows `HiveBot` /
  the station name, not a number), and **register the buddies server-side**
  (`BuddyAddBuddies` → `clientSideBuddyList`) so presence flows. An offline edit
  would still have to do that last part at login anyway — so it buys nothing and
  risks everything.
- The primitives are the proven fleet toolchain: `labctl type` / `key` / `exec`
  / `shot` / `assert`. win98se is a `warpd_e` QEMU tile, so input is
  **keyboard + exec + framebuffer** (there is no scripted pointer — `labctl
  mctl` is ctl-tile-only); the macro is keyboard-first and every step ends in a
  framebuffer `assert`, which is the lab's only proof a step landed.

## Idempotency — the server's shadow of the client's list

open-oscar-server records every non-SSI client's buddy list in
`clientSideBuddyList` when the client pushes it at sign-on. It does **not** drive
what the client *displays* (that is the local store) — but it is a reliable
server-side record of which UINs a station has **already added**. The seeder
reads it (`rn-tool.py buddies <uin>`) and skips a contact that is already there,
so a re-run only adds what is new. Proven:

```
$ seed_contacts.py status win98se
win98se (UIN 98980, icq2000b)
  HiveBot   UIN 10000  present                                   ← already on the list
  win2000   UIN 20000  missing (contact account not created yet) ← blocked until onboarded
  …
```

## The three phases, per station

`seed_contacts.py seed <station>` is dry-run (prints the plan); `--apply` is the
LIVE pass and is **gated** — it refuses until the macro is calibrated.

1. **Stop cleanly from golden.** `labctl reset <station>` restores the known-good
   golden; the live pass backs the golden up first (per
   [`ICQ-STATION.md`](ICQ-STATION.md)).
2. **Seed the missing contacts.** Ensure each contact's server nickname + open
   flag (`rn-tool.py nick` / `user-open`), then replay `icq2000b-add.macro.json`
   per missing UIN, each step framebuffer-verified.
3. **Recapture the golden** with the fuller list baked in. `recapture_golden()`
   uses a **safe snapshot order** that never deletes the live golden before a
   copy of the new state exists: `savevm golden-seeding` → `delvm golden` →
   `savevm golden` → `delvm golden-seeding`.

Adding a station later = one `roster.json` row + `seed <that station>`, and a
re-run of the already-onboarded stations to pick the newcomer up (its account
now exists, so it stops being "blocked").

### Calibration (the one thing that must happen on the live client)

`icq2000b-add.macro.json` ships `calibrated: false` and the tool **refuses
`--apply`** until it is true. Calibration is a one-time pass on a live ICQ 2000b
station: open the real *Find/Add Users* wizard, confirm each keystroke and each
`assert` text against the framebuffer (`labctl shot` / `assert --text`), correct
the `calibrate: true` steps, then set `calibrated: true`. It is deferred here
because it needs a live station and win98se is owned by the swap agent.

## Unix and Mac clients — designed hooks (deferred until media lands)

The roster's `client` field dispatches the seeder. Only `icq2000b` is
implemented; the others are designed and print their plan:

- **`unix-oscar`** (solaris, tru64 — **climm 0.6.4**, the ex-mICQ OSCAR client,
  sourced and built from source): its contact list is plain text under
  `~/.climm/` in the guest home. Seed it **offline** over the guest home (via
  `chroot-guard run-private`, never a raw host mount) or by the client's own add.
  climm is an **ICQ** client, so it fetches the nickname from the **same** server
  directory this tool sets — `verify-nick` proves it — and `HiveBot` / the station
  names show with **no local alias** needed. (Exact `~/.climm/` layout is
  confirmed at build time; the seam is the same either way.)
- **`mac-oscar`** (macos753 — **Mac AIM 2.01.617**, 68K): its buddy list lives in
  the app Preferences (`System Folder:Preferences`). An **AIM** client does
  **not** run the ICQ directory lookup, so here the display name is a
  **client-local alias** (the AIM buddy alias) the seeder writes — the plan's
  "where the client needs a local alias, the seeder writes it" clause. Seed the
  pref offline (HFS mount) or via the client's Add flow.

Both are why the `client` field is a dispatch key, not just a label: the ICQ
legs (ICQ 2000b, climm) get their name from the server directory; the AIM leg
gets a local alias. `verify-nick` proves the server half for every ICQ leg today.

## Operating it

```bash
# the roster + every station's contact set
ssh lab 'python3 /data/kernel-hive/scripts/retronet/icq/seed_contacts.py roster'

# PROVE a client receives an account's nickname (ephemeral acct + real ICQ Meta query)
ssh lab 'python3 …/seed_contacts.py verify-nick 10000'

# set every existing account's server nickname (10000→HiveBot, 98980→win98se, …)
ssh lab 'python3 …/seed_contacts.py nicknames --apply'

# what a station already has / what a seed would do (dry-run)
ssh lab 'python3 …/seed_contacts.py status  <station>'
ssh lab 'python3 …/seed_contacts.py plan    <station>'

# LIVE seed (gated on a calibrated macro; back the golden up first)
ssh lab 'python3 …/seed_contacts.py seed <station> --apply'

# offline checks, no gateway needed
python3 scripts/retronet/icq/seed_contacts.py selftest

# gateway-side, in the CT
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py nick 10000 HiveBot'
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 98980'
```

## Proven vs deferred

**Proven now** (against the live gateway, no station touched):

- Bot nickname `10000 → HiveBot` set server-side, and a **client receives it**
  (ICQ Meta `0x04BA/0x0104` round-trip returns `HiveBot`).
- `rn-tool.py nick` / `nick-get` / `buddies` (idempotent; `buddies 98980` → `10000`).
- Roster logic — every station carries the bot + the six others, excludes itself.
- Idempotency oracle — `status`/`plan` read `clientSideBuddyList` and correctly
  skip present contacts and block not-yet-created ones.
- The Meta encode/parse and macro rendering (`selftest`, offline).

**Deferred to live application** (needs a live, non-contended station):

- Calibrating `icq2000b-add.macro.json` against the real wizard, and the LIVE
  `seed --apply` (macro replay + golden recapture).
- The one-time in-client rename of win98se's existing bare-`10000` bot contact.
- The `unix-oscar` / `mac-oscar` seeders (implemented as designs; wait on media).
