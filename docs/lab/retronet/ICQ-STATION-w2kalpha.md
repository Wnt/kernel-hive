# w2kalpha ICQ station — x86 ICQ 2001b on the Alpha, under FX!32

**Status: FX!32 PROVEN, station NOT yet onboarded.** `w2kalpha` (Windows 2000 RC2 build
2128 for **Alpha AXP**, on the es40 AlphaServer ES40 emulator) runs the fleet's
standard **x86 ICQ 2001b (build 3659)** — the *same binary* the Intel stations
run — translated to Alpha by **FX!32 / Wx86**, Windows NT's built-in x86
emulation layer. The web half of this station's retronet membership is
[`w2kalpha-retronet.md`](w2kalpha-retronet.md); read the fleet recipe
[`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md) first — this doc records only
what is **different on the Alpha**.

## The headline: FX!32 carries the stock x86 client

The interesting question for this station was whether the fleet-standard x86
binary would run at all, or whether a native Alpha OSCAR client had to be
sourced. **It runs.** No new media was sourced, no alternative client was
needed, and this station joins on the exact fleet-standard client.

What is actually on this install:

| Component | Path | Role |
|---|---|---|
| Wx86 emulation layer | `C:\WINNT\System32\wx86.dll`, `wx86cpu.dll` | the interpreter that executes x86 instructions |
| FX!32 translator/optimizer | `C:\WINNT\System32\fx32opt.exe`, `fx32serv.exe`, `fx32cpu.idx`, `fx32msgs.dll` | profiles hot x86 code and caches **native Alpha** translations |
| FX!32 service | service name **`FX!32`** | running (`net start "FX!32"` → *already been started*) |
| x86 program tree | `C:\Program Files (x86)\` | where Windows installs x86 applications — ICQ lands here |

`x86prog` (System Properties ▸ Advanced ▸ Performance ▸ "x86 Program
Optimization") is the native Alpha applet that lists what FX!32 has translated.

**Correction to a stale claim.** `docs/guests/w2kalpha.md` recorded that
"interactive-session x86 does NOT work — telnet-session x86 does", i.e. that x86
apps launched from the auto-logon console session fail with *"The system cannot
find the path specified"* and therefore could never be shown on the framebuffer.
That is **not true on this install**: launching the x86 `C:\Apps\sol.exe` from
**Start ▸ Run** in the interactive session opened Solitaire on the framebuffer,
and the x86 ICQ 2001b installer launched the same way ran its full wizard on the
framebuffer. The earlier failure was some other launch path, not a property of
FX!32 in the interactive session. This is what makes an x86 GUI ICQ client
possible here at all.

## Media delivery — HTTP, not TFTP

The NT4 recipe delivers `ICQ2001b.exe` by TFTP over the exec channel. On this
station **do not**: TFTP's lock-step 512-byte blocks run at roughly **7
blocks/s** across es40's pcap NIC — about **20 minutes** for the 4.3 MB
installer, and the transfer dies with the telnet session that started it.

The same file over **HTTP** moves at **421 KB/s — 4.11 MB in 10 seconds**, a
~60x difference on the identical link. The bottleneck is the protocol's
round-trip lock-step, not the emulated NIC. So:

1. Serve the blob from the gateway CT (`python3 -m http.server` in a temp dir).
2. In the guest, from the **framebuffer** (Start ▸ Run):
   `iexplore http://10.99.0.2:<port>/ICQ2001b.exe` ▸ **Save** ▸ path `C:\ICQ2001b.exe`.
3. Remove the CT server and `C:\ICQ2001b.exe` afterward.

Launch the installer from the **framebuffer**, never the exec channel (the
long-lived-child trap the win2000 doc describes).

## The install is slow — days, not hours, and that is the blocker

**This is the finding that decides whether anyone should repeat this route.**

Running the x86 installer under FX!32 on an emulated Alpha is **compute-bound**,
not I/O-bound. Observed on the bring-up clone: es40 pinned at ~1.1 host cores
while the guest disk image grew only kilobytes per minute — the cost is x86
instruction translation, not disk. The installer's **Red Bend unpack phase** (the
same phase the NT4 doc calls "slow — ~15 min on a QEMU VM") runs for **hours**
here.

**Measured, so the next person does not have to re-derive it.** Timed readings of
the unpack staging dir `C:\Program Files (x86)\ICQ\temp`
(`dir /s` over the exec channel) on the bring-up clone:

| Elapsed from installer launch | Files unpacked | Bytes |
|---|---|---|
| ~2 h (copy phase done, unpack starting) | — | — |
| ~5 h | 177 | 46,406,913 |
| ~7 h | 190 | 47,438,722 |
| ~7.5 h | 194 | 47,490,714 |

That is roughly **5–6 files/hour** in the steady state, against a payload the
progress bar put only ~40% through. **Projected completion is on the order of
days, not hours** — and the unpack is only the staging step; the actual install
into `C:\Program Files (x86)\ICQ` had not begun at all (that directory still
held nothing but `temp`).

So: **FX!32 is not the limit — wall clock is.** The route works and is
architecturally correct; it is simply not affordable as a live install on this
emulator. If this station is to run ICQ 2001b, prefer transplanting the
**installed payload** from an x86 Windows sibling (the same offline-copy pattern
`docs/guests/w2kalpha.md` records for Winamp 2.5e, whose installer likewise
"will not complete on the Alpha") over running the installer here. What FX!32
proves is that the **client binary** will execute once it is in place.

**Telling "slow" from "hung":** the progress bar can sit visually still for
40 minutes while the filename underneath it changes. Check the host side instead —
es40's CPU jiffies (`/proc/<pid>/stat` fields 14+15) climbing at ~300/30 s per
core means it is working:

```bash
P=$(cat <rig>/mame.pid)
c1=$(awk '{print $14+$15}' /proc/$P/stat); sleep 30
c2=$(awk '{print $14+$15}' /proc/$P/stat); echo $((c2-c1))   # ~300 = 1 core busy
```

## Bring-up rig — a namespaced clone, never the live station

The checkpoint bake procedure in [`docs/guests/w2kalpha.md`](../../guests/w2kalpha.md)
("Checkpoint restore") requires a clone anyway. This bring-up used one under
`/data/vms/sandbox/icq-w2kalpha/rig/`, namespaced end to end so it can share the
retronet bridge with the live station without colliding:

| Thing | Live station | Bring-up clone |
|---|---|---|
| veth pair | `w2kalpha-g` / `w2kalpha-h` | `w2ka-icq-g` / `w2ka-icq-h` |
| guest MAC | `52:54:00:52:4e:11` | `52:54:00:52:4e:d1` (outside the reservation scheme) |
| guest IP | reserved `10.99.0.17` | DHCP **pool** address (`10.99.0.101`) |
| guard chain | `W2KALPHARN-IN` | `W2KAICQRN-IN`, scoped to the pool address |
| es40 serial | 21964 / 21965 | 22014 / 22015 |
| shm / ctlsock | station dir | rig dir |

The clone **cold-boots** (no `golden.axp` in the rig) so its `mac=` is honoured —
a restore would bring back the live MAC and put a duplicate on the bridge.

Containment was re-proved from inside the clone, the same three ways as the web
plane:

| From the guest to… | Result | Lock |
|---|---|---|
| gateway CT `10.99.0.2` | **Reply**, 15–23 ms | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` | **100% loss** | the `W2KAICQRN-IN` guard chain |
| internet `1.1.1.1` | **Destination host unreachable** | no default route (Lock 1) |

`route print` shows no `0.0.0.0` entry — the DHCP reservation withholds option 3,
so the addressing itself keeps the no-WAN posture.

## Persona

| | |
|---|---|
| UIN | **`50010`** (NT 5.0 on Alpha), nickname `w2kalpha` |
| Password | gitignored `registry/local.env` `RETRONET_ICQ_W2KALPHA_PASS` (**6–8 chars** — the server enforces the ICQ-era limit) |
| Created with | `rn-tool.py user-set 50010 <pass>`, opened with `rn-tool.py user-open 50010` |
| Server | `10.99.0.2` port `5190` |
| Roster | **SSI / server-stored** — no client-UI seeding, no golden recapture per roster change |

`rn-tool.py login 10.99.0.2 5190 50010 <pass>` completes the real OSCAR BUCP
handshake and reports the BOS address, which is the check that the account works
before any client is involved.

**HiveBot only greets UINs it was told about.** The greeter watches
`RN_BOT_PERSONAS` in `/etc/retronet/bot.env` on labhost; a persona missing from
that list signs in perfectly and is simply never greeted, with nothing logging an
error. `50010:w2kalpha` has to be added there (and a `w2kalpha` row in
`GREETINGS` in `scripts/retronet/bot/bot.py` for a station-tuned opener — absent
that, the `_default` opener is used).

## What is done, and what is not

**Done and durable:**

- FX!32 / Wx86 inventoried and **proven to run the stock x86 ICQ 2001b installer
  and its GUI wizard** on the framebuffer (the headline above).
- The stale interactive-session-x86 claim in `docs/guests/w2kalpha.md` corrected.
- Persona **UIN `50010`** created, opened (authorization off, or presence never
  reaches the greeter), nicknamed `w2kalpha`; a real OSCAR BUCP login verified
  with `rn-tool.py login`.
- `50010:w2kalpha` appended to `RN_BOT_PERSONAS` in `/etc/retronet/bot.env`
  (backup alongside it), so the greeter will see this persona when it signs in.
- The bring-up rig, containment re-proof, and the delivery/rate findings above.

**Not done — the station is NOT onboarded.** Its roster row stays
`onboarded: false`. The blocker is wall clock, not a technical wall: the
installer had not finished unpacking after 7.5 h and projects to days. The next
session should **not** simply re-run the installer and wait; pick one of:

1. **Transplant the installed payload** from an x86 Windows sibling (the
   Winamp 2.5e pattern), then do first-run config natively here — FX!32 is
   already proven to execute the client.
2. Let the existing rig's installer run to completion out-of-band and resume
   from step 3 below (the rig is isolated and harmless while it runs).

Remaining steps once ICQ is in place:

- ICQ 2001b first-run: **Existing User** ▸ UIN `50010` ▸ password, **Save
  password** ON. (A *fresh* install has no migrated-password prompt; that ritual
  in the other station docs is an artefact of the 2000b→2001b upgrade.)
- Preferences ▸ Connections ▸ **Server**: Host `10.99.0.2`, Port `5190`,
  **Keep connection alive ON** (load-bearing for the silent post-wake reconnect),
  Launch ICQ on startup ON.
- Clean **Shut Down** of ICQ to flush the password to disk, relaunch, confirm a
  silent connect.
- Re-bake the checkpoint with the **live** MAC and stage it into the live asset
  tree; re-verify instant restore, exec channel and desktop responsiveness.
- Acceptance must exercise a **genuinely fresh** OSCAR session: idle until the
  UIN disappears from the gateway's session list, *then* `labctl reset` — a reset
  seconds after sign-on reconnects nothing, because the server session is still
  valid. Budget extra time for the Alpha.
- Flip this station's row in `scripts/retronet/icq/roster.json` to
  `onboarded: true` with `client: icq2001b` only after that passes.
