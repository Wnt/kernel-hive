# Retronet ICQ fleet onboarding — coordinator contract

**Status: BUILDING.** Bring six more stations onto the ICQ gateway, cross-list
them all in each other's contact lists, and make the bot appear by **name**, not
a number. Parent: [`RETRONET-BRIEF.md`](../RETRONET-BRIEF.md) §5; the pathfinder
recipe is [`ICQ-STATION.md`](ICQ-STATION.md) (win98se, being finalized on the
bridge); server is [`GATEWAY.md`](GATEWAY.md); bot is [`BOT.md`](BOT.md).

## Targets + difficulty tiers

The gating fact (proven on win98se): **OSCAR can't traverse slirp** — every ICQ
station needs the win98se-style **bridged NIC** (tap on `vmbr-rn`, real IP,
containment-fenced), then client install, persona sign-in, clean golden. Per
station = ONE opus agent doing network-then-install-then-golden (splitting them
would collide on the same live golden).

| Station | Client | Tier / why | UIN |
|---|---|---|---|
| **win2000** | ICQ 2000b (already sourced) | **A** — clean copy of win98se; rtl8139 netdev | `20000` |
| **nt4** | ICQ 2000b | **A** — clean copy; pcnet netdev; peak-1996 era | `40000` |
| **win95** | ICQ 2000b | **B** — its NIC also carries the **warpnet** pointer agent; the bridge swap must carry that across (do after A proves the plain path) | `95000` |
| **solaris** | micq/centericq/licq (OSCAR) — media TBD | **C** — needs a Unix OSCAR client sourced/built; e1000 netdev | `30000` |
| **tru64** | Unix OSCAR client (Alpha binary) — media TBD | **C** — already on a real veth today; Alpha client sourcing is the friction | `64000` |
| **macos753** | Mac ICQ/AIM (OSCAR) — media TBD | **D** — has **no NIC** (device-set change → cold rebuild) + MacTCP; hardest | `75300` |

(Existing: bot `10000` = **HiveBot**, win98se persona `98980`.) Each station's
install agent creates its UIN server-side (`rn-tool.py user-set <uin> <pass>`,
SQLite-safe) and stores the password in `registry/local.env` as
`RETRONET_ICQ_<STATION>_PASS`. Every account is opened for unattended contacts
(`rn-tool.py user-open <uin>`) — the [authRequired gotcha](BOT.md).

## The cross-list roster + the named bot

**Every ICQ station carries every *other* ICQ station + HiveBot in its contact
list.** As the fleet grows the roster is the single source; adding a station is
one row, then re-run the seeder.

- **HiveBot by name.** ICQ 2000b keeps its contact list **client-local** (not
  server SSI), so the name must land where the client shows it: set the bot
  account's server-side nickname to `HiveBot`, and where the client needs a
  local alias, the seeder writes it. Contacts must never read as a bare `10000`.

## Contact-seeding automation (the reusable tool)

The operator's flow, generalized into `scripts/retronet/web/`… (or
`scripts/retronet/icq/`) — **roster-driven, idempotent**:

1. Station offline: clean-shutdown from golden (or the powered-off seed).
2. Seed the client's contact list — **method chosen per client for
   reliability**: offline-mount + edit the contact store (via `chroot-guard
   run-private` or the `mount-guard-ok` escape — never a raw host mount), **or**
   drive the client's own Add-Contact flow over the exec channel + framebuffer.
   (ICQ 2000b's local store is a proprietary DB; the tool agent picks whichever
   is reliable and documents it.)
3. Recapture the golden with the fuller list baked in.

Adding contacts later = edit the roster + re-run. **This tool does NOT mutate a
live station during its build** — win98se is owned by the swap agent, the others
aren't onboarded yet — it is built + proven on a safe copy / dry-run, then
applied per station as they come online.

## Waves (sequenced, not blind-parallel)

- **Now (independent, no live-station risk):**
  - **Media (sonnet ×2):** Unix OSCAR client (solaris + tru64/Alpha) and Mac
    OSCAR client (macos753). Windows reuses win98se's ICQ 2000b.
  - **Contact tool (opus ×1):** design + build the roster-driven seeder + set
    HiveBot's server nickname; prove mechanics on a copy.
- **On win98se recipe proven (imminent — it lands `ICQ-STATION.md`):** fan the
  **Tier-A** bring-ups **win2000 + nt4** (opus, one per station), then **win95**
  (Tier B) once the plain path is proven.
- **On Unix media landed:** **solaris**, then **tru64** (opus).
- **After a NIC-add design:** **macos753** (opus) — flagged as materially
  different (device-set change + cold rebuild).
- **Finally:** run the contact seeder across all onboarded stations, recapture
  goldens with the full roster + HiveBot.

## Guardrails (every stream)

- Own worktree (`wt.sh new`); land on `main` yourself. Per-station agents work a
  **live** station directly (operator-authorised, no VM clones) — **back up its
  golden first**; process control via `ssh lab`/`labrun`; kills via clone-guard.
- Follow the win98se recipe (`ICQ-STATION.md`) for the bridge swap; do not
  re-derive it. Prove UDP+ICMP + containment (guest reaches `10.99.0.2`, NOT the
  LAN/gallery/internet) exactly as win98se does.
- No raw host mounts except through `chroot-guard run-private` or with the
  `mount-guard-ok` escape set.
- Green-before-done for languages touched, or report **BLOCKED**. Report
  concisely; detail in your station/tool doc. Don't edit `docs/README.md`.
