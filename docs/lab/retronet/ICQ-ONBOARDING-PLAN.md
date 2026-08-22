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
| **solaris** | climm 0.6.4 (OSCAR, formerly micq) — **sourced**, build from source | **C** — gcc 3.4.3 confirmed on-box (`/usr/sfw/bin/gcc`); still needs the bridge swap (e1000 → tap on vmbr-rn) | `30000` |
| **tru64** | **Gaim 0.59.9** (OSCAR, GTK+1.2 desktop client) — LIVE since 2026-08-22; onboarded on climm 0.6.4, which stays installed as the rollback | **C** — media sourcing is **not** a blocker (native Compaq C already built Lynx on this guest); already on a real veth, needs rehoming onto vmbr-rn | `64000` |
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

- **HiveBot by name — DONE (server side).** ICQ 2000b keeps its contact list
  **client-local** (not server SSI), but the *name* it shows a UIN comes from the
  server's ICQ directory, fetched on add-by-UIN. So `10000`'s directory nickname
  is set to `HiveBot` (`rn-tool.py nick`), and a client-faithful ICQ Meta query
  proves a client receives it. A contact added *before* its nickname was set (the
  bot on the existing win98se golden) needs a one-time in-client rename; every
  station onboarded from here shows the name natively. See
  [`CONTACT-SEEDER.md`](CONTACT-SEEDER.md).

## Contact-seeding automation — BUILT: `scripts/retronet/icq/`

The reusable tool is landed and its server-side mechanics proven; full write-up
is [`CONTACT-SEEDER.md`](CONTACT-SEEDER.md). `roster.json` is the single source
(`seed_contacts.py roster`), the flow is **roster-driven, idempotent**:

1. Station offline: `labctl reset` from golden (live pass backs the golden up first).
2. Seed the client's contact list. **Method chosen for ICQ 2000b: drive the
   client's own Add-Contact flow** over the exec channel + framebuffer — its
   local store is a proprietary per-UIN binary DB with no safe reference to edit,
   and the client itself fetches the nickname + registers the buddies. The
   `icq2000b` input macro is calibrated on the live client (the tool refuses
   `--apply` until it is). Unix (**climm** dotfiles — an ICQ client, name from the
   server directory) and Mac (**Mac AIM 2.01.617** prefs — an AIM client, so a
   client-local alias) seeders are designed, deferred until those stations onboard.
3. Recapture the golden with the fuller list baked in (safe savevm order).

Idempotency reads the server's `clientSideBuddyList` shadow (skip contacts
already added). Adding a station later = one `roster.json` row + re-run. **This
tool does NOT mutate a live station during its build** — win98se is owned by the
swap agent, the others aren't onboarded yet — it is built + proven on the live
gateway / a golden backup / dry-run, then applied per station as they come online.

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
- **Addressing is DHCP, not per-guest static** (as of the win98se DHCP conversion).
  Set the guest to obtain IP *and* DNS automatically + no proxy, and add ONE
  `mac=ip` line to `registry/local.env` `RETRONET_DHCP_RESERVATIONS` +
  `install-dhcp.sh --apply` on the gateway. That alone gives the station the
  **seamless web** (type a URL, it renders — no proxy) plus a stable IP for
  exec-over-bridge, and keeps containment (DHCP hands out **no default gateway**).
  Recipe: [`ICQ-STATION.md`](ICQ-STATION.md) §Seamless web. (win2000/nt4/solaris
  finish on static; the coordinator retrofits them to DHCP + unique MACs later.)
- **Unique MAC per station (required).** Every QEMU guest defaults to
  `52:54:00:12:34:56`; two on `vmbr-rn` collide at L2 — the bridge FDB flaps, so
  exec/ICQ break whenever both are active — and it defeats per-MAC DHCP. Assign
  `52:54:00:52:4e:<last-IP-octet>` (win98se `.10`→…0a, win2000 `.11`→…0b, nt4
  `.12`→…0c, win95 `.13`→…0d, solaris `.14`→…0e, tru64 `.15`→…0f; macos753's OUI
  is forced to Apple, so `08:00:07:00:00:10`). The MAC lives in the golden
  vmstate — `loadvm` restores it regardless of a launcher `mac=` — so bake it via
  a **cold boot**, then recapture. Real MAC → `local.env`, placeholder in the
  registry. **Retrofit owed:** win98se / win2000 / solaris were baked on the
  default MAC; they need a cold re-bake (a dedicated fleet MAC pass).
- No raw host mounts except through `chroot-guard run-private` or with the
  `mount-guard-ok` escape set.
- Green-before-done for languages touched, or report **BLOCKED**. Report
  concisely; detail in your station/tool doc. Don't edit `docs/README.md`.
