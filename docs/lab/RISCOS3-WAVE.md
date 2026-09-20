# RISC OS 3.11 integration wave — 2026-09-20

RISC OS **3.11** (29 Sep 1992) on the **Acorn Archimedes 310** (1987), Tier 1,
host-native under a per-station MAME build (`SUBTARGET=aa310`, driver
`aa310`, `src/mame/acorn/aa310.cpp`, status **preliminary**). Tracking:
issue #47, prep branch `riscos3`. Scaffolded `--like apple2gs` for the
registry row shape and the shared host-native
`stations/mame-native/x11-runtime.sh` launcher convention only — the two
machines share nothing else (different driver, different keyboard/mouse
device model, no checkpoint support on `aa310`).

## Ledger — from `scripts/dev/wave.sh alloc riscos3`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 213 / 54213 / 213 |
| x11warp display | — (not allocated: host-native MAME, no in-guest X) |
| retronet address / MAC / tap / chain / UIN | — (none this wave — seed says "do not let networking block the desktop exhibit") |
| sibling (`--like`) | `apple2gs` |
| hardware tuple | `paramTower\|homeCrtD\|none\|paramMouseD` (apple2gs's own `pizzaBoxB\|homeCrtD\|none\|paramMouseD` tuple was already taken; `stations-registry.py new` printed the free combinations) |
| render orders | as scaffolded by `stations-registry.py new --like` — never hand-edited |
| device set | no extra devices: RISC OS 3.11 is ROM-resident on the `aa310`/bios=311 romset, no disk attached |
| media | staged under labhost `/data/assets-staging/riscos3/` — see Media below |

**Retronet: intentionally absent** — the integration seed calls for "no
networking blocking the desktop exhibit" in the first wave. No
`rn-tapnet.sh` is committed for this station (rule 15).

## Media — staged, hashed, pinned

Source: archive.org `mame-0.264-roms-non-merged` (a mirror of MAME's own
released romsets, matching the fleet-pinned MAME family exactly by member
sha1 — verified below, not trusted by filename).

| File | Bytes | SHA-256 |
|---|---|---|
| `aa310.zip` | 5211558 | `04d17d96963816721219691857af17e6439ae30088ebf2e89fac9d8b12d7194b` |
| `archimedes_keyboard.zip` | 1323 | `1d02b14cd4d2ff80a343c3afb1ba43de0bd77815952816fc19d0736f8644664e` |

Extracted to loose files (34 members) under `/data/assets-staging/riscos3/`
for `stage-romset.py`'s per-member sha1 match against the pinned binary's own
`-listxml`; `MANIFEST.sha256` (zips) and `MANIFEST-members.sha256` (loose
files) both live there. Verified with the system MAME 0.264 package
(`/usr/games/mame`, whose driver/romset metadata matches the fleet's pinned
0.289 for this driver): `mame -verifyroms aa310` → `romset aa310 is good`.

`bios=311` selects RISC OS 3.11 (`0296,041-02.rom`..`0296,044-02.rom`, four
524288-byte halves) plus `cmos_riscos3.bin` (the CMOS/RTC seed byte) and the
shared `archimedes_keyboard` MCU romset
(`acorn_0280,022-01_philips_8051ah-2.bin`).

## Smoke proof — MEASURED 2026-09-20 08:56 UTC

Command (system MAME 0.264, Xvfb `:1` on CT950, `import`-captured window):

```
mame aa310 -bios 311 -rompath roms -skip_gameinfo -sound none -window \
  -nomax -resolution 1024x768
```

`aa310` is `status="preliminary"` in `-listxml`, so the driver's own "known
problems" nag panel shows regardless of `-skip_gameinfo` (that flag only
skips the ordinary game-info screen); one keypress past it, and ~6 s later
the machine reaches the **RISC OS 3.11 Desktop**: mid-grey backdrop, icon
bar along the bottom (floppy icon at `:0`, an Apps directory viewer icon,
palette + Acorn icons at the right), pointer visible mid-screen. Frame
captured at `/data/vms/sandbox/riscos3-work/smoke/poll-6.png` (not
committed — binary artifact; the registry poster hero at
`spa/public/posters/riscos3/desktop.webp` still carries the copied
apple2gs placeholder and needs replacing from a real riscos3 rig frame).

The `mame-irix-skip-warnings.patch` (already in the tree, applied to every
`preliminary`/`imperfect` MAME native build via `NATIVE_SKIP_WARNINGS=1`)
removes that keypress for the exhibit itself.

## Native build

`scripts/build-guests/emulators/native.d/riscos3.sh` — driver `aa310`,
`NATIVE_SOURCES=src/mame/acorn/aa310.cpp`, `NATIVE_GEOM=1024x768`,
`NATIVE_MAME_ARGS=(-bios 311)`, `NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)`,
`NATIVE_SKIP_WARNINGS=1`. No pointer-correction patches — `aa310`'s own
quadrature mouse ports are a different device model from every MAME native
station shipped so far (apple2gs/macsys1's ADB HLE, oberon's kh-ramabs);
they are unmeasured and out of scope for the first proof.

Build kicked off in the background on labhost at 2026-09-20 09:16 UTC:
```
bash scripts/build-guests/emulators/build-mame-native.sh riscos3 \
  /data/vms/sandbox/riscos3-work/BUILD-native-riscos3 \
  /data/vms/streamhost/assets/riscos3/mame-native/aa310
```
log: `/data/vms/sandbox/riscos3-work/native-build.log` on labhost. This
clones/builds MAME from source (ccache-shared per the operator's standing
rule) — expect a real compile even warm, since this is the FIRST native
build of the `acorn/aa310.cpp` translation unit in this tree.

## Sandbox verdict

**No container.** `riscos3` is an EMULATED MACHINE under a per-station MAME
binary; the visitor's reach ends at the emulated Archimedes 310. The
launcher line is the shared host-native one:

```
streamhost/stations/mame-native/x11-runtime.sh
  MAME_NATIVE_BIN=/data/vms/streamhost/assets/riscos3/mame-native/aa310
  MAME_NATIVE_DRIVER=aa310
  MAME_NATIVE_ARGS=-bios 311
```

## Open at hand-off

- [ ] Native MAME build finish + `native_boot_gate` framebuffer proof (drawshm, non-black floor)
- [ ] `mame-keymap.py` KEYDUMP against a live `riscos3` ctlsock → real `riscos3.keymap` (placeholder committed, empty)
- [ ] Keyboard proof: normal text into a Filer/window, `MAME_CTL_KEY_EXCL` bisect if characters drop
- [ ] Pointer: measure `:keyboard:MOUSE.0/1/2` gain/calibration, or make the deliberate call to ship keyboard-only for the first release (the seed's own stop condition names Arculator/CLK as a host-X11 fallback if MAME's mouse cannot be made deterministic — not attempted yet, budget permitting)
- [ ] `smoke-rig.sh` publish at `/os/riscos3` — its QMP-socket precondition does not fit a MAME-native rig verbatim (no QEMU dbus display); needs the same placeholder-socket + stream.env repatch every other MAME-native station's smoke rig used
- [ ] Real hero frame in `spa/public/posters/riscos3/desktop.webp` (currently the copied apple2gs placeholder from the scaffold)
- [ ] `checkpoint-guard`/golden bake is N/A — `aa310` has no MAME savestate support (`savestate="unsupported"` in `-listxml`); reset is cold-boot relaunch only
