# Walk-in brief — three stations for anyone on the web

**Status: PLANNING.** Nothing in this brief is built. It exists so the epic has
one agreed shape before the first branch is cut. Decisions still owned by the
operator are collected in [§9](#9-operator-decisions).

The epic: let **anyone on the internet register an account and play with three
stations** — no invite, no operator in the loop. Today the public gallery is
invite-only by design ([`../PUBLIC-GALLERY.md`](../PUBLIC-GALLERY.md)); this
brief adds a second visitor class beside it without loosening anything the
invited plane already guarantees.

Vocabulary is [`../GLOSSARY.md`](../GLOSSARY.md). A self-registered account is a
**walk-in** (role `walkin`); invited accounts and their plane are the **invited
plane** and stay exactly as documented.

---

## 1. What already exists, and what is actually new

Most of the hard infrastructure is built and proven:

| Already built | Where |
|---|---|
| Public origin, TLS, UDP media relay, three-gate auth (session, passkey, ticket) | `../PUBLIC-GALLERY.md` |
| WebAuthn with discoverable credentials, sessions, roles (`admin`/`viewer`), admin UI | `scripts/serve/auth/` |
| Instant-ready launch (restored-to-checkpoint, paused; first session resumes) | fleet-wide |
| Pause on idle — an unwatched guest costs ~nothing; receiver gating — no viewer, no encode | `../OVERHEAD.md` |
| Safe clone lifecycle (`clone-guard`), atomic claims (`kh-claim`), session namespacing | `clone-guard.md`, `AGENTS.md` |
| Relay headroom: production slots end at 148, the relay window runs to slot 200 — **~50 free public-reachable slots** | `registry/registry-v1.json` `ports.publicRelay*` |

What is genuinely new, in order of risk:

1. **Per-visitor state.** Invited visitors share each station's one console. A
   walk-in must get a **private clone** — wreck it, leave, the next visitor
   gets a pristine one. Clones exist today only as dev rigs; making them a
   production, self-serve, self-reaping resource is the core of this epic.
2. **Self-registration.** An account-creation path with nobody vouching for
   the person. Everything downstream of it must assume the account is hostile.
3. **Containment.** Invited visitors are known people; a walk-in typing into a
   guest is an anonymous stranger driving code on labhost. The blast radius
   must be an ephemeral overlay, never the museum.

## 2. The shape

```
walk-in browser ── same edge, same three gates ──► gateway (role: walkin)
     │  "play Haiku" → POST /walkin/claim
     ▼
 walkin broker: pick an instant-ready pool clone, mint its ticket,
     return its signaling path ── UI connects as on any station
     ▼
 pool clone: station launcher VERBATIM + overrides (own overlay, own
     slot 149-199, own sockets, netdev restrict=on) — resumed on connect
     ▼
 session ends / TTL / idle → clone-guard kill → overlay discarded →
     fresh clone captured back into the warm pool
```

Principles:

- **A walk-in clone is not a registry station.** The registry keeps one name
  per station; clones are ephemeral daemon identities (`walkin-<os>-<n>`)
  spawned from the station's seed + checkpoint. The registry gains only a
  per-station `walkin` block (pool size, enabled) and the reserved slot range.
- **Reuse the station launcher verbatim, parameterized — never fork it.**
  `loadvm` requires the same device set; deriving the clone command line from
  the station's own launcher with overrides (paths, ports, netdev *options*)
  keeps that true by construction.
- **Warm pool, paused.** Pool members launch instant-ready and sit paused —
  zero CPU, RAM only. Claim = resume; UX is instant like every other station.
- **Fail loudly, reap always.** Claims via `kh-claim`; every kill through
  `clone-guard`; a watchdog reaps expired/orphaned clones and refills the pool.

## 3. Which three OSes

Selection rules, in order: (1) **license permits public operation** — the OS
and everything installed in the seed is freely redistributable; (2) **KVM, not
TCG** — walk-in CPU is bounded by cap × per-guest cost, so no interpreter-class
guests; (3) **mouse-first desktop** — anonymous visitors get no manual; (4)
**already a station** — zero bring-up cost.

The fleet already holds the bench. Candidates (all Tier-1 direct QEMU, KVM):

| Station | License | RAM | Why | Why not |
|---|---|---|---|---|
| **`kolibrios`** | GPL | 256 M | Tiny, instant, games in the menu; the fleet's measured latency reference (`../OVERHEAD.md`) | Niche looks |
| **`reactos`** | GPL | 512 M | "It's Windows, but it isn't" — the strongest hook for a stranger | Alpha-grade; crashes are part of the exhibit |
| **`haiku`** | MIT | 2048 M | Gorgeous, modern, absolute pointer, ships a browser and demos | Heaviest RAM of the trio |
| `serenityos` | BSD | — | Charming, mouse-first | Younger exhibit, similar niche to haiku |
| `helenos` | BSD | 512 M | Research-OS curiosity | Thin demo surface for a stranger |
| `freedos` | GPL | 64 M | Near-zero cost | Text console, keyboard-only — hostile to walk-ins |
| `tinycore` / `alpine` | GPL/MIT | — | Cheap | Generic Linux, weak museum story |

**Recommendation: `kolibrios` + `reactos` + `haiku`.** Three different stories
(assembly micro-OS, Windows re-creation, BeOS successor), all KVM, warm-pool
RAM for 3+3+2 clones ≈ 6.5 GB. `templeos` is excluded deliberately: content
and tone are wrong for anonymous strangers. `riscos` is excluded: RPCEmu
interpreter cost plus a poster/licensing story that needs its own work.

Per-seed checklist before an OS goes on walk-in duty: no lab secrets in the
image (exec-channel *public* keys are fine, anything private is not), no
non-redistributable software from `../catalog/software-catalog.md` additions,
scene shows something a stranger can use in 10 seconds.

## 4. Session lifecycle and quotas

Defaults to tune, not measurements:

| Knob | Default |
|---|---|
| Warm pool | kolibrios 3, reactos 3, haiku 2 |
| Active (resumed) sessions, global cap | 6 — beyond it, claims queue with a live position |
| Session TTL | 20 min, +10 min extensions while nobody queues |
| Idle (no input) inside a session | 3 min → session ends early |
| Per-account | 1 concurrent session, 90 min/day |
| Walk-in CPU ceiling | `walkin.slice` CPUQuota ≈ 4 cores + MemoryMax; the museum's 68 stations must not feel it |

Lifecycle: claim → resume → visitor plays → end (leave / TTL / idle / kill
switch) → `clone-guard` kill → discard overlay → respawn instant-ready → pool.
A clone is **never** handed to a second visitor.

## 5. Registration and the walkin role

- **Passkey-first, usernameless, no email.** Reuse the existing WebAuthn
  ceremony; walk-in signup mints an account with role `walkin` and a generated
  handle. No PII collected at all — nothing to leak, nothing GDPR-heavy.
- **Throttled:** per-IP registration rate limit, global walk-in account cap,
  inactive-account expiry. Friction (proof-of-work) is a later lever, added
  only if abuse arrives.
- **Kill switch:** one env flag (`WALKIN_OPEN`) gates signup *and* claims.
  Off = walk-ins refused with a friendly page; invited plane untouched.
- **Role fencing in `gate.py`:** `walkin` sessions reach the walk-in landing
  page, the claim API, and the signaling/media path of *their own clone* —
  nothing else. The full-fleet manifest, `/museum`, `/fleet`, `/admin`,
  `/clientcmd*` (already refused for everyone public) stay invisible. Same
  origin as the gallery; separate origin only if abuse ever forces it.
- `auth-state.json` remains the one account database; walk-in accounts live in
  it with their role. All existing rules apply (**never `rm` it**).

## 6. Security model

Threats, worst first:

| Threat | Containment |
|---|---|
| Guest→host escape (anonymous code driving QEMU) | KVM + stock pve-qemu only (no patched forks on walk-in duty); `-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny`; per-clone unprivileged user; RO seed + throwaway overlay; `walkin.slice` quotas; **no reachable network** — where the device set has a NIC, the slirp backend runs `restrict=on` (device preserved for `loadvm`, zero connectivity) |
| Resource exhaustion | Active-session cap + queue; TTL + idle reaper; slice-level CPUQuota/MemoryMax/TasksMax; input-rate pacing already in the daemon |
| Registration/account abuse | Rate limits, account cap, kill switch, admin purge view |
| Cross-visitor harm | None by construction — private clones, no shared writable surface anywhere |
| Ticket/media abuse | Unchanged ticket gate, per-clone identity; `check-stream-tickets.py` extended to pool identities |
| Bandwidth | ABR + receiver gating already fleet-wide; cap bounds egress |

Two standing rules: **walk-in clones never join retronet**
([`RETRONET-BRIEF.md`](RETRONET-BRIEF.md)) until that combination is re-vetted
as its own decision, and **no walk-in machinery touches the invited plane's
config** — the existing Playwright suite (`tests/e2e-live`) must stay green
untouched throughout.

## 7. What the visitor sees

Landing page: three cards, live pool status ("2 of 3 free"), one-tap passkey
signup, claim → the normal station view. Reset button = discard my clone, give
me a fresh one (visitor-facing **reset**, mechanism: respawn). A short
licenses/credits page (Haiku MIT, ReactOS GPL, KolibriOS GPL) and an abuse
contact. No museum hall, no fleet table in v1.

## 8. Phases

Each phase lands on `main` behind the kill switch; nothing is visitor-reachable
until P4 flips it.

| Phase | Delivers | Exit criterion |
|---|---|---|
| **P0 — decide** | Trio + quotas + §9 answers | Operator sign-off on this brief |
| **P1 — broker on one OS** | Clone pool + claim/reap lifecycle for `kolibrios`, exposed only to **invited** accounts; slots from 149+; claims + clone-guard + watchdog | Invited visitor wrecks a clone; next claim is pristine; kill leaves zero orphans (`labctl who` clean); station fleet untouched |
| **P2 — walkin plane** | `walkin` role, passkey signup, throttles, landing page, role fencing, kill switch | e2e suite (virtual authenticator) covers signup→claim→play→TTL; invited suite still green |
| **P3 — harden** | Sandbox flags, slice quotas, `restrict=on`, seed audit, abuse drills (registration flood, input flood, wedge-and-abandon), 6-way load test via the browser-probe rig | Drills pass; museum latency unchanged under full walk-in load |
| **P4 — soft launch** | `WALKIN_OPEN=1`, monitoring (pool health in `check-stream-tickets.py`, clientlog, `SESSION_REJECTED`), operator eyeball | First stranger session observed end-to-end; kill switch drill |
| **P5 — iterate** | Pool sizing from telemetry; maybe a 4th OS; revisit friction | — |

Rough size: P1 and P2 are the substance (M each); P3 M; P4 S.

## 9. Operator decisions

1. The trio — recommendation `kolibrios` + `reactos` + `haiku`.
2. Quota defaults in §4 — sane to start?
3. Same-origin walk-in surface (recommended) vs a separate origin.
4. Registration friction at launch: none beyond rate limits (recommended)?
5. Account lifecycle: purge walk-ins after N days idle (proposal: 90)?
6. Reserve slots 149–199 for the walk-in pool in `registry-v1.json`?

## 10. Pointers

[`../PUBLIC-GALLERY.md`](../PUBLIC-GALLERY.md) — the plane this extends ·
[`clone-guard.md`](clone-guard.md) — the kill path ·
[`../GUEST-TIERS.md`](../GUEST-TIERS.md), [`../OVERHEAD.md`](../OVERHEAD.md) —
why KVM-only · [`../catalog/os-media-catalog.md`](../catalog/os-media-catalog.md)
— licensing posture · [`RETRONET-BRIEF.md`](RETRONET-BRIEF.md) — the other
epic, and why walk-ins are excluded from it.
