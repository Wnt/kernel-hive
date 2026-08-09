#!/usr/bin/env bash
# =============================================================================
# build-guests/win11.sh — zero-click Windows 11 (25H2) install under RAW QEMU.
#
# WHAT THIS BUILD IS (read before editing):
#   The Proxmox-era recipe (scripts/provision/pve-win11-vm.sh, VM 900, since deleted) built
#   Windows 11 as a `qm` VM on a zvol and streamed it through an RDP bridge that
#   no longer exists. Every gallery exhibit today is a raw QEMU process under
#   streamhost@<tile>, so this builder reproduces the SAME hardware recipe with a
#   plain `qemu-system-x86_64` invocation writing a qcow2 — which is exactly what
#   a tile boots. Each block below is the raw-QEMU equivalent of one line of the
#   locked `qm create` recipe in docs/guests/win11.md:
#
#     --machine q35 --bios ovmf            ->  -machine pc-q35-11.0,smm=on + pflash
#     --efidisk0 …,pre-enrolled-keys=1     ->  a private copy of OVMF_VARS_4M.ms.fd
#     --tpmstate0 …,version=v2.0           ->  swtpm socket + -device tpm-tis
#     --scsihw virtio-scsi-single          ->  -device virtio-scsi-pci + iothread
#     --scsi0 …,ssd=1,discard=on           ->  scsi-hd rotation_rate=1, discard=unmap
#     --net0 virtio                        ->  virtio-net-pci (SLIRP, no host tap)
#     --agent enabled=1                    ->  virtio-serial + org.qemu.guest_agent.0
#     --ide2/--sata0/--sata1 cdrom         ->  three ide-cd on the q35 AHCI
#     --ostype win11                       ->  the hv_* enlightenments PVE implies
#
#   The machine type is PINNED (pc-q35-11.0) because the resulting qcow2 becomes a
#   golden with an internal `golden` snapshot: loadvm requires the device set to
#   match forever after.
#
# AUTOMATION HONESTY:
#   (1) VIRTIO ISO ... FULLY AUTOMATED (fetches stable virtio-win when missing).
#   (2) ANSWER FILE .. FULLY AUTOMATED (autounattend.xml -> unattend.iso).
#   (3) INSTALL ...... ZERO CLICKS. The one moment no answer file can reach is the
#       OVMF "Press any key to boot from CD" prompt; ~6 QMP send-key ENTERs cover
#       it. Do NOT flood — surplus keys leak into Setup and hit Cancel (pitfall 1,
#       docs/guests/win11.md).
#   (4) DONE PROOF ... qemu-guest-agent answers on the virtio-serial channel. That
#       only happens after OOBE and FirstLogonCommands ran on a real desktop.
#   (5) GOLDEN ....... Stage 2, NOT here: bake `savevm golden` on the tile.
#
#   The Windows ISO is operator-supplied (Microsoft copyright) — drop it in
#   $ISO_DIR. Nothing here downloads it.
#
# IDEMPOTENT: refuses to clobber an existing qcow2 without --force, and refuses
# to start a second QEMU while this build's pidfile is live. Kill only by pidfile.
# =============================================================================
set -euo pipefail

OS_ID="win11"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/Win11}"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
ISO_DIR="${ISO_DIR:-/data/isos/template/iso}"
WIN_ISO="${WIN_ISO:-Win11_25H2_EnglishInternational_x64_v2.iso}"
VIRTIO_ISO="${VIRTIO_ISO:-virtio-win.iso}"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
OUT_QCOW="$GUEST_DIR/win11.qcow2"

DISK_GB="${DISK_GB:-40}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
# Local admin the answer file creates. The password is read from a file so it
# never reaches a command line or a log; WIN_PASS still works for one-offs.
WIN_USER="${WIN_USER:-lab}"
WIN_PASS_FILE="${WIN_PASS_FILE:-/root/.win11-pass}"
# The "EnglishInternational" media is en-GB; feeding en-US re-shows the language
# page in WinPE and OOBE (pitfall 5).
LOCALE="${LOCALE:-en-GB}"
# Generic edition-SELECT key — skips the edition picker, is NOT a license.
EDITION_KEY="${EDITION_KEY:-VK7JG-NPHTM-C97JM-9MPGT-3V66T}"
EDITION_NAME="${EDITION_NAME:-Windows 11 Pro}"

OVMF_CODE="${OVMF_CODE:-/usr/share/pve-edk2-firmware/OVMF_CODE_4M.secboot.fd}"
OVMF_VARS_MS="${OVMF_VARS_MS:-/usr/share/pve-edk2-firmware/OVMF_VARS_4M.ms.fd}"

WAIT_MIN="${WAIT_MIN:-45}"
FORCE=0

for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --win-iso=*) WIN_ISO="${a#*=}" ;;
    --disk-gb=*) DISK_GB="${a#*=}" ;;
    --cores=*) CORES="${a#*=}" ;;
    --memory=*) MEMORY="${a#*=}" ;;
    --wait-min=*) WAIT_MIN="${a#*=}" ;;
    *)
      echo "unknown arg: $a" >&2
      exit 2
      ;;
  esac
done

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# --- QMP / QGA plumbing ------------------------------------------------------
# One tiny client for both sockets: QMP needs a capabilities handshake, the guest
# agent does not, and the agent socket simply refuses to answer until the driver
# and service are installed inside Windows — which is precisely the signal we
# want, so a failure here is data, not an error.
qmp() {
  python3 - "$WORK/qmp.sock" "$@" <<'PY'
import json, socket, sys
sock, payload = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
buf = b""
def line():
    global buf
    while b"\n" not in buf:
        buf += s.recv(65536)
    out, buf = buf.split(b"\n", 1)
    return json.loads(out)
def cmd(o):
    s.sendall((json.dumps(o) + "\r\n").encode())
    while True:
        m = line()
        if "return" in m or "error" in m:
            return m
line()
cmd({"execute": "qmp_capabilities"})
print(json.dumps(cmd(json.loads(payload))))
PY
}

qga_ping() {
  python3 - "$WORK/qga.sock" <<'PY' >/dev/null 2>&1
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-ping"}\n')
sys.exit(0 if b"return" in s.recv(65536) else 1)
PY
}

send_ret() { qmp '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}' >/dev/null; }

shot() {
  local png="$WORK/shots/$1.png"
  qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/shot.ppm\"}}" >/dev/null || return 0
  pnmtopng "$WORK/shot.ppm" >"$png" 2>/dev/null || cp "$WORK/shot.ppm" "${png%.png}.ppm"
  echo "$png"
}

# --- preflight ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root on the lab box"
[ -w /dev/kvm ] || die "/dev/kvm not writable — KVM is required"
for tool in qemu-system-x86_64 qemu-img swtpm swtpm_setup genisoimage python3; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
command -v pnmtopng >/dev/null || log "WARN: pnmtopng absent — screendumps stay PPM"
[ -s "$OVMF_CODE" ] || die "missing OVMF code: $OVMF_CODE"
[ -s "$OVMF_VARS_MS" ] || die "missing pre-enrolled-keys vars: $OVMF_VARS_MS"
[ -s "$ISO_DIR/$WIN_ISO" ] || die "operator must supply the Windows ISO: $ISO_DIR/$WIN_ISO"

if [ -n "${WIN_PASS:-}" ]; then
  :
elif [ -s "$WIN_PASS_FILE" ]; then
  WIN_PASS="$(head -c 200 "$WIN_PASS_FILE" | tr -d '\r\n')"
else
  die "no guest admin password: set WIN_PASS or write one to $WIN_PASS_FILE"
fi
[ -n "$WIN_PASS" ] || die "empty guest admin password"

if [ -f "$WORK/qemu.pid" ] && kill -0 "$(cat "$WORK/qemu.pid")" 2>/dev/null; then
  die "a build QEMU is already live (pid $(cat "$WORK/qemu.pid")); kill it by pidfile first"
fi
if [ -s "$OUT_QCOW" ] && [ "$FORCE" -eq 0 ]; then
  log "qcow2 already present ($OUT_QCOW); pass --force to rebuild. Done."
  exit 0
fi

mkdir -p "$WORK/shots" "$WORK/unattend" "$WORK/tpm" "$GUEST_DIR"
chmod 700 "$WORK"

# --- (1) virtio-win ----------------------------------------------------------
if [ ! -s "$ISO_DIR/$VIRTIO_ISO" ]; then
  log "fetching stable virtio-win ISO ..."
  curl -fSL --retry 3 -o "$ISO_DIR/$VIRTIO_ISO.part" "$VIRTIO_URL" || die "virtio-win download failed"
  mv "$ISO_DIR/$VIRTIO_ISO.part" "$ISO_DIR/$VIRTIO_ISO"
fi
file "$ISO_DIR/$VIRTIO_ISO" | grep -q ISO || die "virtio-win ISO looks invalid"
log "virtio-win: $(file -b "$ISO_DIR/$VIRTIO_ISO" | head -c 80)"

# --- (2) the answer file -----------------------------------------------------
# Unchanged from the proven Proxmox run: windowsPE injects the vioscsi/NetKVM
# drivers (WinPE cannot see a virtio-scsi disk without them) and writes the
# LabConfig bypasses; specialize re-enables the offline account path; oobeSystem
# creates the local admin, auto-logs in once, and installs the guest tools.
# Drive letters at WinPE time are not fixed, so every driver path is listed for
# D:, E: and F: — Setup silently skips the ones that do not exist.
cat >"$WORK/unattend/autounattend.xml" <<UNATTEND
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>D:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>E:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>F:\NetKVM\w11\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage><UILanguage>${LOCALE}</UILanguage></SetupUILanguage>
      <InputLocale>${LOCALE}</InputLocale><SystemLocale>${LOCALE}</SystemLocale>
      <UILanguage>${LOCALE}</UILanguage><UserLocale>${LOCALE}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
      <DiskConfiguration>
        <Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>128</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>FAT32</Format></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Format>NTFS</Format><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall><OSImage>
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>${EDITION_NAME}</Value></MetaData></InstallFrom>
        <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
      </OSImage></ImageInstall>
      <UserData>
        <ProductKey><Key>${EDITION_KEY}</Key><WillShowUI>OnError</WillShowUI></ProductKey>
        <AcceptEula>true</AcceptEula><FullName>${WIN_USER}</FullName><Organization>homelab</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>${OS_ID}</ComputerName>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order>
        <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
      </RunSynchronousCommand></RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>${LOCALE}</InputLocale><SystemLocale>${LOCALE}</SystemLocale>
      <UILanguage>${LOCALE}</UILanguage><UserLocale>${LOCALE}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add">
        <Name>${WIN_USER}</Name><DisplayName>${WIN_USER}</DisplayName><Group>Administrators</Group>
        <Password><Value>${WIN_PASS}</Value><PlainText>true</PlainText></Password>
      </LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>${WIN_USER}</Username><LogonCount>1</LogonCount>
        <Password><Value>${WIN_PASS}</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>reg add "HKLM\System\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine><Description>Enable RDP</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>netsh advfirewall firewall set rule group="remote desktop" new enable=Yes</CommandLine><Description>Allow RDP</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>cmd /c for %i in (D E F G H) do if exist %i:\virtio-win-guest-tools.exe start /wait %i:\virtio-win-guest-tools.exe /install /quiet /norestart</CommandLine><Description>Install VirtIO guest tools</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>4</Order><CommandLine>cmd /c for %i in (D E F G H) do if exist %i:\guest-agent\qemu-ga-x86_64.msi msiexec /i %i:\guest-agent\qemu-ga-x86_64.msi /qn /norestart</CommandLine><Description>Ensure qemu-guest-agent</Description></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
UNATTEND
chmod 600 "$WORK/unattend/autounattend.xml"
genisoimage -quiet -J -R -V UNATTEND -o "$WORK/unattend.iso" "$WORK/unattend/" || die "unattend ISO build failed"
log "answer file -> $WORK/unattend.iso"

# --- (3) disk, firmware vars, vTPM ------------------------------------------
rm -f "$OUT_QCOW"
qemu-img create -f qcow2 "$OUT_QCOW" "${DISK_GB}G" >/dev/null || die "qcow2 create failed"
cp -f "$OVMF_VARS_MS" "$WORK/OVMF_VARS.fd" # private copy == PVE's efidisk0
if [ ! -s "$WORK/tpm/tpm2-00.permall" ]; then
  swtpm_setup --tpm2 --tpmstate "$WORK/tpm" --createek --create-ek-cert \
    --create-platform-cert --lock-nvram --overwrite >"$WORK/swtpm-setup.log" 2>&1 ||
    die "swtpm_setup failed (see $WORK/swtpm-setup.log)"
fi
rm -f "$WORK/swtpm.sock"
swtpm socket --tpm2 --tpmstate "dir=$WORK/tpm" \
  --ctrl "type=unixio,path=$WORK/swtpm.sock" \
  --pid "file=$WORK/swtpm.pid" --terminate --daemon ||
  die "swtpm socket failed to start"
for _ in $(seq 1 20); do
  [ -S "$WORK/swtpm.sock" ] && break
  sleep 0.25
done
[ -S "$WORK/swtpm.sock" ] || die "vTPM socket never appeared"
log "vTPM 2.0 up (pid $(cat "$WORK/swtpm.pid" 2>/dev/null || echo '?'))"

# --- (4) launch --------------------------------------------------------------
rm -f "$WORK/qmp.sock" "$WORK/qga.sock" "$WORK/qemu.pid"
QEMU_ARGS=(
  -name "win11-install"
  -enable-kvm
  -machine "pc-q35-11.0,smm=on"
  -cpu "host,hv_ipi,hv_relaxed,hv_reset,hv_runtime,hv_spinlocks=0x1fff,hv_stimer,hv_synic,hv_time,hv_vapic,hv_vpindex"
  -smp "cores=${CORES},sockets=1"
  -m "$MEMORY"
  -rtc "base=localtime,driftfix=slew"
  # Secure Boot: SMM-protected flash + the MS-key vars copy above.
  -global "driver=cfi.pflash01,property=secure,value=on"
  -global "ICH9-LPC.disable_s3=1"
  -drive "if=pflash,unit=0,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,unit=1,format=raw,file=$WORK/OVMF_VARS.fd"
  -chardev "socket,id=chrtpm,path=$WORK/swtpm.sock"
  -tpmdev "emulator,id=tpm0,chardev=chrtpm"
  -device "tpm-tis,tpmdev=tpm0"
  -object "iothread,id=iothread0"
  -device "virtio-scsi-pci,id=scsihw0,iothread=iothread0"
  -drive "file=$OUT_QCOW,if=none,id=drive-scsi0,format=qcow2,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap"
  -device "scsi-hd,bus=scsihw0.0,drive=drive-scsi0,id=scsi0,rotation_rate=1,bootindex=200"
  # Install media first in the boot order; it falls through to the disk on every
  # later reboot because nobody presses a key then.
  -drive "file=$ISO_DIR/$WIN_ISO,if=none,id=cd-win,media=cdrom,readonly=on"
  -device "ide-cd,bus=ide.0,drive=cd-win,id=cd-win-dev,bootindex=100"
  -drive "file=$ISO_DIR/$VIRTIO_ISO,if=none,id=cd-virtio,media=cdrom,readonly=on"
  -device "ide-cd,bus=ide.1,drive=cd-virtio,id=cd-virtio-dev"
  -drive "file=$WORK/unattend.iso,if=none,id=cd-unattend,media=cdrom,readonly=on"
  -device "ide-cd,bus=ide.2,drive=cd-unattend,id=cd-unattend-dev"
  -netdev "user,id=n0"
  -device "virtio-net-pci,netdev=n0,id=net0"
  -device "virtio-serial-pci,id=vioserial0"
  -chardev "socket,path=$WORK/qga.sock,server=on,wait=off,id=qga0"
  -device "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"
  -device "qemu-xhci,id=xhci"
  -device "usb-tablet,bus=xhci.0"
  -vga std
  -display none
  -boot "menu=off,strict=on"
  -qmp "unix:$WORK/qmp.sock,server=on,wait=off"
  -pidfile "$WORK/qemu.pid"
)
log "launching QEMU (q35 + SecureBoot + TPM2 + virtio-scsi, ${CORES}c/${MEMORY}M) ..."
nohup qemu-system-x86_64 "${QEMU_ARGS[@]}" >"$WORK/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$WORK/qmp.sock" ] && [ -s "$WORK/qemu.pid" ] && break
  sleep 0.5
done
[ -S "$WORK/qmp.sock" ] || die "QEMU never opened its QMP socket — see $WORK/qemu.log"
log "qemu pid=$(cat "$WORK/qemu.pid") qmp=$WORK/qmp.sock qga=$WORK/qga.sock"

# --- (5) defeat the CD prompt ------------------------------------------------
# ~6 ENTERs across the ~12 s window. More than that leaks into Setup (pitfall 1).
log "injecting ENTER for 'Press any key to boot from CD or DVD' ..."
for _ in 1 2 3 4 5 6; do
  sleep 2
  send_ret || true
done

# --- (6) wait for the guest agent -------------------------------------------
log "waiting up to ${WAIT_MIN} min for qemu-guest-agent (proves Setup reached the desktop)"
TICKS=$((WAIT_MIN * 2))
for i in $(seq 1 "$TICKS"); do
  if ! kill -0 "$(cat "$WORK/qemu.pid" 2>/dev/null || echo 0)" 2>/dev/null; then
    die "QEMU exited during the install — see $WORK/qemu.log and $WORK/shots/"
  fi
  if qga_ping; then
    log "guest-agent answered. Windows is up."
    shot "done" >/dev/null || true
    log "disk: $(du -h --apparent-size "$OUT_QCOW" | cut -f1) apparent, $(du -h "$OUT_QCOW" | cut -f1) real"
    log "SUCCESS: $OUT_QCOW   login: ${WIN_USER} / (see the credentials note)"
    log "NEXT: shut the guest down cleanly (system_powerdown over QMP), then wire"
    log "the tile — copy the launcher device set above into the tile's"
    log "qemu-streamhost.sh, swap -display for dbus, and bake 'savevm golden'."
    exit 0
  fi
  if [ $((i % 5)) -eq 0 ]; then
    log "[$i/$TICKS] no agent yet; disk used=$(du -h "$OUT_QCOW" | cut -f1); shot=$(shot "t$i")"
  fi
  sleep 30
done

shot "timeout" >/dev/null || true
die "timed out after ${WAIT_MIN} min. VM still running (pid $(cat "$WORK/qemu.pid")); inspect $WORK/shots/"
