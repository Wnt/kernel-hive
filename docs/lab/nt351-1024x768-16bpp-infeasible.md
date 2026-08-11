# NT 3.51 at 1024×768×16bpp: INFEASIBLE with stock QEMU (findings)

> **RESOLVED 2026-07-28 — now LIVE.** The "infeasible with *stock* QEMU" conclusion
> below still holds, but the user chose to fix QEMU itself. A second parallel round
> root-caused + patched the QEMU Cirrus bug (source-independent ROP1 fill dropped NT's
> text-row clears): `streamhost/qemu-patches/0004-cirrus-blt-rop1-fill.patch` +
> [trace analysis](nt351-cirrus-blt-trace-angle.md). The patched binary is installed
> isolated at `/opt/qemu-cirrusfix/` (only nt351 uses it); nt351 is live at
> 1024×768×65536, verified clean. See `docs/guests/nt351.md`.

**Goal:** bump the `nt351` exhibit to 1024×768 × 65536 colors (16bpp) rendering
**cleanly** (no scroll/drag/icon corruption).

**Result: not achievable with stock QEMU + NT 3.51.** Reached via the
[hard-problem methodology](HARD-PROBLEM-METHODOLOGY.md) — four parallel, bounded
agents, each a distinct angle on its own clone. All four are proven dead-ends
(framebuffer evidence on each `nt351hi-*` branch).

## Why every graphical path corrupts or can't reach the mode

| Angle | Approach | Verdict | Evidence |
|---|---|---|---|
| A | keep isapc+Cirrus, QEMU `isa-cirrus-vga,blitter=off` | ❌ | `blitter=off` **discards** BLT commands (`bitblt_ignore` in QEMU cirrus_vga.c) → nothing repaints; Write invisible, 3/3 runs |
| B | keep device set, disable Cirrus **driver** accel via registry | ❌ | `Acceleration.Level=5` + `DisableHWAcceleration=1` both **ignored**; `cirrus.sys`/`cirrus.dll` import **no registry API** and are `noconfig` in video.inf → no software-only path exists; 3/3 corrupt |
| C | `-M pc,acpi=off -vga std` (no blitter) + VBE miniport | ❌ | `-M pc` **boots NT 3.51** (isapc not required), but every VBEMP miniport (2007/2015, VBE20/30, 486+Pentium) fails to service-load → falls back to VGA 640×480×16; can't reach the mode |
| D | `-M pc,acpi=off` + PCI `cirrus-vga` (more VRAM) + accel/blitter off | ❌ | NT 3.51 Cirrus miniport never **binds** to PCI Cirrus GD5446 → falls back to `vga.sys` 640×480×4bpp; can't reach the mode |

## Root cause (the box we're in)
Clean rendering requires **no accelerated blitter**. Under stock QEMU + NT 3.51:
- The **only** NT 3.51 driver that reaches 1024×768×16bpp is the **ISA Cirrus
  miniport**, and it **always** issues accelerated BLTs — which QEMU's Cirrus
  emulation misrenders (the original scroll/drag corruption; guest-side, confirmed by
  raw QMP screendump). The driver **cannot be told to stop accelerating** (no registry
  API in `cirrus.sys`/`cirrus.dll` — proven at the binary level, Angle B).
- Turning the accelerator off in **QEMU** (`blitter=off`) just **drops** the blits →
  nothing renders (Angle A).
- The **clean, non-accelerated** path (standard VGA) tops out at **640×480×16** — no
  higher-res NT 3.51 miniport (VBE or PCI-Cirrus) will load/bind (Angles C, D).

**Therefore the clean ceiling is 640×480×16 (the current live checkpoint).** There is no
clean 800×600 or 1024×768 or higher-colour mode: every higher mode routes through the
corrupting Cirrus blitter.

## The only path to clean 1024×768×16bpp
**Patch QEMU's Cirrus BLT emulation** (fix the misrendered BitBlt in
`hw/display/cirrus_vga.c`) and build/deploy a patched `pve-qemu`. This is achievable —
the corruption is a QEMU emulation defect, fixable in code — but heavyweight: a custom
QEMU to build, deploy, and maintain across upgrades. Only worth it if 1024×768×16bpp is
a hard requirement for this exhibit.

## Decision
Pending the user: keep the clean **640×480×16** (recommended), invest in the **QEMU
cirrus-BLT patch** for clean hi-res, or accept the **corruption at 1024×768×16bpp**
(not recommended — reintroduces the reported bug).
