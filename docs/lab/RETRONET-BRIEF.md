# Retronet brief — a 90s internet inside the lab

**Status: PLANNING.** Nothing in this brief is built. Decisions still owned by
the operator are in [§10](#10-operator-decisions).

The epic: give the 90s stations a **living internet of their era** — popular
period web pages served in a form Netscape 2–4 and IE 3–5 can actually render,
plus **ICQ, AIM, MSN Messenger and IRC that work station-to-station**, with a
few simple chatbots as resident conversation partners. A joined station wakes
**already signed in**: within ~30 seconds of a visitor opening it, a bot says
hello and the client's desktop notification leads them to the era's instant
messaging. All of it lab-local: **stations reach the gateway's local services
and nothing else — there is no path to the real internet, the proxy included.**

Vocabulary is [`../GLOSSARY.md`](../GLOSSARY.md). The whole assembly — gateway,
services, corpus, addressing — is the **retronet**.

---

## 1. Principles

- **Offline by construction.** The retronet has no WAN leg anywhere: the
  gateway has no route to the internet, and the proxy has no upstream — it
  answers from the local corpus or not at all. Content is acquired
  out-of-band (on CT950, by agents) and synced in. A guest that escapes the
  retronet reaches nothing, because there is nothing to reach.
- **The retronet greets you.** Every joined station carries a ready-made
  persona whose messenger is installed, signed in and **connected when the
  scene is captured**. A visitor configures nothing and discovers the
  messaging era because it says hello first.
- **The framebuffer is the only proof.** "The server works" is not done; done
  is Netscape rendering the page and two stations exchanging an ICQ message,
  shown in shots from both ends.
- **Additive, never regressive.** Joining the retronet must not risk a working
  station. Device sets are sacred (`loadvm` requires them unchanged), so the
  plan prefers attachment paths that touch **netdev options only**, and every
  launcher change is proven on a clone before the station adopts it.
- **Era protocols end-to-end.** Real HTTP/1.0, real OSCAR, real IRC — the
  authenticity *is* the exhibit. Modernity lives only behind the gateway.
- **Private-plane only.** The retronet serves the invited museum. Walk-in
  clones ([`WALKIN-BRIEF.md`](WALKIN-BRIEF.md)) are excluded until that
  combination is re-vetted (anonymous strangers + mirrored copyrighted pages +
  open chat is three new problems, not zero).

## 2. What the fleet already has

Read before designing: 28 station JSONs already carry a QEMU `netdev` (mostly
slirp user-mode backing the ssh/exec channel), and 7 declare a `network`
block. The precedents worth copying and the trap worth fearing:

| Station | Today | Meaning for retronet |
|---|---|---|
| `tru64` | `internet` — dec21143 via pcap on a host-only veth, outbound NAT | The veth pattern to copy, and **the one place a station reaches the real internet today — off-vision now**: joining replaces the NAT with routes to the gateway only. Netscape 4.76 installed; day-one client. |
| `w2kalpha`, `openvms` | `host-only` veths | Same lane, no NAT — join by routing to the gateway |
| `hpuxvue` | `nic-only` — tulip on slirp, no IP configured | Join = in-guest IP config + scene recapture. No device change |
| `win95` | pcnet + slirp, `hostfwd` **carries the warpnet pointer agent** | **THE TRAP: that netdev is load-bearing input infrastructure.** Only ever *add options* to `n0`; never replace or renumber it |
| `win98se`, `win2000`, `winxp`, `nt4`, `beos`, `haiku`, `freedos`, … | netdev present | Options-only join candidates |
| `win311`, `msdoswin1`, `aux`, `sunos414`, `newsos`, `macos753`, … | no NIC in the device set | Joining needs a device-set change → **cold recapture** — late waves only |

Era client software is already curated: `../catalog/software-catalog.md` plans
Netscape 2.02 + Trumpet Winsock (win311), Communicator 4.x + IE5 (win9x), mIRC,
Arachne (freedos). This epic adds the chat clients (ICQ 99/2000b, AIM 5.x, MSN
6/7) to that catalog and installs them; media comes from the lab's archival
sources as always ([`../catalog/os-media-catalog.md`](../catalog/os-media-catalog.md)).

## 3. Topology

One **gateway** (a dedicated CT on labhost — snapshotable, contained, its own
claims) hosts every service. Guests reach it over one of two lanes:

**Lane A — slirp pinholes (default, wave 1+).** Stations that already have a
user-mode netdev get `guestfwd=` TCP pinholes on that same netdev id, mapping a
stable virtual address (e.g. `10.0.2.100:<port>`) to the gateway's services —
plus `restrict=on` where nothing else needs slirp. Device set untouched, so
checkpoints survive; the allowlist is explicit per station. Costs: TCP only
(no guest DNS, no UDP, no ping) — which the era stack absorbs, because **every
era browser speaks HTTP-proxy** (the proxy does all naming) and every chat
client accepts a literal server address or a HOSTS entry.

**Lane B — the museum bridge (fidelity, later waves).** The generalized
`tru64` pattern: a shared host-only bridge (pick an unused RFC1918 block, e.g.
`172.31.80.0/24`), per-station veth/tap, gateway CT attached, **no uplink**.
Real DNS (wildcard — every name a guest types resolves to the gateway), UDP,
ICMP, and a home for emulators that do networking via pcap/tap (MAME machines,
`newsos`-class exotics) or that never had slirp. Stations without a NIC join
here, paying the cold-recapture price.

Chat is client-server, so **station↔station traffic needs no shared L2** —
both clients talk to the gateway daemons. Lane A alone carries the whole chat
and web story for the x86 fleet; Lane B is for naming fidelity, exotics, and
whatever P2P curiosities come later (direct file transfer, LAN games —
parking lot).

Every launcher/netdev-option change follows the standard discipline: clone
first, `loadvm` proven under the changed command line, then the station, then
scene recapture with clients installed/configured, `labctl shot` acceptance.

## 4. The web plane

**Proxy-first, corpus-only.** Era browsers get one setting — HTTP proxy =
gateway — and the proxy answers every name from the local **corpus** and from
nowhere else: no upstream, no pass-through, no live fetch, no exceptions. A
name the corpus does not hold gets the local miss page. The same corpus is
also served as wildcard-DNS vhosts on Lane B, so both lanes show the same web.

**Corpus pipeline (`era-press`, the acquisition tool):**

1. **Fetch** (runs on CT950, never on the gateway): pull a site at a target
   date from the public web archive (CDX + snapshot fetch), one directory per
   host per year.
2. **Downgrade:** strip scripts and modern CSS, flatten to HTML 3.2-ish, GIF/
   JPEG only (transcode PNG), Latin-1, size caps, kill chunked/gzip — output
   must be honest 1996 bytes.
3. **Sync** into `/data/retronet/corpus/` on the gateway; serve with HTTP/1.0
   semantics.
4. **Validate in a real browser** — the acceptance for a site is a Netscape
   shot, not an HTTP 200.

Misses render a period-styled "this page is not in the museum's internet" page.
A **local search engine** over the corpus (AltaVista-styled results, directory
page Yahoo-styled) makes it explorable instead of a bookmark list. Starter
corpus: ~25 landmark sites of 1995–1999 (portals, the browser homes, a
GeoCities neighborhood, news frontpages, HamsterDance-class ephemera) — exact
list is an operator-taste decision (§10).

Copyright posture: mirrored pages are served only inside the invited, private
museum — same stance as the gallery itself ([gallery is private](../PUBLIC-GALLERY.md));
nothing from the corpus is ever committed to this public repo.

## 5. The chat plane

| Service | Server | Clients on stations | Notes |
|---|---|---|---|
| IRC | ngIRCd (or similar small RFC1459 daemon) | mIRC (win9x+), ircII/BitchX (unix guests), Ircle (mac), Vision (haiku/beos) | Cheapest, most portable — first service up |
| ICQ + AIM | **Retro AIM Server** (open-source OSCAR reimplementation; serves AIM 5.x-era and ICQ 2000b-era clients) | ICQ 99a–2000b, AIM 4/5 (win9x/NT/2000/XP), Mac AIM | One daemon, two nostalgia brands. Verify upstream state at build time |
| MSN Messenger | Escargot-class MSNP server reimplementation | MSN 4–7 (win98se/2000/XP) | Heavier eval (license, deps) — **decide in P4, not v1** |
| Email | SMTP/POP3 (Outlook Express, Netscape Mail) | — | Parking lot — charming, not core |

**Signed in before the scene is captured.** Accounts are pre-provisioned
server-side, **one persona per station**; lab-local, nothing federates, and no
client ever runs a registration flow. Joining a station means: install the
client, configure the persona with saved credentials and auto-reconnect, sign
in, arrange the desktop (client running, sound on where the station has
audio), **then capture the scene** — the checkpoint holds a connected
messenger.

A restored checkpoint holds a frozen TCP session the gateway no longer knows,
and pause/resume severs it the same way — and that is exactly the mechanism
the greeting rides: on resume the client notices the dead link, auto-reconnects
with its saved credentials, and its fresh sign-on is the event the greeter
reacts to (§6). Idle pause guarantees a reconnect between visitor sessions, so
every visitor gets greeted. **Auto-reconnect after `loadvm` is therefore a
join requirement, verified per client per station** — a client that shrugs and
sits offline fails the wave.

## 6. Chatbots

The bots are the retronet's staff — and its doorbell:

- **The greeter.** Watches presence on the chat servers; when a station's
  persona signs on (which every visitor session causes — §5), it waits ~30 s
  and sends a hello tuned to the station ("hey, is that the Windows 98
  machine?"). The era client does the rest — message window, sound, tray
  flash — a real desktop notification that leads the visitor to the
  messenger. IM toast where the station has an IM client, an IRC query
  elsewhere. Sign-on-triggered, so back-to-back visitors with no idle pause
  between them share one greeting; accepted.
- **The conversation partner.** A SmarterChild homage on ICQ/AIM (and MSN if
  it lands): backed by the lab's local LLM worker (the same router the qwen
  agents use), with a tight persona prompt, era-plausible tone, reply length
  caps, request rate caps, and a canned-ELIZA fallback when the GPU is busy.
  Typing-delay pacing so it feels like 1999, not an API. Greeter and partner
  are naturally the same buddy — the greeting is just its opening line.
- **ELIZA** on IRC (`#lobby`) — period-perfect, zero dependencies, canned logic.

Bots connect as ordinary protocol clients to the same servers — no special
server hooks, so they prove the client path daily by existing. Bot memory is
per-conversation only; nothing persists, nothing leaves the lab.

## 7. Station enablement waves

| Wave | Stations | Cost per station |
|---|---|---|
| 1 — already wired | `tru64` (drops its NAT for gateway-only routes), `hpuxvue` (IP config only) | In-guest config + persona signed in + scene recapture |
| 2 — options-only | `win98se`, `win95` (mind the warpnet trap), `win2000`, `winxp`, `nt4`, `beos`, `haiku`, `freedos` (Arachne lane) | `guestfwd` pinholes on the existing netdev + clients installed + persona signed in, reconnect-after-restore proven on a clone, then scene recapture |
| 3 — cold recapture | `win311` (Trumpet Winsock lane; carries the interrupts-freeze history — late, careful), `msdoswin1`, `macos753`, `aux`, `sunos414` | NIC added to device set → full checkpoint recapture |
| 4 — Lane B exotics | `newsos`, MAME-hosted machines with NIC emulation, `w2kalpha`/`openvms` veth joins | Bridge attach + per-emulator networking work |

Waves of 2–3 stations, merged and eyeballed per wave, exactly like every other
fleet campaign ([`MIGRATION-WAVE-BRIEF.md`](MIGRATION-WAVE-BRIEF.md) is the
model). **A station's acceptance shot is the greeting**: restore from the new
checkpoint, wait, and the bot's hello lands on screen inside ~30 s. Each
joined station's registry `network` block gains `status: "retronet"` + a note;
the fleet table grows the facet; a UI badge on station cards is a late-phase
nicety.

## 8. Security

- Guests reach **only** the gateway's allowlisted TCP ports (Lane A pinholes)
  or an uplink-less bridge (Lane B). No WAN leg exists anywhere.
- The gateway CT is unprivileged, snapshotted, rate-limits its daemons (era
  TCP stacks + a flood = broadcast-storm nostalgia nobody ordered), and logs
  enough to answer "which station did that".
- Era guests attacking each other over the retronet is accepted risk inside
  the invited museum — checkpoints make every station restorable — but the
  gateway must survive them (it is the only shared surface).
- Slirp's default host-loopback reachability is exactly what `restrict=on` +
  explicit `guestfwd` removes: with pinholes in place a guest cannot reach
  labhost services, the LAN listener included. Verify per station, not by
  assumption.
- Walk-in exclusion is restated here because both epics will be in flight at
  once: **no retronet pinhole ever appears in a walk-in clone's launcher.**

## 9. Phases

| Phase | Delivers | Exit criterion |
|---|---|---|
| **P0 — gateway + first light** | Gateway CT, ngIRCd, proxy serving a hand-made 3-site corpus, reached from `tru64` (no station changes at all) | Netscape 4.76 on tru64 renders a 1996 page via the proxy; joins `#lobby` — shots |
| **P1 — second station** | `win98se` joins over Lane A pinholes; mIRC connected as its persona, IE5/Netscape4 proxied; clone-proven first, scene recaptured connected | tru64↔win98se IRC conversation, framebuffer-proven both ends |
| **P2 — ICQ/AIM + the greeting** | Retro AIM Server up; ICQ+AIM clients with personas signed in on the wave-2 Windows stations, scenes recaptured connected; greeter + ELIZA | Restore `win98se` from its checkpoint: the persona auto-reconnects and the greeting + desktop notification land within ~30 s — shots; plus a station-to-station ICQ message |
| **P3 — the real corpus** | `era-press` pipeline + ~25-site corpus + local search engine; browser-matrix validation | Search → click → render on three different era browsers |
| **P4 — MSN decision + smart bot** | MSN server eval (license/effort) and go/no-go; LLM-backed persona buddy with pacing | Persona bot passes the "feels like 1999" eyeball |
| **P5 — the fleet** | Wave-3 cold recaptures, Lane B bridge + exotics, UI badges, catalog/docs consolidation | Each wave's per-station acceptance shots |

Rough size: P0 M, P1 S, P2 M, P3 M–L, P4 M, P5 L (ongoing, wave-paced).

## 10. Operator decisions

1. Gateway home: dedicated CT (recommended) — pick the CT id.
2. The starter corpus list — 25 sites of operator taste, plus the search
   engine's period skin (AltaVista? Yahoo directory? both?).
3. Chat lineup for v1: IRC + ICQ + AIM (recommended); MSN deferred to P4 —
   agree?
4. Persona naming: the greeter/partner buddy's name, and the per-station
   account handles the visitor sees (one homage buddy + ELIZA to start?).
5. Wave-2 station order — which two stations after `tru64`/`win98se`?
6. Lane B address block reservation.
7. Email: parking lot (recommended) or pull into P5?

## 11. Pointers

[`../GUEST-TIERS.md`](../GUEST-TIERS.md) · per-guest netdev reality:
`registry/stations/*.json` + [`../guests/`](../guests/) ·
[`../catalog/software-catalog.md`](../catalog/software-catalog.md) — the era
client roster this extends · [`ADD-NEW-OS-PLAYBOOK.md`](ADD-NEW-OS-PLAYBOOK.md)
§scene/recapture discipline · [`MIGRATION-WAVE-BRIEF.md`](MIGRATION-WAVE-BRIEF.md)
— the wave-campaign template · [`WALKIN-BRIEF.md`](WALKIN-BRIEF.md) — the other
epic and the standing exclusion.
