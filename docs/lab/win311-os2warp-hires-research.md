# Win3.11 & OS/2 Warp 4 hi-res — driver research + clone-test queue

Status: research complete 2026-07-27 (7-angle parallel study + synthesis);
clone-testing in flight. This captures the ranked plan so the outcome docs in
`docs/guests/win9x.md` (win311) and `docs/guests/os2warp.md` build on it.

> **win311 SHIPPED 2026-07-27 — candidate 1 (`PluMGMK/vbesvga.drv`) passed on the
> first try.** Live at **1024×768×8** on `-vga std` (dacdepth=6; see the full recipe
> + the `dacdepth=8` savevm/loadvm palette-corruption gotcha in
> `docs/guests/win9x.md` → "Win311 hi-res SHIPPED"). 1280×1024×8 also validated but
> not shipped (curated PM layout fills 1024×768; lighter for the TCG tile).
>
> **os2warp SHIPPED 2026-07-27 — but by none of the candidates below.** The verdict
> to move to `-vga std` was right; the driver ranking was chasing the wrong root
> cause. IBM's in-box **GENGRADD** works on stock QEMU once the adapter is capped
> at **`-global VGA.vgamem_mb=2`**: GENPMI's mode tables hold 64 entries and
> SeaVGABIOS advertises 93 at the 16 MiB default, overflowing them (`c0000005`).
> No VESA-PMI (`4F0Ah`) is involved — no OS/2 driver in the chain calls it. Live at
> **1024×768×64k**; full write-up in `docs/guests/os2warp.md` → "SOLVED", tooling in
> `scripts/dev/os2-gengradd-hires.sh`, issue
> [#15](https://github.com/Wnt/kernel-hive/issues/15). The os2warp candidate list
> below is retained as the record of what was tried and why it failed.

## The verdict (unanimous)

Switch **both** tiles off `-vga cirrus` onto **`-vga std`** (QEMU Bochs
DISPI/VBE, `1234:1111`, default 16 MiB) and drive it with a **generic-VESA/VBE
guest driver**. This is the *same* packed-linear path the shipped win95
(1280×1024) and win98se (1600×1200) VBEMP tiles already run
(`docs/lab/tile-resolution-responsiveness.md`).

The real blocker on both targets is **chipset auto-detection, not lack of
acceleration**:

- **win311** — the Cirrus 5446 Win3.1 drivers set the mode but blank all GDI
  font glyphs via QEMU-11's broken colour-expand BitBLT (the 1bpp glyph-blit
  path). A generic-VESA driver has no BitBLT dependence → can't blank.
- **os2warp** — OS/2's `SVGA.EXE` cannot ID QEMU's emulated GD5446, so
  `\OS2\SVGADATA.PMI` is never written. A generic-VESA GRADD needs no
  chipset-detect and no PMI → sidesteps it.

## Capture-compatibility gate (applied hard)

`-vga std` is a dumb packed-linear framebuffer with **no hardware cursor**, so
every driver on it (a) presents a CPU-composited packed 32bpp scanout our
GPU-less dbus `ScanoutMap` capture reads exactly like the Win9x VBEMP tiles, and
(b) is forced to draw a **software cursor** into that framebuffer → always
captured.

Dropped as gate failures: **vmware-svga** (HW-cursor overlay invisible to our
capture, and no Win16/OS2 driver exists), **qxl / virtio-gpu-3D / virgl** (need
GL/DMABUF that can't init on a GPU-less box), **ati-vga** (QEMU-experimental,
HW-cursor overlay), **native cirrus** (proven dead on both). **86Box/PCem** with
real S3/Matrox cores: the drivers genuinely reach clean hi-res, but they are
different emulators exposing no QEMU dbus scanout — attaching would need a whole
new `CaptureSource::Vnc` (RFB) + input backend in the Rust daemon. Recorded as a
future heavy-hammer only if every `-vga std`/VBE path fails the readability gate.

## Ops constraint

cirrus→std is a **device-set change**, so `loadvm golden` won't match. Every
clone test cold-boots from the materialized golden disk
(`qemu-img snapshot -a golden`), installs the driver, verifies, **then**
`savevm golden` on the new std set. The warpd serial COM1 pointer agent is
device-set-safe and auto-restarts from the guest, so it survives the re-bake
(re-verify 1:1 landing at the new resolution). Both tiles stay TCG (OS/2
triple-faults under KVM; win311 is TCG today).

## Acceptance test (per clone, before any `savevm golden`)

A `labctl shot` framebuffer screendump must satisfy **all**: (a) readable glyphs
at ≥1024×768 — Program Manager title/menu/icon captions (win311) or WPS
desktop/folder/title text (os2warp), the exact thing cirrus blanks; (b) the
framebuffer settles bit-identical across ~3–5 samples over ~1s (no
tearing/corruption; never judge a single first-repaint); (c) the mouse/PM cursor
is present in the screendump (captured software cursor); (d) warpd move+click
lands 1:1 and a full-window drag repaints cleanly under TCG; (e) the daemon
journal shows `[capture] ScanoutMap <w>x<h>` packed + a served frame including
the cursor. Only on all-pass: `savevm golden` → fresh `-loadvm golden` re-verify
→ live cutover (launcher `-vga std`, registry regen, `labctl gen`).

## Ranked clone-test queue

### win311 (target 1024×768, then 1280×1024)

1. **vbesvga.drv (PluMGMK)** — lead, conf 0.8, medium. Maintained generic
   VBE-3.0 Win3.1x driver: GDI → RAM double-buffer → memcpy to the linear FB,
   software cursor, VBE mode-set; ships `VDDVBE.386` (fixes QEMU/SeaBIOS DOS-box
   corruption). Prefer 8bpp (dodges the PM 64 KB high-colour icon-segment limit).
2. **Japheth SVGAPatch'd MS SVGA256.DRV** — conf 0.6, low. `svgaptch -p` drops
   chipset-detect → generic VESA, CPU-rendered (no BitBLT blank), mode 0x105.
3. **SciTech Display Doctor 6.53 (free)** — conf 0.5, medium. Universal VBE.
4. **Shipped WfW SVGA/ET4000 + VGAPATCH P** — conf 0.4, low (highest artifact risk).

### os2warp (target 1280×1024, else 1024×768)

1. **IBM VIDEOPMI/BVHSVGA (no fixpak, no download)** — cheap probe, run FIRST,
   conf 0.3. The image already has IBM's SVGA stack; `SVGA.EXE` may now generate
   a usable PMI by probing the clean Bochs VBE. Near-zero cost.
2. **SciTech SNAP 3.1.8** — lead, conf 0.7, high. Freeware, self-contained
   generic-VESA GRADD, no chipset-detect/PMI; the archive.org `os2_snap.iso`
   bundles the required WP4FP15 fixpak.
3. **IBM GENGRADD + Warp 4 FixPak ≥5 (FP15)** — conf 0.6, high. Free, no
   commercial binary; needs the fixpak (GA GRADD is too buggy).
4. **Panorama VESA (free eCS v1.21)** — conf 0.45, high. ArcaOS default driver.
5. **Base-image swap to ArcaOS/eCS/Warp 4.52** — conf 0.85 but **last resort**:
   changes the exhibit's OS identity + a full reinstall. Only on a user decision
   if 1–4 all fail the readability gate.
