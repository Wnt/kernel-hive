# The retronet's LLM and its ICQ bot — as built

**Status: LIVE.** The doorbell works: sign persona `98980` into the gateway and
a station-tuned hello lands **30 seconds later**, followed by a conversation
backed by a local language model — with a 1966 chatbot standing behind it so the
exhibit can never hang. Stream C of the [PoC plan](POC-PLAN.md); the server it
talks to is stream B's [gateway](GATEWAY.md).

Two systemd units on labhost, both caged:

| Unit | What | Endpoint |
|---|---|---|
| `retronet-llm` | llama.cpp `llama-server`, CPU-only | `127.0.0.1:8091`, OpenAI-compatible |
| `retronet-bot` | OSCAR/ICQ client: greeter + partner | outbound to `10.99.0.2:5190` and to the LLM. Listens on nothing |

```bash
ssh lab '/data/kernel-hive/scripts/retronet/llm/install-llm.sh --apply'
ssh lab '/data/kernel-hive/scripts/retronet/bot/install-bot.sh --apply'
```

Both are idempotent, and both read every knob from `/etc/retronet/*.env` — the
unit files carry no defaults, so "what is it running" is one `cat`.

---

## The LLM

### The bench

Every number below is `llama-bench` on the box that runs the fleet: a GPU-less
**Xeon D-2146NT, 8C/16T, AVX-512**. Both thread counts are published because
only one of them is real: the unit runs at `CPUQuota=400%`, so **`-t 4` is what
the bot actually gets**. `-t 8` is there to show the shape of the curve, not to
be quoted.

`pp256` = prompt processing, `tg64` = token generation, ±: stddev over 3 runs.
Peak RSS is `systemd MemoryPeak` after loading the model and serving a request.

| Model (Q4_K_M) | On disk | `-t 4` pp256 | `-t 4` tg64 | `-t 8` pp256 | `-t 8` tg64 | Peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| **Qwen3-4B-Instruct-2507** ← **chosen** | 2.32 GiB | **25.35 ± 0.17** | **7.09 ± 0.25** | 38.74 ± 1.55 | 9.65 ± 0.60 | **3.05 GB** |
| Llama-3.2-3B-Instruct | 1.87 GiB | 33.62 ± 1.95 | 9.14 ± 0.26 | 54.22 ± 0.71 | 11.82 ± 0.36 | 2.39 GB |
| Qwen3-30B-A3B-Instruct-2507 (MoE) | 17.28 GiB | 17.73 ± 0.56 | 8.48 ± 0.26 | 24.15 ± 1.53 | 7.40 ± 0.51 | 15.06 GB |

Reproduce: `ssh lab '/data/kernel-hive/scripts/retronet/llm/bench.sh'`
(llama.cpp b10516, build `b95502ba9`).

Two things in that table are worth stopping on. The **30B MoE decodes about as
fast as a 3B dense model** — that is the whole point of a 3B-active mixture —
but its *prompt* rate is the worst of the three, and prompt rate is what the
first reply of a conversation pays. And it is the only row where **more threads
made generation slower** (8.48 → 7.40): at 17 GiB the workload is memory-bound,
and the extra threads buy contention, not bandwidth.

### The pick: Qwen3-4B-Instruct-2507 Q4_K_M

Latency is not the discriminator — the three are within a couple of seconds of
each other on a ~50-token reply. **Instruction adherence is**, because the whole
persona is instructions: one line, ≤200 characters, 1999 vocabulary, never
mention what an LLM is. Identical probes through the real bot code:

| Probe | Qwen3-4B (chosen) | Llama-3.2-3B | Qwen3-30B-A3B |
|---|---|---|---|
| *hi, who are you?* | "Hey there! I'm HiveBot, the friendly chat bot from '99, still buzzing on this old network :) What's your machine running? I'm curious!" | "just a simple chatty bot, nice to meet u :)" | "hey there! just a lil' chat bot hangin' out on ICQ, curious 'bout your Windows 98 setup :)" |
| *what can this computer do?* | "Oh wow, that's a sweet 98 SE! Can run IE 4, winamp, maybe even a little Quake…" | "It's got a 166MHz CPU, 16MB RAM, and a 2G HDD, so it can do Win98, AOL, and some pretty sweet gamez :)" | "Got Windows 98 SE? You can surf the web, play Solitaire, chat with me, maybe even play Doom if you're lucky :)" |

Llama-3.2-3B is terse and invents hardware specs for a machine it cannot see.
The 30B is the best writer by a hair — and costs **5× the resident memory** on a
box whose free RAM is the fleet's headroom. Qwen3-4B lands within a hair of the
30B at 3 GB, so it wins on quality-per-gigabyte, not on speed.

**If the operator later wants more wit and can spare 20 GB**, the upgrade is two
lines: point `RN_LLM_MODEL` at the 30B GGUF (already downloaded) and raise
`MemoryHigh`/`MemoryMax` in the unit. Nothing else changes.

### llama.cpp: pinned release, not a local build

`install-llm.sh` fetches the **pinned** `b10516` ubuntu-x64 release tarball and
verifies its sha256 before unpacking. That tarball ships one ggml CPU backend
per microarchitecture and dispatches at load time, so this Skylake-SP Xeon picks
`libggml-cpu-skylakex.so` and gets its AVX-512 path — the same thing a local
`-march=native` build would produce, without putting cmake and a toolchain on
the Proxmox host. Bumping versions is `LLAMA_TAG` + `LLAMA_SHA256`.

### The cage, and why each bar is there

`retronet-llm.service` is not a normal service unit. This box runs 61 production
stations; a chatbot that makes one of them stutter is a regression, so the LLM
is a *guest* in the box's resources:

| Setting | Why |
|---|---|
| `CPUQuota=400%` | 4 of 16 hardware threads. The bench above was taken at `-t 4` for exactly this reason: a published throughput the unit cannot reach is a lie. `RN_LLM_THREADS` in `llm.env` must be kept in step. |
| `CPUWeight=20` | streamhost runs at 100. Under contention the fleet wins 5:1. |
| `Nice=10`, `IOSchedulingClass=idle` | a token is never more urgent than a frame. |
| `MemoryHigh=6G` / `MemoryMax=8G` | headroom over the 3 GB working set, and a hard ceiling so a runaway context cannot push the fleet into swap. |
| `IPAddressAllow=localhost` + `IPAddressDeny=any` | the model can be reached by the bot and can reach nothing. The retronet's first principle is "no path to the internet"; the LLM lives on labhost rather than in the offline gateway CT, so it gets the same guarantee from a cgroup instead of from a missing route. |
| `DynamicUser=yes`, `ProtectSystem=strict`, `SystemCallFilter=@system-service` | it parses untrusted text for a living. |

`DynamicUser` has one sharp edge worth remembering: it is a transient uid in no
groups, so **everything it reads must be world-readable**. `curl` under root's
umask leaves 0600 GGUFs and 0700 directories behind, and the only symptom is
`Permission denied` at `ExecStart`. Both installers `chmod a+rX` for this reason.

### Serving

`llama-server --ctx-size 8192 --parallel 2 --cache-reuse 256 --no-webui`, model
alias `retronet`. Two slots so a second visitor is not queued behind the first;
`--cache-reuse` keeps the system-prompt KV block between turns, which is why the
first reply of a conversation costs ~11 s and every later one ~4–7 s.

---

## The bot

### What it does

**Greeter.** Watches presence for the persona UINs it was given. On sign-on it
waits 30 s and sends a station-tuned opener — `win98se` gets *"hey, is that the
Windows 98 machine?"* and two variants. The era client turns that into a message
window, a sound and a tray flash: the desktop notification the visitor never
configured. Sign-on is the trigger because every visitor session produces one —
the checkpoint holds a connected messenger, resume kills that TCP session, and
the client auto-reconnects ([brief §5](../RETRONET-BRIEF.md)).

**Partner.** Each inbound message goes to the LLM with a tight persona prompt
and up to 8 turns of in-RAM history. The reply is trimmed to one line, cut to
200 characters at a sentence boundary, and rate-capped per peer (8 replies /
60 s, token bucket).

**ELIZA.** Any LLM failure — down, timeout, busy, junk — returns `None` from one
place and the reply comes from `eliza.py` instead. Proven below.

### Typing pacing is what hides the seam

A 1999 chatter types ~14 characters a second including thinking pauses, so a
70-character reply "should" take about 6 s. The pacer computes that target and
then subtracts **the time the LLM already spent**:

```
wait = clamp(1.2 + len(reply)/14, 0, 9) − llm_elapsed
```

A slow LLM reply is sent the instant it arrives; an ELIZA reply that took 0.0 s
waits ~5 s. From the persona's side the two are indistinguishable — measured on
the live gateway, LLM replies landed at +10.9 s and +6.6 s after the question,
ELIZA replies at +4.8 s and +5.1 s. The fallback does not *look* like a fallback.

### One greeting per sign-on

A single sign-on produces **two** `BuddyArrived` SNACs milliseconds apart (the
peer's own `ClientOnline` broadcast, plus our visibility replay). The bot keeps
a believed-online set: an arrival for a UIN it already thinks is online is a
duplicate and is dropped; a `BuddyDeparted` clears it, so a genuine reconnect
two minutes later *is* greeted again. A 15 s cooldown is the belt for a server
that bounces a session without saying so. Back-to-back visitors with no pause
between them share one greeting — accepted, per the brief.

### Files

| File | Lines | What |
|---|---:|---|
| `scripts/retronet/bot/oscar.py` | ~460 | FLAP/SNAC/TLV, BUCP sign-on, presence, channel-1 and channel-4 IMs |
| `scripts/retronet/bot/bot.py` | ~350 | greeter, partner, rate cap, pacing, reconnect |
| `scripts/retronet/bot/llmclient.py` | ~135 | OpenAI-compatible client + the never-hang policy |
| `scripts/retronet/bot/eliza.py` | ~160 | DOCTOR script, canned, instant |
| `scripts/retronet/bot/persona-sim.py` | ~90 | a persona in a shell — the test harness |

Stdlib only. No venv, no pip, no requirements file: `install-bot.sh` copies five
files to `/data/retronet/bot` and that is the deployment.

### Why a hand-rolled OSCAR client

Four verbs are needed — sign on as a UIN, watch a buddy, receive an IM, send an
IM — and no maintained Python OSCAR library exists. 460 lines of stdlib beats a
dependency that would have to be vendored into a public repo and kept alive.

**The one ordering rule that is not obvious**: `BuddyAddBuddies` (0x03,0x04)
must be sent **before** `ClientOnline` (0x01,0x02). The server suppresses arrival
notifications until sign-on completes and only replays them at `ClientOnline`
*if the contact list was already initialised*. Add buddies after, and a persona
that is already online stays invisible until it signs on again — which, on a
station that reconnects once a day, is a bug you would chase for a week.

---

## The thing that silently breaks the greeting

**Newly created ICQ accounts require authorization, and that stops presence.**

Open OSCAR Server creates every ICQ account with
`icq_permissions_authRequired = 1`. Adding such a contact is refused —
`BuddyAddBuddies` comes back as `BuddyRejectNotification`, and the feedbag route
behaves the same — until the *owner* clicks "authorize" in a client. Presence
only ever reaches watchers on the contact list. So with the flag set:

- the server is healthy, the bot signs in fine, `nc -z` passes, `verify` is green;
- the bot simply never learns that the persona signed on;
- **the greeter never fires**, and nothing anywhere logs an error.

That is the failure mode this exhibit is most likely to hit in six months, so it
is fixed at the root — in the gateway's provisioning, not worked around in the
bot ([`rn-tool.py`](../../../scripts/retronet/gateway/rn-tool.py)
`cmd_user_open`):

```bash
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py user-open 98980'
```

`provision-gateway-ct.sh accounts` now does this for both UINs automatically,
and `verify` asserts it:

```
PASS  bot UIN 10000 accepts contacts unattended
PASS  persona UIN 98980 accepts contacts unattended
```

Clearing the flag is also the era-accurate setting — ICQ's own *"My
authorization is not required"* checkbox — and it is symmetric, so at wave 2 the
persona's ICQ client can add the bot without a prompt either. The management API
has no endpoint for ICQ permissions, so `user-open` writes the single column
directly; SQLite is multi-process safe and the server re-reads the row on every
check, so it takes effect with no restart.

If the bot ever does hit a gated contact, it says so loudly rather than sitting
mute:

```
BUDDY LIST REJECTED for ['98980'] — contact requires authorization; presence will NOT arrive
```

---

## Configuration

`/etc/retronet/llm.env` (0644) and `/etc/retronet/bot.env` (**0600** — it holds
the password). `install-bot.sh` derives everything from stream B's contract keys
in `registry/local.env` (gitignored, written by the gateway provisioner):
`RETRONET_ICQ_HOST`, `_PORT`, `_BOT_UIN`, `_BOT_PASS`, `_PERSONA_UIN`.

| Key | Default | Meaning |
|---|---|---|
| `RN_BOT_SERVER` | `10.99.0.2:5190` | the **labhost door** (5190). Never 5191 — that door advertises `10.0.2.100` as BOS, which only a slirp guest can route |
| `RN_BOT_UIN` | `10000` | the bot's account |
| `RN_BOT_PERSONAS` | `98980:win98se` | comma-separated `uin:station`; adding a wave-2 station is one entry plus a `GREETINGS` row. Live set also carries `20000:win2000`, `30000:solaris`, `40000:nt4`, `64000:tru64`, `95000:win95` and `50000:beos` — the last one is a **legacy UDP-4000** persona rather than an OSCAR one, and the greeter cannot tell the difference |
| `RN_BOT_GREET_DELAY` | `30` | seconds between sign-on and hello |
| `RN_BOT_MAX_CHARS` | `200` | reply cap |
| `RN_BOT_LLM_URL` | `http://127.0.0.1:8091` | any OpenAI-compatible endpoint |
| `RN_BOT_LLM_TIMEOUT` | `60` | wall clock; past it, ELIZA answers. Raised from 20 so a cold or slow reply waits for the model rather than falling back |
| `RN_BOT_LLM_CONCURRENCY` | `2` | in-flight LLM calls; matches the 2 worker threads and llama-server's 2 slots, so two near-simultaneous messages (one visitor across two OSes) both reach the model; a rarer 3rd queues for a worker rather than falling back |
| `RN_BOT_RATE_BURST` / `_WINDOW` | `8` / `60` | per-peer token bucket |
| `RN_BOT_TYPE_CPS` / `_BASE` / `_MAX` | `14` / `1.2` / `9` | the pacer |
| `RN_BOT_BOS_HOST` | unset | force the BOS reconnect host when the advertised one is not routable from here |

**UINs are 10000 and 98980, not the plan's 1000 and 9898.** Mirabilis reserved
every UIN below 10000 and the server enforces it (`ErrICQUINInvalidFormat`,
range 10000–2147483646); `POST /user` answers 400. ICQ passwords are **6–8
characters** for the same era-accuracy reason. Both limits are stream B's
amendments and are documented in [GATEWAY.md](GATEWAY.md).

---

## Proof

All of it against **stream B's live gateway** (`10.99.0.2:5190`), bot as UIN
`10000`, persona as UIN `98980`, driven by `persona-sim.py`.

**Greeting — 30.1 s after sign-on, twice:**

```
signed on as 98980 at 10.99.0.2:5190
  +  30.1s  <10000>  oh hey — Windows 98. nice. what are you up to?
  +  45.0s  ->10000   yeah! whats this network then?
  +  55.9s  <10000>  ah, ICQ! classic. you on a 98 system? love the floppy drive sounds :)
  +  75.0s  ->10000   any good games on this machine?
  +  81.6s  <10000>  Quake? maybe. but I'd say it's more about the nostalgia than the gameplay ;)
```

**ELIZA fallback — same run shape with `systemctl stop retronet-llm`:**

```
  +  30.1s  <10000>  hey, is that the Windows 98 machine?
  +  40.0s  ->10000   i am stuck on this old computer
  +  44.8s  <10000>  How long have you been stuck on this old computer?
  +  60.0s  ->10000   do you know anything about modems?
  +  65.1s  <10000>  What would it mean if I did know anything about modems?
```

```
retronet.llm  WARNING  LLM unreachable (Connection refused) — falling back
retronet.bot  INFO     reply via eliza in 0.0s (+4.8s pacing): How long have you been stuck…
```

**One greeting per sign-on**, two consecutive sessions, no double-greet:

```
=== session 1   +30.1s  <10000>  oh hey — Windows 98. nice. what are you up to?
=== session 2   +30.1s  <10000>  hey, is that the Windows 98 machine?
```

The framebuffer is still the only proof a **guest** reacted — that is wave 3.
What is proven here is that the server and the bot do their part.

## How to run and test

```bash
# is it up
ssh lab 'systemctl status retronet-llm retronet-bot --no-pager'
ssh lab 'journalctl -u retronet-bot -n 40 --no-pager'
ssh lab 'curl -s http://127.0.0.1:8091/v1/models'

# both reply paths, no OSCAR server needed
ssh lab 'python3 /data/retronet/bot/bot.py --selftest'

# the whole doorbell, no guest needed (~2 min)
ssh lab '. /data/kernel-hive/registry/local.env
  python3 /data/kernel-hive/scripts/retronet/bot/persona-sim.py \
    --server "$RETRONET_ICQ_HOST:$RETRONET_ICQ_PORT" \
    --uin "$RETRONET_ICQ_PERSONA_UIN" --password "$RETRONET_ICQ_PERSONA_PASS" \
    --buddy "$RETRONET_ICQ_BOT_UIN" --listen 90 --say-after 45 --say "hey whats this?"'

# prove the fallback
ssh lab 'systemctl stop retronet-llm'   # …run persona-sim again…
ssh lab 'systemctl start retronet-llm'

# re-bench
ssh lab '/data/kernel-hive/scripts/retronet/llm/bench.sh -o /tmp/bench.md'
```

Offline development without the gateway: run any Open OSCAR Server instance on a
spare port and point `RN_BOT_SERVER` at it. `install-bot.sh` writes an
`IPAddressAllow` drop-in for a non-contract server address automatically — the
cage is an allowlist, so a server it does not know about is silently unreachable
otherwise.

## Known limits

- **No offline-message handling.** A greeting is only sent to a persona the bot
  saw sign on, so a message queued for an offline account never happens by
  design. `ICBMTLVStore` is deliberately not set.
- **Bot memory is per-conversation and in RAM**: 8 turns, expiring after 30
  minutes idle, gone on restart. Nothing about a visitor persists — [brief
  §6](../RETRONET-BRIEF.md).
- **Prompt injection is not defended against**, only bounded. A visitor who
  talks the model out of its persona gets a bot that mentions 2026. The blast
  radius is a message window on an exhibit; the cage is what makes that
  acceptable, not the prompt.
- **One LLM, one box.** Two worker threads and `--parallel 2` serve two
  conversations at once; a third *simultaneous* message waits briefly in the job
  queue for a free worker and is then answered by the model too, not by ELIZA.
  ELIZA is reserved for a real outage (LLM down) or a reply that blows the 60 s
  timeout. Sustained heavy concurrency is bounded by `CPUQuota=400%`, not by
  dropping to ELIZA — a single visitor hopping between OSes stays on the model
  throughout.
- **The greeting has never been seen by a guest.** Every number here comes from
  a Python persona. ICQ 2000b on `win98se` is wave 2, and the framebuffer is the
  only proof of it.
