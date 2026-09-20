# its guest — MIT ITS on a SIMH PDP-10 (KS10)

Status: **PROVEN ON THE FRAMEBUFFER 2026-09-20** (Tier 3 host-native container, no checkpoint).
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
ch    Chaosnet, node 177002, listener 44042            (REQUIRED — see below)
dz    DZ11, lines=8, 8b, telnet listener               (line 0 is the visitor)
cpu   set cpu its · set cpu idle · set tim y2k · set console wru=034
```

The upstream config's extra `at -u dz0 line=7` (VT52) and `line=6` (GT40)
listeners are dropped — the station publishes exactly ONE terminal. No network plane at all: ITS spoke ARPANET NCP and Chaosnet, neither
has anywhere to go here, and the station is an island on purpose. The DZ telnet
listener lives on the container's own loopback behind `--private-network`, so it
claims no host port and is unreachable from labhost.

| Part | Value |
|---|---|
| Simulator | `assets/its/tree/tools/simh/BIN/pdp10` (KS10, `VM_PDP10 USE_INT64`) |
| Seed disk | `assets/its/tree/out/simh/rp0.dsk`, bound read-only, `cp --reflink=auto` into `work/rp0.dsk` on every launch |
| Boot | `b rp0` — ITS boots unattended; see "the DSKDMP dance does not apply" below |
| Display | pinned Xvfb `:116`, `1024x768x24` inside the container |
| Visitor client | one `xterm`, 80x31, DejaVu Sans Mono `-fs 14`, measures 964x748 px, placed `+30+10` to centre it; `telnet -E 127.0.0.1 10004` |
| Capture | `SH_CAPTURE=x11` (X root) |
| Input | `SH_X11TEST_KEYS=1`, keyboard only — a 1967 timesharing terminal has no pointer |
| Network | none |

Launcher `streamhost/stations/its/x11-runtime.sh` (contained, the medley shape)
execs `nspawn-inner.sh`, which stages `work/`, writes the SIMH ini and execs the
lane's shared engine `shared-terminal-runtime.sh`.

## Three things that are specific to ITS

**Chaosnet is not optional.** With the `ch` device absent, ITS gets as far as
`Salvager 261` and then prints

```
CHAOSNET INTERFACE NOT RESPONDING (CHECK THE BREAKER ON THE UNIBUS)
BUGHALT.  FIND A WIZARD OR CONSIDER TAKING A CRASH DUMP.
```

and drops into DDT. The 1967 kernel expects the hardware to be there. It does
**not** need a reachable peer — the configured peer never answers and ITS boots
anyway, complaining only that it could not set its clock from the network
("No host responded ... run :PDSET"). It needs the *interface* to answer. Both
Chaosnet ports live on the container's own loopback behind `--private-network`
and claim nothing on the host. This was a boot-and-a-half to learn and it is
the single most likely reason a future device-set change breaks this station.

**The DSKDMP dance DOES apply — do not believe the first read.** The generated
`out/simh/boot` ends in `b rp0`, which makes it look as though ITS boots
unattended under `EMULATOR=simh` and the upstream README's `DSKDMP` /
<kbd>ESC</kbd><kbd>G</kbd> dialogue is a KLH10-only concern. It is not: `b rp0`
loads DSKDMP, which prints ` DSKDMP` and waits for a system name and then an
ESC-G. Three variants were measured:

| ini | result |
|---|---|
| `expect "DSKDMP" send "its\r"; go` | DSKDMP sits forever; no further output |
| two rules, ESC-G on an `after=` timer | the ESC raced the filename — DSKDMP read `$`, then `Gits`, and answered `FNF` twice |
| `expect "DSKDMP" send delay=200000 "its\r\033G"; go` | `Salvager 261`, then ITS in operation |

The last is what ships. Finding 3 of the shared runtime still holds, and is the
point: SIMH answers this dialogue **itself** from the ini file, so there is
still no pty/expect supervisor in the container, the simulator stays the single
supervised process, and the `mame.pid` + `/proc/<pid>/exe` contract is
unchanged.

**Readiness is a console line, not the port.** SIMH's `at -u dz0` binds the
telnet listener while the ini file is still being read, long before ITS exists;
a client started on the port alone attaches to a dead line. ITS prints

```
SYSTEM JOB USING THIS CONSOLE
```

on the PDP-10's **own console** when it is up and ready to be logged in to.
The console is the simulator's stdout, which the shared runtime captures to
`work/emulator.log`, so `ITS_READY_LOG_RE` matches it directly. The neighbouring
`DB ITS 1652 IN OPERATION` line comes first and reads better, but is **not**
used: ITS prints a BEL inside it (`DB ITS 1652\a IN OPERATION\a`), so the
obvious regex silently fails to match. The version number is not pinned either —
it increments with each self-build.

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
- Boot: **32 s** from launcher start to a live DDT session (measured 2026-09-20,
  launcher return to return).
- Keyboard proof: **PASS** — `:LISTF` typed over XTEST echoed byte-perfect at the
  DDT prompt and ITS answered `DSK: 0; .FILE. (DIR) - NON-EXISTENT DIRECTORY`;
  `:LISTF SYS;` then printed the real system directory, timestamps running from
  1977 to 1987, behind a `--More-- (Space=yes, Rubout=no)` pager.
- Pointer: N/A — the exhibit publishes none (`stream.pointer.present=false`).
- Deterministic-reset proof: **PASS** — `:LISTF SYS;` scrolled the screen to
  49472 lit px; relaunch brought the greeting back at 13586; and the seed's
  `sha256` `7974e21b959164ebbe8125643b6932cc895111e268550119befcd6fce4401a90`
  was byte-identical before and after. The work copy diverges from the seed
  within one session (`51b4be6d…`), the seed never does.
- Media pin: `rp0.dsk` 317132800 B
  `7974e21b959164ebbe8125643b6932cc895111e268550119befcd6fce4401a90`;
  `pdp10` 1548856 B
  `6173472cb707d9ed34654e5fdbde5c84b7e59011c3c2221fe58d86f8620b3e10`.
- Credentials reference only (never values): `guest/its` — ITS has no passwords
  at all, which is the exhibit rather than an oversight; the container, not the
  guest, is the security boundary.
- Rollback: the station is new, so rollback is `enabled: false` in
  `registry/stations/its.json` plus a fleet re-emit. Nothing else depends on it.
