# Windows 95 full-window drag tearing

Investigation date: 2026-07-15 UTC (the lab box crossed midnight in its local
timezone during the run). Lab host: `labhost`, QEMU 11.0.2. The live `win95`
and `win98se` launchers, disks, services, and goldens were not edited, stopped,
reset, or re-baked. Live interaction was limited to opening read-only property
pages and a drag route that returned the Win95 window to its starting position.
All driver changes were made to copies below
`/data/vms/soltest/win95-paint-tearing-20260715/`.

## Result

The Win95 tearing is a guest painting-path problem. Its current Microsoft
`VGA.DRV` is locked to 640x480x16-colour legacy planar VGA. With full-window
drag enabled, QMP screendumps taken while GDI repaints show detached horizontal
bands, stale window bodies, and partly repainted edges. Those defects are
already present in the real QEMU framebuffer, before WebRTC encoding and
independent of pointer transport.

The proposed Win98SE packed-pixel control was not present. Win98SE currently
uses its own Microsoft `VGA.DRV`, is also locked to 640x480x16 colours, and has
"Show window contents while dragging" disabled. It draws only an XOR outline,
so its apparently cleaner drag is not an apples-to-apples driver/depth result.

The least-invasive effective fix was nevertheless validated on a Win95 clone:
the latest available upstream JW Soft/BearWindows VBEMP release, with the QEMU
PCI ID added to its INF, retained `-vga std` and ran at 640x480 High Color
(16-bit packed VBE). The same full-content drag capture had no stale bands or
partial bodies in 0/8 evenly sampled frames, versus 9/9 torn samples on the
Microsoft VGA baseline.

## Exact live state

The following values were read from Display Properties and Device Manager, and
recorded in real framebuffer screenshots.

| Guest | Device Manager / driver files | Display mode | Full-window drag |
|---|---|---|---|
| `win95` | **Standard PCI Graphics Adapter (VGA)**; `C:\WINDOWS\SYSTEM\VGA.DRV`, `C:\WINDOWS\SYSTEM\vmm32.vxd (vdd.vxd)`; Microsoft `VGA.DRV` file version **4.00.1111** | **640 by 480 pixels, 16 Color**; palette offers only Monochrome and 16 Color | **Enabled** in the Plus! tab |
| `win98se` | **Standard PCI Graphics Adapter (VGA)**; `C:\WINDOWS\SYSTEM\VGA.DRV`, `C:\WINDOWS\SYSTEM\vmm32.vxd (vdd.vxd)`; Microsoft `VGA.DRV` file version **4.10.1998** | **640 by 480 pixels, 16 Colors**; palette offers only 2 Colors and 16 Colors | **Disabled** in the Effects tab |

This refutes the central hypothesis only in its Win98SE contrast: Win95 really
is on generic 16-colour planar VGA, but Win98SE is not currently on a packed
256-colour-or-better driver. QEMU exposes the same standard VGA PCI device to
both guests (`1234:1111`). QEMU documents its legacy VGA ports and separate
Bochs VBE interface at ports `0x1ce/0x1cf` in the
[Standard VGA specification](https://www.qemu.org/docs/master/specs/standard-vga.html).

The streamhost logs show a 640x480, 2560-byte-stride, 32-bit host scanout map for
both tiles. That is QEMU's rendered host surface, not evidence that the guest is
using packed pixels: `VGA.DRV` updates the four legacy guest bit planes and QEMU
materializes them into that host surface. A capture can therefore observe a
partially materialized planar repaint.

## Framebuffer proof

All paths in this section are on `labhost`.

### Win95 Microsoft VGA baseline

The live Win95 drag used the baked warpnet agent, 45 ms between each cursor
position and screendump, and returned to its original title-bar coordinate
before release. Every inspected PPM has at most the expected 16 VGA colours.

- Contact sheet:
  `/data/vms/soltest/win95-paint-tearing-20260715/live-win95-drag/seq/contact.png`
- Original PPMs and hashes:
  `/data/vms/soltest/win95-paint-tearing-20260715/live-win95-drag/seq/`
- Post-test clean framebuffer:
  `/data/vms/soltest/win95-paint-tearing-20260715/live-win95-drag/live-left-clean.png`

Nine evenly spaced samples all contain one or more characteristic incomplete
repaints: a title/client edge at an old Y coordinate, a horizontal strip from a
new position attached to the old window, or a client body whose right/bottom
portion has not arrived. The independent standard-VGA clone reproduced the
same signature:

- Clone contact sheet:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-std/evidence/std-drag-slow/contact.png`
- Clone originals:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-std/evidence/std-drag-slow/`

Because QMP `screendump` reads the real emulated framebuffer and catches these
states, the artifacts are upstream of input delivery, WebRTC frame rate, and
video encoding. The packed-mode A/B below removes them while leaving KVM, CPU,
machine type, QEMU standard VGA, resolution, warpnet input, and capture method
unchanged. That isolates the guest display driver/depth as the causal variable.

### Why current Win98SE looks cleaner

The Win98SE contact sheet shows only the moving XOR outline; the Notepad body is
never repainted during the drag:

- `/data/vms/soltest/win95-paint-tearing-20260715/live-win98-drag/seq/contact.png`
- Originals and hashes:
  `/data/vms/soltest/win95-paint-tearing-20260715/live-win98-drag/seq/`

This is consistent with its unchecked Effects option. It is useful evidence
that the observed live difference is configuration-confounded, but it cannot be
used as evidence for a packed Win98SE framebuffer.

## Fix experiments

All clones used KVM, one Pentium vCPU, 256 MiB RAM,
`pc-i440fx-11.0,acpi=off,usb=off,kernel-irqchip=off`, `-cpu pentium,-apic`, an
SB16, PCnet user networking, namespaced QMP/pidfiles/host forwards, and
`nice -n15`. QEMU processes were terminated only through their own pidfiles.

### (a) Select 256 colours on the existing Microsoft driver: unavailable

Win95 exposes only Monochrome and 16 Color. There is no 256-colour entry to
select, so a colour-depth-only fix is impossible with the current driver.

Evidence:

- `/data/vms/soltest/win95-paint-tearing-20260715/live-baseline/win95-colour-options.png`
- `/data/vms/soltest/win95-paint-tearing-20260715/live-baseline/win95-display-settings.png`

### (b) VBEMP on `-vga std`: effective and least invasive

Tested archive:

- Upstream page: [Universal VBE 9x Display Driver](https://bearwindows.zcm.com.au/vbe9x.htm)
- Download: `https://bearwindows.zcm.com.au/191201.zip`
- Upstream release date / INF `DriverVer`: **2019-12-01 / 19.12.0001**
- Archive SHA-256:
  `93d9bd34fc82904e827e0f4a5cee28beb3013c5d3d8b9730b5367a74b06acd3d`
- Variant: `032MB/{VBEMP.DRV,VBE.vxd,vbemp.inf}`. QEMU standard VGA exposes a
  16 MiB framebuffer BAR, so the smallest memory-limited universal build is
  sufficient.

Win95 OSR2 Have Disk filters on the device Hardware ID rather than the
compatible class ID already in the INF. The clone INF therefore added this
line immediately below `[Mfg]`:

```ini
%JWSoft.DeviceDesc% (QEMU Bochs VBE) = PCIVID, PCI\VEN_1234&DEV_1111
```

The upstream INF is CRLF. An initial `sed` expression anchored to `[Mfg]$`
silently matched nothing because of the trailing carriage return; patch it
with a CRLF-aware tool and verify the exact added line before injection.

The installed clone reported:

- Adapter: **VBE Miniport (QEMUBochsVBE)**
- Manufacturer: **JW Soft**
- Current files: `vbemp.drv`, `*vdd`, `*vflatd`, `vbe.vxd`
- Mode: **640 by 480 pixels, High Color (16 bit)**
- QEMU device: still standard VGA `1234:1111`; no device-set change

Evidence:

- Driver page:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-vbemp-191201/evidence/vbemp-advanced-driver.png`
- Depth page:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-vbemp-191201/evidence/vbemp-display-settings.png`
- Clean packed-mode drag contact sheet:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-vbemp-191201/evidence/vbemp-drag/contact.png`
- Original packed drag PPMs/hashes:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-vbemp-191201/evidence/vbemp-drag/`
- Key artifact hashes:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-vbemp-191201/evidence/key-evidence.sha256`

The packed capture used the same 45 ms drag/capture interval. Zero of eight
evenly sampled frames contains the baseline's stale bands or partial bodies;
the complete window tracks each title-bar position. This is the validated fix.

Cold boot is unusually slow on this image. The validated retry reached the
network-password dialog after about 1 minute 49 seconds, while an earlier cold
boot needed almost 3 minutes. A byte-identical splash over a short interval is
not enough to diagnose a hang; wait beyond three minutes and distinguish it
from the Cirrus GUI deadlock with framebuffer phase plus vCPU state.

The vendor labels 2019.12.01 **"Release version beta"**, and documents unresolved
generic moving-window/garbage issues. There is no newer stable-labelled Win9x
VBEMP release. This is the latest available upstream release and it passed this
specific QEMU 11.0.2/KVM drag test, but a strict "stable-labelled releases only"
policy requires an explicit exception before rebaking the live golden. The old
2008 Bochs-specific archive was also explored and is not recommended: a fresh
test ended in "adapter type is incorrect, or the current settings do not work
with your hardware." SciTech Display Doctor was not pursued after the current
upstream VBEMP build passed; SDD 7 for Win9x is likewise an abandoned beta and
has no current official stable artifact.

### (c) `-vga cirrus`: exposes packed modes, then deadlocks under KVM

QEMU documents Cirrus GD5446 as recognized by Windows 95 and recommends 16-bit
guest colour in the [QEMU system manual](https://www.qemu.org/docs/master/system/qemu-manpage.html#hxtool-5).
On this clone, Win95 loaded its native driver without external media:

- Adapter: **Cirrus Logic 5446 PCI**
- Chip: **CL-GD5446 Rev 0**, 4 MiB
- Current files: `cirrusmm.drv`, `*vdd`, `*vflatd`, `cirrus.vxd`
- Offered depths: 16 Color, 256 Color, High Color (16 bit), True Color (24 bit)

After selecting 256 Color, the warm restart stuck at "Windows is now
restarting". A pidfile-scoped stop and cold boot reached the network-password
frame but never painted its body. Two PPMs five seconds apart have identical
SHA-256
`2600d6a290c208cf5d3e32277aaec9db32e9c663d0c92bf2c4d4145f8c2c5e64`.
The vCPU remained at about 100%, `HLT=0`, in a 16-bit ring-3 loop
(`EIP=00001647`, `CPL=3`). This reproduces the image's known Cirrus/KVM
display-driver deadlock. It is not a deployable fallback under the required
KVM profile.

Evidence:

- Driver page:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-cirrus/evidence/cirrus-advanced.png`
- Offered palette:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-cirrus/evidence/cirrus-colour-options.png`
- Deadlock frames/hashes/registers:
  `/data/vms/soltest/win95-paint-tearing-20260715/clone-cirrus/evidence/deadlock-a.ppm`,
  `deadlock-b.ppm`, `deadlock.sha256`, and `deadlock-registers.txt`

## Recommendation and ranking

1. **Use JW Soft/BearWindows VBEMP 19.12.0001 at 640x480x16-bit on the existing
   `-vga std` device**, conditional on accepting the upstream beta label. It is
   the only tested option that removes the tear and does not change the QEMU
   device set. It still requires an in-guest install and a new golden bake.
2. **Outline-only drag is a mitigation, not the requested fix.** Clearing "Show
   window contents while dragging" immediately avoids full-window repaint, as
   current Win98SE demonstrates, but gives up the desired interaction.
3. **Do not use `-vga cirrus` with this KVM image.** Although it offers packed
   modes and is normally the classic Windows 95 answer, this guest's native
   Cirrus driver deadlocks under the mandatory KVM profile.

If beta-labelled drivers are prohibited without exception, there is currently
no validated policy-compliant packed-pixel fix that retains `-vga std`; keep the
live tile unchanged and use outline drag until a stable artifact is approved.

## Follow-up bake procedure (not performed in this investigation)

1. Schedule downtime. Stop `streamhost@win95` and its QEMU only by the live
   pidfile. Copy the complete qcow2 snapshot container to a timestamped rollback
   file before any offline mount.
2. Fetch `191201.zip` over HTTPS from the upstream URL above and require the
   recorded SHA-256. Extract the `032MB` files and add the exact `1234:1111` INF
   line shown above.
3. Offline-mount only the working copy and place the three files in
   `C:\VBEMP`. Cold boot the working copy with the unchanged production machine
   profile and `-vga std`; do **not** `loadvm golden`, because that would restore
   pre-injection disk/RAM state.
4. Open Display Properties -> Settings -> Advanced Properties -> Adapter ->
   Change -> Have Disk, enter `C:\VBEMP`, and select the explicit QEMU Bochs VBE
   model. Apply. A transient black/corrupt display during driver replacement is
   expected; stop only this candidate QEMU by its pidfile and cold boot again.
   Capture the staged Adapter page before Apply: selecting the nearby Standard
   Display Adapter entry instead switches Win95 to `MONO`/64 KiB and produces a
   misleading black-and-white boot.
5. Verify Adapter = `VBE Miniport (QEMUBochsVBE)`, mode =
   `640x480 High Color (16 bit)`, and full-window drag enabled. Repeat the real
   framebuffer sequence with
   `streamhost/guest-agents/win9x/capture-win95-drag.py`. Also smoke-test the
   Start menu, Notepad, and curated DOS games before accepting the driver.
6. Only after approval, delete/replace the candidate's old `golden` snapshot,
   `savevm golden`, cold-launch a new process with `-loadvm golden`, and verify
   the framebuffer and warpnet input again. Transplant/re-bake through the
   normal golden workflow. The launcher remains `-vga std`.

Rollback is a whole-file restore: stop the candidate/live QEMU through its
pidfile, replace the modified snapshot container with the timestamped pre-VBEMP
qcow2, and start the unchanged `-vga std` launcher. Do not try to mix a disk or
saved RAM state from the Cirrus experiment with the standard-VGA device set.

## Reproduction helpers

- `streamhost/guest-agents/win9x/launch-win95-paint-clone.sh` requires an
  explicit inactive `SOURCE_DISK`, creates only a namespaced soltest directory,
  keeps the production KVM profile, and terminates only by its own pidfile.
- `streamhost/guest-agents/win9x/capture-win95-drag.py` captures real QMP PPMs
  while warpnet performs a deterministic full-window drag and returns the
  window to its starting position.

The complete experiment root is
`/data/vms/soltest/win95-paint-tearing-20260715/`; aggregate contact-sheet
hashes are in `analysis/contact-sheets.sha256`, and all experiment QEMUs stopped
by pidfile are recorded in `clone-stop.log`.
