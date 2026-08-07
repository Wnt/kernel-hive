# Phase-1 bare-metal provisioning

These files vendor the HTTP/iPXE/answer-file pieces used by
`docs/lab/MASTER-REPRODUCE.md` Phase 1. The flow keeps the large upstream
Proxmox ISO unchanged: `proxmox-auto-install-assistant` prepares PXE artifacts
whose installer fetches an editable answer file over HTTP.

## 1. Prepare the served directory

Create a private scratch directory outside the repository and copy the two
templates into it. Replace every `{{PLACEHOLDER}}` in the answer. The disk
selector is deliberately a serial-number match: confirm it against
`proxmox-auto-install-assistant device-info disk` before booting, because the
selected disk will be erased.

The HTTP fetch endpoint receives a POST containing installer hardware details.
`isoserver.py` drains that request body and returns the named static TOML file.
Do not place secrets or unrelated files in the served directory.

```bash
SERVE="$HOME/pve-provision"
mkdir -p "$SERVE/pve"
cp scripts/provision/pve-answer.toml.tmpl "$SERVE/pve/answer.toml"

# On a Linux system with the assistant installed. This emits vmlinuz,
# initrd.img, a prepared ISO, and an upstream-generated boot.ipxe.
proxmox-auto-install-assistant prepare-iso \
  --fetch-from http \
  --url "http://{{HTTP_SERVER_IP}}:58080/pve/answer.toml" \
  --pxe-loader ipxe \
  --output "$SERVE/pve" \
  /path/to/proxmox-ve_{{PVE_VERSION}}.iso

# The vendored template is useful when the chain URL must live outside the
# generated artifact directory. Replace its three placeholders, then publish
# it as $SERVE/boot.ipxe. Keep PVE_PREPARED_ISO equal to the emitted ISO name.
cp scripts/provision/boot.ipxe.tmpl "$SERVE/boot.ipxe"
```

Validate the edited answer with the same version of the assistant that prepared
the installer:

```bash
proxmox-auto-install-assistant validate-answer "$SERVE/pve/answer.toml"
rg -n '\{\{[^}]+\}\}' "$SERVE" && echo 'ERROR: unresolved placeholders'
```

Serve the directory on all interfaces. The default is port 58080:

```bash
scripts/provision/isoserver.py "$SERVE"
curl -I http://127.0.0.1:58080/ipxe.iso
curl -H 'Range: bytes=0-15' http://127.0.0.1:58080/ipxe.iso
```

The HEAD response must include `Accept-Ranges: bytes`; the range request must
return `206 Partial Content`.

## 2. Redfish virtual-media boot

Build or retain one small generic UEFI iPXE ISO whose embedded script chains to
`http://{{HTTP_SERVER_IP}}:58080/boot.ipxe`, and put that `ipxe.iso` in the
served directory. Give the HTTP server a stable address before embedding it.

Set the BMC password in an environment variable rather than putting it in shell
history. The Supermicro virtual CD enumerates as a USB CD-ROM, so `UsbCd` and
UEFI are required:

```bash
export BMC_HOST={{BMC_IP}}
export BMC_USER=ADMIN
export IPMI_PASSWORD='{{BMC_PASSWORD}}'
export HTTP_SERVER_IP={{HTTP_SERVER_IP}}

# A prior TrueNAS boot may have armed a hard-reset watchdog.
ipmitool -I lanplus -H "$BMC_HOST" -U "$BMC_USER" -E mc watchdog off

curl -skS -u "$BMC_USER:$IPMI_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X POST "https://$BMC_HOST/redfish/v1/Managers/1/VirtualMedia/CD1/Actions/VirtualMedia.InsertMedia" \
  -d "{\"Image\":\"http://$HTTP_SERVER_IP:58080/ipxe.iso\"}"

curl -skS -u "$BMC_USER:$IPMI_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X PATCH "https://$BMC_HOST/redfish/v1/Systems/1" \
  -d '{"Boot":{"BootSourceOverrideEnabled":"Once","BootSourceOverrideTarget":"UsbCd","BootSourceOverrideMode":"UEFI"}}'

ipmitool -I lanplus -H "$BMC_HOST" -U "$BMC_USER" -E chassis power reset
```

Poll the virtual-media resource until it reports `Inserted: true` and
`ConnectedVia: URI`, and watch the HTML KVM during the destructive install.
Eject with the `VirtualMedia.EjectMedia` action after the host is installed.

The server intentionally uses HTTP because this is an isolated provisioning
LAN. If that assumption changes, use HTTPS and configure the Proxmox installer
certificate fingerprint rather than exposing the answer on an untrusted LAN.
