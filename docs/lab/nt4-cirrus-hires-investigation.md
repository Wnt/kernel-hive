# NT4 Cirrus 1024x768x16 investigation and promotion

Investigation and promotion date: 2026-07-28. Verdict: **PROMOTED**.

The first investigation proved the winning i440fx plus ISA-Cirrus device set
but stopped safely when fresh-process `-loadvm golden` restored a corrupt
blue/lavender framebuffer. QEMU patch
`0005-cirrus-isa-vmstate-descend-substruct.patch` fixed that blocker. A new
clone then passed the complete three-run gate, and production `nt4` was
promoted to accelerated 1024x768x16bpp with true-absolute vmmouse.

## Acceptance-first tooling

The clone-only gate is `scripts/dev/nt4-cirrus-acceptance.sh`; its guarded
launcher is `scripts/dev/nt4-cirrus-clone-launch.sh`. Both require a path below
`/data/vms/soltest/nt4-cirrus-*`, assert the QMP and pidfile through
`clone-guard`, reject a QEMU process that references a production station, and pin
the executable used for the promotion to:

```text
/data/vms/soltest/cvmstate-trace-20260728T084646Z-14233/qemu-fixed-clean
-L /usr/share/kvm
```

The accepted binary is pve-qemu 11.0.2 with patches 0004 and 0005 and has
SHA-256
`ce53f2f9b2dad95774811af0eba93563eda8206d3b2bc4f9f8948f40ece2e073`.
The gate captures raw QMP PPMs for the mode panel, five pointer targets, ten
Notepad Page Downs, live window motion, settled window redraw, and a desktop
icon move. It saves `golden` once and repeats the sequence from a new
`-loadvm golden` QEMU process three times, followed by one final clean load.

## Option A: PCI Cirrus on i440fx

Clone:

```text
/data/vms/soltest/nt4-cirrus-20260728T070630Z-GJyobY/
```

Device set:

```text
-enable-kvm
-machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3
-device cirrus-vga
```

The clone cold-booted and vmmouse remained active, but NT4 stayed on its
640x480 VGA driver. The SP6 `cirrus.sys` and `cirrus.dll` were staged, the
`cirrus` service was enabled, and NT4's own Display Type installer selected
`Cirrus Logic 544x Compatible Graphics Adapter`. After reboot, Display Type
still reported `vga compatible display adapter`; List All Modes contained only
640x480 and 800x600 at 16 colors. The `cirrus\Device0` key acquired requested
resources but no hardware-identification fields, confirming that the miniport
did not bind to QEMU's PCI GD5446.

Key framebuffers:

- `option-a-cold-60s.ppm` — SHA-256
  `8cd8be31da0c13410547880a51a9a6efb3bad6cb80ccab66bc03178e07987cfd`
- `display-type-after-install.ppm` — SHA-256
  `7bfdb90eb2fdc7c03603a4dec4cd19e58c01d1c1fb5f1f23152718949a824380`
- `list-modes-after-install.ppm` — SHA-256
  `9ea0d5046c9705e6db413385dba686ccb31dbde8183bc1f9f599266d93af9f69`

## Option B: ISA PC

Fresh clone:

```text
/data/vms/soltest/nt4-cirrus-isafresh-20260728T074009Z-eyoH9H/
```

Both `-cpu 486` and `-cpu pentium` on `-machine isapc` stopped during kernel
startup with `INACCESSIBLE_BOOT_DEVICE (0x0000007B)`. The failure reproduced
from a fresh curated disk before Cirrus was enabled, with the ISA NIC removed,
and with the disk's logical CHS forced to its NTFS BPB geometry of 255 heads /
63 sectors. The boot-start `atapi.sys` service and file were present, but this
prebuilt NT4 installation did not bind the isapc IDE controller.

Key framebuffers:

- `option-b-fresh-first-boot.ppm` (486) — SHA-256
  `557139865334fa32fec070e62d6f667f72d26c81ddbcf054ffa7dddc497db728`
- `option-b-fresh-pentium.ppm` — SHA-256
  `f4a648864f4f78cc2fad63b949ce52599f909155fa80f3c5bd40ba39a0e1ba97`
- `option-b-forced-geometry.ppm` — SHA-256
  `77e63e6f5648b3fdeea8dbec49e21412044184b456e7268ba29d55abb1f4414a`

## Best achievable: i440fx plus ISA Cirrus

A bounded hybrid retained the working i440fx storage/HAL and vmmouse while
presenting Cirrus on the machine's ISA bus:

```text
-enable-kvm
-machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3
-device isa-cirrus-vga,global-vmstate=on
```

NT4's 544x driver bound as `CL 5430` with 2 MiB of video memory and cold-booted
cleanly at 1024x768x16bpp. The active hardware-profile values were:

```text
DefaultSettings.BitsPerPel = 16
DefaultSettings.XResolution = 1024
DefaultSettings.YResolution = 768
DefaultSettings.VRefresh = 70
```

`a-isa-settings-1024-selected.ppm` visibly shows `65536 Colors` and
`1024 by 768 pixels` (SHA-256
`b61f639f204e68bf1fcccf5f28712dbb2c17152e41ee7887c6b1c1b6fb5ac1ff`).
The clean cold-boot framebuffer is `a-isa-clean-coldboot.ppm` (SHA-256
`abf402bab32564554da30f2cb0085c0bfe97a7a9c6e0e79da778434ad90bdcf6`).

### Pointer

Vmmouse survived. On the clean 1024x768 framebuffer, requested client
fractions and detected cursor bounding-box origins were:

| Target | Expected pixel | Observed pixel |
| --- | ---: | ---: |
| 10%, 10% | 102, 77 | 102, 76 |
| 50%, 10% | 512, 77 | 512, 76 |
| 90%, 10% | 922, 77 | 921, 76 |
| 25%, 75% | 256, 576 | 256, 575 |
| 75%, 75% | 768, 576 | 767, 575 |

This is 1:1 within the one-pixel integer-coordinate boundary. The five source
frames are under `preaccept-pointer/` in the fresh clone.

### Cold-boot rendering

`acceptance-cold-clean/` contains one complete adversarial run started from a
cold boot, without a snapshot restore. Notepad's ten Page Downs, both settled
window positions, and the moved Briefcase icon render cleanly:

- `run-1-04-pgdn-10.ppm` — SHA-256
  `205f85c26e9c8ad36accf06d7bbdecdd149e9a0d1679433db906b5e8228c5c9d`
- `run-1-06-window-drag-left-settled.ppm` — SHA-256
  `ee56cabeb6254176a1832b2822c167b7eaa3695de3072ecffc96ea9255577354`
- `run-1-08-window-drag-right-settled.ppm` — SHA-256
  `ece39d6841362e13745f6c1bbd53ea00067aa5e9af79215e0a99983cabf449c9`
- `run-1-10-icon-moved.ppm` — SHA-256
  `a50600571436e9be49e3d2cbec4084e92ca352aea2360e164ca15e3a06881b04`

### Historical `loadvm` failure

The clean pre-save idle pair was byte-identical:

```text
e262c63dc71d140a25848926bb69b189e349c9d9df558b1bd782a45272092ff4
```

A fresh process using the byte-compatible hybrid device set and
`-loadvm golden` produced a different, visibly wrong blue/lavender framebuffer.
Its two no-input frames were byte-identical to each other, proving a stable bad
restore rather than capture noise:

```text
f39c586fafaa0a18bb5cd277ad7e381a4b43ed55e20658c4aaeda7c7e1830983
```

The same test was recaptured under TCG in:

```text
/data/vms/soltest/nt4-cirrus-tcg-20260728T082415Z-shHLYf/
```

TCG also changed a correct teal pre-save framebuffer
(`7bd462291cc7a951fc6aac5acd97c7f0f5d85d65b1bec4943d9304b0c46e9b3b`)
to the bad blue/lavender state after fresh-process load
(`44d831db1102279e56a98fd787a0e3645df5c5ad666a7fed25fdeaf2e944d1f1`).
Thus the failure is not KVM-specific.

`acceptance-pure-loadvm-corrupt/` contains the three-run snapshot-restored
sequence. Every run begins in the wrong color interpretation; window and icon
motion also leave persistent horizontal artifacts. This fails the required
clean-render and byte-identical `loadvm` gates even though cold boot and
vmmouse are otherwise good. The root cause and QEMU-side trace are documented
in `docs/lab/nt4-cirrus-vmstate-trace-fix.md`.

## Fixed-binary acceptance and promotion

The successful clone and proof root is:

```text
/data/vms/soltest/nt4-cirrus-promote-20260728T-SAP4aj/
```

The authentic SP6a `cirrus.sys` and `cirrus.dll` payloads were installed, the
Cirrus CL 5430 adapter was selected, and Display Properties visibly reported
`65536 Colors`, `1024 by 768 pixels`, `70 Hertz`. `acceptance/` contains 86 PNG
counterparts to the raw QMP framebuffers from the final-only review set.

All 11 decisive raw idle PPMs—stable pre-save pair, post-save, each of three
fresh-process load pairs, and the final fresh-process pair—are byte-identical:

```text
4f35ac3b50ee031543781740209f21bc9d5f30ca9ac978ca01c10b2d2c30db42
```

Every Page-Down sequence, live window outline, settled window, and icon move is
clean in all three runs. Raw pointer targets differ from the requested screen
fractions by at most one pixel.

Production uses the same guest-visible device set and:

```text
/opt/qemu-cirrusfix2/bin/qemu-system-i386 -L /usr/share/kvm
```

The production disk backup is
`/data/vms/streamhost/tiles/nt4/nt4-golden.qcow2.bak-preHiRes-20260728T110112Z`.
The launcher and `tile.env` have matching timestamped backups. `live-proof/`
contains a visible live mode panel, `labctl` pointer and keyboard proofs, stable
raw idle frames, and genuine UI screenshots. The UI decoded 1024x768 with no
console errors; its five browser-driven pointer targets land within two pixels,
and browser Ctrl+Esc visibly opens the Start menu.

The clone QEMU was reaped through `clone-guard`. NT 3.51,
`/opt/qemu-cirrusfix`, the system QEMU, and all unrelated stations were untouched.
