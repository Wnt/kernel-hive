# Walk-in brief — three stations for anyone on the web

**Status: PLANNING, P0 complete.** Nothing in this brief is built. It exists so
the epic has one agreed shape before the first branch is cut. The lineup, the
network plane and the emulator posture are settled ([§3](#3-which-three-oses),
[§6](#6-security-model)); every P0 decision is recorded in
[§9](#9-decisions). P1 is ready to cut.

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
| A second bridge + guarded tap per guest, fail-closed | the retronet stations' `rn-tapnet.sh` |
| Relay headroom: production stations end at slot 151, the relay window runs to slot 200 — **~49 free public-reachable slots** | `registry/registry-v1.json` `ports.publicRelay*` |

What is genuinely new, in order of risk:

1. **Per-visitor state.** Invited visitors share each station's one console. A
   walk-in must get a **private clone** — wreck it, leave, the next visitor
   gets a pristine one. Clones exist today only as dev rigs; making them a
   production, self-serve, self-reaping resource is the core of this epic.
2. **Self-registration.** An account-creation path with nobody vouching for
   the person. Everything downstream of it must assume the account is hostile.
3. **Containment.** Invited visitors are known people; a walk-in typing into a
   guest is an anonymous stranger driving code on labhost. The blast radius
   must be an ephemeral overlay on an isolated network, never the museum.
4. **A second network plane.** Walk-ins get the corpus web without getting the
   fleet ([§6](#6-security-model)) — a new bridge, not a firewall rule on the
   old one.

## 2. The shape

```
walk-in browser ── same edge, same three gates ──► gateway (role: walkin)
     │  "play OS/2 Warp" → POST /walkin/claim
     ▼
 walkin broker: pick an instant-ready pool clone, mint its ticket,
     return its signaling path ── UI connects as on any station
     ▼
 pool clone: station launcher VERBATIM + overrides (own overlay, own
     slot 152-200, own sockets, own tap on vmbr-wi) — resumed on connect
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
  `loadvm` requires the same device set *and the same binary*
  ([`OPERATING-RULES.md`](OPERATING-RULES.md) rule 6); deriving the clone
  command line from the station's own launcher with overrides (paths, ports,
  netdev *options*, tap name) keeps that true by construction.
- **Warm pool, paused.** Pool members launch instant-ready and sit paused —
  zero CPU, RAM only. Claim = resume; UX is instant like every other station.
- **Fail loudly, reap always.** Claims via `kh-claim`; every kill through
  `clone-guard`; a watchdog reaps expired/orphaned clones and refills the pool.

## 3. Which three OSes

**`win311` + `os2warp` + `rhapsody`.** These are exhibits a stranger arrives
*for*: Windows 3.11, OS/2 Warp 4, and Apple's Rhapsody DR2 — the Platinum Finder
on a Mach substrate. A walk-in has no reason to cross the internet for a lineup
chosen on running cost.

| Station | Slot | Emulator | Accel | RAM | Reset | Network today |
|---|---|---|---|---|---|---|
| **`win311`** | 90 | pve-qemu 11.0.2 (patched SeaBIOS INT16h, passed as `-bios`) | TCG | 16 M | `loadvm` | tap `win311rn0` → `vmbr-rn`, DHCP `.27`, ne2k_pci |
| **`os2warp`** | 108 | pve-qemu 11.0.2 | TCG *(will not boot under KVM)* | 256 M | `loadvm` | tap `os2rn0` → `vmbr-rn`, DHCP `.19`, pcnet |
| **`rhapsody`** | 146 | fork `/opt/qemu-rhapsody` (i8259 lenient-cascade) | TCG | 64 M | `loadvm` | tap `rhaprn0` → `vmbr-rn`, `.22`, tulip |

Three things follow from that table:

- **All three are TCG**, so capacity is bounded by host CPU per *resumed*
  session — a paused clone costs nothing either way. The pool is therefore sized
  from a **measured per-guest CPU ceiling**
  ([§4](#4-session-lifecycle-and-quotas)), benched rather than inferred from the
  accelerator.
- **Each clone runs the same binary its golden was captured against**, forks
  included — rhapsody's Mach kernel loses every IDE interrupt without the i8259
  patch, and win311's SeaBIOS fix lives in the vmstate itself.
  [`OPERATING-RULES.md`](OPERATING-RULES.md) rule 6 binds checkpoint + binary +
  device set into one combination, so the binary is not a free choice.
  [§6](#6-security-model) carries the containment instead.
- **All three are already bridged onto `vmbr-rn`** with a tap, a unique MAC and
  a fail-closed guard chain, so each has a working per-station network script to
  model its walk-in sibling on ([§6.1](#61-the-walk-in-network-plane)). None of
  them needs a device added, and none may have one added: `loadvm` matches the
  device set the golden was captured against.

Per-seed checklist before an OS goes on walk-in duty: no lab secrets in the
image (exec-channel *public* keys are fine, anything private is not), no
retronet credentials or `RETRONET_ICQ_*` material, scene shows something a
stranger can use in 10 seconds.

**The `os2warp` seed fails that checklist today** and the decision is open. Its
golden boots with the ICQ client running, so a walk-in's first frame carries
*"ICQ server not accepting your login"* — correct (the walk-in plane withholds
OSCAR by design) but it reads as broken — and the image carries the station's
retronet ICQ identity for a stranger to rummage through. The credential is inert
off the retronet, which a walk-in clone cannot reach, so this is a hygiene and
first-impression problem rather than an exposure. Three ways out: accept it,
suppress the client in a walk-in seed, or recapture a walk-in golden without it
(a second lineage per station, rule 6). `win311` and `rhapsody` need the same
audit before they go on duty.

## 4. Session lifecycle and quotas

Defaults to tune, not measurements. **Bench each guest's resumed cost before
sizing the pool** — three TCG guests is the whole capacity question, and
`MEASUREMENT-METHODOLOGY.md` is the method.

| Knob | Default |
|---|---|
| Warm pool | win311 3, os2warp 2, rhapsody 2 |
| Active (resumed) sessions, global cap | 6 — beyond it, claims queue with a live position |
| Walk-in CPU ceiling | `walkin.slice` CPUQuota sized from the bench (a resumed TCG guest is ~1 host core) + MemoryMax; **the museum's stations must not feel it** |
| Session TTL | 20 min, +10 min extensions while nobody queues |
| Idle (no input) inside a session | 3 min → session ends early |
| Per-account | 1 concurrent session, 90 min/day |

Warm-pool RAM is a rounding error at 16/256/64 MB — CPU is the only real
constraint, and only while a session is resumed.

Lifecycle: claim → resume → visitor plays → end (leave / TTL / idle / kill
switch) → `clone-guard` kill → discard overlay → respawn instant-ready → pool.
A clone is **never** handed to a second visitor.

## 5. Registration and the walkin role

- **Passkey-first, usernameless, no email.** Reuse the existing WebAuthn
  ceremony; walk-in signup mints an account with role `walkin` and an
  autogenerated handle. No PII collected at all — nothing to type, nothing to
  leak, nothing GDPR-heavy.
- **Throttled:** per-IP registration rate limit, global walk-in account cap,
  inactive-account expiry. Friction (proof-of-work) is a later lever, added
  only if abuse arrives.
- `auth-state.json` remains the one account database; walk-in accounts live in
  it with their role. All existing rules apply (**never `rm` it**).

### 5.1 The switch

Walk-in access is **an operator control in `/admin`**, not a deploy-time
setting. It gates signup, sign-in and claims together, and closing it **ends
every walk-in session that is running at that moment**. The invited plane is
untouched either way.

Three positions, not two:

| Position | Who reaches the walk-in plane | Pool |
|---|---|---|
| **Closed** | Nobody | Empty |
| **Invited only** | Invited accounts, on the production URL | Warm |
| **Open** | Anyone with a passkey | Warm |

**Invited only** is not extra machinery — it is the gating the build phases need
anyway ([§8](#8-phases)), exposed as a switch position instead of buried in a
phase. It is what makes opening safe: the finished plane can be driven on the
real production URL, warm pool and all, before any stranger can reach it.

Two layers, and they must not fight:

| Layer | What it is | Who moves it |
|---|---|---|
| `WALKIN_OPEN` (env) | A **hard floor** over all three positions. `0` means closed whatever the switch says — a way to shut walk-ins without a browser | A deploy |
| The `/admin` switch | The runtime control. It can only reach as far as the env floor permits | One click, live |

The toggle is **persisted in `auth-state.json`** through the existing store. A
setting that lived only in memory would silently re-open the plane on the next
service restart, which is the one failure mode a kill switch may not have.

**Dropping to Closed, in order** — inflow first, so nothing re-enters behind
the teardown:

1. Refuse signup, sign-in and `/walkin/claim`.
2. Revoke every outstanding walk-in ticket, so a client cannot re-handshake
   into the clone it was just disconnected from.
3. Close the live sessions with a **distinct reason code** (`WALKIN_CLOSED`,
   beside the existing `SESSION_REJECTED`) — the SPA renders "walk-in access is
   currently closed", not a generic connection error.
4. `clone-guard` kill every walk-in clone, discard the overlays, leave the pool
   empty.

Moving back up refills the warm pool from the goldens. Every transition is
audit-logged with the admin who moved it and when.

**Enablement must cost one click.** Everything a switch position cannot
change — a deploy, a service restart, an edge nftables range, an
`auth-state.json` migration — is finished and verified while the switch sits at
**Closed** or **Invited only** ([§8](#8-phases)). If flipping to Open would need
any of those, the work is not done.

**What `/admin` shows beside the toggle:** the pool ("2 of 3 free" per OS),
the count of walk-in sessions live right now, and the walk-in account list with
a purge action. The off switch is destructive to people who are mid-session, so
the UI confirms and says how many it is about to disconnect.

A **drain** control — refuse new claims, let the sessions in flight finish — is
the softer sibling and worth having for maintenance windows, but it is not the
kill switch and does not replace it.

### 5.2 Handles

Docker's `adjective_surname` shape, shorter, and drawn from the museum's own
subject matter: **`<adj>-<pioneer>`**, hyphenated, both words short — `bold-turing`,
`warm-knuth`, `keen-hopper`, `sly-kay`.

| | |
|---|---|
| Lists | Two curated wordlists committed beside the auth code — adjectives ≤5 chars, pioneer surnames ≤7. Curated, not generated, so no pairing lands badly |
| Space | ~64 × ~96 ≈ 6 k combinations; a taken handle gets a `-2` … `-9` suffix, Docker-style |
| Uniqueness | Allocated under the same lock that writes `auth-state.json` — never check-then-create ([`OPERATING-RULES.md`](OPERATING-RULES.md) rule 7) |
| Lifetime | Stable for the account's life. Display only: identity is the passkey credential, and the handle carries no authority |

### 5.3 What a walk-in can see

**The whole listed fleet's exhibition notes — none of its interactive state.**
A walk-in browses the museum the way a visitor reads placards: every enabled
exhibit, its prose, its hero shot, its era. Three of them are playable; the rest
are there to be read about.

| Served to `walkin` | Why it is safe |
|---|---|
| `/poster-docs.json` — the curatorial prose, rendered from `registry/posters/*.md` | A static document with no live field in it |
| `/posters/<id>/desktop.webp` heroes | Captured stills already published to the webroot |
| The gallery manifest's **exhibition fields**: `displayName`, `year`, `era`, `eraLabel`, `lineage`, `arch`, `notes`, `blurb`, `eraSoftware`, `iconicApps`, `periodBrowser`, `accent` | Already marked `PUBLIC DATA ONLY` at the top of the rendered manifest |

| Withheld | Why |
|---|---|
| `signalEndpoint` / `transport` for every station **except the visitor's own clone** | These are the interactive surface. A walk-in gets exactly one of them, minted by the claim |
| Station liveness — running / paused / stopped / wedged | Not in the manifest today, and it stays out of the walk-in plane. Pool availability for the three playable OSes is the only status a walk-in sees |
| `/fleet`, `/admin`, `/clientcmd*` (already refused for everyone public) | Operator surfaces |
| `/museum` (3D hall) | Its tiles are live surfaces, not stills. Out of scope for v1 |
| Any station whose registry carries `listing.state=hidden` | Dark-launched exhibits are not public yet, walk-ins included |

**Projection is an allowlist, in `gate.py`.** The walk-in manifest is built by
naming the fields to keep, never by deleting the fields to hide — so a field
added to the registry later is invisible to walk-ins until someone deliberately
adds it. Same origin as the gallery; separate origin only if abuse ever forces
it.

## 6. Security model

### 6.1 The walk-in network plane

Walk-ins get the corpus web and **nothing else on it** — not the fleet, not each
other. That is a topology, not a rule set:

| Piece | Shape |
|---|---|
| Bridge | **`vmbr-wi`, `10.98.0.0/24`, `bridge-ports none`** on labhost — sibling of `/etc/network/interfaces.d/vmbr-rn` |
| Gateway | CT 951 gains **`net1` on `vmbr-wi` at `10.98.0.2/24`** (`pct set 951 -net1 …`); it is single-homed on `vmbr-rn` today |
| No transit | `net.ipv4.ip_forward=0` inside CT 951 **plus** an explicit nft `FORWARD` drop between `eth0`/`eth1`. Without this a walk-in reaches every station on `10.99.0.0/24` through the gateway — exactly what the plane exists to prevent |
| No clone↔clone | `bridge link set dev <tap> isolated on` on **every** walk-in tap; the gateway port is the only un-isolated port on the bridge. Kernel-enforced private VLAN, no rules to get wrong |
| Addressing | A second DHCP scope on `eth1` for `10.98.0.0/24`, **short leases** — clones are ephemeral, so the retronet convention of reserved static IPs does not apply |
| Services on `eth1` | **Web only** — proxy `3128`, DNS, the `:80` seamless origin, `search.retronet`. **No OSCAR (`5190`)**: the OSCAR server *is* the station-to-station relay, so opening that door would put anonymous walk-ins in the fleet's ICQ roster beside HiveBot and the five live personas |
| Per-station wiring | All three carry an `rn-tapnet.sh` that hard-asserts `vmbr-rn`, its reserved IP and a fail-closed guard chain (`OS2RN-IN`, `WIN311RN-IN`). Each needs a **walk-in sibling script** on `vmbr-wi`, not a flag on the live one — per [`OPERATING-RULES.md`](OPERATING-RULES.md) rule 3, fix it in your own stack |

Topology, not policy, is what keeps **walk-in clones off retronet**
([`RETRONET-BRIEF.md`](RETRONET-BRIEF.md)): `vmbr-wi` is a different bridge, and
the gateway does not forward between them.

### 6.2 Threats

| Threat | Containment |
|---|---|
| Guest→host escape (anonymous code driving an emulator) | `-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny` wherever the binary is QEMU (including the rhapsody fork); per-clone unprivileged user; RO seed + throwaway overlay; `walkin.slice` quotas; isolated network plane (§6.1) |
| A forked emulator on public duty | The fork is required by rule 6 and cannot be swapped out. Containment is the row above — the sandbox flags, unprivileged user and slice apply to whatever binary the golden was baked against, and the fork's delta (i8259 cascade, SeaBIOS INT16h) is small, local and reviewed |
| Resource exhaustion | Active-session cap + queue; TTL + idle reaper; slice-level CPUQuota/MemoryMax/TasksMax; input-rate pacing already in the daemon |
| Registration/account abuse | Rate limits, account cap, the `/admin` off switch (§5.1), admin purge view |
| Cross-visitor harm | None by construction — private clones, isolated bridge ports, no shared writable surface anywhere |
| Ticket/media abuse | Unchanged ticket gate, per-clone identity; `check-stream-tickets.py` extended to pool identities |
| Bandwidth | ABR + receiver gating already fleet-wide; cap bounds egress |

Standing rule: **no walk-in machinery touches the invited plane's config** — the
existing Playwright suite (`tests/e2e-live`) must stay green untouched throughout.

## 7. What the visitor sees

Landing page: three cards — Windows 3.11, OS/2 Warp 4, Rhapsody DR2 — with live
pool status ("2 of 3 free"), one-tap passkey signup, claim → the normal station
view. Reset button = discard my clone, give me a fresh one (visitor-facing
**reset**, mechanism: respawn).

Below the three, **the rest of the museum to read about**: the listed fleet as
hero shots and exhibition notes ([§5.3](#53-what-a-walk-in-can-see)), each
plainly marked as not playable rather than as a broken button. The walk-in
arrives for Windows 3.11 and leaves knowing the lab has sixty other machines in
it. A short about/credits page and an abuse contact. No museum hall, no fleet
table in v1.

## 8. Phases

Each phase lands on `main` **and deploys to production**, with the switch
([§5.1](#51-the-switch)) held at Closed or Invited only. Nothing a stranger can
reach changes until the switch moves to Open, and moving it must be the only
action left.

| Phase | Delivers | Exit criterion |
|---|---|---|
| **P1 — broker on `os2warp`** | Clone pool + claim/reap lifecycle, invited-only; slots from 152; claims + `clone-guard` + watchdog | Invited visitor wrecks a clone; next claim is pristine; kill leaves zero orphans (`labctl who` clean); station fleet untouched |
| **P2 — walkin plane** | `walkin` role, passkey signup + handle generator, throttles, landing page, allowlist manifest projection + fleet notes browsing, role fencing, the `/admin` switch (§5.1) | e2e suite (virtual authenticator) covers signup→claim→play→TTL; a walk-in session sees every listed exhibit's notes and **no** `signalEndpoint` but its own; **switching off mid-session disconnects it with `WALKIN_CLOSED` and leaves zero clones**; invited suite still green |
| **P3 — network + the other two** | `vmbr-wi` + CT 951 `net1` + isolation (§6.1); `os2warp` and `rhapsody` onto the pool with walk-in tap siblings; sandbox flags, slice quotas, seed audit; abuse drills (registration flood, input flood, wedge-and-abandon); CPU bench and pool sizing | Drills pass; a clone reaches the corpus and **provably** reaches neither `10.99.0.0/24` nor another clone; museum latency unchanged under full walk-in load |
| **P4 — production pre-flight** | The whole plane deployed and restarted on the production URL at **Invited only**; edge relay range verified live; `auth-state.json` migrated in place; service worker not serving a stale shell; `check-stream-tickets.py` knows the pool identities; monitoring (pool health, clientlog, `SESSION_REJECTED`) | Operator drives the finished plane on the production URL, warm pool and all; **the only remaining action is the switch**; off-switch drill against a real session |
| **P5 — open** | The switch moves to Open | First stranger session observed end-to-end |
| **P6 — iterate** | Pool sizing from telemetry; a fourth station; revisit friction | — |

Rough size: P1 and P2 are the substance (M each); P3 M–L (it carries the network
plane and two more stations); P4 M — it is small in code and large in things
that must be true before the switch can move.

The phases name deliverables, not an order of work. P1–P3 are built as parallel
lanes with disjoint file territories over a frozen contract; P4 is the
coordinator's integration and deploy.

## 9. Decisions

The decisions this plan rests on, in one place:

1. Lineup: `win311` + `os2warp` + `rhapsody` (§3); `os2warp` is the broker
   pathfinder.
2. Emulators: the same binary the golden was captured against, forks included
   (§3, §6.2).
3. Capacity: a measured per-guest CPU ceiling (§4).
4. Network: dedicated `vmbr-wi` plane, gateway-only reachability, isolated
   bridge ports, **web services only — no OSCAR** (§6.1).
5. Same-origin walk-in surface; separate origin only if abuse forces it (§5).
6. Slots **152–200** reserved for the pool in `registry-v1.json` — production
   stations now run to 151, and the relay DNAT window ends at 54200.
7. Registration friction at launch: rate limits only. Walk-in accounts purged
   after 90 days idle.
8. Visibility: the whole listed fleet's exhibition notes, no interactive state;
   autogenerated `<adj>-<pioneer>` handles (§5.2, §5.3).
9. Access is an `/admin` switch (Closed / Invited only / Open) over an env
   floor; closing it disconnects live sessions immediately (§5.1).
10. The wave ends **deployed on the production URL at Invited only** — enabling
    walk-ins is one click, never a deploy (§5.1, §8).

## 10. Pointers

[`../PUBLIC-GALLERY.md`](../PUBLIC-GALLERY.md) — the plane this extends ·
[`clone-guard.md`](clone-guard.md) — the kill path ·
[`retronet/GATEWAY.md`](retronet/GATEWAY.md) — CT 951, the bridge pattern
`vmbr-wi` copies · [`../OVERHEAD.md`](../OVERHEAD.md),
[`MEASUREMENT-METHODOLOGY.md`](MEASUREMENT-METHODOLOGY.md) — the CPU bench
P3 owes · [`RETRONET-BRIEF.md`](RETRONET-BRIEF.md) — the other epic,
and why walk-ins are fenced off from it.
