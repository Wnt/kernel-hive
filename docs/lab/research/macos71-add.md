# Add Classic Mac OS 7.1 — plan (native m68k `q800`)

Plan for [`Wnt/osgallery#26`](https://github.com/Wnt/osgallery/issues/26), the
predecessor repo's exhibit request. Follow
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) for anything this file
does not contradict; the phases below map onto its sections.

## What is actually new here

The issue frames this as a routine native-QEMU exhibit. It is not: **the whole
fleet launches only `qemu-system-x86_64` (47 call sites) and `qemu-system-i386`
(3). There is no foreign-architecture QEMU station today.** The two non-x86
exhibits reached their architecture by other means — `w2kalpha`/`tru64` run the
`es40` Alpha emulator, `irix` runs MAME. So the first deliverable is not a
station, it is a **build**: `third_party/qemu-kernel-hive` (fork
`github.com/Wnt/qemu`, branch `kernel-hive`) must produce a working
`qemu-system-m68k` that still carries the fork's own patches.

That reframing is the plan's main content. Everything downstream (install,
pointer, registry, deploy) is well-trodden.

## Phase 0 — decide two things before any work

**0.1 Which version.** The issue asks for **7.1**; the catalog
(`docs/catalog/os-media-catalog.md` §3) calls **7.5.3 the sweet spot** and it
carries the same museum value (MV 5), the same ROM, and materially better
tooling support (E-Maculation walkthroughs, `matthewdeaves/QemuMac`
automation). 7.1 is the more distinctive *exhibit* — earlier, more austere,
pre-"Mac OS" branding. Recommend **7.1 as the exhibit, 7.5.3 as the fallback
if install choreography stalls**; the decision costs nothing to defer until
media is in hand, but it must be made before the golden is baked.

**0.2 Where the issue lives.** This request is filed on the predecessor repo.
Kernel Hive is the successor and its terminology has moved (`tile` → `station`,
`registry/tiles/` → `registry/stations/`). Mirror the issue here, or accept
that the tracking issue stays in the old repo — either is fine, but the
acceptance criteria must be restated in current terms:
`registry/stations/macos71.json`, not `registry/tiles/macos71.json`.

## Phase 1 — build `qemu-system-m68k` from the kernel-hive fork

The gating phase. Nothing else can start.

1. Add `m68k-softmmu` to the fork's configured target list and build it.
2. **Verify the fork's own patches survive on a non-x86 target.** The
   kernel-hive branch carries display and input work (`-display dbus,p2p=on`,
   the fastpoll input path). These were written and exercised against x86
   machines; assume nothing. The specific questions to answer, from code:
   - does the dbus display backend scan out the `q800` framebuffer at all, and
     at what geometry (the q800's video is fixed-mode, not a resizable VGA)?
   - does the fastpoll input path have any x86/PS2 assumption? The q800's
     mouse is **ADB**, its keyboard is ADB, and there is no USB.
3. Decide packaging: does the m68k binary ship alongside the x86 one from the
   same build, or as a separate asset under `/data/vms/streamhost/assets/`?
   Follow whatever the existing QEMU build script does; do not invent a second
   convention.

**Exit criterion:** `qemu-system-m68k -M q800 -bios <rom> -display dbus,p2p=on`
puts a Happy Mac on a framebuffer that streamhost can capture. Not a log line —
the framebuffer.

## Phase 2 — media (operator-gated)

Per playbook §3, preservation media is **supplied by the operator**, staged and
hashed on labhost, and **never committed**. Two artifacts:

| Artifact | Source | Note |
|---|---|---|
| `Quadra800.rom` (~1 MB) | Macintosh Garden ROM archive **DL#6** ("dumped from a Quadra 800, courtesy of Mac84"), or `Quadra800.rom` from `mac-rom-archive-20110819.zip` | MD5 published on the page — record it in `ASSETS-MANIFEST.md` |
| Mac OS 7.1 install CD (~80 MB) | Macintosh Garden "Mac OS install CD library", entry #1 | 7.5.3 fallback is `SYSTEM_7-5-3-RETAIL`, ~255 MB |

The gallery is private, so running any of this locally needs no approval — but
the bits stay out of git, always.

## Phase 3 — install to a golden checkpoint

Recipe (catalog §3), with `-display dbus,p2p=on` substituted per the fleet's
standard:

```
qemu-system-m68k -M q800 -m 128 -bios Quadra800.rom -display dbus,p2p=on \
  -drive file=pram.img,format=raw,if=mtd \
  -device scsi-hd,scsi-id=0,drive=hd0 -drive file=disk.img,format=raw,if=none,id=hd0 \
  -device scsi-cd,scsi-id=3,drive=cd0 -drive file=macos.iso,format=raw,if=none,id=cd0 \
  -boot d
```

Two install-time traps that are cheap to respect and expensive to discover:

- **The first HDD partition must be ≤2 GB** or the disk will not boot after
  install completes.
- **On ≤7.6.1 the disk must be initialized with "Apple HD SC Setup"**, not
  Drive Setup. `matthewdeaves/QemuMac` automates the whole dance and is worth
  reading before hand-driving it.

Then bake the checkpoint per playbook §4.3 — capture on a copied disk, verify
the retained tag independently. The scene is the Finder desktop, and it should
be a **quiet** one (no open About box, no menu pulled down): a checkpoint is
what every visitor sees first and what every reset returns to.

## Phase 4 — pointer, and the one honest risk

The q800's mouse is **ADB relative** — there is no absolute-pointer path on
m68k, no USB tablet, nothing like the NeXTSTEP absolute work. Delivery is the
`cursor_scale` **relative-mouse gain calibration** documented in
[`docs/guests/tinycore.md`](../../guests/tinycore.md): relative tracking with
edge re-homing, where the single `cursor_scale` sets the 1:1 gain and the
offset is a neutral origin rather than an absolute anchor.

Two properties of that technique the issue does not mention, and which shape
acceptance:

1. **Calibration must be measured on the LIVE station through a registered
   browser client.** No QMP/HMP offline injection moves the cursor under the
   production dbus launcher. Budget an operator-in-the-loop measurement pass
   (drive a mid-screen grid with `SH_DEBUG_INPUT=1`, read `recv`/`inject`).
2. **The first cursor move of a session lands at an arbitrary offset until the
   pointer first touches a screen edge.** That is inherent to a relative
   device. On tinycore it is a curiosity; on a *desktop* OS it is the visitor's
   first interaction. Decide deliberately: accept it, or have the launcher slam
   the cursor into a corner once at scene entry so the origin is anchored
   before anyone arrives. **Recommend the corner-slam**, baked into the golden.

The q800's fixed video geometry also means the calibration constant is a single
measured number for this station, not a per-resolution family.

## Phase 5 — station wiring, deploy, acceptance

Ordinary playbook work, in order: §5 input transport → §6 registry
(`registry/stations/macos71.json`, streamhost station dir, serve/reset/operator
maps, runtime UI manifest, cold-boot video) → §7 supervised deploy and the
acceptance matrix.

Two station-shape items specific to this exhibit:

- **Idle auto-pause is mandatory.** m68k runs under **TCG** — no KVM, no host
  acceleration — so an idle station burns real CPU. Every recently-added
  station declares idle pause; this one must too, from day one rather than as a
  follow-up. Confirm the pause/resume path behaves across a TCG guest.
- **TCG latency needs measuring, not assuming.** The issue says "verify latency
  stays low". Use
  [`MEASUREMENT-METHODOLOGY.md`](../MEASUREMENT-METHODOLOGY.md) and state a
  number. If interactive latency is poor, that is a finding about the *tier*,
  not a defect in this station — and it is worth knowing before HP-UX/SunOS are
  planned on the same pattern.

## Acceptance (restated in current terms)

1. Mac OS 7.1 boots to the Finder desktop (Happy Mac on the way) and streams.
2. Pointer is **framebuffer-verified 1:1**, with the session's first-move
   behaviour decided and implemented.
3. Golden reset returns to the quiet Finder scene.
4. `registry/stations/macos71.json` exists and `make station-registry-check`
   passes.
5. Idle auto-pause proven: station at ~0 % CPU with no visitor.
6. The full quality gate is green.

## Why this is worth doing beyond the exhibit itself

It validates the **`qemu-system-<arch>` + dbus display** pattern for the whole
foreign-architecture wing. HP-UX 11i (HPPA), SunOS 4.1.4 (SPARC) and Mac OS
9.2.2 (PPC) are all catalogued as native QEMU tiles and all wait on the same
Phase 1 build question. Mac OS 7.1 is the cheapest way to answer it — small
media, well-documented install, and a top-3 museum draw if it lands.
