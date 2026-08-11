# QNX Neutrino 6.5 / Photon — gallery-hid absolute-pointer gate

Status: **STEP-1 HARD GO; PCI DRIVER PARTIAL/BLOCKED ON LICENSED TOOLCHAIN +
INPUT DDK (2026-07-16)**.

Goal: give the `qnx` station an ABSOLUTE-positioning mouse through the generic
`gallery-hid` "HW" device (`SH_INPUT_BACKEND=gallery`), exactly like Solaris.
Keyboard STAYS on the QEMU PS/2 path (gallery-hid does the absolute pointer
only). This document is the synthesis of three independent research passes; they
converge on the same verdict, event path, and plan.

## 0. 2026-07-16 gate result

The decisive abs-Y risk is closed: **GO**. On namespaced clone
`/data/vms/soltest/qnx-ghid-spike-3112` (VMID 3112, 640x480), framebuffer
screendumps showed the Photon cursor at `(30,30)` and `(30,455)` as distinct top
and bottom Y positions, as well as all four corners and centre. A press at
`(560,427)` expanded the Volume widget at that Y. Button-free samples also moved
the cursor. Evidence is committed under
`streamhost/guest-agents/qnx-galleryhid/evidence/`.

The preflight also resolved both toolchain unknowns:

- `which qcc` and `which gcc` both returned 1: neither compiler is in the guest.
- `/usr/include/devi.h` and `/usr/include/sys/devi.h` are both absent (`ls`
  returned 2). No Input DDK header/source set was found on the clone, checkpoint, or
  LiveCD.

The official QNX 6.5 SDP installer was tested in an isolated clone directory and
stopped at its license-key prompt; no key was available or bypassed. QNX's own
documentation says the Input DDK is not included in the SDP and must be obtained
separately. Thus the requested `fake-abs.so` could not be built legally on this
run.

The gate used a behaviorally equivalent fake source instead: a host-side Elo
SmartSet controller fed the shipping `devi-elo` protocol module, which produced
`packet_abs` samples and handed them to the stock `abs` filter. This directly
tests the unknown output path (`packet_abs` -> `abs` -> Photon) but does **not**
claim that the uncompiled custom module or PCI front end is verified. The
committed `galleryhid.c` is therefore an unbuilt porting draft, not a completed
driver.

Decision: iterate once a licensed QNX 6.5 SDP plus the separate Input DDK are
provided. Do not promote the live QNX station. AROS is not indicated because the
abs-Y gate passed.

---

## 1. The critical risk — the abs-Y question — VERDICT

**GO — framebuffer-confirmed on the namespaced clone described in section 0.**

The prior `usb-tablet` NO-GO on QNX ("Photon ignores absolute Y — clicks at
(940,72) and (940,696) both hit the bottom clock") is **NOT a fundamental Photon
limitation**. It is a *path-specific* defect in QNX 6.5's USB-HID input stack
(`devu-hid`/`devi-hid`): the tablet's HID report descriptor was mis-parsed and
its second absolute axis (Y) was collapsed / clamped / treated as relative
before it ever reached the devi absolute filter. That failure is attributable to
the HID-digitizer parser, not to Photon's pointer core.

Photon honors true absolute X **and** Y from a driver that uses the documented
**absolute-device path** — the same path every QNX touchscreen driver uses
(`devi-elo`, `devi-microtouch`, `devi-egalax`, `devi-zytronic`, `devi-penmount`).
Touch panels are QNX's core industrial/automotive HMI market; they position the
cursor absolutely in both axes. A custom `gallery-hid` module that declares class
`DEVI_CLASS_ABS` and emits `struct packet_abs` takes that proven touchscreen
plumbing and **bypasses the broken `devi-hid` HID path entirely**.

### Residual driver risk (the abs-Y uncertainty itself is closed)

The `packet_abs` → abs-filter path is documented, used by shipping touchscreen
drivers, and is now framebuffer-proven with a synthetic source on this exact
6.5 build. The two previously identified uncertainties resolved as follows:

1. **Hover vs. contact.** The abs filter moved the Photon cursor from
   *continuous* position updates with
   `buttons=0` (gallery-hid streams hovering absolute position), not only while a
   contact/pressure is asserted. Mitigation: assert the `packet_abs`
   proximity/pressure (`z`) field on every position record (USB tablets hover on
   QNX, so the abs path supports proximity).
2. **Identity calibration.** `devi-elo ... -s abs -c` placed the cursor at the
   commanded positions across the 640x480 framebuffer.

### The decisive cheap pre-test (completed with the stock Elo protocol vehicle)

Isolate the one GO/NO-GO risk from all the expensive plumbing:

> Planned: on a clone, build a **trivial `DEVI_CLASS_ABS` combination module** fed by a
> FAKE source (reads `"x y"` from a FIFO/stdin, or sweeps Y). Load it with
> `devi-hirun -p ./fake-abs.so` (the DDK isolated-test mode). Framebuffer-verify
> (via `labctl shot`) that the Photon cursor lands at **distinct Y** (top vs
> bottom) and that a synthesized press activates the widget under it.

- **PASS (observed through the stock `devi-elo` producer)** → Photon honors
  absolute Y from `packet_abs`. GO confirmed.
- **FAIL** (even a hand-built `packet_abs` module cannot move the cursor in Y) →
  that is the genuine Photon dead-end → **STOP, fall back to AROS.**

This test needs only `qcc` + the Input DDK — no gallery-hid device, no patched
QEMU, no daemon. It resolves the whole task's viability in hours.

### The proven fallback that STILL yields absolute (de-risks the task)

Even if the abs filter mishandles Y, the **same custom driver** can instead emit
`struct packet_rel` DELTAS computed in-guest (`delta = target_abs - model`, with a
screen-clamped position model). QNX's relative Photon path is already proven 1:1
(the shipped `streamhost.relfix`). Critically, an **in-guest** driver posting rel
deltas has **NO QEMU PS/2 accumulator clamp** — and that clamp was the *sole*
reason the daemon-side abs→rel homing failed (`docs/guests/qnx.md`: lone
`RelMotion(-8192)` was a no-op, deltas re-merged/re-clamped in the PS/2
accumulator, landing at a variable offset). An in-guest rel driver sidesteps
that entirely and delivers true absolute positioning.

**The absolute output mode won, so neither the relative-mode experiment nor the
AROS fallback is required.**

---

## 2. The gallery-hid → Photon absolute-injection method

Build the driver as a QNX **`devi-hirun` combination device/protocol module** of
class `DEVI_CLASS_ABS` (`type = DEVI_MODULE_TYPE_DEVICE | DEVI_MODULE_TYPE_PROTO`).
It runs as a **second `devi-hirun` line** so it never disturbs the existing PS/2
keyboard line. Keyboard stays on the QEMU PS/2 path exactly like Solaris.

### Event path (try FIRST)

```
gallery-hid PCI INTA  ->  module pulse()  ->  drain BAR2 ring
   -> read 16-byte POINTER_ABS_STATE record (x,y 0..32767, buttons, wheel)
   -> scale x,y to screen px (or hand raw + identity calibration)
   -> fill struct packet_abs { x, y, buttons, z(proximity), timestamp=clk_get() }
   -> send UP to the stock devi "abs" filter
   -> abs filter translates raw->screen coords + injects Ph_ev_ptr absolute
   -> Photon positions the cursor at (x,y)
```

### Calibration — identity/passthrough (no interactive calibration)

gallery-hid coords are per-axis normalized `0..32767`. Use a deterministic
**identity** calibration so raw == screen with no skew:

- calib file search order: `-f file` → `ABSF` env → `/etc/system/config/calib.<hostname>`
- format: `XL,YL:XH,YH:XRL XRH YRL YRH SWAP` (screen lo/hi, raw lo/hi, axis-swap)
- identity for 1024×768: screen `0,0 → 1023,767`, raw `0..32767` each axis, `SWAP=0`.

Alternatively scale inside the module (`ghid_map_coordinate(v,size) =
(v*(size-1)+16383)/32767`, ported verbatim from Solaris) and hand the abs filter
an identity calib.

### The pass gate (the exact test usb-tablet failed)

On the clone, drive absolute to the **four corners + center**, and click at
**(940,72) vs (940,696)**; prove via `labctl shot` that they land at DISTINCT
positions and activate DIFFERENT widgets. This is the precise gate usb-tablet
failed; passing it is the whole point.

---

## 3. QNX driver model & the Solaris → QNX port

The reference is
[`streamhost/guest-agents/solaris-galleryhid/galleryhid.c`](../../../../streamhost/guest-agents/solaris-galleryhid/galleryhid.c).
The **transport half ports almost 1:1**; only the OS glue and the output sink change.

### Ports near-verbatim (transport-identical)

- The entire `GHID_*` constant header — copy
  [`gallery-hid-proto.h`](../../../../streamhost/qemu-patches/gallery-hid/gallery-hid-proto.h)
  as-is (PCI `1b36:0015` rev 01 class `0xff00`; BAR0 4 KiB MMIO control; BAR2
  8 KiB `GLIN` ring, 256 × 16-byte records; INTA level-triggered, no MSI).
- BAR-header validation (`DEVICE_MAGIC=='GHID'`, `ABI==0x00010000`,
  `FEATURES&0xf==0xf`, ring `MAGIC=='GLIN'`, `hdr_bytes==0x100`, `rec_bytes==16`,
  `entries==256`, `producer-consumer<=256`).
- Init/reset + `GHIN/GHOK`-independent guest arm: read producer, read epoch
  (fail if 0), `consumer=producer`, `last_epoch=epoch`, barrier,
  `DRIVER_READY=epoch`, `IRQ_ACK=IRQ_ALL`, `IRQ_MASK=IRQ_ALL`. (The `GHIN/GHOK`
  handshake is host↔device only; the guest driver never sees it.)
- ISR ring-drain state machine: acquire-load producer, per-slot copy 16 bytes
  from `RECORDS+((consumer&255)*16)`, validate, parse, inject, advance consumer;
  after the batch release-store `CONSUMER`, barrier, `GUEST_KICK=1`, W1C
  `IRQ_ACK=IRQ_RING`, re-check producer. Level INTx: return not-claimed if
  `IRQ_STATUS & IRQ_MASK == 0`.
- Record decode: `x=[4:6]`, `y=[6:8]` (0..32767), `buttons=[8:10]&0x1f`,
  `wheel_v=(i8)[10]`, `wheel_h=(i8)[11]`, `seq=[2:4]`. Sequence-fault tracking
  (`delta!=1 mod 65536` → inject release-all, continue).

### Rewritten for QNX

| Concern | Solaris (DDI/STREAMS) | QNX |
|---|---|---|
| PCI attach | `pci_config_setup`, `ddi_regs_map_setup` | `pci_attach_device()` / `pci_read_config32()`; set `PCI_COMMAND` MEM+MASTER via `pci_write_config16()` |
| BAR map | `ddi_regs_map_setup` | `mmap_device_memory()` for BAR0 (0x1000) + BAR2 (0x2000) |
| Reg/ring access | `ddi_get32`/`ddi_put32` acc handles | plain volatile LE loads/stores + explicit CPU/compiler barriers (BAR2 is prefetchable RAM) |
| Interrupt | `ddi_intr_alloc`/`add_handler` (FIXED) | `InterruptAttachEvent()` on the PCI-routed INTA (read the IRQ from the pci server / config — **never hardcode**), delivering a pulse → module `pulse()` runs the drain; `InterruptUnmask()` after W1C ack |
| **Event injection** | VUID `Firm_event` (`LOC_X/Y_ABSOLUTE`) → STREAMS mouse minor → Xorg | **fill `struct packet_abs` → send UP to the abs filter → Photon** |

**Drop entirely (~600 lines Solaris-only):** the whole VUID ioctl / `M_IOCDATA`
/ `M_COPYIN/OUT` machinery, `VUIDSFORMAT`/`MSIOBUTTONS`/`MSIOSRESOLUTION`, and the
STREAMS `qinit`/`streamtab`/`module_info`. QNX needs none of it — screen size
comes from Photon/calibration, not an ioctl.

**Driver `input_module_t` skeleton:** callbacks `init()` (one-time PCI attach +
BAR map + interrupt attach), `parm()` (cmdline), `reset()`, `pulse()` (INTA →
drain ring), `input()`/up-call (fill `packet_abs`), `devctrl()`, `shutdown()`.
Init order `init()→parm()→reset()`. Private state in `->data` (framework is
multithreaded/reentrant). `packet_abs` is defined in `<devi.h>`.

**Host-side dependency:** `SH_INPUT_BACKEND=gallery` and the native
`GalleryHidSink` currently live only in the `ghid-native-sink` worktree, not on
`main`. The orchestrator must land and deploy that work before a full end-to-end
test; this task intentionally does not copy or land it.

---

## 4. Toolchain & source delivery

### Toolchain — verified absent on the clone

- The station boots the QNX Neutrino 6.5 LiveCD, but direct guest checks proved the
  image is not self-hosting: neither `qcc` nor `gcc` is present.
- Two-part risk: (a) is `qcc` present? (b) is the **Input DDK**
  (`<devi.h>`, `input_module_t`, `packet_abs`, the devi module lib + skeleton)
  present? A runtime LiveCD may ship `qcc` but not the DDK.
- **Required mitigation:** provide a licensed QNX SDP 6.5 installation and the
  separate Input DDK on an off-labhost/clone-scoped build host, then cross-compile
  for `ntox86`. Public documentation is insufficient to reconstruct the missing
  licensed headers/libraries, and the installer license gate must not be
  bypassed.

### Source delivery into the guest

The **live `qnx` station has NO network device and NO exec channel** (launcher has
zero `-netdev`; device set = `pc-i440fx-11.0`, IDE checkpoint, `QNX650Live.iso`
boot d, Cirrus/std VGA, AC97, implicit PS/2; no USB, no NIC). Only
`labctl sh/type/key/shot` (blind keystrokes + screendumps) reach it.

Since the clone must add `gallery-hid-pci` anyway (a device-set change forcing a
fresh checkpoint recapture), source-delivery devices are "free" to fold into the same
capture:

- **Recommended:** build a second ATAPI CD ISO on labhost (`mkisofs`) carrying
  `galleryhid.c` + vendored DDK headers + `build.sh`. QNX auto-enumerates it
  (`devb-eide`) at `/fs/cd1`; mount, build, load, verify.
- **Alternative:** add `-netdev user` + `e1000` on the clone and SLIRP-fetch the
  tarball from the host at `10.0.2.2` (guest QNX ships `ftp`) via a ONE-shot
  atomic `ssh` that starts the host `python http.server`/FTP **and** does the
  in-guest fetch in the same command (backgrounded servers die between sessions).

### Persistence

The LiveCD runs from a RAM filesystem; `savevm golden` is a RAM snapshot. A
loaded `devi-hirun` line + its in-tmpfs `.so` are captured by the checkpoint snapshot
(exactly how the current `relfix` daemon and the Photon desktop already persist).
No on-disk install is required; the final live checkpoint needs neither the source-CD
nor a NIC.

---

## 5. Spike plan (cheapest-risk-first, each step framebuffer-gated)

0. **DONE:** toolchain probe proved `qcc`, `gcc`, and the Input DDK absent.
1. **DONE, GO:** the fake Elo source plus shipping `devi-elo` exercised the same
   `packet_abs`/stock-`abs`/Photon output path and framebuffer-proved distinct Y,
   hover movement, press hit-testing, and drag. The custom `fake-abs.so` variant
   was not buildable without the missing toolchain/DDK.
2. **Clone** the `qnx` station under `/data/vms/soltest/qnx-ghid-<ts>` with unique
   dir/VMID/`qmp.sock`/pidfile/ports; **copy** the checkpoint qcow2. Launch with the
   patched pve-qemu that carries `gallery-hid-pci`, adding
   `-chardev socket,id=ghid0,path=$D/gallery-hid.sock,server=on,wait=off`
   `-device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=pci.0,addr=0x1e`
   (verify addr free via `query-pci`; shared level INTA with AC97 is fine) plus
   the source-CD. This is a device-set change → **cold-boot** to Photon and capture
   a FRESH clone checkpoint (do NOT `loadvm` the tablet-era checkpoint).
3. **Port** the Solaris transport into the module's device layer
   (`pci_attach_device` → `mmap_device_memory` → `InterruptAttachEvent` → `pulse()`
   ring-drain → `packet_abs`). Load as a second `devi-hirun` line, keyboard PS/2
   line untouched.
4. **De-risk the driver without the daemon** using the standalone exerciser
   [`streamhost/qemu-patches/gallery-hid/tools/ghid-inject`](../../../../streamhost/qemu-patches/gallery-hid/tools):
   `ghid-inject SOCKET pointer <x 0..32767> <y 0..32767> <buttons> <wv> <wh>` →
   corners + center → `labctl shot`, prove the cursor lands exactly and clicks
   activate widgets. **Then** wire the real path: `SH_INPUT_BACKEND=gallery` via
   the `GalleryHidSink` (build from the `ghid-native-sink` worktree; NOT yet on
   `main`) and verify end-to-end through streamhost.
5. **One producer only:** disable the `relfix` relative daemon / `SH_POINTER=rel`
   while gallery abs is active (else double/fighting input). Capture the clone checkpoint
   with the gallery-hid `devi-hirun` line running.

---

## 6. Promotion plan for the LIVE qnx station

Only AFTER the **built PCI driver** passes the equivalent distinct-Y and
different-widget gate on a fresh clone checkpoint:

1. **Back up first** — snapshot the current live checkpoint
   (`golden.qcow2` + the `golden` VM-state), keep a `.bak-preGalleryHid` copy, so
   rollback is one `cp` + `loadvm` (follow the `qnx-upgrade` backup pattern).
2. **Add the device to the live launcher** —
   `streamhost/tiles/qnx/qemu-streamhost.sh` (and the manifest
   `streamhost/stations-manifest.sh`): add the `-chardev` + `-device gallery-hid-pci`
   exactly as validated on the clone. This is a device-set change → the existing
   checkpoint's `loadvm` will mismatch → a **full fresh checkpoint recapture is mandatory**
   (cold-boot to Photon, load the driver line, clean screendump, `savevm golden`).
3. **Set `SH_INPUT_BACKEND=gallery`** for the qnx station and **disable the rel
   pointer path** (`SH_POINTER`/relfix) so gallery-hid is the sole pointer
   producer. Keyboard stays on PS/2. Requires the `GalleryHidSink` merged to
   `main` + built on labhost (the ghid-native-sink work).
4. **Regenerate the capability matrix** — `labctl gen` (update
   `/data/vms/streamhost/tiles.json`) after the launcher change.
5. **Verify on the LIVE station via a browser drag** (not a `-display none` clone —
   the live station runs `-display dbus,p2p=on`; only the dbus peer path is
   representative). Prove full-screen absolute tracking + clicks land on the
   widget under the cursor. Roll back to `.bak-preGalleryHid` on any regression.

Note: the live checkpoint is currently **Cirrus/std 1024×768**; the identity calib
must match that mode. A resolution change needs a matching calib file recaptured.

---

## 7. Status & next decision

- **Gate:** hard **GO** for Photon absolute Y. See the committed framebuffer
  evidence for four distinct corners and the Volume-widget press at Y=427.
- **Driver:** partial. Source exists under
  `streamhost/guest-agents/qnx-galleryhid/`, but it is an uncompiled porting
  draft. No `.so` was loaded; the PCI path, source CD, fresh clone checkpoint, and
  `SH_INPUT_BACKEND=gallery` integration were not completed.
- **Recommended orchestrator decision:** **ITERATE**, supplying a licensed QNX
  6.5 SDP plus the separate Input DDK and landing the native sink dependency.
  Keep the live QNX station unchanged until the built driver passes the same
  framebuffer gate on a fresh clone checkpoint. Do not fall back to AROS: the
  decision gate passed.

### Key evidence

- Prior failure: `.claude/codex-tasks/qnx-upgrade/last.md` (abs-Y NO-GO via
  usb-tablet + devi-hid); `docs/guests/qnx.md` (pointer history, PS/2 accumulator
  clamp root cause, and the now-confirmed "no compiler" claim).
- gallery-hid ABI: `docs/lab/research/low-latency-input/qemu-transport.md`;
  `streamhost/qemu-patches/gallery-hid/gallery-hid-proto.h`, `gallery-hid-pci.c`,
  `README.md`; exerciser `tools/ghid-inject`.
- Reference driver: `streamhost/guest-agents/solaris-galleryhid/galleryhid.c`.
- Host sink: `streamhost/streamhost/src/realtime_input.rs` (`GalleryHidSink`,
  `SH_INPUT_BACKEND=gallery`; per-axis `0..32767` normalization; NOT yet on `main`).
- QNX Input DDK "Writing an Input Device Driver" (`input_module_t`,
  `struct packet_abs` → absolute filter → Photon; combination device/proto
  module; calib file format; `devi-hirun -p` isolated test). Touchscreen drivers
  (`devi-elo`/`devi-microtouch`/`devi-egalax`) prove Photon honors absolute Y.
- Official references: [Writing an Input Device Driver](https://www.qnx.com/developers/docs/6.5.0SP1.update/com.qnx.doc.ddk_en_input/write_driver.html),
  [QNX Neutrino DDKs](https://www.qnx.com/developers/docs/6.5.0SP1.update/650_webhelp/ddk_en/bookset.html),
  and [`pci_attach_device()`](https://www.qnx.com/developers/docs/6.5.0SP1/neutrino/lib_ref/p/pci_attach_device.html).
