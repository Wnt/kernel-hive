#!/usr/bin/env bash
# hw-acceptance.sh — acceptance / burn-in for the USED Supermicro SYS-5019D-FN8TP
# (X11SDV-8C-TP8F, Xeon D-2146NT, 128 GB ECC, Kingston DC2000B + WD Black SN7100).
# Run from a Debian/Ubuntu live env or the freshly-installed Proxmox host BEFORE
# trusting the box. Phases gate on hard-FAIL conditions. memtest + BMC steps are
# manual (noted); everything else is automated here.
#
# Validated baselines (vendor/STH, 2026): SN7100 1TB 7250/6900 MB/s, 600 TBW;
# DC2000B 240GB 4500/400 MB/s (400 write is by-design), 175 TBW, 0.4 DWPD, PLP;
# platform is PCIe Gen3 -> both NVMe cap ~3.5 GB/s seq; PSU 200W 80+Gold (single);
# idle ~50-65 W, AVX-512 load ~110-150 W at the wall. Tjmax ~100-105 C.
#
# HARD FAIL = any uncorrectable ECC error, NVMe media error / SMART fail, CPU
# thermal-throttle (core_throttle_count>0) or MCE, or a new critical SEL entry.
set -uo pipefail
LOG="${LOG:-/root/hw-acceptance-$(date -u +%Y%m%dT%H%M%SZ).log}"
exec > >(tee -a "$LOG") 2>&1
TEST_DIR="${TEST_DIR:-/var/tmp/hwaccept}"
mkdir -p "$TEST_DIR"
say() { printf '\n========== %s ==========\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || MISSING+=" $1"; }

say "PHASE 0  PREREQS + TOOLS"
MISSING=""
apt-get update -qq 2>/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  dmidecode edac-utils rasdaemon stress-ng mprime smartmontools nvme-cli fio lm-sensors \
  linux-cpupower iperf3 ipmitool pciutils util-linux cpu-checker >/dev/null 2>&1 || true
for t in dmidecode edac-util rasdaemon stress-ng smartctl nvme fio sensors turbostat ipmitool lspci kvm-ok; do need "$t"; done
[ -n "$MISSING" ] && echo "WARN missing tools:$MISSING (install manually if a phase needs them)"

say "PHASE 0b  BMC / IPMI + SEL AUDIT (used unit: READ the black box first)"
echo "[manual-if-remote] from a mgmt host: ipmitool -I lanplus -H <BMC_IP> -U ADMIN -P <PW> sel elist"
ipmitool mc info 2>/dev/null | grep -iE 'firmware revision|product' || echo "(in-band ipmitool unavailable; use lanplus from mgmt host)"
echo "--- SEL (prior faults — review EVERY line) ---"
ipmitool sel elist 2>/dev/null | tail -40 || true
echo "--- fans + temps + power baseline ---"
ipmitool sdr type Fan 2>/dev/null
ipmitool sensor 2>/dev/null | grep -iE 'temp|fan|vcc|power' | head -30
echo ">> ACTION: rotate the default BMC ADMIN password (prior owner knew it) and update BMC+BIOS firmware."
echo ">> After reviewing: 'ipmitool sel clear' to start burn-in from a clean log."

say "PHASE 1  MEMORY — memtest86+ (MANUAL, via IPMI virtual media)"
cat <<'TXT'
  1) Download memtest86+ v8.10 'Linux ISO w/ GRUB (64-bit)' from https://www.memtest.org/
  2) BMC iKVM > Virtual Media > mount ISO as virtual CD; BIOS: UEFI, Secure Boot OFF; boot it
  3) Run the default sequence; GATE: >= 4 full passes AND 0 errors (multithreaded -> a few hours, not days)
  ANY reported error address = HARD FAIL -> identify/reseat/swap DIMM, retest.
TXT

say "PHASE 2  PROVE ECC IS ACTIVE + start error daemon for the whole burn-in"
dmidecode -t 16 2>/dev/null | grep -iE 'Error Correction Type' || echo "(no dmidecode)"
dmidecode -t 17 2>/dev/null | grep -E 'Total Width|Data Width|Size|Speed' | head -16
modprobe skx_edac 2>/dev/null || true # CORRECT driver for Skylake-D (NOT ie31200/i10nm)
ls /sys/devices/system/edac/mc/ 2>/dev/null && echo "EDAC mc nodes present" || echo "WARN: no EDAC mc nodes (check BIOS exposes IMC / kernel skx_edac)"
systemctl enable --now rasdaemon 2>/dev/null || true
edac-util -v 2>/dev/null || true
ras-mc-ctl --summary 2>/dev/null || true
echo ">> GATE: Total Width 72 / Data Width 64 per DIMM + 'Multi-bit ECC' + 0 Uncorrected Errors."

say "PHASE 3  NESTED-VIRT ACCEPTANCE (this box runs Windows/macOS guests and the Kernel Hive tile fleet)"
echo -n "VT-x/kvm: "
kvm-ok 2>/dev/null || echo "(install cpu-checker)"
echo -n "nested kvm_intel: "
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo "(load kvm_intel)"
echo -n "VT-d/IOMMU groups: "
# shellcheck disable=SC2012 # counting entries under /sys/kernel/iommu_groups/ (kernel-numbered, not adversarial filenames)
ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l | xargs echo "groups ->"
echo ">> GATE: VT-x present, nested=Y after enabling, IOMMU groups > 0 (need intel_iommu=on for passthrough)."
echo ">> Also: actually boot one nested KVM guest post-Proxmox-install to confirm /dev/kvm inside a VM."

say "PHASE 4  CPU / THERMAL / STABILITY SOAK (run >=1h each; ideally overnight)"
sensors-detect --auto >/dev/null 2>&1 || true
echo "--- idle baseline ---"
turbostat --quiet --interval 5 sleep 15 2>/dev/null | tail -3 || sensors 2>/dev/null | grep -iE 'core|package' | head
echo "--- 4a non-AVX max-clock soak (stress-ng matrixprod) ---"
timeout "${CPU_SECS:-3600}" stress-ng --cpu 16 --cpu-method matrixprod --metrics-brief 2>&1 | tail -4 || true
echo "--- 4b AVX-512 worst-case heat (mprime Small FFTs) — run separately/interactively: 'mprime -t' ---"
echo "--- throttle + MCE check (MUST be zero) ---"
grep -H . /sys/devices/system/cpu/cpu*/thermal_throttle/*_throttle_count 2>/dev/null | awk -F: '$2!=0{print "THROTTLE:",$0; f=1} END{if(!f)print "throttle counts: all 0 (PASS)"}'
dmesg 2>/dev/null | grep -iE 'mce|hardware error|throttl' | tail -5 || true
ras-mc-ctl --errors 2>/dev/null | tail -5 || true

say "PHASE 5  STORAGE — SMART (USED: check wear/hours/errors) + fio + NVMe thermals"
nvme list 2>/dev/null || true
for d in /dev/nvme0 /dev/nvme1; do
  [ -e "$d" ] || continue
  echo "--- SMART $d ---"
  smartctl -a "$d" 2>/dev/null | grep -iE 'Model|Serial|Power On Hours|Power Cycles|Percentage Used|Data Units Written|Media and Data Integrity Errors|Available Spare|Critical Warning|Composite Temp' || nvme smart-log "$d" 2>/dev/null | grep -iE 'percentage_used|data_units_written|media_errors|critical_warning|temperature|available_spare'
  echo ">> GATE $d: Critical Warning 0, Media Errors 0, Available Spare > threshold, sane Power-On-Hours/Percentage-Used for a used drive."
done
echo "--- fio (run on an EMPTY scratch fs only; identify nvme0=DC2000B nvme1=SN7100 via 'nvme list') ---"
FIOF="$TEST_DIR/fio.bin"
fio --name=seqread --filename="$FIOF" --rw=read --bs=1M --iodepth=32 --numjobs=1 --direct=1 --size=8G --runtime=30 --time_based --ioengine=libaio --group_reporting 2>/dev/null | grep -iE 'READ:' || true
fio --name=seqwrite --filename="$FIOF" --rw=write --bs=1M --iodepth=32 --numjobs=1 --direct=1 --size=8G --runtime=60 --time_based --ioengine=libaio --group_reporting 2>/dev/null | grep -iE 'WRITE:' || true
fio --name=randread --filename="$FIOF" --rw=randread --bs=4k --iodepth=32 --numjobs=4 --direct=1 --size=8G --runtime=30 --time_based --ioengine=libaio --group_reporting 2>/dev/null | grep -iE 'read: IOPS' || true
echo "--- small-sync-write (WAL-style) fsync latency — run on the PLP Kingston (GATE: fsync 99p < 10 ms) ---"
fio --name=etcdfsync --filename="$TEST_DIR/wal.bin" --rw=write --ioengine=sync --fdatasync=1 --bs=2300 --size=22m --runtime=60 --time_based 2>/dev/null | grep -iE 'fdatasync|fsync|99.00th' | head -6 || true
echo "--- NVMe temps during/after write (1U: SN7100 runs hot) ---"
for d in /dev/nvme0 /dev/nvme1; do [ -e "$d" ] && nvme smart-log "$d" 2>/dev/null | grep -iE 'temperature|warning.*temp|critical.*temp'; done
echo ">> Expected seq ~3.0-3.5 GB/s (Gen3 cap); investigate sustained-write collapse (SLC exhaustion vs thermal throttle)."

say "PHASE 6  NETWORK — iperf3 every NIC (peer with another 10G host running 'iperf3 -s')"
echo "[manual] iperf3 -c <peer> -t 60 -P 4   ; and -R (reverse) ; per port: X557 10GbE, SFP+, i350 1GbE"
for p in /sys/class/net/*; do
  i=${p##*/}
  case "$i" in lo | veth* | docker* | wg* | vmbr* | tap* | fwln* | fwpr*) continue ;; esac
  sp=$(cat "$p/speed" 2>/dev/null)
  echo "iface $i speed=${sp:-?}Mb $(ethtool "$i" 2>/dev/null | grep -i 'Link detected')"
done

say "PHASE 7  POWER + FINAL SEL re-read + SIGN-OFF"
ipmitool dcmi power reading 2>/dev/null | grep -i 'instantaneous' || ipmitool sensor 2>/dev/null | grep -iE 'pwr|power' | head
echo "--- NEW SEL entries since clear (any new CRITICAL = FAIL) ---"
ipmitool sel elist 2>/dev/null | tail -20 || true
cat <<'TXT'

SIGN-OFF GATES (all must hold):
  [ ] memtest86+ >=4 passes, 0 errors
  [ ] ECC active (72/64 width, Multi-bit ECC) and 0 uncorrected errors after soak
  [ ] VT-x + nested=Y + IOMMU groups>0, and a nested guest booted
  [ ] CPU soak (non-AVX + AVX-512): throttle counts 0, no MCE
  [ ] both NVMe: SMART healthy, 0 media errors, sane wear; seq ~3+ GB/s; PLP drive fsync 99p <10ms
  [ ] NICs negotiate expected speeds, iperf3 near line-rate, no errors/drops
  [ ] power draw in the ~50-150W envelope; no fan/PSU faults
  [ ] BMC ADMIN password rotated; BMC+BIOS firmware current; SEL clean after burn-in
Log saved to: see $LOG
TXT
echo "ACCEPTANCE SCRIPT COMPLETE (review gates above)."
