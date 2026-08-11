# Windows 9x under KVM — reproducible recipe & root-cause

Investigated 2026-07-04 on the Proxmox dry-run labhost (`root@192.0.2.10`,
QEMU 11.0.0, Intel Xeon D-2146NT / Skylake-D). All results below are verified from
**framebuffer screendumps + vCPU register/IRQ inspection**, never logs alone. Work
was done on a namespaced copy of the Win95 station image in `/data/kvm9x-lab/` — the
live win95 station, its checkpoint `/data/gallery-guests/Win95/win95-osr2.qcow2`, VM 900/925,
CT 110 and the Solaris dir were never touched.

## Win311 hi-res SHIPPED — vbesvga.drv on `-vga std` @ 1024×768×8 (2026-07-27, LIVE)

The Cirrus hi-res paths below all failed the readable-glyph gate on QEMU 11 (text
blanks / palette corruption — a Cirrus GDI/BitBLT regression). The winning path is
the Win16 analogue of the shipped Win9x VBEMP recipe: **abandon Cirrus entirely,
switch the device to `-vga std` (QEMU Bochs DISPI/VBE, packed-linear 32bpp scanout,
software cursor) and install a GENERIC VBE display driver** that never touches
Cirrus acceleration. Live since 2026-07-27; `labctl reset win311` (loadvm golden)
restores it exactly.

**Driver = PluMGMK `vbesvga.drv`** (actively-maintained generic VBE-3.0 Win3.1x
driver; GDI → system-RAM double buffer → memcpy to the linear FB, so it *cannot*
hit the Cirrus BitBLT glyph-blank; ships a software cursor and `VDDVBE.386` for the
windowed-DOS-box VDD).

- Release `v1.0-beta4`, `vbesvga-release.zip` from
  `https://github.com/PluMGMK/vbesvga.drv/releases/download/v1.0-beta4/vbesvga-release.zip`
  SHA-256 `e4272c942b9330305af8c1388a1e56289913f4eb6dfcda4c4af1ba256e1a770f`.
- Files staged into `C:\WINDOWS\SYSTEM`: `VBESVGA.DRV`
  (`d03d373e1214839b79f78bb0e3ce9d7773e2de1a858092b4fc0d2b416d9c73d6`), `VDDVBE.386`
  (`dd6ab674e0ea84b9ded358cfd72f7d4b653df099e25a4a1690cb4c0824b28cc1`), `VBEVMDIB.3GR`
  (`c5b01b9c803f448cec2da1e3209758e3a9f99d671f023d15d42aa655c602d25c`).

**Install = offline, headless** (no GUI Setup): stop the VM, `qemu-nbd` the FAT16
C:, drop the three files into `C:\WINDOWS\SYSTEM`, and CRLF-preservingly edit
`SYSTEM.INI`:

```ini
[boot]
display.drv=vbesvga.drv
386grabber=vbevmdib.3gr

[386Enh]
WindowUpdateTime=15
display=vddvbe.386        ; was display=vdd54xx.386 (Cirrus VDD)

[drivers]
dci=display              ; was DCI=DCI54X6 (Cirrus DCI); Cirrus VPM= line removed

[vbesvga.drv]
Width=1024
Height=768
Depth=8
dacdepth=6
BounceOnModeset=1
```

- **`Depth=8` (256-colour, packed 1 byte/px)** is deliberate: it dodges Program
  Manager's 64 KB high-colour icon-segment limit (8bpp allows ~50 icons/group vs
  ~31 at 16bpp), keeps VRAM tiny (1024×768×1 = 768 KB, far under the 16 MiB std
  default), and matches the Win9x stations' packed-scanout capture path.
- **`dacdepth=6` is LOAD-BEARING — do NOT use 8.** With `dacdepth=8` the driver puts
  the Bochs VBE DAC in 8-bit mode, which QEMU 11 **does not restore across
  savevm/loadvm**: the cold-boot palette is correct but the `-loadvm golden` restore
  comes back with a shifted palette (magenta Program Manager title bar, black
  Clock/min-max glyphs). `dacdepth=6` uses the standard VGA 6-bit DAC (historically
  correct for Win3.x anyway), which survives the checkpoint round-trip with colours
  intact. This was caught by the mandatory post-`savevm`/`loadvm` re-verify — a fresh
  cold-boot screenshot alone would have missed it.

**Device set** now: `-accel tcg -m 64 -smp 1 -machine pc-i440fx-11.0 -cpu pentium
… -vga std …` (the ONLY launcher change is `-vga cirrus` → `-vga std`; SB16, ne2k,
COM1 serial for the warpd agent, and the two IDE checkpoint disks are unchanged). The
COM1 `AGENT.EXE` warpd pointer agent is device-set-safe and auto-starts; it reads
`GetSystemMetrics` so it lands 1:1 at 1024×768 with no code change.

**Acceptance (all framebuffer-verified on a `/data/vms/soltest/win311-vbesvga-*`
clone, then re-verified on the live station):** readable Program Manager title/menu/
group-icon glyphs; framebuffer settles bit-identical across samples; the software
cursor is present in the scanout; warpd `M x y` lands the cursor tip pixel-exact at
the commanded point; a group-window drag repaints cleanly (Win3.x outline-drag +
crisp reveal on release); and a streamhost points at it logging
`[capture] ScanoutMap 1024x768 stride=4096 fmt=0x20020888` (PIXMAN_x8r8g8b8, packed)
+ `first frame 1024x768 (shm=true)`. Live encode latency at 1024×768 is p50≈1.2 ms.

**1280×1024×8 also works** (just bump `Width`/`Height`; the driver mode-scores to it
and the settle/readability gates pass) — but 1024×768 was shipped because the
curated Program Manager window layout fills 1024×768 edge-to-edge (at 1280×1024 the
group windows only occupy the top-left, leaving a large empty desktop) and it is the
lighter egress/decode choice for this TCG station (the resolution study caps un-bumped
stations at ~1280×1024 anyway).

**Capture / cutover (what shipped).** Extract a consistent checkpoint-state C:/D: with
`qemu-img convert -U -l golden` (immutable snapshot read — safe against the running
station), inject the driver + `SYSTEM.INI` offline, cold-boot `-vga std`, run the
acceptance test, `savevm golden` on the std set, then a fresh `-loadvm golden`
re-verify of readable-glyphs + cursor + colours. Live cutover: `systemctl stop
streamhost@win311` → back up launcher + **both** checkpoints as `*.bak-cirrus-<ts>` →
`sed -i 's/-vga cirrus/-vga std/'` the launcher → copy **both** clone disks
(same-`savevm` VM clock) over `win311-golden.qcow2` + `games-golden.qcow2` →
`systemctl start streamhost@win311`. The launcher's `qemu-img snapshot -l | grep
golden` auto-adds `-loadvm golden`.

## Win311 Cirrus high-resolution clone trial: blocked on QEMU 11 (2026-07-15/16)

The requested Win311 move from Standard VGA 640x480x16 to Cirrus 1024x768x256
(with 800x600x256 as fallback) was proved only on namespaced copies under
`/data/vms/soltest/win311-hires-codex-20260715*`. The live station, launcher, and
checkpoint were not modified because neither Cirrus driver candidate passed the
settled-framebuffer gate. Every launch retained the production device set:
TCG, Pentium, `pc-i440fx-11.0`, `-vga cirrus`, SB16, NE2K PCI, and COM1, at
nice 15 under pve-qemu 11.0.2.

Exact inputs and results:

- Cirrus **CL-GD5446 Windows 3.1x Drivers and Utilities v1.31**,
  `K54462E.ZIP`,
  `https://ftpmirror.infania.net/sites/ct_treiber_service/treiber/cirrus/desktop/5446/k54462e.zip`,
  SHA-256
  `c5a1633f343029e38e79e4d32c0f99f0ac46fb75b8af08585dd6402eba549fac`.
  Install path: `C:\CIRRUS\INSTALL.EXE` -> Continue -> destination
  `C:\WINDOWS\VGAUTIL` -> Install -> `VGA Display` group -> completion ->
  WinMode -> select **256** colours and **1024x768** (then a separate clean
  trial at **800x600**) -> OK -> Restart Windows. 1024x768 painted icons and
  window geometry but blanked all GDI text. The 800x600 fallback still blanked
  title and menu glyphs after the desktop settled.
- Cirrus **GD5426/GD5428 Windows 3.1 Drivers v1.5** archive, whose Setup entry
  is **GD5426/28 v1.50e** (`256_1280.drv` reports v1.74, 149312 bytes,
  1995-05-27),
  `https://ftpmirror.infania.net/sites/Cirrus%20Logic/Cirrus%20Logic%20GD5426%20GD5428%20Windows%203.1%20Drivers%20v1.5.zip`,
  SHA-256
  `c0947038d3cb4094c8b82fea2bec26f73484d3c154a3f34c5b5620aaac326889`.
  Install path: `C:\CIR542X\INSTALL.EXE`, exit Windows, run
  `C:\WINDOWS\SETUP`, highlight Display, choose
  **GD5426/28 v1.50e, 1024x768x256 Smlfnt** (then separately
  **GD5426/28 v1.50e, 800x600x256**), keep the installed driver, accept, and
  restart Windows. Both modes settled with black Program Manager client
  surfaces, broken palette/text, and unusable groups.

The default QEMU Cirrus VRAM is 4 MiB; 1024x768x8 requires only 786432 bytes,
so no `vgamem_mb` change is justified. QEMU rejected 2 MiB, disabling the
Cirrus blitter made the display black, and `fontcaching=128` yielded only
partial glyph strokes. As a discriminator, Microsoft's 1993 CPU-rendered
SVGA256 supplement (`https://www.infania.net/misc/win31files/files/svga.exe`,
SHA-256 `2810f2312a183928c74cdae77c5475ffab071b22a0affb6806df8b2bf279f23b`)
produced a clean, settled **800x600x256** framebuffer on the same QEMU device
set. That proves the resolution, framebuffer size, and base Windows install are
viable; the blocker is the accelerated Cirrus Win3.1 driver path on modern
QEMU. It is not a compliant substitute for a Cirrus-driver capture, so it was not
promoted.

Keep the builder's Standard VGA patch until a future QEMU/driver combination
passes all clone gates: readable settled Program Manager at 1024x768x256 or
800x600x256, COM1 warpd corner/centre probes using the dynamic
`GetSystemMetrics` geometry, `savevm golden`, and a fresh exact-device-set
`loadvm golden` framebuffer check. Do not recapture live based only on a successful
mode set or the first transient repaint.

## Builder rebuild trial: Win95, then Win98SE (2026-07-14/15)

This is the reproducible scene-capture record for `scripts/build-guests/tiles/win95.sh`
followed by `scripts/build-guests/tiles/win98.sh`. Everything ran below one disposable
`/data/vms/soltest/repro-win9x-<timestamp>/` namespace with unique QMP sockets,
VNC displays, host-forward ports and pidfiles. The live stations and
`/data/gallery-guests` were read-only. Every state claim below was checked from a
QMP `screendump` that was converted to PNG and visually inspected.

| station | verdict | end-to-end wall | final checkpoint size | checkpoint round-trip | input result |
|---|---|---:|---:|---|---|
| `win95` | **PASS** | 29m 46s | 1,500,708,864 B (1.3 GiB allocated) | 25.6 MiB `golden`; fresh QEMU `-loadvm golden` reached desktop | warpnet TCP pointer probes landed exactly at (600,100), then (400,300) after restore |
| `win98se` | **PASS** | 69m 50s | C: 1,161,625,600 B (665 MiB allocated); D: 407,699,527 B (389 MiB allocated) | C: 84 MiB and D: 0 B snapshots at the same VM clock; fresh QEMU restore framebuffer was byte-identical | no warpnet by design; QMP USB-tablet absolute event landed at 75% x / 50% y |

The full cold Win95 builder spent 842s and built/injected its source disk; its old
verifier returned 2 because forced QEMU termination left ScanDisk running in the
90-second proof frame. The full cold Win98 builder spent 372s after a separate 34s
failed attempt exposed stdout logging contaminating a command-substitution path;
its old `acpi=off`/TCG verifier returned 1 on a flat PnP frame. The scene captures
were completed manually below. After correcting the builders, cached end-to-end
replays returned 0: Win95 injection in 9s (`VERIFY=0`, because acceptance used the
separate production KVM scene), and Win98 CAB injection plus its production-profile
framebuffer verifier in 136s.

### Hash-verified inputs and fixes discovered

- Win95 UTM ZIP: 351,717,750 B; MD5
  `9ccbf5b59f1ddf82f2ad007ff9471814`; SHA-256
  `9dfd213d1f58268a5e8214a0067121b63b76d6e7a6896c86efd5944f5dc7eedd`.
- Win98 VMware archive: 425,349,569 B; MD5
  `3d436db22042970b0fe56fbb138e9500`; SHA-256
  `08ba180d64e75972b019a9f3ef37c8cd153f40fa7b65fdcb228e0546865be47e`.
- Win98SE CD ISO: 655,591,424 B; MD5
  `7c32b76e1b8374597cb5ef58a22aa635`; SHA-256
  `2adfb46df8a9c7bbd2f67bff07461cc2f9d9ec8e01f0e112cb044c9e3e62f607`.
  This ISO was not present in the box asset cache and is not listed in
  `ASSETS-MANIFEST.md`; it was fetched from the builder's pinned archive.org item.
  The manifest explicitly says the Win95/Win98 source caches are purged, so those
  two archives were also re-fetched and verified rather than assumed present.
- The ISO contains 77 CABs. Copying only the 69 `WIN98_*.CAB` files fails at
  `pci.vxd`; the builder now stages all 77, including `DRIVER*.CAB`, and extracts
  the 9,296-byte `hidusb.sys` with the complete spanning-CAB chain adjacent.
- The README MinGW command produced an executable that raised an illegal-operation
  dialog on the emulated Pentium because the default i686 target may emit CMOV.
  The working command is
  `i686-w64-mingw32-gcc -O2 -s -mwindows -march=pentium -mtune=pentium -o warpnet.exe warpnet.c -lwsock32`;
  the resulting 18,432-byte agent is captured as `C:\WARPNET.EXE` via `WIN.INI load=`.
- Win95 no longer uses a loose archive.org regex for GTA. That regex selected an
  unrelated 837 MiB Rockstar collection with no `gtados` tree. Supply an explicit
  full `gtados` + `gtadata` ZIP through `GTA1_URL` or `payload/gta1.zip`.

### Exact Win95 one-time interaction transcript

`Enter` below means one QMP key-down/key-up pair. The first two entries occurred
during inspection of the old builder's blind-Enter settle window; they are retained
because this is the complete input record. The builder now defaults `SETTLE=0` and,
when explicitly enabled, sends no blind keys.

1. Pressed `Enter` on **New clock settings** to accept **OK**.
2. Left-clicked unused desktop space to clear the selected **My Computer** icon,
   then pressed `Esc` to remove the selection rectangle.
3. On the TCG/std-VGA driver-swap boot, pressed `Enter` on **Enter Network
   Password** (user `Steve Jobs`, blank password), `Enter` for **Next** in Update
   Device Driver Wizard, `Enter` for **Finish** on Standard PCI Graphics Adapter,
   and `Enter` for **Yes** at System Settings Change.
4. After restart, pressed `Enter` on the same blank Network Password dialog.
5. The first, non-Pentium warpnet build faulted. Pressed `Enter` for **Close**, then
   `Ctrl+Esc`, `U`, `Enter` for Start -> Shut Down -> default **Shut down**.
6. With QEMU stopped, replaced `WARPNET.EXE` with the `-march=pentium` build.
7. Cold-booted the exact production KVM/std device set and pressed `Enter` on the
   blank Network Password dialog. No other modal remained; the desktop framebuffer
   was clean.
8. Connected to the namespaced host-forward and sent `M 600 100\nQUIT\n`.
   The next screendump showed the cursor exactly at (600,100).
9. Issued HMP `delvm golden` (harmless if absent), `savevm golden`, and
   `info snapshots`; quit through QMP, started a brand-new identical QEMU process
   with `-loadvm golden`, and visually rechecked the desktop.
10. Reconnected to warpnet and sent `M 400 300\nQUIT\n`; the restored framebuffer
    showed the cursor exactly at (400,300). The two desktop captures differed only
    in the tray clock advancing by one minute.

The final Win95 checkpoint SHA-256 was
`b2fa51ca64d1c1547c2b548b3487242d7acf8b9cfa5ad0d1c5074283ef1dd305`.

### Exact Win98SE one-time interaction transcript

Before boot, the complete CAB set was injected at
`C:\WINDOWS\OPTIONS\CABS` and `hidusb.sys` at
`C:\WINDOWS\SYSTEM32\DRIVERS`. All boots used the production device set:
KVM, `pc,acpi=on`, Pentium III, std VGA, SB16, PCnet, and usb-tablet.

The repeated **search sequence** below is exactly:
`Enter` (Next), `Enter` (Search for best driver), `Space` (uncheck Floppy),
`Tab`, `Space` (uncheck Windows Update), `Tab`, `Space` (check Specify a
location, already `C:\WINDOWS\OPTIONS\CABS`), `Enter` (Next). The repeated
**no-driver finish** is `Enter` on unable-to-locate, then `Enter` on Finish.

1. On the first boot, pressed `Enter` on **Insert Disk**, typed
   `C:\WINDOWS\OPTIONS\CABS` over selected `D:\WIN98`, and pressed `Enter`.
   This exposed the incomplete 69-CAB attempt at `pci.vxd`; quit only this QEMU,
   offline-expanded the cache to all 77 CABs, and cold-booted again.
2. Repeated `Enter`, type the CABS path, `Enter`; then pressed `Enter` for **Yes,
   keep the existing newer file** at the `pci.vxd` Version Conflict.
3. Performed search sequence + no-driver finish four times, once for each of four
   **Unknown Device** wizards, and once more for **ACPI Generic Bus**.
4. For **Intel 82441FX Pentium Pro Processor to PCI bridge**, performed search
   sequence, then `Enter` on driver found at `MACHINE2.INF` and `Enter` for Finish.
5. For **Intel 82371SB PCI to ISA Bridge**, performed the same search sequence,
   `Enter` at `MACHINE2.INF`, and `Enter` for Finish. IRQ Holder then installed
   without input.
6. For **Intel 82371SB PCI Bus Master IDE Controller**, performed search sequence,
   pressed `Enter` with the updated driver selected, `Enter` at `MSHDC.INF`, and
   `Enter` for Finish.
7. For **Standard PCI Graphics Adapter (VGA)**, performed search sequence, pressed
   `Enter` at `MSDISP.INF`, pressed `Enter` once more when that page retried, and
   pressed `Enter` for **Yes, restart** at System Settings Change.
8. For **Plug and Play Monitor**, performed search sequence, pressed `Enter` at
   `MONITOR.INF`, then `Enter` for Finish.
9. For **Intel 82371SB PCI to USB Universal Host Controller**, performed search
   sequence, pressed `Enter` with the updated driver selected, `Enter` at
   `USB.INF`, `Enter` at Insert Disk, typed the CABS path over `D:\WIN98`, pressed
   `Enter`, then `Enter` for Finish.
10. For **Intel 82371EB Power Management Controller**, performed search sequence,
    `Enter` at `MACHINE2.INF`, and `Enter` for Finish. PCnet installed without input.
11. For **USB Human Interface Device** (QEMU tablet), performed search sequence,
    `Enter` at `HIDDEV.INF`, `Enter` for Finish, then `Enter` for **Yes, restart**.
12. Pressed `Enter` on **New clock settings**, then `Enter` in Date/Time Properties
    without changing its values. At the clean desktop pressed `Ctrl+Esc`, `U`, then
    `Enter` with **Shut down** selected; QEMU exited through guest ACPI shutdown.
13. Cold-booted a fresh process. Pressed `Enter` on Network Password
    (`Administrator`, blank), then `Ctrl+Esc`, `R`, typed `control netcpl.cpl`, and
    pressed `Enter`. From the component list pressed `Tab`, `Tab`, `Alt+Down`,
    `Down`, `Enter` to select **Windows Logon**, then `Tab` to File and Print
    Sharing, `Tab` to OK, `Enter`, and `Enter` for **Yes, restart**.
14. That warm restart hung at “Windows is now restarting” with disk writes already
    quiescent. Quit only the trial QEMU and cold-booted. Pressed `Enter` on the Safe
    Mode warning, then `Ctrl+Esc`, `U`, `Enter` for a clean Safe Mode shutdown.
15. Cold-booted again: normal mode reached a clean desktop with no modal. Sent QMP
    absolute tablet axes x=24576 and y=16384 (the 0..32767 range); the screendump
    placed the cursor at about (480,240), exactly 75% x / 50% y.
16. Issued HMP `delvm golden`, `savevm golden`, and `info snapshots`. After QMP
    quit, launched a brand-new identical two-disk QEMU with `-loadvm golden`. The
    saved and restored 640x480 PPM files had the same MD5
    (`b65fc0f4c6de9e59eed3c9c88074eefe`) and the restored desktop was visually clean.

Final checkpoint SHA-256 values: C:
`bde86b6a1ac026593d85315fad587d18100e12ee73d115d14c3f284d5ee7f564`;
D: `4c42d99c9b9f273854ec76c7cba9d0553867efea40c34e2250ef039596c003ff`.

## TL;DR

- The Win95 station hangs under KVM because of **the guest's Cirrus Logic 5446 PCI
  display driver**, not because of the CPU/TSC/timer knobs everyone blames first.
- **Fix that WORKS (verified to a full, responsive normal-mode desktop under KVM):**
  swap the guest's display driver from *Cirrus Logic 5446 PCI* to the generic
  *Standard PCI Graphics Adapter (VGA)*, and launch with the KVM args below.
  Trade-off: standard VGA = **640×480×16-colour** (vs cirrus 1024×768 hi-colour
  under TCG). This is the honest cost of KVM for Win95 today.
- **CPU-idle already solved for free:** the image already ships **Rain** (an idle-HLT
  TSR) in the Startup folder. Once the desktop actually loads under KVM, Rain's HLT
  works and the idle vCPU drops to **~1–2 % of a core** (no busy-loop peg). No extra
  TSR/FIX95CPU needed — those target a *different* failure (see "ruled out").
- Idle vCPU: **KVM ≈ 1–2 % of a core** (Rain HLT works) vs **TCG ≈ 10 %** — the clean,
  load-independent win. (Boot-time was measured on a host at load-avg 42/16 and is
  contention-dominated for both; see measurements.)

## Smooth full-window drag — VBEMP 19.12.0001 at 16-bit (2026-07-16, LIVE)

The Standard-VGA driver above is the KVM-viability fix, but it runs 640×480 in the
legacy **16-colour PLANAR** mode (mode 12h, 4 bit-planes at 0xA0000). Every pixel a
repaint touches is a read-latch/modify/write across 4 VGA planes done by the guest CPU
and produces torn, partly repainted full-window drags.

**Current shipped fix:** BearWindows/JW Soft **VBEMP 19.12.0001**, `032MB` variant,
at **640×480 High Color (16 bit) PACKED**. QEMU still exposes the same standard VGA
device (`1234:1111`) and the launcher remains `-vga std`; this is only a guest driver
and colour-depth change. "Show window contents while dragging" remains enabled.

- Upstream: `https://bearwindows.zcm.com.au/191201.zip`
- SHA-256: `93d9bd34fc82904e827e0f4a5cee28beb3013c5d3d8b9730b5367a74b06acd3d`
- Files: `032MB/{VBEMP.DRV,VBE.vxd,vbemp.inf}`
- Installed adapter: **VBE Miniport(QEMUBochsVBE)**, manufacturer **JW Soft**
- Mode: **640 by 480 pixels, High Color (16 bit)**

Win95 OSR2 Have Disk filters on the hardware ID, so add this exact line immediately
below `[Mfg]` in `vbemp.inf`:

```ini
%JWSoft.DeviceDesc% (QEMU Bochs VBE) = PCIVID, PCI\VEN_1234&DEV_1111
```

The INF is CRLF. A sed expression anchored to `[Mfg]$` silently matches nothing due
to the carriage return; patch bytes/lines with CRLF awareness and assert exactly one
new hardware-ID line before injection.

The validated click path is Display Properties → Settings → Advanced Properties →
Adapter → Change → Have Disk → `C:\VBEMP` → **VBE Miniport(QEMUBochsVBE)** → Apply.
Do not choose the adjacent “VBE Miniport - Standard PCI Graphics Adapter (VGA)” row.
The driver-switch framebuffer may transiently corrupt; stop only that candidate by
pidfile and cold boot it. Never use `loadvm golden` for the first post-injection boot,
because it restores the pre-injection disk state.

Full-window drag is enforced by importing:

```reg
REGEDIT4

[HKEY_CURRENT_USER\Control Panel\Desktop]
"DragFullWindows"="1"
```

The shipped validation used the real QMP framebuffer at 45 ms intervals. The legacy
Microsoft VGA baseline had characteristic incomplete repaints in 9/9 inspected
samples; the validated VBEMP clone had 0/8, the fresh ship clone had 0/14, and the
post-`labctl reset win95` live capture had 0/14. Warpnet motion landed at all four
corners and centre at 16-bit, while QMP-delivered buttons opened Start and completed
a full-window drag. Evidence is under
`/data/vms/soltest/win95-paint-tearing-vbemp-ship-20260715/` and
`/data/vms/streamhost/stations/win95/vbemp-live-verify-20260716/`.

Do not infer the guest depth from `file(1)` on a screenshot: `labctl shot` may
losslessly optimise the mostly flat Win95 desktop into a 4-bit paletted PNG even
though the guest is in 16-bit packed mode. Verify depth from the real framebuffer's
Display Properties → Settings text (or driver/mode state), not the PNG container's
chosen encoding.

The from-source automation in `scripts/build-guests/tiles/win95.sh` §6c downloads and
hash-checks this archive, performs the CRLF-aware INF patch, stages `C:\VBEMP`, drives
the Have-Disk selection on the KVM/std copy, cold-boots, imports `DRAG.REG`, and emits
`verify-vbemp-640x480x16.ppm`. The live checkpoint was recaptured under pinned
`pc-i440fx-11.0` with `-vga std` and checkpoint `golden` on 2026-07-16.

## The QEMU/KVM launch args (the working recipe)

```
qemu-system-i386 \
  -machine pc,acpi=off,usb=off,kernel-irqchip=off,accel=kvm \
  -cpu pentium,-apic -m 256 -smp 1 \
  -drive file=win95-osr2.qcow2,format=qcow2,if=ide,index=0,media=disk -boot c \
  -vga std \                         # NOT cirrus — see root cause
  -audiodev <backend>,id=snd -device sb16,audiodev=snd \
  -netdev user,id=n0 -device pcnet,netdev=n0 \   # optional; see "network freeze"
  -rtc base=localtime
```

Two non-obvious, load-bearing pieces:

1. **`kernel-irqchip=off` + `-cpu pentium,-apic`** (userspace 8259/PIT, no local APIC).
   The in-kernel KVM PIT delivers **zero IRQ0 (timer) interrupts** to this guest — a
   real, verified timer-delivery failure that on its own freezes any Win9x delay loop.
   Removing the local APIC (`-apic`) is what *allows* `kernel-irqchip=off` (otherwise
   QEMU refuses: "KVM does not support userspace APIC"). With userspace irqchip, IRQ0
   ticks at ~100 Hz like it does under TCG. This is the correct replacement for the
   classic `kernel-irqchip=off` fix that the prior workflow found "conflicts with
   acpi=off" — the conflict is the APIC, not ACPI; drop the APIC and it works.
2. **`-vga std`** instead of `-vga cirrus` — the core fix (see below).

## Root cause (verified, step by step)

Reproduced the hang exactly: under KVM the "Enter Network Password" dialog frame draws
but its **body never paints** and input is dead; the same image under TCG paints it
fully and reaches the desktop.

There are actually **two distinct KVM hangs**, both were chased to ground:

- **Freeze A — with any NIC:** the guest freezes at the network-logon password dialog
  (body unpainted). Happens with `pcnet`, `rtl8139`, `ne2k_pci` alike.
- **Freeze B — with no NIC:** the guest gets further (taskbar draws) then freezes at
  the desktop bring-up. vCPU register inspection shows a **fixed spin**:
  `EIP=0x1117`, 16-bit ring-3 code (CPL=3, CS16), `IF=1`, `HLT=0`, registers frozen —
  a tight `GS: TEST byte[0x0040],1 ; JNZ` loop waiting for an async handler to clear a
  flag that never clears. 100 % of one vCPU, byte-identical framebuffers = a real
  deadlock, not slowness.

**Key discriminator:** booting to **Safe Mode reaches a full, responsive desktop
under KVM** (dialog fully painted, EIP advancing, IRQ0 live, mouse/keyboard work).
Safe Mode differs from normal boot by using the generic `VGA.DRV` instead of the
cirrus driver (plus skipping network/startup). Since removing the NIC, removing sound,
removing the Startup item (Rain), disabling APM, and disabling cirrus *acceleration*
all still froze — but the **Standard-VGA display driver boots normally** — the culprit
is isolated to the **Cirrus 5446 driver's normal (non-safe) init/paint path under KVM**.
The cirrus mode-set itself succeeds (the frozen desktop is a correct 1024×768 teal
background); the deadlock is when the driver does accelerated desktop composition, in a
way QEMU's cirrus device + KVM timing never satisfies.

Proof of the fix: with the display driver switched to *Standard PCI Graphics Adapter
(VGA)*, a **normal-mode** (no Safe-Mode banner) Win95 desktop comes up under KVM with
all icons, taskbar, tray clock, working Start menu, and `HLT=1` at idle.

## What was tried and RULED OUT (all still froze — screenshot-verified)

The usual Win9x-on-KVM folklore does **not** fix this image:

| Attempt | Result |
|---|---|
| `-global kvm-pit.lost_tick_policy=discard` | froze (and in-kernel PIT delivered 0×IRQ0) |
| `hpet=off`, RTC variations | froze |
| `kernel-irqchip=off` / `=split` / on | fixes IRQ0 delivery but guest still deadlocks (Freeze B) |
| APIC on / off | froze |
| ACPI on / off | froze |
| `-cpu pentium` / `486` / `pentium2` | froze (note: KVM runs at native ~2.3 GHz regardless of `-cpu`) |
| `-cpu pentium,tsc-frequency=100/200 MHz` (HW TSC scaling confirmed present) | froze — **not a TSC/fast-CPU bug** |
| CPU throttle to 40 % via `systemd-run -p CPUQuota=40%` | progressed slightly, same deadlock |
| Remove NIC / swap NIC model / remove SB16 sound | moves or keeps the freeze; not the cause |
| Disable APM (`device=*vpowerd`) | froze |
| Remove Startup item (Rain.lnk) | froze |
| Cirrus **acceleration = None** (`SwCursor=1` + `Mmio=0`) | froze — accel-off is insufficient; it's the driver itself |
| **Standard VGA display driver** | **BOOTS to full desktop** ✅ |

**FIX95CPU / patcher9x / idle-TSR (AmnHLT/Rain) are the wrong tool for THIS hang.**
They fix the fast-CPU *"Windows protection error" crash* and CPU-idle heat — a crash and
a busy-loop, respectively. This image is already patcher9x-patched and the failure is a
silent display-driver *deadlock*, not that crash (a `-cpu 486` with no RDTSC deadlocks
identically, and HW TSC-scaling to 120–200 MHz changes nothing). Rain is still valuable
— it idles the vCPU to ~1–2 % once the desktop loads — but it does not unblock the boot.

## Applying the guest-side fix reproducibly

The display-driver swap is a one-time guest change. Two reproducible ways:

1. **Auto-detect (used here, scriptable):** launch once with `-vga std` under **TCG**
   (TCG boots fine). Win95 sees the hardware change and pops the *Update Device Driver
   Wizard* offering "Standard PCI Graphics Adapter (VGA)"; click Next→Finish→Restart
   (drivable headless with QMP `send-key ret`, like the existing PnP "settle" step in
   `scripts/build-guests/tiles/win95.sh`). After the restart the image is KVM-ready and boots normally
   under `-vga std` + the KVM args above.
2. **In Safe Mode:** boot Safe Mode under KVM (works), Device Manager → Display adapters
   → change driver to Standard PCI Graphics Adapter (VGA), reboot normal.

Do NOT keep `-vga cirrus` in the KVM launch after the swap — with the std driver the
guest expects the std adapter.

## The "network password" freeze (Freeze A) — orthogonal

Even with the display driver fixed, a NIC present makes Win95 stop at the network-logon
password dialog on a fresh `-snapshot` boot. Two clean options:
- Keep the NIC and **click OK / send `ret`** once (the station already dismisses this).
- Or drop networking. If the station does not need in-guest internet, omit the `pcnet`
  device; the logon dialog then does not appear.
This is the same dialog the live TCG station shows on every boot; it is not KVM-specific
beyond the timing, and the std-VGA guest dismisses it and reaches the desktop normally.

## Before / after measurements (this host, verified)

Measured while the host was at **load-avg ~42 on 16 cores** (many sibling build agents
running), so wall-clock boot times are heavily contention-bound for *both* modes and
are **not** a clean KVM-vs-TCG measure. The load-independent metrics (idle CPU, accel
engaged, desktop responsiveness) are the reliable comparison.

| metric | TCG (cirrus, stock) | KVM (std-VGA driver) |
|---|---|---|
| accel engaged (/dev/kvm fd open in qemu) | no (fd count 0) | **yes (fd count 1)** |
| **idle vCPU (one core, 5 s sample)** | **~10 %** (51 ticks) | **~1–2 %** (9 ticks) |
| desktop reached, fully painted + responsive | yes (laggy) | **yes (snappy)** — Start menu, icons, tray clock, mouse all work |
| idle CPU state | emulated busy-loop | **`HLT=1`** — vCPU genuinely halts |
| resolution / colour | 1024×768 hi-colour | 640×480 × 16 |
| boot to end-of-boot on THIS load-42 host | ~150 s (to login dialog) | ~90–100 s to splash, then desktop (contention-bound) |

Net: under KVM the guest runs at native speed and idle-halts to ~1–2 % of a core (Rain),
instead of TCG software-emulating every instruction and holding ~10 % even at idle (far
more under active use). On an un-oversubscribed host the boot/interaction gap is much
larger than the contention-flattened numbers above; the clean proof here is the 10×
lower idle CPU + `HLT=1` + a genuinely responsive normal-mode desktop. The price is
standard-VGA video (640×480×16). The orchestrator decides whether the speed is worth the
visual downgrade for the museum aesthetic (see recommendation).

## Recommendation for the live station

- If **responsiveness** wins: ship the std-VGA + KVM recipe. Snappy, ~1–2 % idle CPU,
  frees the CT-110 core budget the TCG stations fight over.
- If **retro fidelity** (1024×768 hi-colour) wins: keep the current cirrus + TCG station;
  KVM cannot drive the cirrus driver on this image today.
- A middle path worth a follow-up spike: test the cirrus driver at **256 colours** or
  **640×480** (different blit path) — it may dodge the deadlock while keeping cirrus.
  Not yet verified.

## Generalisation to other old-Windows guests

- **The IRQ0 / userspace-irqchip point is general** to all Win9x under KVM: prefer
  `kernel-irqchip=off` + `-cpu <model>,-apic` (or `=split`) so the PIT actually ticks.
- **The cirrus-driver deadlock is likely 95/98-specific and driver-specific.** Win98's
  cirrus driver is different and Win98 is generally far friendlier under KVM; test it on
  its own — it may not need the std-VGA swap. **Win 3.11** runs its display in the same
  cirrus/VGA family and is worth the same std-VGA test. **Windows 2000** uses the NT
  kernel and a proper HAL/ACPI — it runs under KVM with the normal modern recipe
  (`accel=kvm`, in-kernel irqchip, `-cpu` host/pentium-class, standard VGA or QXL) and
  does **not** share this Win9x display-driver deadlock; do not carry these Win9x knobs
  to Win2000.
- **Rain/idle-TSR** generalises to every Win9x station (95/98/Me) to keep the idle vCPU
  from pegging a core under KVM.

## Absolute pointer — two different routes (win95 = warpnet agent, win98se = usb-tablet)

**win98se** now gets a true absolute pointer from a **`usb-tablet`** (`SH_POINTER=abs`),
enabled by switching that station to `acpi=on` — see the win98se bullet below. **win95**
keeps `usb=off` (part of its anti-protection-error combo) so it has no usable USB HID
stack; its only pointing hardware is the PS/2 **relative** mouse, and Win9x pointer
acceleration makes the streamhost abs→rel homing bridge drift. The fix **for win95** is
the in-guest agent `streamhost/guest-agents/win9x/warpnet.c` (Win32, `SetCursorPos` +
`mouse_event`, Winsock TCP `:7777`, speaks the warpd `M/P/R/B` newline protocol — daemon
side `InputBackend::Warpd` is unchanged):

- **win95** — WORKS, captured 2026-07 (hostfwd `127.0.0.1:57791` → `:7777`), commit
  `3d47064`, coalescing fix `39d17b3`. Calibration 2026-07-12: driving the live station's
  warpd moves the cursor to the exact commanded pixels and renders it in screendumps.

- **win98se** — absolute pointer via **usb-tablet: CAPTURED + LIVE** (2026-07-12). The earlier
  "PCI is dead, so it's impossible" conclusion was **misdiagnosed**. The station now runs
  `SH_POINTER=abs` with a `usb-tablet`; the recaptured checkpoint restores (via `-loadvm golden`)
  to a working 1:1 absolute pointer, verified at 3 commanded positions on the live station.

  **Real root cause of the dead PCI bus = `acpi=off`, NOT the `usb=off`/`-apic`/
  `kernel-irqchip=off` bundle.** This checkpoint is an **ACPI-HAL install** — `System devices`
  in Device Manager lists *"Advanced Configuration and Power Interface (ACPI) BIOS"*. Booting
  it with `-machine …,acpi=off` is therefore a **HAL/firmware mismatch**: the ACPI enumerator
  finds no ACPI tables, Win98 falls back to *"Plug and Play BIOS (fail safe)"* (yellow-bang,
  Code 28) and **never walks the PCI config space**. Framebuffer-verified under `acpi=off`:
  Device Manager (view by type) shows **only** `Other devices → Plug and Play BIOS (fail safe)`
  and a 4-item `System devices` node — **no PCI bus, no display/network/USB adapters at all**;
  a Device-Manager **Refresh re-scan finds nothing new**; injecting `usb-tablet` abs events
  moves **no cursor** (PS/2 relative motion works). Dropping the aggressive KVM flags did
  **not** revive PCI — the flags were never the cause. `acpi=off` is.

  **Fix = boot with ACPI on.** With `-machine pc,acpi=on -cpu pentium3` Win98 **enumerates the
  full PCI bus**: a cold boot pops *"New Hardware Found → PCI bus"* and cascades through the
  real chipset — `Intel 82441FX … to PCI bridge`, `Intel 82371SB PCI to ISA bridge`, `IRQ
  Holder for PCI Steering`, `Standard PCI Graphics Adapter (VGA)` (this also **clears the
  display-adapter nag**), **`Intel 82371SB PCI to USB Universal Host Controller`** →
  `USB Root Hub` → `USB Human Interface Device` (the tablet), and the **AMD PCnet NIC** (which
  pulls the TCP/IP stack — `winipcfg` then shows the **10.0.2.15** SLIRP DHCP lease). This is
  the **natural** config for an ACPI install — **not** a "reinstall-level ACPI HAL switch";
  Win98 simply detects its real hardware. (`acpi=off` was almost certainly copied from the
  win95 recipe by habit.)

  **`hidusb.sys` + base cabs were missing from the WinWorld image and had to be staged.** The
  tablet's HID device needs `hidclass.sys` + **`hidusb.sys`** + `hidparse.sys` (per
  `WINDOWS\INF\HIDDEV.INF`, `NTMPDriver="hidusb.sys"`); `hidusb.sys` and the base
  CD CAB set were absent (the image's `C:\WINDOWS\OPTIONS\CABS` held only loose update
  DLLs). Fix: fetch a Win98SE CD ISO from the same upstream (archive.org item
  `windows-98-se-isofile`), extract `hidusb.sys` from `\WIN98\WIN98_21.CAB` (`7z e`) into
  `C:\WINDOWS\SYSTEM32\DRIVERS\`, and copy all 77 CAB files (`WIN98_*`,
  `DRIVER*`, and the two lowercase CABs) into `C:\WINDOWS\OPTIONS\CABS\` so PnP
  self-services the rest (offline via `qemu-nbd`).

  **Winning accel = KVM + `acpi=on` (apic ON, default in-kernel irqchip).** Verified across
  **3 cold boots**: NO "Windows protection error" and NO logon-dialog freeze (the "Enter
  Network Password" dialog paints fully and is responsive — the *same* dialog that froze under
  the old KVM + cirrus + acpi=off combo, see "Freeze A" above). So `acpi=on` also cures the
  old KVM timer/freeze — **no `FIX95CPU`, no `kernel-irqchip=off`, no `-apic` needed**. TCG +
  `acpi=on` is an equally-clean fallback (idle auto-pause covers the TCG idle cost).

  **Capture recipe (captured into `scripts/build-guests/tiles/win98.sh`):** stage `hidusb.sys` + cabs
  (above) → cold-boot `acpi=on` → drive the PnP cascade, pointing any "insert disk" copy prompt
  at `C:\WINDOWS\OPTIONS\CABS` (Win98 then remembers it) and Cancel/Finish-marking the handful
  of driverless ACPI stubs (ACPI Generic Bus/EIO Bus, PnP Monitor, IDE bus-master) → idle
  desktop → verify 1:1 abs tracking + `winipcfg 10.0.2.15` → `savevm golden` →
  `station.env SH_POINTER=abs`. The station boots via `-loadvm golden`, so the RAM snapshot restores
  the settled desktop with the pointer live (no cold-boot re-scan, no nag). Live launcher:
  `-enable-kvm -machine pc,acpi=on -cpu pentium3 … -usb -device usb-tablet,id=tab0` (backup of
  the pre-cutover checkpoint C: at `win98se-kvm.qcow2.pre-usbtablet-*`).

  The old **serial-warpnet** path (below) is obsolete for win98se — the usb-tablet is the live
  absolute-pointer route. Do **not** re-add `acpi=off` / `usb=off` / `-apic` / `kernel-irqchip=off`.

  <details><summary>superseded 2026-07-12 warpnet-TCP finding (kept for history)</summary>

  An earlier pass concluded the TCP-agent path was blocked because the PCnet NIC never
  started (`winipcfg` → "Fatal Error: Cannot read IP configuration", no SLIRP DHCP lease),
  and attributed the dead NIC to the `usb=off`/`-apic`/`kernel-irqchip=off` combo. The NIC
  symptom was real, but the **cause was `acpi=off`** (same no-PCI-enumeration as above), so
  the NIC will come back once ACPI is on — making the device-set-safe TCP path potentially
  usable too. The serial transport (`warpnet-serial` over an `isa-serial` chardev,
  `SH_POINTER=warpd SH_WARPD_ADDR=unix:…`) remains a valid fallback that also needs a recapture.
  </details>

## Full-window drag fix — VBEMP-9x packed linear framebuffer (win98se, CAPTURED + LIVE 2026-07-13; REGRESSED 07-15; RE-CAPTURED 2026-07-26)

> **2026-07-26 recapture (current live state).** The 2026-07-15 full builder rebuild
> (see "Builder rebuild trial" above) recaptured the win98se checkpoint straight from the
> planar seed and its PnP transcript re-selected the inbox **Standard PCI Graphics
> Adapter (VGA)** driver — so the shipped checkpoint **silently reverted to 640×480
> 16-COLOUR PLANAR** and the `DragFullWindows` crawl returned (its `labctl shot` was a
> 4-bit-colormap PNG; win95's was 8-bit). This was re-fixed on **2026-07-26** by
> re-applying the exact VBEMP-9x recipe below: a namespaced clone was booted from a
> `qemu-img convert -l golden` C:/D: extract with the driver floppy attached, the
> **VBE Miniport - Standard PCI Graphics Adapter (VGA)** (JW Soft) driver installed
> via Have Disk → `A:\VBEMP.INF` (Win98's Have Disk needs **no** INF hardware-ID patch,
> unlike Win95 OSR2), colour depth confirmed **High Color (16 bit)** with the smooth
> gradient bar, `DragFullWindows=1` enabled on the Effects tab, and a clean shutdown.
> The verified clone C: was then copied over `win98se-kvm.qcow2` (both disks' stale
> `golden` snapshots removed first for a consistent pair), the station cold-booted, the
> **Notepad** checkpoint scene re-established (clock hidden, steady caret, focused), and
> `savevm golden` taken (C: 82.9 MiB + D: 0 B at one VM clock). Live re-verified: the
> served station shows the hi-color desktop and a title-bar drag tracks the cursor with
> the full window painted at every step (device set unchanged — still `-vga std` +
> `acpi=on` + usb-tablet, so the launcher/registry did not change).
> **Watch out:** the Win9x guest **warm restart hangs at "Windows is now restarting…"**
> under this KVM/QEMU 11 build and the ACPI power-off never fires — do a GUI **Shut
> down** (Start ▸ Shut Down ▸ Shut down ▸ OK), wait for the striped shutdown-fade
> (FS + clean-shutdown flag are flushed by then), then **kill by pidfile and cold
> boot**. Killing mid-warm-restart lands the next boot in Safe Mode; the clean
> shutdown then cold boot reaches Normal mode with VBEMP loaded.

**Symptom.** With Windows' "Show window contents while dragging" (`DragFullWindows=1`)
ON, dragging a window on win98se crawled at **<1 FPS** — the window body could not
keep up with the cursor. WinXP is smooth because its station runs the VBEMP VESA
linear-framebuffer miniport (`winxp-vbemp-hires.sh`); win98se did not.

**Root cause (established).** The win98se checkpoint shipped the inbox **Standard PCI
Graphics Adapter (VGA)** driver, which on QEMU `-vga std` runs **640×480 × 16-COLOUR
PLANAR** (VGA mode 12h, 4 bit-planes). Every pixel write is a read-modify-write across
4 planes via the VGA sequencer/GC latches — **CPU-bound in the guest**, so a full-window
repaint during a drag cannot complete fast enough. (Confirmed in Display Properties →
Settings: *Standard PCI Graphics Adapter (VGA)*, **16 Colors**, 640×480.)

**Fix = give Win98 a PACKED LINEAR framebuffer, exactly like WinXP.** The device set is
**unchanged** (`-vga std`, i.e. QEMU's Bochs VBE) — this is a GUEST-INTERNAL display-driver
swap, so it needs a **checkpoint recapture** (`-loadvm golden` must still match the device set).

- **Driver = bearwindows "VBEMP 9x/ME" universal VBE display driver** — a *different*
  package from the NT-only `vbempk.zip` used for XP. NT's VBEMP (`vbempk.zip`) contains
  **no 9x build** (NT31…2003 only). The Win9x driver is the bearwindows page
  `vbe9x.htm` → latest build **`191201.zip`** (2019-12-01). It ships as `VBEMP.DRV` +
  `VBE.vxd` + `vbemp.inf` in per-VRAM folders `032MB/ 064MB/ 128MB`. Use the **`032MB`**
  build (QEMU `-vga std` default VRAM is 16 MB; the 032MB mode list fits and 640×480×16bpp
  is <1 MB). The INF `DEFAULT` mode is `"16,640,480"` = **640×480 × 16-bit High Color,
  packed** — so a repaint is a `memcpy`, not a 4-plane RMW. Current files after install:
  `vbemp.drv,*vdd,*vflatd,vbe.vxd` (note **`*vflatd`** = the flat-framebuffer VDD).

- **Install (in-guest, GUI, on a clone first).** Build a FAT12 floppy with the three
  `032MB` files, attach as `-fda`, cold-boot, then:
  Display Properties → **Settings → Advanced → Adapter → Change…** → Update Device Driver
  Wizard → *Display a list…specific location* → **Have Disk…** → `A:\` → select
  **"VBE Miniport - Standard PCI Graphics Adapter (VGA)" (JW Soft)** → Next → Finish →
  Close → **Yes, restart**. After reboot the adapter reads *VBE Miniport*, Colors =
  **High Color (16 bit)** with a smooth gradient bar (= packed, not the 16-colour palette).
  Then Effects tab → check **"Show window contents while dragging"** → Apply
  (`DragFullWindows=1`).

- **Resolution stays 640×480.** The fix is the *depth/format* change (planar→packed), not
  resolution. Keeping 640×480 preserves the streamhost capture geometry — QEMU's dbus
  display always presents a **32bpp packed** scanout surface regardless of guest depth
  (`ScanoutMap 640x480 stride=2560`), so **no `streamhost`/UI geometry change is needed**.
  Win98's VBEMP does list 800×600/1024×768 at 16/32bpp if a larger station is ever wanted;
  bump `NEKO_SCREEN`/station geometry to match if you do.

**Cold-boot PnP caveat (not caused by this change).** After the driver swap, a *cold* boot
re-detects the image's driverless PnP stubs as *Add New Hardware Wizard* pop-ups
("Unknown Device", VBEMP's DDC **"Plug and Play Monitor"**, "Intel 82371SB … IDE
Controller") — the same stubs the original capture Cancel/Finish-marks. **Cancel them all**
during the capture, reach a clean desktop, then `savevm golden`. The live station boots via
`-loadvm golden` (RAM snapshot), so **the wizards never appear at station launch** — the
restored settled desktop has them dismissed.

**Verified smooth (framebuffer cadence).** On both the clone and the live station, a scripted
title-bar drag with `DragFullWindows=1` produced **8 distinct, fully-rendered full-window
frames in ~0.2 s** (~30 ms/step incl. QMP round-trips → the guest repaint is *not* the
bottleneck; it tracks the cursor in real time). Each captured frame shows the **entire
window** (title, toolbar, address bar, all icons) painted at the new position with the
vacated desktop correctly restored — the anti-crawl signature — vs the established <1 FPS
planar crawl. Depth confirmed *High Color (16 bit)* in Display Properties.

**Capture / cutover recipe (what shipped 2026-07-13).**
1. Clone under `/data/vms/soltest/win98-drag/`: extract a **consistent** C:/D: from the
   live checkpoint with `qemu-img convert -l golden …` (NOT a raw `cp` of the live-mutating
   qcow2 — that yields a torn image → 0E BSOD on boot). Same device set + `-fda vbe9x.img`.
2. Install VBEMP-9x (above), enable `DragFullWindows=1`, **clean Win98 shutdown**
   (flushes VCACHE so the FS is consistent), verify a clean no-floppy cold boot + smooth drag.
3. Live cutover: confirm the live station is idle/stable → `systemctl stop streamhost@win98se`
   → kill QEMU by pidfile → back up **both** qcow2s (`*.bak-predrag-*`) → delete the stale
   `golden` snapshot from `win98se-games.qcow2` (so `savevm` can re-create a consistent
   snapshot across both disks) → `cp clone/c.qcow2 → win98se-kvm.qcow2` → cold-boot the station
   launcher (auto cold-boot, snapshot absent) → dismiss the PnP wizard cascade → clean
   desktop → `savevm golden` (85.7 MiB on C:, 0 B on D:) → `loadvm golden` verify →
   relaunch QEMU (now auto `-loadvm golden`, instant scene) → `systemctl start
   streamhost@win98se` → confirm `[capture] ScanoutMap 640x480` + `first frame 640x480`.
   The launcher (`qemu-streamhost.sh`) is **unchanged** — still `-vga std` + usb-tablet +
   `acpi=on` (the 2026-07-12 absolute-pointer/ACPI config is preserved).

## Repro harness (in `/data/kvm9x-lab/` on the host)

- `w9xtest.sh <tag> <img> <accel> <cpu> [extra…]` — launches a namespaced test VM
  (own run dir, VNC display via `VNC_DISP`, QMP+monitor sockets, pidfile). Env toggles:
  `NONET=1` (drop NIC), `NOSND=1` (drop SB16), `VGA=std`, `MACHINE=…`, `MEM=…`.
- `w9xshot.sh <tag> <label>` — QMP `screendump` → PPM → PNG (this QEMU build lacks
  libpng for screendump, so PPM+`pnmtopng`; HMP-over-socat mangles input, QMP is clean).
- `w9xkey.sh <tag> <qcode…>` and QMP `send-key` combos for driving the GUI headless.
- `w9xstop.sh <tag>` — QMP `quit`, pidfile fallback. **Never pkill.**
- Judge state from screendumps + `human-monitor-command` `info registers` / `info irq`
  / `info pic` (IRQ0 count and the frozen EIP are what cracked this).

### The launcher (`w9xtest.sh`) — reproduce the whole matrix

```bash
#!/usr/bin/env bash
# w9xtest.sh <tag> <img> <accel> <cpu> [extra qemu args...]
#   env: VNC_DISP, MEM, MACHINE, QEMU, NONET=1 (drop NIC), NOSND=1 (drop SB16), VGA=std
# Kills only by pidfile/monitor. Namespaced run dir per tag.
set -uo pipefail
TAG="${1:?}"; shift; IMG="${1:?}"; shift; ACCEL="${1:?}"; shift; CPU="${1:?}"; shift
EXTRA=("$@"); LAB=/data/kvm9x-lab; RUN="$LAB/run.$TAG"; mkdir -p "$RUN"
MON="$RUN/mon.sock"; QMP="$RUN/qmp.sock"; PID="$RUN/qemu.pid"; LOG="$RUN/qemu.log"
VNC_DISP="${VNC_DISP:-91}"; MEM="${MEM:-256}"; MACHINE="${MACHINE:-pc,acpi=off,usb=off}"
QEMU="${QEMU:-qemu-system-i386}"
if [ -f "$PID" ]; then p=$(cat "$PID" 2>/dev/null||true)
  [ -n "${p:-}" ] && kill -0 "$p" 2>/dev/null && { kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null||true; }; fi
rm -f "$MON" "$QMP" "$PID" "$LOG"
NET_ARGS=(-netdev user,id=n0 -device pcnet,netdev=n0); [ "${NONET:-0}" = 1 ] && NET_ARGS=(-net none)
SND_ARGS=(-audiodev none,id=snd -device sb16,audiodev=snd); [ "${NOSND:-0}" = 1 ] && SND_ARGS=()
VGA="${VGA:-cirrus}"
"$QEMU" -name "w9x-$TAG" -machine "${MACHINE},accel=${ACCEL}" -cpu "$CPU" -m "$MEM" -smp 1 \
  -drive file="$IMG",format=qcow2,if=ide,index=0,media=disk -boot c -vga "$VGA" \
  "${SND_ARGS[@]}" "${NET_ARGS[@]}" -rtc base=localtime "${EXTRA[@]}" \
  -vnc ":${VNC_DISP}" -monitor "unix:${MON},server,nowait" -qmp "unix:${QMP},server,nowait" \
  -pidfile "$PID" -display none -daemonize 2>"$LOG" || { cat "$LOG"; exit 1; }
for _ in $(seq 1 20); do [ -S "$MON" ] && break; sleep 0.5; done
echo "[$TAG] pid=$(cat "$PID" 2>/dev/null)"
```

Companion one-liners: **screendump** `printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"out.ppm"}}\n'; sleep 1 | socat - UNIX-CONNECT:$QMP` then `pnmtopng out.ppm`; **key** `send-key {"keys":[{"type":"qcode","data":"ret"}]}`; **combo** put two qcodes in the `keys` array (e.g. `ctrl`+`esc`); **stop** `{"execute":"quit"}`.

Example reproduction of the two headline results:
```bash
# reproduce the cirrus KVM freeze (no NIC -> the desktop-bringup deadlock):
VNC_DISP=92 NONET=1 MACHINE=pc,acpi=off,usb=off,kernel-irqchip=off \
  ./w9xtest.sh freeze win95.qcow2 kvm pentium,-apic -snapshot
# the WORKING config (after the display-driver swap to Standard VGA):
VNC_DISP=93 NONET=1 VGA=std MACHINE=pc,acpi=off,usb=off,kernel-irqchip=off \
  ./w9xtest.sh ok win95.qcow2 kvm pentium,-apic -snapshot
```

---

<!-- APPENDIX: merged from scripts/neko-win95-perf-tuning.md — audio/input/video tuning of the neko-era Win95 station (complementary findings; the KVM recipe above is the authoritative accel story) -->

# neko Win95 station — audio/input/video performance tuning

> **Historical (neko-era) appendix.** The Win9x guests run today as the streamhost
> stations `win95` / `win98se` / `win311` (`streamhost/stations-manifest.sh`). The
> neko-side artifacts referenced in this appendix — `gallery-integrate-all.sh`,
> the compose overrides `scripts/tools/win95-perf-override.yml` /
> `win311-perf-override.yml`, and `scripts/tools/win95-kvm-boottest.sh` — are all
> neko-era, deleted in the 2026-07 restructure — git history. The guest-side
> findings (KVM viability, Rain/AmnHLT idle TSR, 4:3 geometry) carry over.

Investigated 2026-07-04 on CT 110 "osgallery" (labhost 192.0.2.10), live station
http://192.0.2.12:8091. All facts below were VERIFIED against the then-running
container and an isolated KVM boot test (VMID 961, torn down). Do NOT edit
`gallery-integrate-all.sh` (neko-era, deleted) or `docker-compose.gallery-guests.yml`
from this file — the orchestrator merged these changes; the target was the `win95:`
compose service.

## Verified baseline (what is actually running)

Live win95 QEMU cmdline (captured from `/proc/*/cmdline` in `osgallery-win95-1`):

```
qemu-system-x86_64 -name Windows 95 OSR2 -m 256 -smp 2 -audiodev pa,id=snd \
  -display gtk,full-screen=on,zoom-to-fit=on,grab-on-hover=off -vga cirrus \
  -rtc base=localtime -machine pc,acpi=off,usb=off -device sb16,audiodev=snd \
  -drive file=/guests/Win95/win95-osr2.qcow2,format=qcow2,if=ide -boot c \
  -cpu pentium -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot
```

- **NO `-enable-kvm`, no `accel=kvm`** → `-machine pc,...` defaults to **TCG software
  emulation**. `/dev/kvm` IS passed into CT 110 (crw-rw---- root:kvm) and the host
  has virt flags, but the win95 station never asks for it. (All other kvm-capable stations —
  win11, macos, android, serenity — add `-enable-kvm` in their `QEMU_EXTRA`; win95's
  `QEMU_EXTRA` does not.)
- **`-smp 2`** comes from `launch-qemu.sh` default (`QEMU_SMP:-2`). Win95 is
  uniprocessor and cannot use the 2nd CPU — wasted under TCG.
- **`usb=off`** → the only pointing device is the default **PS/2 (i8042) mouse**,
  which is a **relative** device.
- **`-audiodev pa,id=snd`** with **no buffer/latency params** (launch-qemu.sh
  hardcodes `pa,id=snd`). PulseAudio daemon runs all-defaults (null-sink
  `audio_output`, `module-native-protocol-unix` on `/tmp/pulseaudio.socket`).
- **Display**: `NEKO_SCREEN=1280x720@30`; live guest video mode is **640x480**
  (framebuffer screenshot: desktop fills only the top-left quadrant, black padding
  right/bottom). `zoom-to-fit=on` hardcoded in launch-qemu.sh.
- **Labhost contention**: CT 110 is `cores: 4` (labhost has 16). Observed
  **load average 50, 0.0% idle** — every TCG neko station plus the sibling VMs
  (macOS 925, Win11 900) are contending for those 4 cores. TCG guests are
  ~10-20x more CPU-hungry than KVM, so they are the first to starve.

## KVM viability — TESTED, it works

Isolated boot test: same seed qcow2, `-machine pc,acpi=off,usb=off,accel=kvm
-cpu pentium -m 256 -smp 1 -snapshot` (no writes to the seed image), headless
VNC. Result: **boots cleanly to a 1024x768 Win95 desktop, renders live, stays
stable, no corruption, no triple-fault.** The build-script warning "KVM
hangs/corrupts first-boot PnP" is about the FIRST install boot — this seed
image is already past PnP and already patcher9x-patched, so that warning no
longer applies. Reproduce with `scripts/tools/win95-kvm-boottest.sh` (neko-era,
deleted — recover from git history, or just replay the QEMU line above).

Caveat: Win95 never issues HLT when idle (no ACPI/APM idle), so under KVM the
vCPU thread still shows ~100% host CPU. That is a native busy-loop, not real
work — it leaves ample headroom to service input/audio (unlike TCG, where the
same busy-loop consumes the whole slow emulated core). Optional guest-side fix:
install a CPU-idle TSR (e.g. `AmnHLT`/`Rain`) to halt the idle loop.

## Fixes (highest impact first)

### 1. Enable KVM for the win95 station  [PRIMARY — fixes audio + input + slow desktop at once]
In the `win95:` service `QEMU_EXTRA`, prepend `-enable-kvm` and force uniprocessor:

```yaml
      # was: "-cpu pentium -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot"
      QEMU_EXTRA: "-enable-kvm -cpu pentium -smp 1 -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot"
```

(`launch-qemu.sh` also emits its own `-smp 2`; passing `-smp 1` later on the line
wins in QEMU. If duplicate-option strictness bites, set `QEMU_SMP: "1"` in the env
block instead.) Then recreate ONLY this service:
`docker compose -f docker-compose.gallery-guests.yml up -d --force-recreate win95`.
Expected: ~10-20x more effective guest CPU → login chime stops crackling, desktop
appears in seconds not a minute, mouse becomes responsive. Risk: low (boot
validated); if a specific labhost microcode ever destabilises it, revert the one line.

### 2. Relieve CPU oversubscription  [supports #1]
CT 110 is capped at 4 cores against 16 physical. Even with KVM, 8+ neko stations plus
sibling VMs on 4 cores contend. Raise CT 110 `cores` (e.g. to 8) in
`/etc/pve/lxc/110.conf`, or `cpulimit`/`cpuunits` weight the win95 service. This is
a labhost/orchestrator decision (coordinate — siblings share this labhost). TCG stations are
the main CPU sink; moving win95 to KVM already removes the biggest one.

### 3. Audio buffer hardening  [after KVM; makes underruns impossible, not just rare]
Crackle is a buffer underrun upstream of neko (sb16 DMA → PulseAudio), caused by
CPU starvation — Opus/WebRTC is not the culprit, so Opus bitrate is NOT the knob.
KVM (#1) removes the starvation. For extra margin, give the pa backend an explicit
larger buffer. This needs the `-audiodev` line, which is hardcoded in
`launch-qemu.sh`; cleanest is to make launch-qemu.sh honour an override, e.g.:

```
-audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000   # microseconds: 100ms buf / 50ms
```

Until launch-qemu.sh is parameterised, #1 alone is expected to clear the crackle.

### 4. Input — keep PS/2, do NOT switch to usb-tablet
Win95 OSR2 has no usable built-in USB HID stack, so `-usb -device usb-tablet`
(the absolute-pointer trick that helps DOS/modern guests) will NOT be picked up by
Win95 and risks breaking the station — do not use it here. The mouse lag is
overwhelmingly CPU starvation (the guest can't service the i8042 IRQ), so #1 is the
real fix. Optional polish inside the guest image: Control Panel → Mouse → Motion →
set pointer speed to the middle notch and disable acceleration/trails, which aligns
neko's absolute→relative delta injection and feels snappier.

### 5. Video sharpness — native-resolution 1:1 mapping
Blur = a 640x480 guest inside a 1280x720 neko frame, then browser-upscaled. Make the
guest resolution equal the neko screen so pixels map 1:1 (no scaling anywhere until
the user's own browser window):

- Set the guest to **1024x768 High Color** persistently: boot the seed image ONCE
  **without `-snapshot`**, set Display Properties → Settings → 1024x768, reboot to
  confirm it sticks, `File → Shut Down` to a clean "safe to turn off", re-add
  `-snapshot`. (The image already supports 1024x768 — the KVM test came up at it.)
- Set `NEKO_SCREEN: "1024x768@30"` on the win95 service to match. With guest==screen,
  `zoom-to-fit` becomes a no-op and there is no interpolation blur; the whole frame
  is used (no black padding). Keep 30fps.

## Do-not-touch / hygiene honoured
- Only inspected + one isolated test VM (VMID 961, VNC :61) on labhost, `-snapshot`
  on the read-only seed image (no multi-GB copy; pool FREE was 36.5G). Torn down
  via QEMU monitor `quit` (no pkill). Live `osgallery-win95-1` left running/healthy.
- Did not edit `gallery-integrate-all.sh` (neko-era, deleted), the compose file, or
  any other station; did not touch VM 900/925 or CT 112.

---

# APPENDIX A — VIDEO LAYER deep-dive (neko encode pipeline)  [added by video agent 2026-07-04]

Supplements section #5 above with the exact, verified neko-side facts. Section #5's
"make guest res == neko screen" is correct and is the single deepest fix; the items
below are the neko encoder/client levers that also matter and need no seed-image edit.

## Verified encode pipeline (from `docker logs osgallery-win95-1`)
Image is **n.eko v3** ("nurdism/m1k1o dev@dev"). Default pipeline in effect (no
`capture.video.pipelines` set — log warns "no video pipelines specified, using default"):
```
ximagesrc display-name=:99.0 show-pointer=false use-damage=false !
  capsfilter caps=video/x-raw,framerate=2500/100 !     # 25 fps
  videoconvert ! queue !
  vp8enc target-bitrate=1996800 cpu-used=4 deadline=1 end-usage=cbr
    keyframe-max-dist=25 min-quantizer=4 max-quantizer=20
    undershoot=95 buffer-initial-size=6144 buffer-optimal-size=9216 buffer-size=12288 !
  appsink
```
- Codec **VP8**, ~**2 Mbps** CBR, **25 fps**, quantizer clamp **4..20**, `cpu-used=4`
  (fast/low-quality preset), captures the **full 1280x720** display.
- Audio: `opusenc bitrate=128000 inband-fec=true` (fine; crackle is upstream CPU, per #3).
- Client bundle `app.e62fe42e.js`: **zero `image-rendering` rules** → `<video>` upscaled
  bilinear (smoothed), never nearest-neighbor.
- `NEKO_SCREEN=1280x720@30` env OVERRIDES `neko.yaml desktop.screen: 1920x1080@60`.
- `/etc/neko/xorg.conf` smallest modeline is **800x600** — there is **no 640x480 mode**,
  so matching the neko screen to the 640x480 guest requires adding a modeline (below) OR
  raising the guest to 800x600/1024x768 as in #5 (preferred — more real detail).

## Blur decomposition (all three compound)
1. **640x480 guest in a 1280x720 frame** → 72% of every frame is black; 2 Mbps CBR is spent
   ~1/3 on real content and the rest re-encoding static black, and the browser bilinear-scales
   the whole frame (incl. black bars) to the station so guest pixels never land 1:1. (== #5.)
2. **VP8 `max-quantizer=20` + `cpu-used=4` + CBR** softens 1px text / dithered teal.
3. **No client pixelated rendering** → final upscale is smoothed.

## VIDEO changes (none require a seed-image edit; do alongside #5)

### A1 — pixelated client upscale  [HIGH perceived sharpness, LOW risk, do first]
Client sets no `image-rendering`. Serve a CSS override (extra `<style>` mounted over
`/var/www/index.html`, or a mounted css): 
```
video { image-rendering: pixelated; image-rendering: crisp-edges; }
```
Turns the browser upscale into crisp nearest-neighbor — the correct retro look. Instant,
reversible, independent of everything else.

### A2 — sharpen + de-waste the encoder  [MED-HIGH, MED risk = CPU]
Override the default via `NEKO_CAPTURE_VIDEO_PIPELINE` (single) on the win95 service:
```
NEKO_CAPTURE_VIDEO_PIPELINE=ximagesrc display-name=:99.0 show-pointer=true use-damage=true ! videoconvert ! vp8enc name=encoder target-bitrate=3000000 cpu-used=2 deadline=1 keyframe-max-dist=60 min-quantizer=2 max-quantizer=10 end-usage=vbr ! appsink name=appsink
```
Deltas: `max-quantizer 20→10` (higher floor quality on text), `cbr→vbr` (stop burning bits on
static frames), `use-damage=true` (only re-encode changed regions — also saves TCG CPU),
`cpu-used 4→2` (better encode). Simpler no-pipeline lever: `NEKO_VIDEO_BITRATE=3000` +
`NEKO_MAX_FPS=20` (helps but does not lift the quantizer ceiling). Note: after #5 raises the
guest to match the neko screen, 3 Mbps VBR over the now-fully-used frame is near-lossless.

### A3 — 640x480 modeline (only if you keep the guest at 640x480 instead of doing #5)
Add to the dummy Monitor + Screen Modes in `/etc/neko/xorg.conf`, then `NEKO_SCREEN=640x480@60`:
```
Modeline "640x480_60.00" 23.86 640 656 720 800 480 481 484 497 -HSync +Vsync
```
Prefer #5 (raise the guest to 800x600/1024x768) over this — more genuine detail = sharper.

### A4 — codec (optional)  [LOW-MED, MED risk on TCG box]
`NEKO_CAPTURE_VIDEO_CODEC=vp9` sharpens text at equal bitrate but competes for CPU with the
TCG guest. Only if #1 (KVM) frees CPU. Otherwise stay on VP8.

## Recommended VIDEO order
A1 (instant) → #5 (guest res == neko screen, kills black-bar blur) → A2 (crisp text) → then
A4/A3 as needed. All live screen tests here used the admin API and were RESTORED to
1280x720@30; the running station was left unchanged.

---

# APPENDIX B — VIRTUALIZATION / KVM LAYER deep-dive  [added by KVM agent 2026-07-04]

Independent re-verification of the TCG-vs-KVM hypothesis with the accel actually
exercised end-to-end. Confirms section #1 and adds the missing hard proof + one
correction. Live `osgallery-win95-1` (pid 12, TCG) left untouched and healthy; test
VM 961 torn down by pidfile (no pkill).

## Hard proof the live station is TCG, and KVM is available-but-unused
- Live qemu (pid 12) cmdline: no `-enable-kvm`/`-accel kvm` → TCG. Confirmed.
- `/proc/12/fd` contains **no /dev/kvm fd** (`NO_KVM_FD_OPEN`) → definitively not using KVM.
- ~36 min accumulated CPU on an idle desktop = TCG burn signature.
- KVM is present and usable, just never requested:
  - Labhost `/dev/kvm` = `crw-rw---- root:render (10,232)`; LXC 110.conf passes it in
    (`lxc.cgroup2.devices.allow: c 10:232 rwm` + `lxc.mount.entry: /dev/kvm`).
  - Inside the win95 container `/dev/kvm` = `crw-rw-rw-` (world-rw). This is made so at
    each start by **`/usr/local/bin/fix-kvm-perms.sh`** run as root via supervisord
    **`kvmperms.conf`** (priority 100, before qemu at 500) — because Docker's `devices:`
    recreates the node 0660 and neko's qemu runs as uid `neko`. Mechanism already in place.
  - `qemu-system-x86_64 -accel help` lists **tcg AND kvm**; binary is QEMU 10.0.8.

## KVM boot actually exercised (VMID 961, vnc 127.0.0.1:61, QMP)
Same seed qcow2, `-accel kvm -cpu host -m 256 -smp 1 -snapshot` (read-only seed, writes
to throwaway overlay). QMP `query-kvm` returned **`{"enabled":true,"present":true}`** — i.e.
KVM was genuinely engaged, not silently falling back. Guest booted to the Win95 splash
cleanly, no KVM error, no triple-fault. This is the direct proof the fix path works.

## Correction to sections #5 / Appendix A: guest native res is 640x480, not 1024x768
Framebuffer truth (neko admin `screen/shot.jpg` on the LIVE station + QMP screendump on the
KVM test): the guest renders **640x480** (boot logo 640x400). Appendix A section states the
"KVM test came up at 1024x768" (lines ~45/112) — not what I observed; the persisted mode in
the seed image is 640x480. Practical impact: the section-#5 plan (raise guest to
800x600/1024x768 and match `NEKO_SCREEN`) is still the right sharpness fix, but the image
does **not** already boot at 1024x768 — you must set + persist it (boot once without
`-snapshot`, change Display Properties, shut down clean, re-add `-snapshot`).

## CPU/-cpu recommendation nuance (host vs pentium)
Both `-cpu host` (my test) and `-cpu pentium` (Appendix section #1) run under KVM. For an
already-installed ancient guest, `-cpu pentium` is the *safer* pick (hides modern CPUID from
Win95); `-cpu host` is marginally faster but exposes modern features. Recommend keeping the
section-#1 `-enable-kvm -cpu pentium -smp 1`; only try `-cpu host`/`pentium3` if you want the
last few % and are willing to re-validate boot. Either way `-smp 1` (Win95 is uniprocessor).

## Disk/backend (no bottleneck for the 1-min load)
`-drive ...,if=ide -snapshot`, no explicit `cache=`. Seed qcow2 is volume-mounted **read-only**
+ `-snapshot` (throwaway overlay), so no image-corruption risk and no ZFS write amplification
on the seed. The ~1-min desktop appearance is **TCG CPU starvation, not I/O** — under KVM it
collapses to seconds. Optional micro-opt: add `cache=unsafe` to the ephemeral overlay (safe
precisely because `-snapshot` discards it), but it is a rounding error next to enabling KVM.

## Bottom line
Hypothesis CONFIRMED: win95 station is TCG. KVM is fully wired (device passthrough + perms fix +
binary support) and merely not requested by `launch-qemu.sh`'s assembled args. Enabling it
(section #1) is the single highest-impact fix and is proven to boot.

---

# MEASUREMENT & APPLIED-FIX PASS  [2026-07-04 — measure + apply + re-measure]

This pass built a reusable QoE harness, captured BEFORE numbers, APPLIED fixes to the live
win95 station, and re-measured. **Headline result: the diagnosis's #1 fix (enable KVM) does NOT
work for this guest — Win95 HANGS under KVM — so it was reverted.** Only the TCG-safe subset
was kept. All work touched the win95 service only (compose OVERRIDE, never the shared
`docker-compose.gallery-guests.yml`); VMs 900/925, CT 112 and sibling stations untouched.

## Historical neko measurement harness (retired 2026-07-16)

The following records how the deleted neko/Docker/WebRTC plane was measured in
2026-07-04; it is historical evidence, not a runnable procedure. The two named
probe files were removed after streamhost WebTransport became the only live
plane. Use `labctl health`, `labctl assert`, `scripts/dev/verify-tile.sh`, and
`tests/e2e-live/` for current verification.

- **Retired `gallery-perf-probe.mjs`** — zero-dependency Node (>=22) probe. Drove the
  system Chrome over the DevTools Protocol using Node's built-in `WebSocket`/`fetch` (no
  puppeteer, no chromium download). For any neko station it reported:
  - WebRTC video via `RTCPeerConnection.getStats`: encoded frameWidth/Height, fps
    (reported + measured from `framesDecoded` delta), receive bitrate, RTT, jitter,
    packetsLost, freeze/pause counters, availableIncomingBitrate.
  - Content geometry: the guest's non-black bounding box inside the capture frame and the
    **content-fill %** (the black-bar-waste metric).
  - **input->photon latency (ms)**: takes neko control, right-clicks the guest desktop to pop
    a Win95 context menu, and times the first video-pixel change of that region (N trials,
    min/median/max).
  - Historical invocation used port 8091 and eight trials; there is no current
    equivalent because streamhost does not expose neko WebRTC stats.
  - It required a **HEADFUL** browser for input latency: neko only forwarded mouse/keyboard to the
    guest once the client is pointer-engaged; headless Chrome gets *control* but its synthetic
    events are not forwarded. `--headless` gives WebRTC+geometry only (input reports null).
- **Retired `gallery-perf-cpu.sh`** — host+guest CPU sampler over SSH. Reported labhost
  loadavg, the station qemu's own CPU% (host-side `/proc` utime+stime delta — it finds the qemu
  PID uniquely by the guest-disk filename so it never mis-samples a sibling VM), qemu lifetime
  %CPU, whether KVM is engaged on the live cmdline, and whether a `/dev/kvm` fd is actually
  open in the running qemu.
- Framebuffer truth (per hygiene rule): guest state judged from real screenshots via the neko
  admin API — `POST /api/login {username:admin,password:admin}` then
  `GET /api/room/screen/shot.jpg` with the bearer token. (Also useful:
  `GET/DELETE /api/sessions` to list/clear stale viewer sessions.)

## Environment caveat that shapes the numbers
The station serves a **static desktop**, and neko encodes **on-change only**, so static fps is
1–5 and bitrate is single-digit kbps *by design* — not a defect. Input->photon is therefore
floored by the encode cadence (~250 ms–1 s between frames) on top of guest speed, and the
shared labhost had reconnecting viewer sessions (a sibling "baseline-*" probe kept re-appearing)
that contend for neko control. Net: absolute input-latency numbers are noisy; treat them as
order-of-magnitude, and lean on **content-fill %** and **CPU** for clean attribution.

## CRITICAL FINDING — KVM HANGS this Win95 guest (corrects sections #1 / Appendix B)

> **SUPERSEDED.** The hang was resolved by the Standard-VGA display-driver swap
> (the KVM recipe near the top of this file); the live `win95` launcher runs
> `accel=kvm` today (`streamhost/stations-manifest.sh`, image
> `win95-osr2-kvm.qcow2`). Kept for the diagnostic record.
Applied `QEMU_MACHINE=pc,acpi=off,usb=off,accel=kvm` + `QEMU_SMP=1` and force-recreated win95.
- KVM genuinely engaged: live cmdline had `accel=kvm`, and `/dev/kvm` fd was **open** in the
  qemu process (count 1) — verified, not a silent TCG fallback.
- **But the guest HANGS**: it froze at the "Enter Network Password" dialog with the dialog body
  **unpainted** (title bar only, no controls, no taskbar, no icons); successive framebuffer
  shots were byte-identical (frozen), and mouse/Enter/Escape had no effect. Reverting to TCG on
  the *same image* rendered the *same* dialog **fully** (User name "Steve Jobs", OK/Cancel) and
  the desktop loaded — proving the guest executes fine under TCG and hangs only under KVM.
- Tried the classic old-Windows-on-KVM stabiliser `kernel-irqchip=off`: qemu refuses to start —
  `"KVM does not support userspace APIC"` (and it is moot here anyway since `acpi=off` means no
  APIC). `split` has the same requirement.
- Why the diagnosis missed it: the isolated boot tests (VMID 961) only reached the **splash**;
  they never drove the full shell boot where the hang occurs.
- **Consequence:** mouse lag (#1), the ~1-min desktop load (#2), and audio crackle (#3) are all
  TCG-CPU-bound and **cannot be fixed without KVM**, which is not usable on this image as-is.
  Enabling KVM needs guest-side timing work first (e.g. a Win9x CPU-idle/timing TSR, a slowed
  TSC `-cpu pentium,tsc-frequency=…`, or re-testing the seed image after such a patch).
  **Do not ship `accel=kvm` for win95 until the hang is resolved and framebuffer-verified.**

## What was APPLIED and LEFT RUNNING on the neko station (TCG-safe, verified booting to a full desktop)
Compose override `scripts/tools/win95-perf-override.yml` (neko-era, deleted; was also
placed at `/opt/osgallery/win95-perf-override.yml` on CT 110):

| key | baseline | applied | why |
|-----|----------|---------|-----|
| `QEMU_SMP` | (default 2) | **1** | Win95 is uniprocessor; drops a whole TCG emulation thread → less host contention. Zero guest downside. |
| `NEKO_SCREEN` | `1280x720@30` | **`800x600@30`** | match guest 4:3 → guest fills 66.8% of the frame vs 34.8% → ~half the black-bar bitrate waste; desktop fills the station. |

Apply / revert (neko-era commands, for the record):
```
# inside CT 110
cd /opt/osgallery
docker compose -f docker-compose.gallery-guests.yml -f win95-perf-override.yml \
  up -d --no-deps --force-recreate win95        # apply
docker compose -f docker-compose.gallery-guests.yml up -d --no-deps --force-recreate win95   # revert
```

## BEFORE / AFTER (same harness, live station)
| metric | BEFORE (TCG, `-smp 2`, 1280x720) | AFTER (TCG, `-smp 1`, 800x600) | note |
|--------|----------------------------------|--------------------------------|------|
| capture resolution | 1280x720 (16:9) | 800x600 (4:3) | matches 4:3 guest |
| **content-fill %** | **34.8 %** | **66.8 %** | **~2× less wasted black — the clean win** |
| guest content px | 636x504 top-left | 638x503 top-left | guest still native 640x480 |
| static fps (measured) | 1–5 | 1–5 | on-change encoding; unchanged by design |
| static bitrate | 5–45 kbps | 5–9 kbps | fewer bits on black |
| RTT | 5–28 ms | 5–123 ms | LAN-direct; both noise, network is not the bottleneck |
| packet loss | 0 | 0 | transport healthy |
| input->photon (right-click→menu) | erratic: 143 ms best, most attempts **dropped/>4 s** | 342 ms best, **median ~3.1 s**, 7/8 hits | still TCG-bound; only KVM would fix it |
| desktop-load after dismissing login dialog | ~1 min (user-reported; TCG) | still **>60 s** (measured >1200×50 ms) | TCG single-core; smp=1 can't speed Win95's own CPU |
| qemu CPU | TCG `-smp 2`, ~46 % lifetime | TCG `-smp 1`, ~10–20 % window | one fewer vCPU thread |
| KVM `/dev/kvm` fd | none (TCG) | none (TCG — KVM reverted, hangs) | see critical finding |

Framebuffer verification (neko admin `shot.jpg`): AFTER config boots to the **full interactive
desktop** — all icons + Start taskbar + clock — under TCG+smp1+800x600.

## Honest scorecard vs the four symptoms
1. **Mouse lag** — NOT fixed. Root cause is TCG CPU starvation; needs KVM (hangs). smp=1 gives
   a little labhost-contention relief only.
2. **~1-min desktop load** — NOT fixed (still >60 s). Pure TCG single-core speed; smp=1 doesn't
   speed the guest's one CPU. KVM required.
3. **Audio crackle** — NOT directly addressed (KVM was the fix; reverted). smp=1 frees some CPU
   which may marginally help; the `-audiodev` buffer hardening (section #3) needs a
   `launch-qemu.sh` edit and was not applied.
4. **Blurry video** — PARTIALLY improved: black-bar waste roughly halved (fill 34.8%→66.8%),
   so the desktop fills the station better and no bits are wasted on black. TRUE native-res
   sharpness still needs the guest raised to 800x600/1024x768 **in the seed image** (below).

## Remaining sharpness work (NOT applied — needs careful seed-image surgery / is fragile)
- **Raise the guest display mode** to 800x600 (or 1024x768) High Color and persist it. The seed
  qcow2 (`/data/gallery-guests/Win95/win95-osr2.qcow2`, 437 MB) is bind-mounted **read-only** and
  the live qemu holds a `-snapshot` read lock, so this must be done with the win95 service
  STOPPED: stop win95 → boot the qcow2 **RW under TCG** on labhost (KVM hangs, so TCG) →
  Display Properties → 800x600 → clean `Shut Down` → restart the service with matching
  `NEKO_SCREEN`. Then the guest fills the frame ~100% at real higher resolution = genuinely
  sharp. (Risk: a write to the shared seed image; do deliberately, ideally after a 437 MB
  backup — pool had 16–31 GB free during this pass.)
- **Client-side crisp upscale** (`video{image-rendering:pixelated}`) — the largest *perceived*
  sharpness win, but it requires injecting CSS into the neko-served web root (mount over
  `index.html`); left un-applied to avoid risking the working station with a fragile late mount.
- Note: the "Enter Network Password" dialog appears on **every** fresh `-snapshot` boot and must
  be OK-clicked before the desktop shows (this is the user's symptom #2 entry point). Auto-skip
  would require a guest-image config change (also a seed-image edit).

---

# WIN95 STATION GAMES — Duke3D + GTA fixed & captured to checkpoint  [2026-07-12]

Both games on the streamhost `win95` station failed to start for gallery viewers.
Root-caused with framebuffer evidence, fixed, clone-validated
(`/data/vms/soltest/win95-c3/`), replayed on the live station and captured with
`savevm golden`. `scripts/build-guests/tiles/win95.sh` now stages all of it for a
fresh capture (DUKE3D.CFG / DINO.BAT / STARTUP.INI / DIG.INI / desktop PIFs /
AUTOEXEC BLASTER line are embedded verbatim in the script).

## Duke Nukem 3D — missing DUKE3D.CFG
- Duke3D v1.1 **hard-exits at startup when `DUKE3D.CFG` is absent**
  (`ReadSetup: DUKE3D.CFG does not exist — Please run SETUP.EXE`); the DOS box
  just flashes and dies. SETUP.EXE had never been run before the earlier capture
  ("run SETUP.EXE first for sound" understated it: for v1.1 the CFG is a hard
  startup requirement, not a sound nicety).
- Fix: ran `C:\GALLERY\DUKE3D\SETUP.EXE` → Sound Blaster auto-detect
  (0x220/IRQ5/DMA1/HDMA5 — exactly the station's QEMU sb16; music **None**, the
  launcher has no OPL device) → save. The resulting CFG is captured into the
  checkpoint and embedded in `win95.sh`.

## GTA 1 — gta8 froze under VBEMP; retargeted to GTA24 (2026-07-14, CAPTURED LIVE)

The 07-12 gta8 fix below was correct **for the Standard-VGA checkpoint it was captured
on** — the 07-13 VBEMP recapture broke it one screen deeper than anyone had
tested. User-reported as "starting GTA crashes the VM".

- **Symptom / root cause:** `GTA8.EXE` launches fine under VBEMP (windowed DOS
  box → fullscreen PDM intro at 640×400 → menu at 640×480 all render), but at
  **level entry** the first street frame paints and then the display freezes
  while the game loop keeps spinning (~97 % vCPU busy, input apparently dead).
  Signature = VESA **page flipping**: gta8 flips display pages via VBE
  set-display-start, and under the VBEMP-era DOS-box display virtualization the
  scanout never follows — the game draws to a page that is never shown.
  Reproduced deterministically on a `/data/vms/soltest/win95-gta` clone with NO
  streamhost attached (so not a daemon/capture issue), with and without a QMP
  stop/cont in the history. Duke3D (mode-X direct writes, no VBE flipping) is
  unaffected. NOT the idle-pause gotcha, NOT the Settings-tab wedge (that one
  is vCPU-idle; this one busy-spins).
- **Fix (clone-validated via the desktop icon, then captured live):** retarget the
  launch chain to **`GTA24.EXE`** — the high-colour **VESA-LFB** build renders
  straight to the linear framebuffer (no page flip) and plays correctly
  (320×200 in-game; intro/menu unchanged). `GTA.pif` program path patched
  in-place in the FAT partition (raw byte patch at the PIF's program field —
  preserves the long-filename desktop label "GTA"), `DINO.BAT` → `gta24.exe`
  for the K.EXE chain. `scripts/build-guests/tiles/win95.sh` §6 stages gta24 + the
  retargeted PIF for fresh captures.
- **Capture record:** pre-swap checkpoint backed up as
  `tiles/win95/win95-golden.qcow2.bak-preGta24-1784042733`; old internal
  snapshot dropped, cold-booted the patched disk to the settled scene
  desktop, `savevm golden` 2026-07-14 18:29, daemon restarted, `labctl gen`.
  Verified end-to-end through the deployed UI (Chromium): icon double-click →
  intro → menu → Travis → map → **streamed live gameplay**, `labctl reset`
  back to the clean desktop.
- Client-side hardening shipped alongside (UI streamClient): the decoder is
  now rebuilt (never reconfigured in place) on SPS change, and a silent
  no-output decoder stall self-heals at the next keyframe — GTA's
  480→400→480→320×200 mode-switch chain is the stress case.

### Follow-up the same day — stray CLICK killed the fullscreen game ("VESA function 5h failed")

After the gta24 capture, launching still died for a REAL user while every scripted
run passed. Discriminated live (pause/resume exonerated by a scripted
4-minute-pause run): the difference was a **mouse click while the DOS box is
fullscreen**. warpnet injects clicks with Win32 `mouse_event` — a WINDOWS-level
click that punches through the fullscreen DOS box's input ownership (a physical
mouse can't: the DOS VM owns INT 33h). Windows deactivates the box on that
click, yanks the VGA, and the game's next VESA call fails → windowed
"Finished - GTA / Error 9,2: VESA function 5h failed" over a VBEMP transient
garbled desktop. Reproduced deterministically with one mid-intro click; also
explains historical flakiness reports for the other fullscreen DOS games.

**Fix (live, station.env + manifest):** `SH_WARPD_BUTTONS=qemu` — the win311
hybrid-buttons mode. Motion stays on the warpnet agent (absolute, drift-free);
buttons ride the real PS/2 device, so a fullscreen-DOS click lands in the
game's own INT 33h (no-op) instead of backgrounding it, and desktop clicks
keep working at the agent-positioned cursor (icon double-click verified — GTA
launches). No `SH_WARPD_BUTTON_DELAY_MS` needed (TCP agent, not win311's slow
serial). Verified: mid-intro click no longer kills the game; menu → Travis →
map → gameplay; in-game PS/2 stray clicks harmless.

## GTA 1 — Windows build unrunnable, DOS build is the working path (2026-07-12, gta8 target SUPERSEDED above)
- Desktop shortcut pointed at `C:\GALLERY\GTA\gtawin\GTAWIN.EXE`, which dies at
  load: **"A required .DLL file, DPLAYX.DLL, was not found"** — Win95 OSR2
  ships only DirectX 2 (no DirectPlay); GTA1's Windows build needs DX5+.
  Even after a DX install it would still be blocked: the KVM checkpoint runs the
  **Standard VGA** display driver (640x480x16, see cirrus-KVM deadlock above)
  which exposes **no 8/16-bpp DirectDraw modes**.
- Working fix (clone-validated to real gameplay, then replayed live): the rip's
  **DOS build** `C:\GALLERY\GTA\gtados\GTA8.EXE` (8-bit VGA) in a full-screen
  DOS box — QEMU's VGA BIOS provides the mode independent of the Windows
  display driver, and Win95 auto-switches a graphics-mode DOS box to full
  screen under Standard VGA. Config captured:
  - `gtados\DINO.BAT` = `gta8.exe` (was `gtafx.exe` = 3dfx, no Voodoo in QEMU),
    `STARTUP.INI` runtype `0` (Low Color) so K.EXE's "Run GTA" defaults right.
  - `gtados\DIG.INI` = Miles SB16 driver config (K.EXE "Configure Sound
    Details" → SB16 → "Device Successfully Detected!").
  - `C:\AUTOEXEC.BAT` gained `SET BLASTER=A220 I5 D1 H5 P330 T6` (Miles reads
    it for IRQ/DMA; the file was previously empty).
  - Desktop **`GTA.pif`** (patched byte-for-byte from the Duke PIF: target
    `C:\GALLERY\GTA\GTADOS\GTA8.EXE`, workdir `C:\GALLERY\GTA\GTADOS`)
    replaced the stale `GTA.lnk`. Icon double-click → PDM intro → menu →
    Liberty City gameplay.
- `gta24`/univbe and a VBEMP-style VBE desktop driver were NOT needed;
  DirectX 8.0a install was NOT needed (dead-end anyway per the DirectDraw
  point above). No CD device involved (rip is self-contained; the station has no
  cdrom and adding one is a forbidden device-set change).

## Driving the win95 station (quirks — verified 2026-07-12)
- ~~The warpd pointer agent on host port 57791 is **DEAD** in this checkpoint~~
  **SUPERSEDED 2026-07-13:** the agent is live again after the VBEMP checkpoint
  recapture — the live station runs `SH_POINTER=warpd` on `127.0.0.1:57791`.
  (Historical state: TCP accepted via slirp but nothing moved; QMP **abs**
  pointer events did nothing — PS/2 **relative** mouse only, `cdrv.py rel` +
  HMP `mouse_move`/`mouse_button`.)
- `ctrl`-/`alt`-letter **chords mostly do NOT register** via QMP send-key
  (ctrl-esc, alt-f4, ctrl-w, alt-enter all dead). WORKING: `meta_l` = Start
  menu, single letters/digits/arrows/ret/esc, `alt` **then** letter for menu
  bars, `alt spc` for the system menu (close windows with alt-spc, c).
- Desktop icons keyboard-only: click empty desktop (HMP mouse_button), then
  first-letter type-ahead cycles matching icons, `ret` launches.
- Win95 shutdown on this launcher DOES power the VM off (APM): after
  "Shut down the computer?" the qemu process exits by itself ~1-2 min later
  (pidfile removed) — wait for it instead of killing.
- Checkpoint recapture flow used here (disk-only changes, device set untouched):
  clean in-guest shutdown → qemu exits → back up qcow2 → `qemu-nbd` inject
  files offline → `qemu-img snapshot -d golden` → station launcher cold-boots →
  reach clean desktop → `savevm golden` via `/root/qmp_hmp.py` → `loadvm
  golden` verify → `systemctl restart streamhost@win95`.

---

<!-- APPENDIX: as-built image manifests, folded in from retro-gallery-guests.md (neko-era env contract; accel guidance superseded by the KVM recipe at the top of this file) -->

> **Image-name note:** the appendix predates the KVM recaptures — the live stations
> boot the `-kvm` variants (`win95-osr2-kvm.qcow2`, `win98se-kvm.qcow2`; the
> `win98se-games.qcow2` data disk is unchanged). See
> `streamhost/stations-manifest.sh`.

### Windows 95 OSR2

- **Labhost:** `/data/gallery-guests/Win95/win95-osr2.qcow2` (2 GiB virtual, ~1.4 GB free
  inside a single FAT32 partition)
- **Container:** `/guests-retro/Win95/win95-osr2.qcow2`
- **Env mapping:**
  ```
  QEMU_MACHINE = pc,acpi=off,usb=off
  QEMU_MEM     = 256           # Win9x max ~512
  QEMU_VGA     = cirrus        # comes up 1024x768 after first-run driver install
  QEMU_SOUND   = -device sb16,audiodev=snd
  GUEST_DISK   = /guests-retro/Win95/win95-osr2.qcow2
  GUEST_FMT    = qcow2
  GUEST_BOOT   = c
  QEMU_EXTRA   = -cpu pentium -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot
  ```
- **Software (all from `C:\GALLERY\`, README on desktop):** **Doom95**, **Duke Nukem 3D
  shareware** (needs `DUKE3D.CFG` — captured since 2026-07-12; without it v1.1 exits at
  startup), **Quake shareware** (WinQuake), and **GTA 1** — via the **DOS build**
  `gtados\GTA24.EXE` (desktop `GTA.pif`); the native Win build `gtawin.exe` does **NOT**
  run on this image (DPLAYX.DLL missing — OSR2 = DX2 only — and no 8/16-bpp DirectDraw
  modes on the Standard-VGA KVM checkpoint; see "WIN95 STATION GAMES" section above).
  **Netscape Communicator 4.05** and
  **Winamp 2.95** are **staged** one-click installers in `C:\GALLERY\INSTALL\`.
- **Critical:** the original Cirrus image needs TCG. The station-local settled scene
  uses KVM with std VGA, `kernel-irqchip=off`, and `-cpu pentium,-apic`; keep
  `acpi=off`/`usb=off`. Warpnet supplies its absolute pointer.
- **Footprint:** 437 MB. Only ~1.4 GB free inside; don't add >1 GB without repartitioning.

### Windows 98 SE

- **Labhost:** `/data/gallery-guests/Win98SE/win98se.qcow2` (8 GiB virtual, boot=c → **C:**),
  `/data/gallery-guests/Win98SE/win98se-games.qcow2` (→ IDE slave **D:**, all curated SW)
- **Container:** `/guests-retro/Win98SE/win98se.qcow2`, `.../win98se-games.qcow2`
- **Env mapping:**
  ```
  QEMU_MACHINE = pc,acpi=on
  QEMU_MEM     = 384           # keep ≤512
  QEMU_VGA     = std
  QEMU_SOUND   = -device sb16,audiodev=snd
  GUEST_DISK   = /guests-retro/Win98SE/win98se.qcow2
  GUEST_FMT    = qcow2
  GUEST_BOOT   = c
  QEMU_EXTRA   = -enable-kvm -cpu pentium3 -smp 1 -usb -device usb-tablet
                 -drive file=/guests-retro/Win98SE/win98se-games.qcow2,format=qcow2,if=ide,index=1
                 -netdev user,id=n0 -device pcnet,netdev=n0 -loadvm golden
  ```
- **Software:** **IE5** pre-installed (period browser, working). **Doom95** (+ shareware
  + Freedoom WADs), **Duke Nukem 3D shareware**, **Quake shareware** — **working
  drop-in** on `D:\GAMES\`. **Winamp 2.95** and **GTA 1** (Rockstar free release) are
  **staged** one-click installers on `D:\INSTALL\` (GTA1's modern re-release installer may
  refuse on 98 — fall back to the XP guest). **Netscape not included** (no clean free
  standalone source; IE5 satisfies the browser goal).
- **Note:** the one-time ACPI PCI/USB PnP cascade is manual and uses the complete CAB
  cache at `C:\WINDOWS\OPTIONS\CABS`; reproduce the transcript above before saving
  `golden`. Games disk = **D:**. KVM + `acpi=on` + usb-tablet is the verified profile.
- **Footprint:** 967 MB (592 + 375).
