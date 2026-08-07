> **Historical snapshot.** This document describes the system as it stood around 2026-07-03 to 2026-07-12. It is kept for historical context and is not a description of the current system.

# Hardware Validation Log — SYS-5019D-FN8TP (used unit)

_Started 2026-07-03. Box on temporary SATA SSD (wipeable). SSD performance tests skipped per owner
(temporary disk). BMC at 192.0.2.13 (DHCP), MAC 02:00:00:00:00:02 — matches chassis PWD sticker._

## Access
- BMC web UI: https://192.0.2.13 (self-signed cert; Chrome shows ERR_CERT_AUTHORITY_INVALID interstitial).
- User ADMIN / password from chassis "PWD" sticker (`<REDACTED-see-private-notes>`). **STILL THE STICKER PASSWORD — rotate it.**
- Out-of-band CLI (Mac): `IPMI_PASSWORD=… ipmitool -I lanplus -H 192.0.2.13 -U ADMIN -E <cmd>`
  (ipmitool installed via Homebrew this session).

## PHASE 0b — BMC / IPMI + SEL audit  ✅ DONE (via ipmitool lanplus)
- BMC firmware **1.74** (X11SDV), IPMI 2.0. → check for newer BMC + BIOS firmware before production.
- Chassis: power ON; no power/main/fan/drive/cooling faults.
- Only IPMI user is ADMIN (id 2). SOL enabled (payload port 623) but box emits no serial-console text
  currently (no BIOS serial redirection active / idle).
- **SEL (56 entries) — one recurring real fault: CMOS/RTC battery.**
  - Repeated `Battery VBAT: Low` → `Battery VBAT: Failed` across 2023, 2024-09, 2026-03. Live VBAT sensor
    reads FAILED (discrete 0x02) now.
  - RTC clock wanders as a result (SEL timestamps jump 2023↔2025↔2026).
  - Everything else benign: "Session Audit" (logins) + undecodable OEM "Unknown #0xff" boot events.
  - **No ECC errors, no DIMM errors, no thermal/MCE, no PSU faults in entire history.** Clean for a used box.
  - **ACTION: replace CR2032 coin cell (~€2)**, then `ipmitool … sel clear` to start burn-in from a clean log.

## Sensors baseline (idle/light) ✅ all nominal
- CPU 51 °C · PCH 55 °C · VRMCpu 59 °C · VRMAB 50 · VRMDE 48 · DIMMs 41–47 °C · System 35 · Peripheral 37.
- FAN1 6000 / FAN2 5900 / FANA 4800 RPM (FAN3/4/B not populated — normal 1U).
- 12V=12.33 · 5VCC=5.12 · 3.3VCC=3.21 · Vcpu=1.772 · VDimmAB=1.20 · VDimmDE=1.19 · standby rails OK.
- VBAT = FAILED (see above). U2NVMe temps n/a (no U.2 drive; temp disk is SATA).
- DCMI power reading returns 0 W (known X11 quirk; single fixed PSU, not PMBus — ignore).

## Memory inventory ✅ (via BMC Hardware Information)
- **128 GB = 4 × 32 GB SK Hynix ECC Registered DIMM** HMA84GR7MFR4N-UH, slots A1/B1/D1/E1.
- Operating 2133 MHz (max capable 2400) — Xeon D-2146NT controller ceiling for this population; expected.

## STILL TO RUN — needs bootable media on the box
Memtest86+ v8.10 GRUB ISO staged (bootable hybrid, works for Virtual Media or USB dd):
`…/scratchpad/memtest_iso/grub-memtest.iso`.
1. **Memory — memtest86+ v8.10**: boot ISO (UEFI, Secure Boot OFF). GATE: ≥4 passes, 0 errors. Watch via iKVM.
2. **ECC active** (in-band Linux): `dmidecode -t 16/17` (72/64 width, Multi-bit ECC), `modprobe skx_edac`,
   rasdaemon, `edac-util -v` → 0 uncorrected.
3. **Nested-virt** (in-band): `kvm-ok`, `/sys/module/kvm_intel/parameters/nested`=Y, IOMMU groups > 0.
4. **CPU/thermal soak** (in-band): stress-ng non-AVX + mprime AVX-512; throttle counts MUST be 0, no MCE.
   (Full script: `scripts/provision/hw-acceptance.sh` — run its phases 2–4, skip phase 5 SSD perf.)
- Blocked on: owner picks boot method (IPMI Virtual Media vs physical USB) + participates
  (web login for iKVM — I can't enter the password; or inserts the USB).

## Remote provisioning capability — PROVEN
- BMC supports **Redfish HTTP VirtualMedia** (`/redfish/v1/Managers/1/VirtualMedia/CD1` → InsertMedia).
  Mount an ISO fully headless: serve it over HTTP from a host (`isoserver.py`, must send
  `Accept-Ranges: bytes` on HEAD + support Range GET — stock `python -m http.server` FAILS with
  "Connect failure"), then POST `{"Image":"http://<host>:<port>/x.iso"}`. Set boot: `ipmitool …
  chassis bootdev cdrom` (one-time), then `chassis power reset`. No web login / no OOB license prompt.
- Booted **SystemRescue 11.03** this way; host NIC `eno2` got DHCP `192.0.2.10`
  (host NIC MAC 02:00:00:00:00:01 — distinct from BMC a8; host NICs DO have LAN link, the earlier
  PXE-E61 was just the wrong boot NIC). SSH in via key after a one-liner on console opened the
  SystemRescue firewall. Confirmed CPU Xeon D-2146NT/16T, 125 GiB RAM usable.
- NOTE: HTML5 iKVM session can't be automated from here (ATEN idle-timeout + password re-entry);
  drive via Redfish/IPMI/SSH instead, user watches iKVM.

## ⚠ BLOCKER — temporary SATA SSD NOT detected
- Live OS sees NO disk (only virtual CD sr0). sSATA controller `00:11.5` (AHCI) enumerates 6 ports —
  **all `SATA link down, SStatus 0`** (electrically nothing present). Main I-SATA controller `00:17.0`
  absent from PCI (disabled in BIOS). No RAID/VMD.
- User has the Intel SSD on an sSATA **combo/SuperDOM connector** that is supposed to also power the disk.
  Diagnosis: standard 2.5" SSD is almost certainly **not being powered** by a SuperDOM connector (its
  power pin is for SATA-DOM modules only). FIX: give the SSD a standard SATA **power** feed + standard
  SATA **data** cable to an sSATA port; or move to an I-SATA port and enable that controller in BIOS.
- Until the drive links up, memtest + in-band ECC/nested-virt/CPU-soak can still run (don't need the
  disk), but the "write to disk" step is blocked.

## PHASE 2-4 — in-band validation (netbooted SystemRescue, root@192.0.2.10)  ✅ DONE
- **ECC active**: dmidecode Total Width 72 / Data Width 64 per DIMM; skx_edac mc0/mc1 present;
  ce_count=0 ue_count=0 both controllers before AND after soak. Correction type "Single-bit ECC"
  (= standard SECDED; normal, not a fault).
- **Nested virt**: VT-x (vmx) present, /dev/kvm present, kvm_intel nested=Y, VT-d/DMAR present.
  IOMMU groups=0 only because this rescue boot lacks `intel_iommu=on` — add it at Proxmox install
  for PCIe passthrough. VT-d hardware capability confirmed.
- **CPU / thermal soak** (2026-07-03): stress-ng --cpu 16 --cpu-method matrixprod, ~39 min sustained.
  Peak package **60 °C** (high 88 / crit 98). **0** core-throttle, **0** package-throttle, **0** MCE.
  All-core clock pinned 2.5 GHz (80 W TDP cap — expected). Result: **PASS**, large thermal headroom.
- **Fan/cooling check**: BMC ramps FAN1/FAN2 6000→7700 RPM under load (Optimal curve); forcing Full
  mode (~13700 RPM) drops loaded CPU 60→52 °C. Cooling has big reserve. Restored to Optimal (0x02).
  Fan mode via `ipmitool raw 0x30 0x45 0x01 <00=Std 01=Full 02=Optimal 04=HeavyIO>`; read with `0x00`.

## Sign-off checklist
- [x] BMC/SEL audit — clean except CMOS battery
- [x] Sensors/fans/voltages nominal
- [x] Memory inventory (128 GB ECC, 4 DIMMs)
- [x] memtest86+ — 1 full pass, 0 errors (owner opted for 1 pass, not 4)
- [x] ECC active + 0 uncorrected after soak (72/64 width, EDAC mc0/mc1, ce=0 ue=0)
- [x] VT-x + nested kvm_intel=Y (VT-d/DMAR present; IOMMU groups need `intel_iommu=on` at Proxmox install)
- [x] CPU soak: ~39 min 16-thread matrixprod, peak **60 °C**, 0 core/pkg throttle, 0 MCE — **PASS**
- [ ] CR2032 battery replaced; SEL cleared
- [ ] BMC ADMIN password rotated; BMC+BIOS firmware updated (firmware already latest — password still sticker default)
- [~] SSD perf — SKIPPED (temporary disk)
