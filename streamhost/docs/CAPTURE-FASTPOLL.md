# QEMU display-capture fast-poll — measured before/after

---

## AS-DEPLOYED — fleet-wide on pve-qemu (2026-07-13)

Shipped fleet-wide as a **pve-qemu quilt patch** (an upstream binary can't
`loadvm golden` — the golden snapshots carry a pve-only `pbs-state` vmstate
section — so it had to be a rebuilt `pve-qemu-kvm`, not a side binary). Build +
rollback steps: `streamhost/qemu-patches/README.md`.

- **Package:** `pve-qemu-kvm 11.0.0-3` rebuilt from git `684796e` + patch
  `debian/patches/0047-streamhost-dbus-display-fast-poll.patch`
  (== repo `streamhost/qemu-patches/0001-…`). Binary md5 `01b7f38b…`
  (stock `cb63a095…`). `.deb`:
  `/data/vms/qemu-fastpoll-build/pve-qemu/pve-qemu-kvm_11.0.0-3_amd64.deb`.
- **Knob:** `SH_DBUS_UPDATE_MS=4` (the knee), baked into every tile's
  `qemu-streamhost.sh` (`export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"`,
  per-tile overridable) and into the generator `scripts/streamhost-station.sh`.
- **Fleet:** 26/28 tiles on the patched binary; **apple2 + win98se deliberately
  left on stock**. 28/28 `streamhost@` daemons active. Bridge tiles
  (c64/atarist/amiga) relaunched inside their `qcap-*` 3 G `systemd-run --scope`.
- **`loadvm golden` confirmed** on the patched binary (the whole reason for the
  pve-qemu route): canary freedos + fleet-wide (23 golden tiles restore OK; the
  3 no-golden cold-boot tiles — sailfishos/serenityos/toaruos — cold-boot as
  before).
- **Poll cadence (live, `SH_DBUS_TRACE`):** freedos **250/s**, atarist (bridge)
  **233/s** — vs stock ~33/s. Matches the N=4 target.
- **Streaming (WebTransport probe, SPA-independent):** freedos 174 AU/6 s,
  c64 325, win95 13 (static golden desktop), reactos 18 — all resume-on-connect
  and stream on the patched binary.

### The idle-cost fix (why the patch also touches `ui/console.c`)

The first cut (dbus-listener only) **regressed idle CPU**: `gui_update()` arms
the refresh timer at `min(3 s, listener intervals)`, always taking the min and
with **no** damage-based idle fall-back — so a 4 ms listener pins the poll at
250/s **even on a paused guest**. Measured: each paused tile burned ~1–2 % of a
core; **26 tiles = 63.5 % of one core = 3.97 % host, continuous.** That fails the
"paused tiles = no fast-scan cost" bar.

Fix (patch hunk 2, `gui_update`): cap the interval back at the stock 30 ms
whenever `!runstate_is_running()`. streamhost pauses unwatched tiles, so the fast
scan is now spent **only while a tile is running (watched)**; it only ever
*lengthens* the interval (benign failure mode), and resume restores the fast rate
within one ≤30 ms tick (join latency unaffected).

| freedos on the patched binary | poll rate | tile CPU |
|-------------------------------|-----------|----------|
| **running** (watched)         | 250/s     | ~4 %     |
| **paused** (unwatched)        | (30 ms)   | **0 %**  |

Fleet idle (26 patched tiles, settled): **before gate 63.5 % of a core (3.97 %
host) → after gate 9.9 % of a core (0.62 % host)** — a 6.4× cut, back to the
stock noise floor, paused tiles at ~0. (25/28 tiles paused at rest; the 3
no-golden cold-boot tiles keep their guest running and so still pay the running
poll — a pre-existing trait, ~0.6 % each, orthogonal to the patch.)

### Rollback (staged + tested-path)

```sh
dpkg -i /data/vms/qemu-fastpoll-build/rollback/pve-qemu-kvm_11.0.0-3_amd64.deb  # stock, md5 490f9602
# then relaunch each tile's qemu (stop daemon; bash qemu-streamhost.sh; start daemon)
```

The stock `11.0.0-3` `.deb` is kept locally because the no-subscription repo has
since moved to 11.0.2-1 (a plain `apt reinstall` would no longer give 11.0.0-3).

---

**Date:** 2026-07-12 · **Box:** root@192.0.2.10, pve-qemu-kvm 11.0.0-3, QEMU 11.0.0
**Clone:** `/data/vms/sandbox/freedos-fastpoll/` (FreeDOS, `-display dbus,p2p=on`,
non-destructive cold-boot overlay — the fleet was never touched).
**Patched binary:** `/data/vms/sandbox/qemu-fastpoll/qemu-11.0.0/build/qemu-system-x86_64`
(upstream QEMU 11.0.0 + `streamhost/qemu-patches/0001-dbus-display-fast-poll.patch`).

## The change

`ui/dbus-listener.c`: the dbus display listener takes its `dcl.update_interval`
from **`SH_DBUS_UPDATE_MS`** (clamp 1..29 ms; unset/0 = stock 30 ms). This is the
only knob that changes the display poll interval — QEMU exposes no CLI/QMP knob,
so a rebuilt `qemu-system-x86_64` is required. Root cause and mechanism:
`streamhost/qemu-patches/README.md`.

## 1. Capture-wait (PRIMARY) — direct poll-cadence, ≥80 % target

Measured with a counter in `dbus_refresh` (exactly one call per display poll
tick, `SH_DBUS_TRACE=1`) while the guest drove a continuous full-screen text
scroll — change rate ≫ any poll rate, so every poll finds damage and the tick
rate equals the effective poll rate = 1/interval. Same binary throughout; only
`SH_DBUS_UPDATE_MS` differs (a clean controlled comparison, and the "baseline"
row is the patched binary with the env unset = byte-identical stock 30 ms path).
4 × 2 s windows per config.

| Config              | poll ticks/s (measured) | poll interval | avg capture-wait | **capture-wait reduction** |
|---------------------|-------------------------|---------------|------------------|----------------------------|
| baseline (30 ms)    | 31.5                    | 31.7 ms       | 15.9 ms          | —                          |
| `SH_DBUS_UPDATE_MS=8` | 112.9                 | 8.9 ms        | 4.4 ms           | 72 %                       |
| `SH_DBUS_UPDATE_MS=4` | 229.5                 | 4.4 ms        | 2.2 ms           | **86 %**                   |
| `SH_DBUS_UPDATE_MS=2` | 448.3                 | 2.2 ms        | 1.1 ms           | **93 %**                   |

Measured tick rate tracks the theoretical 1/N almost exactly (N=4 → 250 ideal vs
229 measured; the small shortfall is real per-tick work — graphic_hw_update +
capture handler + encode wakeups — running slightly longer than N; honest and
expected). Cross-checked with `SH_CAP_TRACE=1`: streamhost `map_update`
(damage-rects/s) rose ~750/s (baseline) → ~1250/s (N=2), corroborating (it
under-reports the poll ratio because faster polls carry fewer dirty rects each).

**≥80 % of the capture-wait removed? YES** — **86 % at N=4, 93 % at N=2.**
**Knee = N=4 ms**: clears the bar with margin at half the timer-wakeup rate of
N=2, matching the ~250/s target. N=2 buys the last ~7 pts. N=8 (72 %) is under.

## 2. Total glass-to-glass (inject→wire) — keystroke echo

Keystroke stimulus at a clean FreeCom prompt; `t0` (CLOCK_REALTIME) → first wire
video AU carrying the echoed glyph, pixel-verified in the glyph's own cell
(cursor-blink-immune). Single-host clock (probe on the box, same kernel as
QEMU/QMP), following the rig's methodology. **inject→wire** includes capture-wait
+ libx264 encode (~5–10 ms) + WebTransport-to-wire, but NOT the browser's
decode+paint (a constant few ms on top for the true photon). 36 matched
trials/config.

| Config           | inject→wire p50 | p95     | **total reduction vs baseline (p50)** |
|------------------|-----------------|---------|---------------------------------------|
| baseline (30 ms) | 19.9 ms         | 39.1 ms | —                                     |
| N=4              | 11.4 ms         | 24.5 ms | **43 %**                              |
| N=2              | 8.4 ms          | 29.0 ms | **58 %**                              |

The **total** drops far less in percentage than the capture-wait does, because it
also carries the encode+transport floor the patch does not touch — exactly as
expected. But the **absolute** p50 shave (baseline→N=2 = 11.5 ms; →N=4 = 8.5 ms)
is essentially the whole capture-wait landing on the wire. Against a true
browser-photon total (add a constant decode+paint), the percentage would be
smaller still; the honest headline is the capture-wait figure in §1.

## 3. Option 3 (stretch) — event-driven emit — sketch only (not built)

Option 1 already clears the bar, so this was not built. Sketch: drive
`graphic_hw_update(con)` from the guest framebuffer-dirty path instead of only
the poll timer. In the VGA/console layer, when the framebuffer MemoryRegion is
dirtied (the same dirty-log the scanout already consults), `qemu_bh_schedule` a
coalesced handler that runs `graphic_hw_update` + emit, guarded by a min-interval
timer (≥1–2 ms) so a busy guest cannot exceed a rate cap; keep the 30 ms/3 s poll
as the idle fallback. Effect: removes the average-wait term entirely (floor ≈
handler+encode, ~1 ms) — the theoretical max (~100 % of the wait) vs Option 1's
86–93 %. Cost/risk: touches the shared console/VGA path (all backends), needs the
rate cap to avoid encode-starving a busy guest, and buys only ~1–2 ms over N=2 —
low ROI once Option 1 ships. Pursue only if a future target needs sub-ms capture.

## 4. Option 4 (bonus) — guest-side refresh on a bridge tile — analysis (not run)

Applies only to the bridge tiles (c64/atarist/apple2/amiga), whose in-guest
Linux KMS/X kiosk composites at ~60 Hz and adds ~8 ms of its own *before* QEMU
polls — orthogonal to and additive with the QEMU patch. Prototype path on a
sandbox clone (no rebuild): raise the guest X modeline/refresh to 120–240 Hz
(halves/quarters that ~8 ms compose term) and re-run the §2 rig against the
bridge clone. Not executed this session (all four bridge tiles are live and a
bridge boot is heavy); N/A to plain-VGA text tiles, where the QEMU poll binds —
which is exactly what Option 1 fixes.

## Production rollout — DONE (fleet-wide 2026-07-13, commit `9228b7c`)

Option 1 shipped exactly as recommended: a **pve-qemu quilt patch** (steps in
`streamhost/qemu-patches/README.md`) with **`SH_DBUS_UPDATE_MS=4`** (the knee)
baked into every tile launcher (canaried on freedos first — `SH_DBUS_TRACE`
poll rate ~230-250/s, glass-to-glass re-run — then fleet-wide), **paired with
idle-auto-pause**: the patch is env-gated and the idle gate caps paused guests
back at the stock 30 ms poll, so the fast scan is only paid while a tile is
running (watched). Cost is timer wakeups only — an unchanged surface emits
nothing (dirty-bitmap check), no extra bytes/frames. Live deployment details:
the AS-DEPLOYED section at the top.

## Reproduce

Patched binary + clone live under `/data/vms/sandbox/` (kept for follow-up).
Harness (also in `streamhost/qemu-patches/harness/`, shellcheck-clean):
`launch-qemu.sh` (env: `QEMU_BIN`, `SH_DBUS_UPDATE_MS`, `SH_DBUS_TRACE`),
`launch-streamhost.sh`, `measure.sh <label>` (cadence),
`g2g-run.sh <label> <ntrials>` (inject→wire, uses the rig `wt_probe.py` +
`g2g_key_inject.py`/`g2g_key_detect.py`).
