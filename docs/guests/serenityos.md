# SerenityOS gallery tile

**Status: source rebuild and restart reset verified (2026-07-14); display bumped
to 1920×1080 (2026-07-27).** The tile boots a directly loaded SerenityOS kernel
with a raw ext2 root attached as NVMe. The root must be writable, but the rebuilt
`_disk_image` is the read-only base: every launch deletes and recreates a qcow2
overlay. There is no vmstate snapshot; the manifest therefore uses
`resetMode=restart`.

## Display resolution

The tile runs a **single-head 1920×1080** framebuffer (16:9, full-era-correct).
WindowServer reads `[Screen0] Width`/`Height` from `/etc/WindowServer.ini` inside
the base `_disk_image` at start; the QEMU device set is unchanged (`-vga std` =
QEMU stdvga, the Bochs/VBE packed-linear framebuffer that SerenityOS' BochsDisplay
drives — default 16 MB vgamem covers 1920×1080×32bpp = 7.9 MB, single head). The
display path drives this 1:1 (see `docs/lab/tile-resolution-responsiveness.md`),
and the streamhost daemon's abs pointer scaling is derived from the live surface
geometry, so it maps across the full 1920×1080 surface.

Set two ways, kept in sync:

- **Reproducible (builder):** `scripts/build-guests/serenityos.sh` step 4d edits
  `[Screen0]` Width→1920 / Height→1080 offline with `debugfs` on the packed
  `_disk_image` (same no-mount pattern as the desktop-shortcut step 4c), so a
  from-scratch rebuild comes up at 1920×1080.
- **Live golden (box):** the same offline `debugfs` edit was applied to the
  running tile's base image `/data/gallery-guests/SerenityOS/_disk_image` (the
  hand-curated golden fixture — autostarted Terminal, desktop shortcuts — is
  preserved; only the two resolution keys changed; uid/gid/mode 13/13/0664 kept;
  `e2fsck -fn` clean, still plain ext2). The pre-bump image was backed up to
  `/data/gallery-guests/SerenityOS/_disk_image.bak-res1024x768` for rollback:
  `systemctl stop streamhost@serenityos` → restore that file over `_disk_image` →
  `systemctl start streamhost@serenityos`.

Verified live: journal `[encode] geometry changed 1024x768 -> 1920x1080, re-opening`
then steady `geometry 1920x1080 … out 1920x1080`; framebuffer screendump shows the
full-width taskbar and the complete desktop-shortcut column with the desktop
intact.

## Source contract

`scripts/build-guests/serenityos.sh` deliberately pins SerenityOS commit
`55c5f6336d074a8fa2402fc897e859a9b7458ceb` (2026-07-02). SerenityOS is a
rolling source project, so this known-good commit is retained rather than
tracking `master`. The GitHub clone and all pinned-commit toolchain downloads
resolved during the trial. No licensed asset is required.

The build creates or reuses a dedicated privileged Debian 13 LXC, builds the
GNU cross-toolchain and SerenityOS as an unprivileged `builder`, packs the ext2
image as root through the upstream genext2fs fallback, and copies the kernel and
disk to `OUT_DIR`. Host-side QEMU scratch, sockets, logs, pidfile, and the
throwaway overlay stay under `WORK_DIR`.

## Rebuild trial

The trial began with a nonexistent CT 112 and empty namespaced output. The clean
cross-toolchain plus 6,385-target OS compile took **2,321.42 s** after dependency
repair. The final incremental image/content/boot verification pass took
**88.78 s**. Across all failure-discovery and confirmation attempts, measured
builder time was **2,741.72 s (45m41.72s)**.

The final invocation exercised the direct path overrides:

```sh
OUT_DIR=/data/vms/soltest/repro-serenityos-1784060537/out-final2 \
WORK_DIR=/data/vms/soltest/repro-serenityos-1784060537/work-final2 \
SERENITY_CTID=112 ./serenityos.sh
```

Final trial artifacts:

| artifact | bytes | trial SHA-256 |
|---|---:|---|
| `_disk_image` | 1,549,250,560 | `dce9d48bfbbc40d4e5e5b0e5647b4d15c397635556bb68b209468ab3b813c93e` |
| `Kernel/Kernel` | 15,954,000 | `658c13e1f4fcc9f6d1feb5a44c874f4c3c9025b2cb29961bc637a9f652c85cb7` |
| `Kernel/Kernel.efi` (optional/unused) | 15,465,788 | `11bbe46b7fbdf4223ba1db51237c2ca35d72cb1bed3df93f07e2780a96350e68` |

The hashes record this build, not a byte-reproducibility promise. The offline
ext2 edit passed `e2fsck -fn`. Its directory listing proved that the stock
Browser, Text Editor, Help, and Home entries plus Solitaire, Minesweeper, Snake,
Chess, 2048, Spider, Calculator, and PixelPaint were all present.

The builder then booted with the manifest's guest-visible device model: KVM,
`q35`, host CPU, 2 GiB RAM, 2 vCPUs, `std` VGA, AC97, direct multiboot kernel,
and NVMe root overlay. The inspected 1024×768 QMP framebuffer (the pre-bump
default; see **Display resolution** above) showed the ready desktop, all added
icons, and a fully painted focused terminal at the shell prompt.

## Restart reset proof

The emitted `boot.sh` was run twice against the final artifacts with its own
Unix VNC/QMP sockets. On the first boot, `resetdirty` was typed visibly into the
focused terminal. QEMU was stopped through its own QMP socket/pidfile. The next
launch deleted and recreated `verify-overlay.qcow2` (inode changed from 220190
to 210454) and cold-booted the same base image.

All three framebuffers were inspected: baseline prompt, dirty prompt containing
`resetdirty`, and post-restart clean prompt. Excluding only the 30-pixel bottom
panel with its live clock/resource graphs:

```text
baseline -> dirty:   322 differing pixels
baseline -> restart:   0 differing pixels
```

This proves both halves of the reset contract: the root is writable during a
session, and relaunch discards that session's overlay without modifying the raw
base.

## Rebuild fixes and pattern rot

- Added the pinned upstream build requirements `zlib1g-dev` and `qemu-utils`.
  Their absence broke binutils (`zlib.h`) and image packing (`qemu-img`).
- Recover an interrupted `Toolchain/Local/x86_64` when the linker is missing,
  and remove the old Kernel before compiling so a stale artifact cannot hide a
  failed incremental build.
- Fixed the shortcut existence probe. `debugfs stat` exits zero even for a
  missing path; the builder now requires an actual `Inode:` result.
- Added direct `OUT_DIR`/`WORK_DIR` overrides and namespaced Unix VNC/QMP
  sockets instead of fixed TCP VNC `:7`.
- Made the verification boot match the streamhost launcher: `std` VGA rather
  than `bochs-display`, plus AC97 and local-time RTC. The writable root always
  uses a fresh qcow2 overlay over the raw base.
- Increased the post-WindowServer settle to 12 seconds so the proof captures
  the completed desktop and terminal paint.
- Corrected the optional EFI-kernel source path to
  `Kernel/EFIPrekernel/Kernel.efi`; the direct multiboot tile does not use it.
