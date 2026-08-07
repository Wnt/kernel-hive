# ToaruOS gallery tile

**Status: clean rebuild and restart reset verified (2026-07-14).** Tile
`toaruos` is a LiveCD: the remastered `image.iso` is the complete artifact.
There is no writable disk and no QEMU vmstate snapshot. The manifest therefore
uses `resetMode=restart`; relaunching QEMU discards all in-RAM changes and boots
the ISO from its initial state.

## Source and content bake

The builder deliberately pins [ToaruOS v2.3.2](https://github.com/klange/toaruos/releases/tag/v2.3.2),
which GitHub reported as the latest upstream release during this trial. The
stock 7,483,392-byte ISO is checked against SHA-256
`b1dc51bd48f2b4613237185c9acb1a9beb13ab6acdd2e01d9722f77343e4c9ea`.

`scripts/build-guests/toaruos.sh` then injects the repo's six launcher stubs
into `/ramdisk.igz`, exposing ToaruOS's built-in Mines, Pong, Julia Fractals,
Plasma, Calculator, and Image Viewer applications on the desktop. The stubs add
no third-party binaries. This xorriso remaster is content-repeatable but not
byte-reproducible: generated ISO and gzip timestamps can change the final hash.
The stock ISO hash is the durable integrity pin.

## Clean rebuild trial

The final builder was run with direct, empty output and work directories:

```sh
OUT_DIR=/data/vms/soltest/repro-toaruos-1784059437/out-clean2 \
WORK_DIR=/data/vms/soltest/repro-toaruos-1784059437/work-clean2 \
  ./toaruos.sh
```

Download, checksum verification, ramdisk/ISO remaster, launcher-equivalent KVM
boot, and framebuffer capture completed in **68.82 s**. The remastered
`image.iso` was **14,548,992 bytes**; this trial's non-pinned SHA-256 was
`96728f0082d187b424d3c2aec037b25842429ce85d5ca5904b197c475825cb81`.
The inspected 1920×1080 framebuffer showed a fully painted Yutani desktop, the
active first-run welcome window, and all six injected application icons.

The verifier now matches the manifest's guest-visible device set: `pc`, KVM,
host CPU, 1 GiB RAM, 2 vCPUs, `std` VGA, AC97, and USB tablet. Its display and
audio backends are headless substitutes. VNC uses a namespaced Unix socket, so
verification does not reserve or collide on a TCP port.

## Restart reset proof

A separate launcher-equivalent trial boot captured the ready first tutorial
page, used the USB tablet to click **Next**, and captured the changed in-RAM
frame. QEMU was stopped via its own QMP socket/pidfile, then the same ISO was
cold-started again. Excluding only the 30-pixel panel containing the live clock:

```text
baseline -> dirty: 2,384 differing pixels
baseline -> restart: 0 differing pixels
```

Both baseline and post-restart framebuffers were inspected and showed the same
initial welcome page. This proves the documented cold-restart reset; ToaruOS
does not need a per-boot disk overlay because the guest has no writable disk.

## Rebuild fixes and pitfalls

- Added direct `OUT_DIR` and `WORK_DIR` overrides; all bake/runtime scratch now
  stays below `WORK_DIR`.
- Replaced fixed TCP VNC `:61` with a unique Unix socket.
- Updated verification from stale TCG/PS2-like arguments to the manifest's
  KVM/host-CPU and USB-tablet contract. `VERIFY_ACCEL=tcg` remains available.
- Increased the ready-state wait to 60 seconds.
- Delete old proof images before boot and wait for `screendump` to finish. Before
  these fixes, a stale or partially written PNG could satisfy the size-only
  success gate.
- The welcome dialog is expected for the builder artifact and does not block
  the desktop. The separately curated live fixture may suppress it and focus a
  terminal; that box-side curation is not part of this builder.

No licensed external asset is required.
