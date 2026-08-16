# Add Classic Mac OS 7.5.3 — plan (native m68k `q800`)

Plan for [`Wnt/osgallery#26`](https://github.com/Wnt/osgallery/issues/26), the
predecessor repo's exhibit request. Follow
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) for anything this file
does not contradict; the phases below map onto its sections.

**The tracking issue stays on the predecessor repo.** Nothing is mirrored here;
the acceptance criteria are restated in current terms in the last section, and
this file is the working contract.

## Decisions (operator, 2026-08-16)

| Question | Decision |
|---|---|
| Which version | **7.5.3**, outright. Not 7.1, and no fallback dance. |
| Station id | **`macos753`** — id == `stationDir` == `SH_STATION`, and the name must not lie about the version. Slot **142**, udpPort **54142** (next after `tru64` at 141). |
| Autonomy | Build, install, bake, wire, deploy **live**, green gate, merge to `main`. |
| Pointer calibration | Ship `scale 1.0` with linear mouse tracking baked into the checkpoint; operator eyeballs and re-calibrates later if it is not 1:1. |

## What is actually new here

The issue frames this as a routine native-QEMU exhibit. It is not: **the whole
fleet launches only `qemu-system-x86_64` (47 call sites) and `qemu-system-i386`
(3). There is no foreign-architecture QEMU station today.** The two non-x86
exhibits reached their architecture by other means — `w2kalpha`/`tru64` run the
`es40` Alpha emulator, `irix` runs MAME. So the first deliverable is not a
station, it is a **build**: a working `qemu-system-m68k` that still carries the
kernel-hive fork's own patches.

## Phase 1 — build `qemu-system-m68k` from the kernel-hive fork — **DONE**

Built 2026-08-16 on labhost from `github.com/Wnt/qemu` @ `kernel-hive`
(`73f67ff`), QEMU **11.0.2** — the same upstream version as the installed
`pve-qemu-kvm 11.0.2-1`.

```sh
../configure --target-list=m68k-softmmu --enable-slirp --enable-dbus-display \
  --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
  --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-m68k
ninja qemu-system-m68k
```

**Answers to the questions this phase existed to ask:**

- **Do the fork's patches survive on a non-x86 target?** Yes, and the question
  was mis-framed. `0001-dbus-display-fast-poll` touches only `ui/console.c` and
  `ui/dbus-listener.c` — both arch-neutral. Verified in the binary:
  `SH_DBUS_UPDATE_MS` and `SH_DBUS_TRACE` are present.
- **Is there an x86/PS2 assumption in "the fastpoll input path"?** There is no
  such thing — fast-poll is a *display* patch. The low-latency **input** device
  is `gallery-hid-pci`, which is PCI and therefore simply unavailable on q800
  (no PCI bus). It is also not needed: the generic dbus `Mouse.RelMotion` path
  drives the ADB mouse.
- **Does dbus scan out the q800 framebuffer, and at what geometry?** Yes.
  QMP `screendump` off a ROM-only boot returned a live `P6 640 480` frame with
  the arrow cursor drawn. The geometry is **not** fixed as assumed — `macfb`
  accepts `640x480` / `800x600` at depth 1,2,4,8,24 and `1152x870` at depth
  1,2,4,8, selected with `-g WxHxD`.
- **Packaging.** Standalone build under `/opt/`, **not** a `pve-qemu-kvm` .deb
  rebuild. Precedent: `nt4` already runs `/opt/qemu-cirrusfix2/bin/qemu-system-i386`
  (`streamhost/stations/nt4/qemu-streamhost.sh:62`). The `pbs-state` objection in
  `qemu-patches/README.md` only bites when a **pve-baked** checkpoint is loaded by an
  upstream binary; a checkpoint baked by this binary and loaded by this binary is
  self-consistent, and a fleet-wide .deb swap for one station is not a trade
  worth making.

**Also settled here — can q800 `savevm` at all?** This was the unstated risk
that could have killed the exhibit, since the whole checkpoint/reset plane is
`savevm`/`loadvm`. `target/m68k/cpu.c` carries `vmstate_m68k_cpu`, and `macfb`,
`mac_via`, `q800-glue`, `esp`, `dp8393x`, `swim`, `asc`, `adb-kbd` and
`adb-mouse` all carry a `VMStateDescription`. Proven in practice at Phase 3.

## Phase 2 — media (agent-sourced) — **DONE**

Staged on labhost, hashed, never committed. Provenance for
`ASSETS-MANIFEST.md`, class **preservation-source**:

| Artifact | Source | sha256 |
|---|---|---|
| `800.ROM` (1 MiB, Quadra 800) | archive.org item `800_20250604` | `05ad753f…6b09ca` (md5 `69489153dde910a69d5ae6de5dd65323`) |
| `System753 691-1079-A.iso` (268 MB) | archive.org `Macintosh-68K-PPC-System-7.5.3-Bootable-ISO`, Apple part **691-1079-A** | zip `b65d41bd…9e19dc` |
| `macos753-retail.toast` (268 MB) | archive.org `96073-016AU…_CD` (retail 96073-016A) | `ab3382fe…9e3b5d` — held as the fallback image |

## Phase 3 — install to a checkpoint

Reference automation worth reading first: `matthewdeaves/QemuMac` (cloned to
the build dir). Three corrections it forces on the recipe originally planned
here:

- **`-boot d` does nothing on q800.** Boot device selection is a **PRAM patch**:
  write `ffff` + `~(scsi_id + 32)` as two big-endian bytes at offset **120** of
  the PRAM image.
- **SCSI IDs are HD=6, CD=3**, not HD=0.
- **The machine needs an audiodev or it refuses to start** — the Apple Sound
  Chip is not optional. `-M q800,audiodev=audio0 -audiodev …,id=audio0`.
  (Hit this for real: `Initializing audio stream failed`.)

Install-time traps that remain true:

- The first HDD partition must be **≤2 GB** or the disk will not boot after
  install. The image is 2 G, single partition.
- On ≤7.6.1 the disk is initialized with **"Apple HD SC Setup"**, not Drive
  Setup. `QemuMac` drives plain `scsi-hd` with no vendor/product override, so
  no SCSI inquiry spoofing is needed.

Then bake the checkpoint per playbook §4.3 — capture on a copied disk, verify the
retained tag independently. The scene is a **quiet** Finder desktop: no open
About box, no menu pulled down.

**Bake into the checkpoint, before it is captured:** Mouse control panel set to
the **linear / slowest tracking** setting. Classic Mac OS applies its own
pointer acceleration curve, so 1:1 gain is unreachable while acceleration is on
— this is a prerequisite for Phase 4, not a polish item.

## Phase 4 — pointer

The q800's mouse is **ADB relative**: no absolute path, no USB tablet. The
station therefore runs `InputBackend::DbusRel` (`SH_INPUT_BACKEND=dbus-rel`),
the same backend `nt351` uses.

The plan originally carried tinycore's technique here. It does not apply —
tinycore runs an absolute USB tablet that the *guest kernel* re-reads as
relative, which q800 has no equivalent of. What matters instead:

1. **The "first cursor move lands at an arbitrary offset" problem is already
   solved in the daemon.** `dbus-rel` performs a deliberate corner-slam on the
   first sample of a session (`streamhost/streamhost/src/input.rs:377`, "FIX 4:
   HOME on seed"), pins the guest cursor to a known 0,0, and tracks from there.
   No launcher-side corner-slam is needed, and none should be added.
2. **Gain.** With acceleration off in the guest, `cursor_scale` should be
   **1.0**. Shipped unverified by operator decision; the framebuffer-verified
   1:1 check is an operator eyeball pass, not a launch gate.

## Phase 5 — station wiring, deploy, acceptance

Ordinary playbook work, in order: §5 input transport → §6 registry
(`registry/stations/macos753.json`, streamhost station dir, serve/reset/operator
maps, runtime UI manifest, cold-boot video) → §7 supervised deploy and the
acceptance matrix.

- **Idle auto-pause is mandatory.** m68k runs under **TCG** — no KVM — so an
  idle station burns real CPU. Declared from day one.
- **TCG latency needs measuring, not assuming.** Use
  [`MEASUREMENT-METHODOLOGY.md`](../MEASUREMENT-METHODOLOGY.md) and state a
  number. Poor interactive latency is a finding about the *tier*, not a defect
  in this station — and worth knowing before HP-UX/SunOS are planned on the
  same pattern.

## Acceptance (restated in current terms)

1. Mac OS 7.5.3 boots to the Finder desktop (Happy Mac on the way) and streams.
2. Pointer tracks relatively via `dbus-rel` with guest acceleration off and
   `cursor_scale` 1.0; 1:1 confirmation is an operator pass.
3. Checkpoint reset returns to the quiet Finder scene.
4. `registry/stations/macos753.json` exists and `make station-registry-check`
   passes.
5. Idle auto-pause proven: station at ~0 % CPU with no visitor.
6. The full quality gate is green.

## Why this is worth doing beyond the exhibit itself

It validates the **`qemu-system-<arch>` + dbus display** pattern for the whole
foreign-architecture wing. HP-UX 11i (HPPA), SunOS 4.1.4 (SPARC) and Mac OS
9.2.2 (PPC) are all catalogued as native QEMU stations and all waited on the
Phase 1 build question — which is now answered: the fork builds, its patches are
arch-neutral, dbus scans out, and a standalone `/opt/` binary is the packaging.
