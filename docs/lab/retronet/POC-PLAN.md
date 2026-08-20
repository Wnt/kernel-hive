# Retronet PoC — ICQ on win98se (coordinator contract)

**Status: BUILDING.** This is the coordination contract for the first retronet
proof-of-concept. The main session coordinates; parallel worker agents do the
work. Parent epic: [`../RETRONET-BRIEF.md`](../RETRONET-BRIEF.md).

**Goal.** `win98se` (live, no VM clone) runs ICQ against a lab-local server, and
when a visitor opens the station the persona auto-reconnects and a bot greets
them within ~30 s with a real desktop notification — the "kernel hive feels
alive" moment.

## Locked decisions

- **Station:** `win98se` — live production station, driven directly (operator
  authorised: **no VM clones**). Absolute pointer (usb-tablet), clean netdev
  `n0`. Back its golden up before mutating it.
- **Protocol:** ICQ 2000b. **Server:** `mk6i/open-oscar-server` v0.24.0
  (formerly Retro AIM Server; native ICQ UINs — no `iserverd` fallback needed).
- **LLM:** llama.cpp `llama-server`, caged systemd unit on **labhost** for the
  PoC (decoupled from the CT; moving it into the CT later is trivial).
- **UINs:** bot `10000`, win98se persona `98980` (the server reserves every UIN below 10000).

## The network contract — predecided so streams don't block each other

These constants are the interface. Build to them; do not renegotiate mid-wave.
They are lab-internal RFC1918/slirp constants (not scrubbed production secrets),
so they live in committed docs. Only real passwords/keys go to
`registry/local.env`.

| Thing | Value | Owner |
|---|---|---|
| Retronet bridge (labhost, **no WAN uplink**) | `vmbr-rn`, `10.99.0.0/24` | B |
| Gateway CT | id **951** (claim; next free if taken), static `10.99.0.2`, unprivileged, offline | B |
| ICQ/OSCAR server (`mk6i/open-oscar-server` v0.24.0) | the `RN` door `10.99.0.2:5190` (one BOS listener). ~~station/slirp door `:5191`~~ **retired with the slirp swap** — on the bridge the guest uses the same door as the bot | B |
| Server address the guest dials (win98se) | **`10.99.0.2:5190` directly** (win98se is now a bridged NIC on `vmbr-rn`, not slirp; see [`ICQ-STATION.md`](ICQ-STATION.md)). ~~`10.0.2.100:5190` via `guestfwd`~~ **gone** — no two-door hack | A (bridge swap) |
| In-guest exec agent (warpnet `E` verb, `exec_kind: warpd_e`) | guest `:7788`, reached **directly over the bridge at the guest IP `10.99.0.10:7788`** (`exec_host` → `GEXEC_HOST`). ~~`hostfwd 127.0.0.1:57792`~~ **gone with slirp** | A (bridge swap) |
| LLM endpoint | `127.0.0.1:8091` (OpenAI-compatible), labhost | C |
| Bot | labhost systemd unit, outbound only; logs into `10.99.0.2:5190` as UIN 10000, calls LLM at `127.0.0.1:8091` | C |

**Why this decouples everything:** A targets fixed loopback `57792` for exec (no
dependency on B). B stands up the server at a fixed address B controls. C's bot
targets the fixed `10.99.0.2:5190` and can develop against a local test server
until B's is up. D sources media independently. Nobody waits on a runtime value
from anybody. Credentials live in `registry/local.env` (`RETRONET_ICQ_*`),
mirrored from the CT.

## Streams (wave 1 — all parallel)

| Stream | Owner | Deliverable | Acceptance |
|---|---|---|---|
| **A — exec channel** | opus | In-guest Win9x exec agent (clone `warpnet.c` pattern) + `exec_kind: win9x-agent` in `labctl` + win98se `n0` exec hostfwd; agent autostarts; golden recaptured | `ssh lab 'labctl exec win98se "<cmd>"'` launches a visible program |
| **B — gateway CT + ICQ server** | opus | CT 951 offline on `vmbr-rn`; Retro AIM Server; UINs 1000 + 9898; reproducible provisioning script | `nc -z 10.99.0.2 5190` from labhost; both UINs exist; CT has no WAN |
| **C — LLM + bot** | opus | Caged `retronet-llm` unit (GGUF picked by bench) + `retronet-bot` (greeter + LLM partner + ELIZA fallback, typing pacing) | Persona sign-on → greeting ~30 s later; a message gets an LLM reply; fallback proven |
| **D — ICQ media** | sonnet | Era ICQ installer (99b/2000b, server-compatible) staged to media archive + hashed + ASSETS-MANIFEST/software-catalog rows | Installer in archive with sha256; metadata committed; fetch reproducible |

Each stream lands its own doc — `EXEC-CHANNEL.md`, `GATEWAY.md`, `BOT.md`,
media rows in the catalog — so there are no shared-file conflicts. **Do not edit
`docs/README.md`** (the coordinator adds index rows).

## Waves

- **Wave 1:** A, B, C, D in parallel (this).
- **Wave 2 (integration):** install **ICQ 2000b** on win98se over the exec
  channel + framebuffer (media staged by D). **The slirp `guestfwd` integration
  was proven a dead end (single-connection) and superseded by the bridge swap —
  win98se is now a `tap` on `vmbr-rn` with the guest static at `10.99.0.10`, ICQ
  `DefaultPrefs` Host `10.99.0.2`, and the golden captured tap-native with ICQ
  connected. The as-built (containment, exec-over-bridge, the idle-pause reconnect
  mechanism, the display-wedge recovery) is [`ICQ-STATION.md`](ICQ-STATION.md).**
  Historical slirp detail below is kept only to explain the retired constants:
  set `HKCU\Software\Mirabilis\ICQ\DefaultPrefs` Host
  Port `5190` **after install, before the registration wizard** (client bug);
  sign persona `98980` in (creds `RETRONET_ICQ_PERSONA_*`); then `savevm golden`
  **with ICQ connected** — live-inject + `savevm`, never offline-inject
  (`loadvm` discards it). Needs A + B + D.
- **Wave 3 (the demo):** open win98se → persona auto-reconnects → bot greets
  within ~30 s. Acceptance = the greeting shot. Needs everything + C.

## Guardrails (every stream)

- Own worktree: `scripts/dev/wt.sh new <name>`. Land on `main` yourself (commit
  → push branch → `git fetch origin && git merge --ff-only origin/main` → `git
  push origin HEAD:main`); `scripts/dev/box-deploy.sh --apply` if you touched
  deployed files. Report the landed commit.
- `win98se` is **live**; back up its golden before any change; process control
  via `ssh lab`/`labrun`; kills through `clone-guard`; never `pkill -f`.
- `n0` edits are **options-only** (host-side hostfwd/guestfwd don't change the
  guest-visible device set → `loadvm`-safe); never renumber `n0`.
- Contract constants above may be committed; real passwords/keys →
  `registry/local.env` only. Never commit a real production address.
- Green-before-done for the languages you touch, or report **BLOCKED** with the
  failing command + output.
- **Report concisely** at the end: decision, landed commit, blockers, and any
  interface value the coordinator needs. Put detail in your stream doc.
