# Alternatives to QEMU-11 — exotic-OS unlocks & better graphics (research synthesis)

Status: research complete 2026-07-27 (6 parallel angles: QEMU-version landscape,
86Box/PCem, other x86 VMMs, exotic-OS emulators, patching our own stack,
capture/input integration). This synthesizes them into what's worth doing and in
what order. Companion: `docs/lab/win311-os2warp-hires-research.md`,
`docs/lab/os2warp-hires-pmi-handoff.md`.

## The one idea that reframes everything: the emulator barely matters — the capture path does

streamhost's pipeline is **already source-agnostic**. The encoder consumes only a
`Capture{ state: FrameState (BGRA + damage), damage: Notify }` and never touches
QEMU; input already has a backend trait (`RealtimeInputSink`, implemented by
`GalleryHidSink` + `WarpdSink`). The v1 copy-path `FrameState` fields
(`fb`/`note_damage()`) exist and are wired. So a new backend is "fill a
FrameState + implement one input sink." The single structural refactor is
`Capture → CaptureSource` (gating the QEMU-only appendages — dbus audio,
QMP idle-pause, `loadvm golden` — behind the QEMU variant).

That means the question "what can we adopt?" reduces to **two reusable capture
primitives**, one of which we already ship:

1. **The bridge pattern (already built, zero new Rust)** — a frozen Debian-12
   kiosk runs one full-screen SDL/X11 emulator; streamhost captures the *Linux
   guest's* dbus scanout + audio + injects input, exactly as it does for
   C64/Atari ST/Apple II/Amiga today (`streamhost/docs/BRIDGE.md`). Its **killer
   feature**: a `savevm golden` of the kiosk snapshots the **emulator's live
   RAM**, so it grants **instant golden reset to emulators that have no
   save-state of their own** (86Box, SheepShaver, Previous…). Cost: ~1.5 GB Linux
   guest per tile and ~8 ms extra compose latency.
2. **`CaptureSource::Vnc` (an optional ~1 wk RFB client)** — unlocks the "real
   x86 VMM" tier (Bochs/VMware/VirtualBox + any dbus-less QEMU fork) that can't
   cleanly nest inside a kiosk. Mature Rust crates exist (`vnc-rs`, `rust-vnc`).
   Reuses the same FrameState + input trait. Lower priority, because that tier
   turns out to unlock little (below).

Everything below is scored by **(what it unlocks) × (integration cost)** through
that lens.

## Part 1 — the one live blocker (os2warp): fix QEMU, don't switch emulators

**Two independent angles converged on the same root cause and fix.** os2warp's
`c0000005` crash is a **QEMU regression**: around QEMU 1.7 (2013) `-vga std`'s
BIOS was switched from the LGPL vgabios (which implements the VBE Protected Mode
Interface, fn `4F0Ah`) to **SeaVGABIOS, whose `vbe_104f0a()` is a deliberate stub
returning "unsupported."** OS/2's GENGRADD/SNAP call `4F0Ah`, get no PMI table,
dereference garbage `ES:DI` → access violation. OS/2 hi-res on `-vga std` *used
to work*; putting the PMI back fixes it — **preserving the Warp 4 identity and
the curated apps**, unlike the ArcaOS base-swap.

Crucially, **the vgabios is a standalone ROM blob, not compiled into QEMU** — it
can be swapped per-device with `-device VGA,romfile=<blob>`, so this needs no
QEMU device-model change and every existing golden `loadvm`s unchanged.

- **Variant B1 — cheap de-risk probe (hours):** build the LGPL Bochs vgabios
  (`bochs-emu/VGABIOS` v0.9c, actively maintained, *has* the PMI incl.
  set-palette) and `romfile=` it onto a soltest clone of the on-box
  4.52-with-apps build (`os2-452-mcp2-apps-preserved.qcow2`); install
  GENGRADD/SNAP; framebuffer-verify no `c0000005` + a settled readable
  1280×1024 WPS. Honest unknown: the legacy blob hardcodes an LFB base for bank
  ops — must verify an 8bpp LFB driver doesn't trip it, and the mode list may
  differ from SeaVGABIOS's.
- **Variant B2 — durable fix:** backport `4F0Ah` into SeaVGABIOS
  `roms/seabios/vgasrc/vbe.c` (return a valid PMInfoBlock — SetDisplayStart +
  SetPrimaryPaletteData stubs over the DISPI ports; the LGPL vgabios + malc's
  original patch are the reference, so it's a *port*, not from-scratch). Ship as
  the next `pve/00xx` quilt patch via `scripts/provision/build-pve-qemu-fastpoll.sh`, emit
  as a *separate* blob, `romfile=` only os2warp → other std tiles' goldens stay
  byte-identical. Purely additive (win95/98/311/xp never call `4F0Ah`).

**This is now the recommended os2warp path — cheaper and more surgical than
everything in issue #15** (which assumed writing a PMI from scratch, and ranked
86Box/ArcaOS higher). The one residual risk is whether SciTech's SDD engine is
satisfied by a *minimal* Bochs PMI — answerable by the B1 probe in hours behind
the framebuffer gate. **86Box (Part 3) is the fallback** if the PMI proves
insufficient.

## Part 2 — new exotic-OS exhibits (cheap, via the existing bridge)

The bridge pattern makes almost any Linux-runnable emulator a "one more tile"
add. Top picks by appeal × maturity × low effort:

1. **Classic Mac OS 9 / System 7** — SheepShaver (PPC) + Basilisk II (68k),
   actively maintained SDL apps. The biggest gap on the roster (we have modern
   macOS and the 8-bit machines, but not the iconic 1990s Mac). ★★★★★, LOW.
2. **NeXTSTEP / OPENSTEP** — Previous (built on Hatari, which the bridge base
   already carries). Arguably the highest story value in computing history.
   ★★★★★, LOW–MED.
3. **SGI IRIX 6.5** — MAME `indy_4610`; boots the teal 4Dwm desktop in ~45 s.
   Distinct from everything else; watch nested-MIPS CPU cost on the shared box.
   ★★★★★, MED.
4. **IBM MVS 3.8j mainframe (+ VM/370 CMS)** — Hercules + TK4-; a green-screen
   category the museum lacks; legally clean (public-domain MVS, **not** licensed
   z/OS). Console exhibit (full-screen tn3270). ★★★★, MED.
5. **BeOS R5** — plain `qemu-system-i386`, **no bridge needed** (it's x86, a
   normal tile). Cheapest high-appeal win; pairs with the existing Haiku tile.
   ★★★★, LOW.

Honorable: flip the dead **RISC OS 5** showcase poster into a *live* RPCemu
bridge tile; **SIMH** VAX/OpenVMS + PDP-11 2.11BSD as low-CPU serial/green-screen
exhibits. Skip on legality/maturity: z/OS (IBM-licensed), Apollo Domain/OS
(MAME crashy), HP-UX/Alpha (immature).

## Part 3 — better graphics for existing tiles

- **86Box (via the bridge) — the accelerated-graphics unlock.** Emulates *real*
  S3 Trio64/ViRGE, Matrox, Cirrus GD-5480 (working BitBLT), and **3dfx Voodoo**
  with genuine period drivers. It (a) is the **fallback os2warp fix** if the VBE
  PMI proves insufficient (a real S3 → OS/2 writes `SVGADATA.PMI` → accelerated
  hi-res), and (b) opens a **category QEMU can't touch on a GPU-less box:
  software-emulated 3dfx/Glide** → real 3D DOS/Win9x game exhibits. The bridge
  gives it free golden reset (it has no save-states). **Gate on a host
  single-thread benchmark** — 86Box is period-locked with no turbo: 486/early
  Pentium + S3 is comfortable; Pentium-II + Voodoo is the risk zone. Note the
  integration angle corrected a detail: 86Box's Qt VNC shows only menus, so it
  goes through the *bridge*, not RFB. GPLv2, separate process → no license
  entanglement.
- **DOSBox-X** — real S3/ET4000 Win3.x drivers + software Voodoo, and (unlike
  86Box) it has 100-slot save-states. A good pragmatic DOS/Win3.x/9x-games
  backend; DOS/Win-only, captured via the bridge (or Xvfb).
- **virtio-gpu 2D (non-GL)** — capture-safe (host pixman surface, no host GPU),
  gives dynamic resolution/multi-head, but only for guests with a virtio-gpu
  driver (almost none of the legacy fleet). Low-value nicety.

## Part 4 — dead-ends (documented so nobody re-treads them)

- **Software-GL 3D / virgl (`gl=on`)** — emits `ScanoutDMABUF`, which the capture
  listener has **no handler** for; making it work needs a whole new DMABUF/GBM/EGL
  import backend *plus* llvmpipe compositing a desktop in software on a GPU-less,
  30-encoder box. Breaks the CPU-composited-packed-scanout invariant the whole
  pipeline depends on. **No.**
- **VMware Workstation** — SVGA II is XP-and-newer; **no DOS/Win3.1/OS2 drivers**,
  proprietary, non-redistributable. Unlocks nothing `-vga std` doesn't. **Skip.**
- **VirtualBox** — legacy VBoxVGA ≈ `-vga std` (no graphics gain); its OS/2 GA
  driver is version-gated to MCP2 (identity change). Best snapshots, but low
  value. Distant maybe.
- **Fixing QEMU's cirrus BitBLT** — the glyph-blank is real (2017-era CVE
  hardening makes the blitter bail silently), but it's security-hardened,
  unmaintained legacy code (permanent carried liability) and **moot** since
  win311 shipped on `-vga std`. **Skip.**
- **A second/upstream QEMU version** — goldens carry a pve-only `pbs-state`
  vmstate section (upstream can't `loadvm`), and cross-version snapshot loads are
  fragile → a full fleet re-bake for no os2warp gain. Keep display fixes as
  additive vgabios/quilt patches *inside* pve-qemu. **Skip.**
- **Bochs as a fleet emulator** — patchable VBE BIOS + free `vncsrv` make it a
  clean single-guest compatibility *last resort*, but it's an interpreter (too
  slow) with shaky save-state. Reserve only.

## Recommended roadmap

1. **Now — os2warp VBE PMI (Part 1).** Run the B1 LGPL-vgabios `romfile=` probe
   on a clone of the 4.52-apps build behind the framebuffer gate. If clean, ship
   it (or promote to the B2 SeaVGABIOS quilt patch for durability). Only if it
   fails the readability gate, fall back to 86Box-via-bridge. This closes issue
   #15 while preserving apps + Warp 4 identity.
2. **When new exhibits are wanted — bridge adds (Part 2).** SheepShaver Mac OS 9,
   Previous NeXTSTEP, MAME IRIX, Hercules MVS, native-x86 BeOS R5, live RISC OS.
   Each is "one more bridge tile," zero new Rust.
3. **For the accelerated-graphics category — 86Box-via-bridge (Part 3),** gated
   on a host single-thread benchmark; delivers GPU-less 3dfx/Glide game exhibits
   QEMU can never produce, and the os2warp fallback.
4. **Optional infra — `CaptureSource::Vnc` (~1 wk)** only if a real x86 VMM
   (VMware/VirtualBox/Bochs) ever becomes worth hosting; today the VMM tier
   unlocks too little to justify it. The `Capture → CaptureSource` refactor it
   needs is small and worth doing whenever the first non-QEMU/non-bridge backend
   lands.

**Bottom line:** don't replace QEMU. The GPU-less dbus-scanout pipeline is right.
Fix os2warp with a per-tile vgabios that restores the VBE PMI QEMU used to ship;
grow the museum with the bridge pattern (exotic OSes) and 86Box (accelerated /
3dfx graphics); and keep an optional RFB capture source in the back pocket.
