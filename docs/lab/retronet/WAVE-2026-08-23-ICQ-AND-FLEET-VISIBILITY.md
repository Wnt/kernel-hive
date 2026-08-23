# Retronet wave 2026-08-23 — four ICQ onboardings, macOS on the bridge, and
# retronet/ICQ made visible in the fleet table

**Status: RUNNING.** Six parallel streams. This file is the wave's **allocation
ledger and coordination contract** — read it before touching anything shared.
It is deliberately short: each stream's detail lives in its own station doc.

Parents: [`RETRONET-BRIEF.md`](../RETRONET-BRIEF.md),
[`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md). The ICQ recipe to follow is
[`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md) (**ICQ 2001b / SSI** — the
fleet standard; do not re-derive it, and do not onboard anything new on 2000b).

## The streams

| Stream | Owner | What "done" means |
|---|---|---|
| **fleet-data** | schema + emitter + SPA | retronet membership and ICQ persona are first-class registry/roster data, rendered as a fleet-table column, cross-validated by `stations-registry.py` |
| **icq-win95** | `win95` | UIN `95000` signed in on **ICQ 2001b** (retires the 2000b `connect()` blocker recorded in [`ICQ-STATION-win95.md`](ICQ-STATION-win95.md)) |
| **icq-winxp** | `winxp` | UIN `51000` signed in |
| **icq-w2kalpha** | `w2kalpha` | UIN `50010` signed in — **x86 ICQ 2001b under NT/Alpha FX!32**, or a documented alternative |
| **icq-os2warp** | `os2warp` | UIN `23000` signed in on a native OS/2 OSCAR client |
| **rn-macos753** | `macos753` | on `vmbr-rn` at `10.99.0.23`, browsing the corpus; ICQ is **out of scope** for this wave |

## Allocation ledger — claim from here, never invent

Anything below is **already reserved for this wave**. Nothing else on
`vmbr-rn` may take these values. `10.99.0.22` belongs to the concurrent
**rhapsody** stream — leave it alone.

| Station | UIN | retronet IP | MAC (scheme `52:54:00:52:4e:<octet>`) | Note |
|---|---|---|---|---|
| win95 | `95000` | `10.99.0.13` (existing) | `…:0d` (existing) | already bridged; ICQ only |
| winxp | `51000` | `10.99.0.18` (existing) | `…:12` (existing) | already bridged; ICQ only |
| os2warp | `23000` | `10.99.0.19` (existing) | `…:13` (existing) | already bridged; ICQ only |
| w2kalpha | `50010` | `10.99.0.17` (existing) | `…:11` (existing) | already bridged; ICQ only |
| macos753 | `75300` (reserved, not this wave) | **`10.99.0.23` (NEW)** | **`08:00:07:00:00:17` (NEW** — Apple OUI is forced by the guest**)** | NIC add → device-set change → **cold** golden rebuild |

UIN scheme, for the record: the number encodes the OS generation
(`nt4`→`40000`, `winxp` = NT 5.1 →`51000`, `w2kalpha` = NT 5.0 on Alpha →`50010`,
`os2warp` = OS/2 v3 →`23000`). Rows for all five are **already committed** to
[`../../../scripts/retronet/icq/roster.json`](../../../scripts/retronet/icq/roster.json)
with `onboarded: false`.

Passwords go in gitignored `registry/local.env` as
`RETRONET_ICQ_<STATION>_PASS`; the account is created with
`rn-tool.py user-set <uin> <pass>` and opened with `rn-tool.py user-open <uin>`.

## Coordination contract

1. **Own stack, own worktree.** `scripts/dev/wt.sh new <stream>`. Land on `main`
   yourself; never force-push, never touch another stream's files.
2. **Claim before you touch a shared thing** — `kh-claim` for the station, its
   tap, its guard chain and any VMID. `ssh lab 'labctl who'` answers "whose is
   this?". Fail loudly on a taken claim; do not fall back.
3. **Work a clone, not the live station** (`wt.sh new` gives you the sandbox).
   Where a step genuinely has to touch the live golden, **back the golden up
   first** and say so in your report.
4. **Files only one stream may edit:**
   - `registry/stations/<your-station>.json` — yours alone.
   - `scripts/retronet/icq/roster.json` — flip **only your own row's**
     `onboarded` to `true`, on the last commit of your stream. One line each,
     so the merges are clean.
   - `scripts/stations_registry/fleet_table.py`, `spa/src/ui/fleetColumns.tsx`,
     `spa/src/data/fleetTable.ts`, `scripts/stations-registry.py` — **fleet-data
     only**. If you need a registry field that does not exist yet, ask
     fleet-data for it; do not add it yourself.
   - This file — append to §Log, nothing else.
5. **The SSI cross-list is a wave-end step, run ONCE.** Do not run
   `seed_contacts.py ssi --apply` yourself. Flip your roster row, report, and
   the coordinator runs the seeder across the whole fleet when the wave closes —
   otherwise every station's roster is re-seeded five times and the goldens
   disagree about who exists.
6. **`box-deploy.sh --apply` is the coordinator's call while this wave runs.**
   It reverts other streams' in-flight live edits. Push, then say you need it.
7. **Teardown is part of done** — released claims, and the check that proved it.

## Log

Append one line per stream milestone: `YYYY-MM-DDThh:mmZ <stream> <what>`.
- 2026-08-23 fleet-data: `retronet` registry block + ICQ-roster merge landed — 12 members backfilled, `Retronet` column on /fleet, `stations-registry.py` now fails the gate on address/plane/roster/doc drift.
- 2026-08-23T22:50Z icq-winxp: UIN `51000` LIVE on **ICQ 2001b build 3659** (fleet standard, no deviation). Silent self-reconnect at t+17s on the `labctl reset` wake, SSI roster by name, HiveBot greeted. Windows Firewall stays ON — the first-run alert is answered **Keep Blocking** (XP's firewall is inbound-only, so only ICQ's unused P2P listener is blocked). Two findings worth stealing: deliver the installer by **swapping the CD medium** (IE8's download window never paints and winxp has no exec channel), and **idle auto-pause silently DISCARDS QMP input** — send `cont` and the input events back-to-back on one connection, never restart mid-install. `51000:winxp` appended to `RN_BOT_PERSONAS` in `/etc/retronet/bot.env`; roster row flipped. Docs: [`ICQ-STATION-winxp.md`](ICQ-STATION-winxp.md).
