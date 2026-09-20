# its guest — MIT ITS on a SIMH PDP-10 (KS10)

Status: **IN BRING-UP 2026-09-20** (Tier 3 host-native container, no checkpoint).
Wave record: [`../lab/ITS-WAVE.md`](../lab/ITS-WAVE.md).
Shared runtime contract:
[`../lab/record-wave/shared-terminal-runtime.sh`](../lab/record-wave/shared-terminal-runtime.sh),
proved end to end by [`vax43bsd`](vax43bsd.md) — this station's closest sibling
and the one to diff against when something here misbehaves.

## Identity and source

- Public ID / station dir: `its`; slot 216, UDP 54216, VMID 216, Xvfb `:116`.
  Container uid base 2424832 (37 × 65536).
- What it is: **MIT ITS**, the Incompatible Timesharing System, written at the
  MIT AI Lab from 1967, on an emulated **DEC PDP-10 (KS10)** under the SIMH
  build vendored by the ITS project. No QEMU, no MAME, no checkpoint: the
  exhibit is a simulator process plus one terminal, and **reset = relaunch**
  from the pristine built disk.
- **There is no media to source.** ITS was never a product and there is no
  distribution image to fetch. The maintained
  [`github.com/PDP-10/its`](https://github.com/PDP-10/its) tree assembles the
  entire system from its own MIDAS sources — the build boots a PDP-10 and
  builds ITS *inside* it — and leaves a bootable RP06 pack and the simulator
  that boots it in `out/simh`. That pack is the exhibit. Upstream pin
  `0f7d67997f9f5d30208e117e73272031e74f16b9`; the vendored SIMH is submodule
  commit `4d38373206cd7c0ce8b94f5e16bd4429cb96430f`.
- Builder: `scripts/build-guests/tiles/its.sh` — clones and pins the tree, runs
  `make EMULATOR=simh` on labhost, stages it atomically to
  `assets/its/tree`, writes `assets/its/MANIFEST.sha256`, and debootstraps +
  uid-shifts the container rootfs. Budget ~30 min on a quiet box; the long pole
  is the self-assembly, which is CPU-bound by design.

## Runtime and device set

```
rp0   RP06, work copy of the built out/simh/rp0.dsk   (the whole system)
dz    DZ11, lines=8, 8b, telnet listener              (line 0 is the visitor)
cpu   set cpu its · set cpu idle · set tim y2k · set console wru=034
```

No Chaosnet, no GT40 and no second VT52 — the station publishes exactly ONE
terminal. No network plane at all: ITS spoke ARPANET NCP and Chaosnet, neither
has anywhere to go here, and the station is an island on purpose. The DZ telnet
listener lives on the container's own loopback behind `--private-network`, so it
claims no host port and is unreachable from labhost.

| Part | Value |
|---|---|
| Simulator | `assets/its/tree/tools/simh/BIN/pdp10` (KS10, `VM_PDP10 USE_INT64`) |
| Seed disk | `assets/its/tree/out/simh/rp0.dsk`, bound read-only, `cp --reflink=auto` into `work/rp0.dsk` on every launch |
| Boot | `b rp0` — ITS boots unattended; see "the DSKDMP dance does not apply" below |
| Display | pinned Xvfb `:116`, `1024x768x24` inside the container |
| Visitor client | one `xterm`, `telnet -E 127.0.0.1 10004` (geometry/font: TBD, measured) |
| Capture | `SH_CAPTURE=x11` (X root) |
| Input | `SH_X11TEST_KEYS=1`, keyboard only — a 1967 timesharing terminal has no pointer |
| Network | none |

Launcher `streamhost/stations/its/x11-runtime.sh` (contained, the medley shape)
execs `nspawn-inner.sh`, which stages `work/`, writes the SIMH ini and execs the
lane's shared engine `shared-terminal-runtime.sh`.

## Three things that are specific to ITS

**The DSKDMP dance does not apply.** The upstream README tells you to answer a
`DSKDMP` prompt with `its`, then <kbd>ESC</kbd><kbd>G</kbd>. That is the KLH10
and `pdp10-kl` path. The generated `out/simh/boot` for `EMULATOR=simh` ends in
`b rp0` and ITS boots unattended, so there is no prompt to answer and no
pty/expect supervisor in the container — the simulator stays the single
supervised process and the `mame.pid` + `/proc/<pid>/exe` contract is unchanged.

**Readiness is a console line, not the port.** SIMH's `at -u dz0` binds the
telnet listener while the ini file is still being read, long before ITS exists;
a client started on the port alone attaches to a dead line. ITS prints

```
SYSTEM JOB USING THIS CONSOLE
```

on the PDP-10's **own console** when it is up and ready to be logged in to —
the exact line the upstream README tells a human to wait for. The console is the
simulator's stdout, which the shared runtime captures to `work/emulator.log`,
so `ITS_READY_LOG_RE` matches it directly and the ini needs no `expect` rule.

**^Z is how you log in, and the launcher types it once.** ITS does not greet a
terminal that connects to a DZ line — the boot chatter goes to the console, not
to line 0 — so without this the exhibit would open as an empty black terminal.
The launcher types one `^Z` at bring-up, gated on lit pixels rather than on the
keystroke, so the rest scene is a live DDT prompt. `^Z` is on the on-screen
keyboard too: a visitor who logs out needs it back.

## On-screen keyboard

Family `its` in `spa/src/ui/keyboard/keyboardProfiles.data.pc.ts`. The verbs of
this system are control characters, so they sit in an ALWAYS-VISIBLE base row
rather than behind "More" — a key one tap away is a key a visitor never finds:

| Key | Why |
|---|---|
| `^Z` | how you log in to ITS at all |
| `Altmode` | Esc — the 1960s name, and what ITS documentation calls it |
| `^X` | the Emacs prefix |
| `^C` | interrupt |
| `^L` | redisplay |

Deliberately **absent**: `^\` escapes to the SIMH `sim>` prompt and `^]` to the
telnet client. Both take a visitor out of the exhibit and into the plumbing.
`telnet -E` removes the `^]` escape at the client end as well, so it cannot be
reached even by a visitor with a real keyboard.

## Golden, input, and rollback

- Reset mode: `relaunch`. No checkpoint and no statefile — kill `pdp10` by
  `mame.pid`, wipe `work/`, copy the pristine `rp0.dsk` back, start again. A
  device-set change therefore costs a rebuild, not a re-bake.
- Keyboard proof: TBD (framebuffer).
- Pointer: N/A — the exhibit publishes none (`stream.pointer.present=false`).
- Deterministic-reset proof: TBD (write in the guest, relaunch, confirm gone,
  and `sha256sum` the seed either side to prove the immutable pack is intact).
- Credentials reference only (never values): `guest/its` — ITS has no passwords
  at all, which is the exhibit rather than an oversight; the container, not the
  guest, is the security boundary.
- Rollback: the station is new, so rollback is `enabled: false` in
  `registry/stations/its.json` plus a fleet re-emit. Nothing else depends on it.
