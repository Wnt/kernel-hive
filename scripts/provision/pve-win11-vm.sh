#!/usr/bin/env bash
#
# pve-win11-vm.sh — Fully-automated, hands-off Windows 11 (25H2) VM builder for
#                   Proxmox VE 9.x, using an autounattend.xml answer-file ISO.
#
# Goal: ONE invocation, ZERO clicks -> Windows installs, first-logs-in, installs
#       the VirtIO guest tools (qemu-guest-agent) and enables RDP by itself.
#
# It runs everything over SSH against a Proxmox host. Point it at a host, give it
# a VMID + storage + the Windows/virtio ISO names, and it will:
#   1. fetch the stable virtio-win ISO (if missing)
#   2. build VM: q35 + OVMF + Secure Boot (pre-enrolled keys) + TPM 2.0 + VirtIO
#   3. generate an autounattend.xml + build UNATTEND ISO (genisoimage)
#   4. start the VM and inject ENTER via the QEMU monitor to defeat the OVMF
#      "Press any key to boot from CD or DVD..." prompt (the only manual moment)
#   5. poll until the qemu-guest-agent answers -> proves it reached the desktop
#
# Tested: PVE 9.2.2, Win11_25H2_EnglishInternational_x64_v2.iso, virtio-win 0.1.285
#
# See the Win11 guest doc in docs/guests/ for every pitfall + fix behind these choices.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------- parameters -----------------------------------
PVE_HOST="${PVE_HOST:-192.0.2.10}"
SSH_KEY="${SSH_KEY:?set SSH_KEY to the private key path}"
VMID="${VMID:-900}"
VMNAME="${VMNAME:-win11}"
STORAGE="${STORAGE:-data}"   # zfspool for disks (zvols)
ISOSTORE="${ISOSTORE:-isos}" # dir storage holding the ISOs
WIN_ISO="${WIN_ISO:-Win11_25H2_EnglishInternational_x64_v2.iso}"
VIRTIO_ISO="${VIRTIO_ISO:-virtio-win.iso}"
UNATTEND_ISO="${UNATTEND_ISO:-unattend.iso}"
ISO_DIR="${ISO_DIR:-/data/isos/template/iso}" # on-host path of ISOSTORE
DISK_GB="${DISK_GB:-40}"                      # sparse system disk
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
# Local admin created by the unattend file:
WIN_USER="${WIN_USER:-lab}"
WIN_PASS="${WIN_PASS:?set WIN_PASS — guest admin password (no default)}"
# UI/system locale to match the ISO (EnglishInternational == en-GB):
LOCALE="${LOCALE:-en-GB}"
# Generic edition-select key (skips the edition picker; NOT a license):
# VK7JG-...-3V66T => Windows 11 Pro.  For Home use YTMG3-N6DKC-DKB77-7M9GH-8HVX7.
EDITION_KEY="${EDITION_KEY:-VK7JG-NPHTM-C97JM-9MPGT-3V66T}"
EDITION_NAME="${EDITION_NAME:-Windows 11 Pro}"

VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

ssh_h() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${PVE_HOST}" "$@"; }
# shellcheck disable=SC2317 # kept as a documented manual/interactive helper alongside ssh_h; not currently called by this script
scp_h() { scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$1" "root@${PVE_HOST}:$2"; }

echo "==> Target: PVE ${PVE_HOST}  VMID ${VMID} (${VMNAME})  storage=${STORAGE}"

# --------------------- idempotency: bail if VM exists ----------------------
if ssh_h "qm status ${VMID}" >/dev/null 2>&1; then
  echo "!! VM ${VMID} already exists. Refusing to clobber. Destroy it first:"
  echo "     qm stop ${VMID} && qm destroy ${VMID} --purge"
  exit 1
fi

# ----------------------- 1. fetch virtio-win ISO ---------------------------
if ! ssh_h "test -f ${ISO_DIR}/${VIRTIO_ISO}"; then
  echo "==> Downloading virtio-win stable ISO..."
  ssh_h "curl -fsSL -o ${ISO_DIR}/${VIRTIO_ISO} '${VIRTIO_URL}'"
fi
ssh_h "file ${ISO_DIR}/${VIRTIO_ISO} | grep -q ISO || { echo 'virtio ISO invalid'; exit 1; }"
echo "==> virtio-win ISO OK"

# --------------------------- 2. create the VM ------------------------------
echo "==> Creating VM ${VMID}..."
ssh_h "qm create ${VMID} --name ${VMNAME} --ostype win11 --machine q35 --bios ovmf \
        --cpu host --sockets 1 --cores ${CORES} --memory ${MEMORY} \
        --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --vga std \
        --agent enabled=1 --boot 'order=ide2;scsi0'"
ssh_h "qm set ${VMID} --efidisk0 ${STORAGE}:1,efitype=4m,pre-enrolled-keys=1"               # Secure Boot w/ MS keys
ssh_h "qm set ${VMID} --tpmstate0 ${STORAGE}:1,version=v2.0"                                # TPM 2.0
ssh_h "qm set ${VMID} --scsi0 ${STORAGE}:${DISK_GB},ssd=1,discard=on,iothread=1,cache=none" # sparse system disk
ssh_h "qm set ${VMID} --ide2 ${ISOSTORE}:iso/${WIN_ISO},media=cdrom"                        # Windows install media (boots first)
ssh_h "qm set ${VMID} --sata0 ${ISOSTORE}:iso/${VIRTIO_ISO},media=cdrom"                    # VirtIO drivers CD

# ------------------- 3. build the autounattend.iso -------------------------
echo "==> Building autounattend.xml + UNATTEND ISO..."
ssh_h "mkdir -p /root/unattend-${VMID}"
# Write the answer file on the host (heredoc keeps quoting sane). Placeholders
# are substituted below via sed for the few parameterised values.
ssh_h "cat > /root/unattend-${VMID}/autounattend.xml" <<UNATTEND
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
      <SetupUILanguage><UILanguage>__LOCALE__</UILanguage></SetupUILanguage>
      <InputLocale>__LOCALE__</InputLocale><SystemLocale>__LOCALE__</SystemLocale>
      <UILanguage>__LOCALE__</UILanguage><UserLocale>__LOCALE__</UserLocale>
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
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>__EDITION_NAME__</Value></MetaData></InstallFrom>
        <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
      </OSImage></ImageInstall>
      <UserData>
        <ProductKey><Key>__EDITION_KEY__</Key><WillShowUI>OnError</WillShowUI></ProductKey>
        <AcceptEula>true</AcceptEula><FullName>__WIN_USER__</FullName><Organization>homelab</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>__VMNAME__</ComputerName>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order>
        <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
      </RunSynchronousCommand></RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>__LOCALE__</InputLocale><SystemLocale>__LOCALE__</SystemLocale>
      <UILanguage>__LOCALE__</UILanguage><UserLocale>__LOCALE__</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add">
        <Name>__WIN_USER__</Name><DisplayName>__WIN_USER__</DisplayName><Group>Administrators</Group>
        <Password><Value>__WIN_PASS__</Value><PlainText>true</PlainText></Password>
      </LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>__WIN_USER__</Username><LogonCount>1</LogonCount>
        <Password><Value>__WIN_PASS__</Value><PlainText>true</PlainText></Password>
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

# substitute parameterised values
ssh_h "sed -i \
  -e 's|__LOCALE__|${LOCALE}|g' \
  -e 's|__EDITION_NAME__|${EDITION_NAME}|g' \
  -e 's|__EDITION_KEY__|${EDITION_KEY}|g' \
  -e 's|__WIN_USER__|${WIN_USER}|g' \
  -e 's|__WIN_PASS__|${WIN_PASS}|g' \
  -e 's|__VMNAME__|${VMNAME}|g' \
  /root/unattend-${VMID}/autounattend.xml"

ssh_h "which genisoimage >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y genisoimage)"
ssh_h "genisoimage -J -R -V UNATTEND -o ${ISO_DIR}/${UNATTEND_ISO} /root/unattend-${VMID}/"
ssh_h "qm set ${VMID} --sata1 ${ISOSTORE}:iso/${UNATTEND_ISO},media=cdrom"

# ------------------------- 4. start + keypress -----------------------------
echo "==> Starting VM and injecting ENTER to defeat 'Press any key to boot from CD'..."
ssh_h "qm start ${VMID}"
# OVMF shows the CD prompt ~3-6s after power-on for ~5s and needs exactly ONE key.
# Send a FEW ENTERs spread across that window only. Do NOT flood: surplus keys
# leak into Windows Setup and can land on the "Installing Windows" Cancel button,
# popping an "Are you sure you want to quit?" modal that stalls the install.
# (If that ever happens, screendump the console and `qm sendkey <id> ret` on the
#  focused "No" button — see the Win11 guest doc in docs/guests/.)
ssh_h "for i in 1 2 3 4 5 6; do sleep 2; qm sendkey ${VMID} ret >/dev/null 2>&1; done"

# Optional visual sanity check: dump the framebuffer to a PNG you can inspect.
#   qm monitor ${VMID} <<< 'screendump /tmp/vm.ppm'; pnmtopng /tmp/vm.ppm > /tmp/vm.png

# --------------------- 5. wait for the guest agent -------------------------
echo "==> Waiting for qemu-guest-agent (proves unattended install reached desktop)..."
for i in $( # up to ~30 min
  seq 1 60
); do
  if ssh_h "qm agent ${VMID} ping" >/dev/null 2>&1; then
    echo "==> guest-agent responding. Windows is up. Fetching info:"
    ssh_h "qm agent ${VMID} network-get-interfaces" || true
    echo
    echo "SUCCESS: VM ${VMID} installed unattended. Login: ${WIN_USER} / ${WIN_PASS}"
    echo "Post-install cleanup (detach CDs, boot from disk):"
    echo "   qm set ${VMID} --delete ide2,sata0,sata1 && qm set ${VMID} --boot 'order=scsi0'"
    exit 0
  fi
  USED=$(ssh_h "zfs list -Hp -o used ${STORAGE}/vm-${VMID}-disk-2" 2>/dev/null || echo '?')
  echo "   [$i/60] agent not up yet; system-disk used=${USED} bytes; sleeping 30s..."
  sleep 30
done

echo "!! Timed out waiting for guest-agent. Open Proxmox UI -> VM ${VMID} -> Console to inspect."
exit 1
