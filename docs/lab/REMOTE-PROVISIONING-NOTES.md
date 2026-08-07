# Remote Provisioning Playbook & Gotchas — Supermicro SYS-5019D-FN8TP

_Hard-won lessons from driving this box fully remotely (BMC 192.0.2.13, X11SDV-8C-TP8F).
Read this before repeating any bare-metal provisioning so you don't re-hit these. Written as we
solved each issue._

> **2026-07-15 NVMe execution update:** the BMC credential was rotated, the PVE
> auto-install completed, and the post-install NIC/EFI observations below are the
> authoritative values from the real migration.

> **GO-FORWARD PREFERENCE (user, 2026-07-03): do NOT bake custom ISOs to bootstrap installs.**
> Use **PXE/iPXE + HTTP** instead. For Proxmox: netboot the installer kernel+initrd via the existing
> iPXE-via-vmedia chain and fetch the answer file over HTTP (`proxmox-auto-install-assistant
> prepare-iso … --fetch-from http`, or the `proxmox-start-auto-installer` kernel cmdline pointing at
> an answer URL served by `scripts/provision/isoserver.py`; start from
> `scripts/provision/pve-answer.toml.tmpl`). Editing a text file then beats rebaking a 1.6 GB ISO on every
> tweak, and keeps us on latest-stable. The 2026-07-03 dry-run Proxmox install used a baked ISO
> (`--fetch-from iso`) as a one-off; migrate to the PXE/HTTP path for all subsequent installs.

## Access model that actually works
- **Drive the box via Redfish + IPMI + SSH — NOT the web UI/KVM.** The BMC web session idle-times-out
  in ~60–90s and CANNOT be held from browser automation; and entering the BMC password into the web
  login form is disallowed by policy. So: use `ipmitool -I lanplus` and Redfish `curl` for everything
  (mount media, set boot, power, watchdog), and SSH into the booted OS for real work. The user watches
  the HTML KVM in their own browser and reports what's on screen.
- **BMC creds:** ADMIN / the rotated credential in the gitignored
  `docs/gallery-credentials.md` **`## BMC`** section. The chassis “PWD” sticker is
  obsolete. Pass the private value to ipmitool via `export IPMI_PASSWORD=…;
  ipmitool … -E`. For Redfish: `curl -sk -u "ADMIN:$PW"
  https://192.0.2.13/redfish/v1/…`.
- **Recommended recovery/rotation path:** when the host OS is reachable, rotate the
  BMC credential in-band with `ipmitool user set password 2` from the host. This needs
  no old BMC password because it uses the local IPMI device. The ADMIN credential was
  rotated this way on **2026-07-15**; immediately update the private `## BMC` record.
- **ipmitool/dnsmasq etc. installed via Homebrew.** `brew install ipmitool`.

## Chrome / browser tooling
- Use the **`chrome-devtools` MCP**, not `claude-in-chrome` (the extension wouldn't connect this session).
- **macOS "Local Network" privacy permission**: if Chrome shows `ERR_ADDRESS_UNREACHABLE` for a LAN IP
  (192.168.x) while `curl` works fine, it's this permission. System Settings → Privacy & Security →
  Local Network → enable Chrome. (Not fully resolved this session; we routed around it via CLI.)
- The self-signed BMC cert: `chrome-devtools` can get past it; if `net::ERR_CERT_AUTHORITY_INVALID`, the
  page often still loads the login form.
- HTML5 iKVM is **noVNC**. Its RFB object is `window.UI.rfb`. `UI.rfb.sendKey(keysym, code)` CAN type,
  but **keys auto-repeat / stick** (unreliable — e.g. produced `lsssss…`). Do NOT rely on KVM keyboard
  injection for real input; use netboot auto-provisioning + SSH instead.

## Redfish HTTP virtual media — THE reliable remote-mount path
- Device: `/redfish/v1/Managers/1/VirtualMedia/CD1`. It supports `InsertMedia` over HTTP streaming
  (OOB license present on this unit — a prior `ipxe.iso` mount proved it).
- Mount: `POST …/VirtualMedia/CD1/Actions/VirtualMedia.InsertMedia -d '{"Image":"http://<mac-ip>:<port>/x.iso"}'`
  (only the `Image` key — sending `TransferProtocolType` errors). Eject: `…/VirtualMedia.EjectMedia -d '{}'`.
  Poll `CD1` until `Inserted: true, ConnectedVia: URI`.
- **The HTTP server MUST support HTTP/1.1 + Range + send `Accept-Ranges: bytes` on the HEAD response.**
  Stock `python3 -m http.server` FAILS (BMC does a HEAD, then reports "Connect failure"). Use a custom
  threaded Range server: `scripts/provision/isoserver.py` (HTTP/1.1, explicit HEAD
  with Accept-Ranges + Content-Length, Range-capable GET, Proxmox answer-file POST).
  It binds to `0.0.0.0` by default; usage and a curl proof are in `scripts/provision/README.md`.
- BMC streams the ISO on demand: a full SystemRescue boot = thousands of range GETs; a stall at a few
  hundred means it only probed then booted something else.

## Boot device selection — the two traps
1. **The virtual CD enumerates as a USB CD-ROM** (`sr0`, TRAN=usb). So the boot override target must be
   **`UsbCd`**, NOT `Cd`. `ipmitool chassis bootdev cdrom` (generic/legacy CD) does NOT catch it when a
   UEFI OS is installed on the disk — the box just boots the disk. Use Redfish:
   `PATCH /redfish/v1/Systems/1 -d '{"Boot":{"BootSourceOverrideEnabled":"Once","BootSourceOverrideTarget":"UsbCd","BootSourceOverrideMode":"UEFI"}}'`
   then `ipmitool … chassis power reset`. (Redfish AllowableValues here: None,Pxe,Floppy,Cd,Usb,Hdd,BiosSetup,UsbCd.)
2. **Match the mode:** if the installed OS is UEFI (TrueNAS was), use `BootSourceOverrideMode: UEFI`.
   When the disk was empty earlier, plain `bootdev cdrom` worked because there was nothing else to boot.

Post-install EFI result on 2026-07-15: new `Boot0000` **“proxmox”** is first;
old-SSD `Boot0004` **“UEFI OS”** remains available for rollback until migration
Phase 8.

## Proxmox auto-install execution deltas (2026-07-15)

- `proxmox-auto-install-assistant prepare-iso --pxe-loader` requires the directory
  passed to `--output` to **already exist**. Create it before invoking the assistant.
- The artifacts were prepared on the **old Linux box**, where the assistant ran
  natively, and then pulled to the Mac for serving.
- The executed answer file used keyboard **`fi`**, FQDN **`labhost.lan`**,
  `lvm.swapsize=8`, `lvm.maxroot=32`, `lvm.maxvz=0`, disk filter
  `ID_SERIAL_SHORT=EXAMPLE0000000000` (replace with your own drive's serial, e.g. from
  `smartctl -i`), and NIC filter `*020000000001`.

## PVE NIC pinning — names and config rewrite

- `pve-network-interface-pinning` names the ports **`nicN`, not `pmx-nicN`**.
  On this box, MAC `02:00:00:00:00:01` (the uplink) became **`nic3`**.
- The pinning tool does **not** rewrite `/etc/network/interfaces`. Before running it,
  keep a copy as `interfaces.pre-pinning`; afterwards, rewrite the bridge port in
  `/etc/network/interfaces` yourself and verify connectivity before ending the session.

## IPMI watchdog — the "new OS almost boots then the box POSTs again" cause
- **TrueNAS/FreeNAS arms the BMC watchdog** (Timer Use: SMS/OS, Action: Hard Reset, ~137s). When you boot
  a different OS (SystemRescue) that doesn't pet it, the watchdog expires and **hard-resets mid-boot**.
  Symptom confirmed here: `ipmitool mc watchdog get` showed Expiration Flag (0x10 SMS/OS) set; SEL had a
  prior `Watchdog2 → Hard reset`.
- **Fix: `ipmitool -I lanplus … mc watchdog off` BEFORE booting rescue media** (and again if you ever
  boot back through TrueNAS). This was NOT a stray reset command — verify with `mc watchdog get`.

## Storage / SATA detection
- `ahci` is **built into the kernel** on SystemRescue (can't `rmmod`; it's not a module). If disks are
  missing, check `dmesg | grep -i ata`, `lspci | grep -i sata`.
- The **main I-SATA controller (00:17.0) can be absent from PCI = disabled in BIOS**; only the sSATA
  controller (00:11.5) was present at first. All 6 sSATA ports read `SATA link down (SStatus 0)` = nothing
  connected/powered.
- **Supermicro "combo/SuperDOM" sSATA connectors only power SATA-DOM modules, not a standard 2.5" SSD.**
  Putting a normal Intel SSD there → no power → link down. Fix: standard SATA power + data cable. Moving
  the SSD to **SATA 1** made it detected (it then booted the pre-existing TrueNAS off it).

## SystemRescue specifics
- Boots to an auto-login root console. `sr0` = ATEN Virtual CDROM (usb). Host NIC `eno2` gets DHCP.
- **Default firewall DROPS incoming → SSH unreachable** even though sshd runs. And root has no
  authorized_keys. Bootstrap once (per boot) with `scratchpad/iso-serve/go.sh` (session scratchpad,
  not vendored — a 4-liner: install the ed25519 pubkey, flush iptables/nft, start sshd, print the IP;
  the key was the session `scratchpad/lab_key`, also not vendored).
  The recurring one-liner (typed at the console): `curl -s http://<mac-ip>:58080/go.sh | sh`.
- Config system (cloud-init-like): YAML files in a `sysrescue.d/` dir on the boot media. Keys:
  `global.nofirewall: true`, `global.rootpass`, `autorun.ar_source` (fetch scripts over HTTP),
  `autorun.ar0..ar9` (inline scripts). **This is how we auto-inject the SSH key hands-free.**

## Mac-side gotchas
- **Plugging the Mac's ethernet changed its IP** (WiFi 192.0.2.15 → ethernet 192.0.2.16, plus a
  VLAN-30 addr). This breaks any mounted ISO URL / go.sh URL pinned to the old IP. Bind the HTTP server
  to `0.0.0.0` and re-point mounts/URLs after any interface change (`ipconfig getifaddr en0`).
- Scratchpad dir gets cwd-reset between Bash calls; use absolute paths.

## Firmware status (checked 2026-07-03)
- On the box: **BIOS 2.2, BMC 01.74.13** — these ARE the latest (Supermicro's only package is the bundle
  `X11SDV-TP8F_2.2_AS01.74.13_SUM2.14.0`; SHA256 f3f7a1f9…). EOL board, no newer firmware. Do NOT reflash.

## Validation results so far
- **memtest86+ v8.10: 1 full pass, 0 errors** (all 128 GB / 16 threads, CPU ~55 °C). memtest has no
  network output — must read Pass/Errors off the KVM visually.
- Pending in-band tests (need SystemRescue up + disk sorted): ECC-active, nested-KVM, CPU/thermal soak.

## The netboot direction (chosen 2026-07-03): iPXE via virtual media
- Mount a tiny generic **iPXE** image via Redfish virtual media (proven path); it `chain`s to an
  HTTP-served `boot.ipxe` on the Mac (port 58080, no privileged ports, no proxyDHCP/TFTP, no UniFi
  change). `boot.ipxe` netboots SystemRescue (kernel+initrd+squashfs over HTTP) with cmdline
  `nofirewall` + `ar_source=http://<mac>/…` autorun that installs the SSH key → box comes up SSH-ready,
  zero typing, and I edit boot.ipxe/autorun freely without ever re-baking the iPXE image.
- (Alternative considered: true dnsmasq proxyDHCP+TFTP PXE — more reusable across machines but needs root
  + is finickier; deferred.)

## iPXE netboot — BUILT & WORKING (2026-07-03)
The original artifacts lived under the session's `scratchpad/iso-serve/`. The reusable
pieces are now vendored under `scripts/provision/`: the Range server, `boot.ipxe.tmpl`,
the PVE answer-file template, and a Redfish/PXE walkthrough.
**Bake once, then edit HTTP files freely — never rebuild the iPXE ISO.**

1. **Build the iPXE UEFI ISO (once)** — colima on Apple Silicon is ARM64; iPXE x86 build fails native
   (`-m64 unrecognized`) AND segfaults under QEMU emulation. **Solution: native arm64 container +
   x86_64 CROSS-COMPILE** (`apt install gcc-x86-64-linux-gnu`; `make CROSS_COMPILE=x86_64-linux-gnu-
   bin-x86_64-efi/ipxe.efi EMBED=embed.ipxe`). Colima only mounts `$HOME`, so build under `~/…`, not
   `/private/tmp`. Package ipxe.efi as `/EFI/BOOT/BOOTX64.EFI` in a FAT ESP → xorriso UEFI ISO. Full
   script: `~/.claude-ipxe-build/build.sh`. Embedded script = `dhcp || dhcp; chain http://<mac>:58080/boot.ipxe`.
2. **Serve SystemRescue for netboot**: `tar -xf systemrescue.iso -C iso-serve/srescue sysresccd`
   (bsdtar reads ISO9660; macOS `hdiutil` REFUSES this ISO). Netboot paths:
   `srescue/sysresccd/boot/x86_64/{vmlinuz,sysresccd.img}` + `srescue/sysresccd/x86_64/airootfs.sfs` (896MB).
3. **`boot.ipxe`** (HTTP-served, editable). The Phase-1 Proxmox chain starts from
   `scripts/provision/boot.ipxe.tmpl`; this historical SystemRescue chain instead used
   the following kernel cmdline:
   `archisobasedir=sysresccd ip=:::::eth4:dhcp archiso_http_srv=http://<mac>:58080/srescue/ checksum
   copytoram sysrescuecfg=http://<mac>:58080/sysrescue.yaml ar_source=http://<mac>:58080/ar ar_suffixes=0 ar_nowait`.
   - **`copytoram`** = load the 896MB sfs into RAM so it needs the Mac only during boot.
   - **`sysrescuecfg=<url>`** loads a YAML (`sysrescue.yaml`: `global.nofirewall: true`) — opens SSH.
   - **`ar_source=<url>` + `ar_suffixes=0`** fetches `ar/autorun0` and runs it → installs `lab_key.pub`
     into root's authorized_keys, restarts sshd. → box comes up **SSH-ready, zero typing**.
   - **SPEED FIX:** archiso DHCPs every NIC serially at 20s each; the box has 5 (eth0–4). The CONNECTED
     one is **eth4 (MAC 02:00:00:00:00:01)**. `ip=:::::eth4:dhcp` pins to it → saves ~80s. (If cabling
     moves, edit this one line in boot.ipxe — no rebuild.)
4. **Boot it**: mount `ipxe.iso` via Redfish (UsbCd) + `mc watchdog off` + Redfish boot override
   `UsbCd`/`UEFI`/`Once` + `power reset`. iPXE ISO is generic & permanent; all logic is in the HTTP files.
- **Caveat:** the chain URL hardcodes the Mac IP (192.0.2.16). **Give the Mac a UniFi DHCP reservation**
  so it stays put — otherwise the baked iPXE image's URL breaks. If it does change, rebuild the tiny ISO
  (or better, reserve the IP).

## DONE 2026-07-03
- memtest86+: 1 full pass, 0 errors. **Firmware already latest** (BIOS 2.2 / BMC 01.74.13).
- **iPXE-via-vmedia netboot: WORKING, fully hands-free** (auto SSH via autorun). Speed-fixed to eth4.
- **FreeNAS/TrueNAS wiped** off the Intel SSD `/dev/sda` (INTEL SSDSC2CT120A3, 120GB, ser
  `EXAMPLE0000000000` — replace with your own drive's serial, e.g. from `smartctl -i`):
  `wipefs -a` + `sgdisk --zap-all` + `blkdiscard -f`. Disk is blank (empty GPT, 111.8 GiB free).
- **Still pending (in-band, can run now in this SystemRescue session):** ECC-active proof, nested-KVM,
  CPU/thermal soak (hw-acceptance.sh phases 2–4; skip phase-5 SSD perf per owner).

## Kernel Hive / nested-KVM in an LXC — gotchas (solved 2026-07-03/04)
Running QEMU with **KVM acceleration inside a Docker container inside a privileged LXC**. The whole
thing was reproduced by `scripts/pve-osgallery-deploy.sh` (neko-era, deleted in the 2026-07
restructure — git history; the gallery now runs as host-level streamhost tiles, see
`docs/lab/MASTER-REPRODUCE.md` Phases 3–5). The traps below are kept for any future
Docker+KVM-in-LXC workload:
- **QEMU in the neko container runs as uid 1000** (non-root). So the guest crash-loops with
  `Could not access KVM kernel module: Permission denied` unless `/dev/kvm` is reachable by uid 1000.
- **Docker `devices: [/dev/kvm]` recreates its OWN node at 0660 INSIDE the container** — a host-side
  `chmod 666 /dev/kvm` does **not** propagate in. **`group_add` is also useless** here: qemu is uid
  1000 *and* neko's supervisor strips supplementary groups. So neither host-chmod nor group_add fixes it.
- **Two things are needed and they come from different layers:** (a) the **cgroup device-allow** for
  major:minor **10:232** — provided either by the LXC line `lxc.cgroup2.devices.allow: c 10:232 rwm`
  *and* Docker's `devices:`, and (b) the node being **world-rw (0666)**. `volumes: [/dev/kvm:/dev/kvm]`
  (bind-mount) preserves the host mode but does NOT add the cgroup allow (→ `Operation not permitted`);
  `devices:` adds the allow but drops the mode to 0660 (→ `Permission denied`). **Winning combo: keep
  `devices:` for the cgroup allow + chmod the node 0666 from INSIDE the container** (container root
  *can* chmod it). We bake that into the `neko-qemu` image as a **root-run supervisord oneshot**
  (`kvmperms.conf` priority 100 → runs before qemu@500; `fix-kvm-perms.sh` = `chmod 0666 /dev/kvm`).
  Host-independent and reboot-safe — no host udev rule required.
- **Do NOT rely on a host udev rule to make `/dev/kvm` 0666.** The PVE host's shipped rule is
  `KERNEL=="kvm", GROUP="kvm", MODE="0660"`, and on this box something re-chowns the node to group
  `render` after CT/boot events, so an override rule loses the race. Fixing perms *inside* the container
  sidesteps all of it.
- **`lxc.apparmor.profile: unconfined` is NOT required** for KVM or for Docker-in-LXC here — verified by
  removing the line, rebooting the CT, rebuilding the neko-qemu image, and running both guests
  KVM-accelerated. The only apparmor denials in the logs are unrelated (dhclient). Minimal CT set =
  privileged + `nesting=1,keyctl=1` + the `cgroup2.devices.allow c 10:232 rwm` + the `/dev/kvm` bind
  mount. (Add unconfined back only if a future workload trips a real denial: `dmesg | grep -i apparmor`.)
- **No-auth neko:** this neko build (v3-dev) has member providers multiuser/file/object but **no
  `noauth`**. Auto-login is done at the tile URL with neko's query params
  `http://<ip>:<port>/?usr=guest&pwd=neko` → drops straight into the desktop, no login screen. In
  `setup.sh`, **escape `&` before the `sed`** that injects tile URLs (`${OSJSON//&/\\&}`) — an unescaped
  `&` in a sed replacement means "the whole match", corrupting the URL to `...guest__OSES__pwd=neko`.
- **neko healthcheck lies about the guest:** the container reports `(healthy)` when neko's web server is
  up even while qemu is crash-looping. Don't trust `docker compose ps`; verify the guest with
  `docker exec <svc> sh -c 'ls -l /dev/kvm; pgrep -a qemu-system-x86_64; grep -c "Permission denied" /var/log/neko/qemu.log'`.

## HARDENED nested-KVM-in-LXC — least-privilege, NO chmod 666 (validated 2026-07-04)
The chmod-666 approach above was the **testing** config; the least-privilege replacement was encoded
in `pve-osgallery-hardened.sh` (neko-era, deleted — the neko CT itself is superseded by the streamhost
tile flow); the validated security-posture table (testing vs hardened) has since been retired along
with that runbook. Provisioning gotchas discovered while validating it in a
throwaway CT 111 on PVE 9.2.2 (pve-container 6.1.10):
- **Use `dev0: /dev/kvm`** (PVE device passthrough) on an **unprivileged** CT (`nesting=1,keyctl=1`) with
  **default AppArmor**. It replaces the manual `cgroup2.devices.allow` + `mount.entry` AND works unprivileged.
  The in-CT node lands at **660 root:kvm** — exactly what we want, no world bit, no host chmod.
- **`pct set --dev0` APPENDS a duplicate `dev0:` line** (doesn't replace) → the CT then reads a stale/dup
  entry. Normalise the conf yourself: `sed -i '/^dev0:/d' /etc/pve/lxc/<ct>.conf; echo 'dev0: /dev/kvm' >>`.
- **The `dev0` `gid=`/`mode=` options are IGNORED on PVE 9.2** (only `uid=` is honored). Reason: the CT's
  **own systemd-udev re-applies the distro rule `KERNEL=="kvm", GROUP="kvm", MODE="0660"`** after boot,
  overwriting whatever `create_passthrough_device_node` set. Net effect = node is always **660, group = the
  CT's `kvm` group** (gid **993** on debian-13-std). So don't bother with `gid=`; instead **read the live
  gid** (`pct exec <ct> -- stat -c %g /dev/kvm`) and bake THAT into the Docker image.
- **The image fix that survives neko's supervisord:** `usermod -aG kvm neko` where the image's `kvm` group
  gid == the live in-CT gid (build-arg). neko's supervisord drops privs with **initgroups()** (recomputes
  supplementary groups from `/etc/group`), so a real membership survives where `group_add` did not. Verified
  `id` → `groups=1000(neko),993(kvm)`; and `qemu -enable-kvm -cpu host` + `ioctl(KVM_CREATE_VM)` succeed as
  neko even under `--user neko --cap-drop=ALL --security-opt=no-new-privileges`.
- **Docker runs fine unprivileged** in the CT (29.6.1, `overlayfs`, cgroup v2) — no `mknod` feature needed
  (runc bind-mounts `--device` nodes when it can't mknod in a userns).
- Proof qemu really used KVM (not TCG): `-enable-kvm` **hard-fails instantly** if KVM is unavailable, so a
  `timeout 4 qemu … -enable-kvm` that runs until the signal-15 kill == acceleration active. TCG never opens
  `/dev/kvm`, so a successful `KVM_CREATE_VM` ioctl is itself positive proof.

## STANDING RULE — always use LATEST STABLE tools/ISOs (user requirement 2026-07-03)
Always fetch the current latest **stable** release of any tool, package, or OS image — never reuse a
stale pinned artifact without checking currency. See memory `use-latest-stable-tools`.
- **Action carried over:** the pinned netboot image is **SystemRescue 11.03 (2024-12-06)** and has rotted —
  dead snapshot mirrors (`*.archive.pkgbuild.com` NXDOMAIN), defunct `[community]` repo, and the dead-CMOS
  clock (stuck 2024) breaks TLS on HTTPS mirrors. **Next provisioning session: download the latest stable
  SystemRescue (12.x+) into `iso-serve/`** and re-extract the boot tree (`srescue/`), then rebuild none of
  iPXE (generic). Owner approved finishing the *current* bring-up on 11.03; this is deferred hygiene.
- **In-session workaround if staying on 11.03 & needing pacman:** fix the clock first
  (`D=$(curl -sI http://ftp.halifax.rwth-aachen.de/archlinux/ | awk -F': ' 'tolower($1)=="date"{print $2}'); date -s "$D"`),
  repoint `/etc/pacman.d/mirrorlist-snapshot` to a live mirror (e.g. `https://geo.mirror.pkgbuild.com/$repo/os/$arch`),
  and comment out `[community]` in `/etc/pacman.conf`.
