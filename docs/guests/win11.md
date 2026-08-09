# Fully-automated Windows 11 (25H2) — install notes & pitfalls

Reusable automation: **`scripts/build-guests/tiles/win11.sh`** (one invocation, zero
clicks, raw QEMU). Media: `Win11_25H2_EnglishInternational_x64_v2.iso`
(operator-supplied, Microsoft copyright) + `virtio-win 0.1.285`.

Zero-click chain: fetch virtio-win → build an `autounattend.xml` ISO → launch
QEMU → inject ENTER past the OVMF CD prompt → Windows installs, auto-logs-in,
installs the VirtIO guest tools and enables RDP. Nobody touches a console.

**Last run 2026-08-05** on `labhost`: **19 minutes** from launch to the
`lab` desktop; build 26200 (25H2); 9.88 GiB written into a 40 GiB sparse qcow2 at
`/data/gallery-guests/Win11/win11.qcow2`; `qemu-img check` clean.

## Why raw QEMU and not `qm`

Every gallery exhibit is a raw QEMU process under `streamhost@<tile>`, so the
build has to end in a **qcow2 a tile can boot**. The Proxmox-era builder
(`scripts/provision/pve-win11-vm.sh`, VM 900) produced a zvol reached through an RDP bridge
that no longer exists. `build-guests/tiles/win11.sh` keeps the hardware recipe
identical and swaps the wrapper:

| Locked `qm` line | Raw-QEMU equivalent |
|---|---|
| `--machine q35 --bios ovmf` | `-machine pc-q35-11.0,smm=on` + pflash pair |
| `--efidisk0 …,pre-enrolled-keys=1` | private copy of `OVMF_VARS_4M.ms.fd` |
| `--tpmstate0 …,version=v2.0` | `swtpm socket` + `-device tpm-tis` |
| `--scsihw virtio-scsi-single` | `-device virtio-scsi-pci` + dedicated iothread |
| `--scsi0 …,ssd=1,discard=on` | `scsi-hd rotation_rate=1`, `discard=unmap` |
| `--net0 virtio,bridge=vmbr0` | `virtio-net-pci` on SLIRP (no host tap touched) |
| `--agent enabled=1` | `virtio-serial` + `org.qemu.guest_agent.0` |
| `--ide2/--sata0/--sata1` | three `ide-cd` on the q35 AHCI |
| `--ostype win11` | the `hv_*` enlightenments PVE implies |

**The machine type is pinned to `pc-q35-11.0` on purpose.** The qcow2 becomes a
golden with an internal `golden` snapshot, and `loadvm` refuses a device set that
has drifted — an unpinned `q35` would silently break every tile reset on the next
QEMU upgrade.

The answer file and its ISO stay in the 0700 work dir (`/data/vms/build-win11`),
not the shared ISO store: it carries the guest admin password in plaintext, which
is inherent to `autounattend.xml`. The password itself is read from
`/root/.win11-pass`, never a command line.

---

## Pitfalls hit and their fixes

### 1. "Press any key to boot from CD or DVD…" — the one true manual moment
- OVMF + a retail Windows UEFI ISO shows this prompt (~5 s) on first boot on an
  empty disk. Nothing in `autounattend.xml` can suppress it — it fires *before*
  Windows Setup loads. Miss it and OVMF falls through to an empty disk → no install.
- **Fix (scripted):** right after `qm start`, spam ENTER into the QEMU monitor:
  ```
  for _ in 1 2 3 4 5 6; do sleep 2; qmp send-key ret; done
  ```
  QMP `send-key` injects the key with no console/VNC access. Six ENTERs at 2 s
  cover the window even though OVMF POST here (8 GB + vTPM measurement) runs
  longer than the ~3–6 s the Proxmox run saw.
- Proof it worked: the qcow2 starts growing within ~1 min (CD booted, WinPE ran,
  files copying). If the disk never grows, the keypress missed. Observed
  2026-08-05: 1.2 G at t+30 s, 8.9 G at t+4½ min.
- **Don't over-spam.** The prompt needs exactly ONE key. Sending 30 keys (as a
  first attempt did) leaks surplus presses into Windows Setup; one eventually
  landed on the "Installing Windows 11" **Cancel** button and popped an
  "Are you sure you want to quit?" modal that *froze the visible progress at 16%*
  (the copy continued underneath). Send only ~6 ENTERs spread over the ~12 s
  window. If the modal ever appears, dump the framebuffer and press ENTER on the
  focused **No** button (`cdrv.py <qmp.sock> key ret`).
  (After dismissing, progress jumped 16% -> 80% instantly — it had been running.)

### 1b. Watching the install WITHOUT VNC (headless verification)
No console access needed — `-display none` still renders into the VGA device, so
QMP `screendump` writes the live framebuffer to a PPM; convert with netpbm:
```
python3 /root/cdrv.py /data/vms/build-win11/qmp.sock dump /tmp/w.ppm
pnmtopng /tmp/w.ppm > /tmp/w.png
```
This is the real-time ground truth (caught the stray dialog above). Complement it
with `du -h` on the qcow2 (disk growth) and a `guest-ping` on `qga.sock`.

**The agent answers before the desktop settles.** `qemu-ga` starts as a service
during first logon, so a successful `guest-ping` proves Setup finished — but the
screen may still be on "Please keep your PC on and plugged in" for another ~3 min
of OOBE finalization. Wait for the framebuffer hash to stop changing before
calling it done; on 2026-08-05 the agent answered at t+9 min and the desktop
settled at t+12 min.

### 2. VirtIO SCSI disk invisible to Windows Setup
- With `scsihw virtio-scsi-single`, WinPE has no driver for the disk → Setup shows
  "no drives found". Classic VirtIO gotcha.
- **Fix:** `windowsPE` pass, `Microsoft-Windows-PnpCustomizationsWinPE` →
  `DriverPaths` pointing at `vioscsi\w11\amd64` (and `NetKVM\w11\amd64` for the NIC)
  on the virtio-win CD. The CD's drive letter is not fixed at WinPE time, so list
  **D:, E: and F:** for each driver — Setup silently skips paths that don't exist.
  (`w11` is the correct driver subfolder for Win11/Server2022+.)

### 3. Windows 11 hardware checks (TPM/SecureBoot/RAM/CPU)
- Even with real vTPM 2.0 + Secure Boot, edge cases can still trip the checks.
- **Fix (belt-and-braces):** in `windowsPE` write `HKLM\System\Setup\LabConfig`
  `BypassTPMCheck / BypassSecureBootCheck / BypassRAMCheck / BypassCPUCheck /
  BypassStorageCheck = 1` via `RunSynchronous`. Harmless when hardware qualifies.

### 4. Edition picker stalls the unattended install
- The ISO's `install.wim` holds several editions → Setup shows a picker.
- **Fix:** put the **generic edition-select key** in `UserData/ProductKey`
  (`VK7JG-NPHTM-C97JM-9MPGT-3V66T` = Win11 Pro; NOT a license, just selects the
  SKU) **and** pin `InstallFrom/MetaData /IMAGE/NAME = "Windows 11 Pro"`. Both
  together make the choice non-interactive.

### 5. Locale mismatch re-shows the language screen
- The "EnglishInternational" ISO defaults to **en-GB**. Feeding `en-US` in the
  International components can re-prompt for language/keyboard in WinPE and OOBE.
- **Fix:** set `en-GB` consistently in
  `Microsoft-Windows-International-Core-WinPE` (windowsPE) and
  `Microsoft-Windows-International-Core` (oobeSystem).

### 6. OOBE forces a Microsoft account (no local-account path) — 24H2/25H2
- Recent builds hide the "offline account" option and demand internet + MSA.
- **Fix (two layers):**
  1. `specialize`: `reg add …\CurrentVersion\OOBE /v BypassNRO /d 1` (re-enables
     the offline path; the standalone `bypassnro.cmd` was removed in 24H2, the reg
     value still works).
  2. `oobeSystem`: create the local admin directly in
     `UserAccounts/LocalAccounts` and set `OOBE/HideOnlineAccountScreens=true`,
     `HideLocalAccountScreen=true`, `ProtectYourPC=3`, `SkipMachineOOBE/SkipUserOOBE`.
  With the account pre-created, OOBE never needs to ask.

### 7. Reaching an interactive desktop unattended
- **Fix:** `AutoLogon` (Enabled, `LogonCount=1`) for the `lab` user so it lands on
  the desktop once; `FirstLogonCommands` then run in that session.

### 8. Guest agent / drivers must install themselves
- `qm agent <vmid> ping` only answers once `qemu-guest-agent` is running inside
  Windows — the definitive proof the whole chain worked.
- **Fix:** `FirstLogonCommands` probe D:..H: and run
  `virtio-win-guest-tools.exe /install /quiet /norestart` (installs all VirtIO
  drivers + the guest agent), plus a fallback
  `msiexec /i guest-agent\qemu-ga-x86_64.msi /qn`. Same run also enables RDP
  (`fDenyTSConnections=0` + firewall group "remote desktop") so RDP is up with no
  post-install step.

### 9. Building the answer-file ISO
- Windows Setup auto-detects `autounattend.xml` on the **root** of any attached
  removable/CD volume. Build a tiny ISO with Joliet+RockRidge:
  ```
  genisoimage -J -R -V UNATTEND -o "$WORK/unattend.iso" "$WORK/unattend/"
  ```
  Attach as a third `ide-cd`. Keep it in the 0700 work dir, not the shared ISO
  store — it carries the guest admin password in plaintext.

### 10. Sparse sizing
- The 40 GiB qcow2 is sparse: 9.88 GiB real after a full install (`qemu-img info`
  disk size vs virtual size). Watch `zfs list data` — the pool had 693 G free on
  2026-08-05, so headroom is no longer the constraint it was on the old box.

---

## Boot order
`bootindex=100` on the Windows CD, `bootindex=200` on the `scsi-hd`. The CD wins
the first boot; every later reboot falls through to the disk because nobody
presses a key at the prompt. Post-install the tile launcher simply omits the
three `ide-cd` drives.

## Credentials created by the answer file
- Local admin: **`lab`** / password `<REDACTED-see-private-notes>` (member of Administrators)
- RDP: enabled automatically (NLA on).

## Timings (2026-08-05 run, 4 cores / 8 GB on `labhost`)
- virtio-win download ~40 s; vTPM manufacture + launch ~3 s.
- Keypress window 12 s; WinPE booted and copying by t+30 s; 83 % at t+7 min.
- Guest agent answers t+9 min; desktop settled t+12 min; script exit t+19 min.

---

# The gallery tile (live since 2026-08-06)

`win11` is a production streamhost tile: **slot 123, UDP 54123**, 4 GiB / 4 cores,
1280x800, `ultrafast`, audio on, abs pointer. Launcher (and device-set ledger):
`streamhost/tiles/win11/qemu-streamhost.sh`. The pristine install stays at
`/data/gallery-guests/Win11/win11.qcow2`; the tile boots a copy,
`win11-golden.qcow2`, with a `golden` snapshot inside (`resetMode=loadvm`).

**Restore is ~9 s** to an answering guest agent — a RAM restore, not a reboot
(guest uptime keeps counting from the bake).

## What the guest was changed to do

Three registry/service edits make it fixture-stable; everything else is stock.
Applied via the guest agent (`wga.py psenc`, see pitfall 6 — plain strings get
their backslashes eaten, `-EncodedCommand` does not).

1. **Permanent auto-logon.** The answer file's `AutoLogon` is `LogonCount=1` and
   is spent by first boot, so `Winlogon\AutoAdminLogon` + `DefaultUserName` /
   `DefaultPassword` / `DefaultDomainName` are set. Without this a cold boot
   lands on the sign-in screen instead of a desktop.
2. **Never blank, never sleep, never lock.** All eight `powercfg` timeouts to 0,
   `NoLockScreen=1`, `ScreenSaveActive=0`, `InactivityTimeoutSecs=0`.
3. **Windows Update disabled** (`wuauserv` + `UsoSvc` Disabled, `NoAutoUpdate=1`)
   — with no route out it would retry forever and pop toasts nobody can dismiss.

## Network: link up, no internet

`-netdev user,id=n0,restrict=on`. SLIRP still answers DHCP, so the adapter is up
with `10.0.2.15/24`, but there is **no default route and no DNS** — verified by
`Get-NetRoute 0.0.0.0/0` returning nothing, `Resolve-DnsName` failing, and a TCP
connect to `1.1.1.1:443` being refused. Nothing shared on the host is touched:
no tap, no bridge, no firewall rule another rig could flush.

## Three device-set choices that look wrong and are not

Full reasoning is in the launcher header; the short version, all learned the
hard way:

- **The system disk is declared before the pflash pair.** `savevm` picks its
  vmstate device by walking BlockBackends in `-drive` order. With the pflash
  first, the RAM image lands inside the 528 KiB variable store. Verify after any
  reorder — `qemu-img snapshot -l` must show the VM state on
  `win11-golden.qcow2` (2.99 GiB) and `0 B` on `OVMF_VARS.qcow2`.
- **The variable store is writable qcow2.** Read-only hangs OVMF before display
  init ("Guest has not initialized the display (yet)" forever); raw makes
  `savevm` refuse a writable non-snapshottable device.
- **No vTPM.** Windows 11 wants one to install, not to run. Check
  `Get-BitLockerVolume` first — this image is `FullyDecrypted`/protection `Off`,
  so nothing measures boot. On an encrypted image, dropping the TPM would boot
  straight into a recovery-key prompt.

## Not wired yet

`labctl` has no `qga` exec kind, so `labctl exec win11` does not work even though
the guest agent is live on `qga.sock`. Use `labctl sh` (blind) or talk to the
socket directly. Adding a `qga` exec kind would give this tile a real captured
stdout channel.

---

<!-- merged from win11-gallery-tile-notes.md (2026-07 restructure) -->

# Windows 11 Kernel Hive tile — neko-rdp bridge (notes)

> **Historical (neko-era) wiring — superseded, kept for the audio/latency
> findings only.** Both the deploy script `scripts/pve-gallery-win11-tile.sh` and
> VM 900 are gone, and nothing streams Windows over RDP any more: the current
> path is the qcow2 built at the top of this doc, booted directly by a streamhost
> tile like every other exhibit. `scripts/provision/pve-win11-vm.sh` is the retired
> Proxmox builder for that retired VM. Nothing below describes live wiring.

Added a **Windows 11** tile to the Kernel Hive that streams the already-running
Win11 VM 900 into the browser over WebRTC with **super-low-latency video +
sound**, via a FreeRDP bridge. Verified end-to-end 2026-07-04.

- Tile URL: `http://192.0.2.12:8083/?usr=guest&pwd=neko`
- Gallery:  `http://192.0.2.12:8080/`  (behind edge auth only; no WAN exposure)
- Deploy/redeploy: `scripts/pve-gallery-win11-tile.sh` (neko-era, deleted)
- Source lives in CT 110 at `/opt/osgallery/neko-rdp/` + `/opt/osgallery/setup.sh`

## Approach: neko-rdp (chosen, works)

A new sibling image to `neko-qemu`. Instead of booting a guest in QEMU, it runs a
**FreeRDP client fullscreen** against the live Win11 VM and lets **neko** capture
the resulting X framebuffer + PulseAudio and encode them to WebRTC. No KVM, no
ISO, tiny image. The QEMU-boot fallback (below) was **not needed**.

```
Win11 VM 900 (192.0.2.14:3389, RDP+NLA)
   │  RDP  (video: RemoteFX/GFX ; audio: RDPSND)
   ▼
xfreerdp3  (in neko-rdp container, on neko X display :99, 1280x720)
   │  X framebuffer                         │  /sound:sys:pulse
   ▼                                        ▼
neko X capture  ─────────────►  neko  ◄──── PulseAudio audio_output.monitor
   │                             │ (WebRTC: VP8 video + Opus audio)
   ▼                             ▼
             Browser tile  http://192.0.2.12:8083/
```

## The neko-rdp image

`FROM m1k1o/neko:base` (Debian 13 trixie). Adds:
- **freerdp3-x11** (`/usr/bin/xfreerdp3`, v3.15) + `x11-utils`.
  - trixie dropped FreeRDP 2; the binary is `xfreerdp3` (launch script falls back
    to `xfreerdp` if ever renamed).
- `launch-rdp.sh` — the FreeRDP launcher (waits for X + the pulse socket, then a
  reconnect loop).
- `rdp.conf` — a supervisord program (priority 500, same slot the qemu program
  used) that runs the launcher as the `neko` user with `DISPLAY=:99.0` and
  `PULSE_SERVER=unix:/tmp/pulseaudio.socket`.

No `/dev/kvm`, no `shm` requirements beyond neko's — this tile is a pure RDP client.

## Exact xfreerdp flags (latency + audio)

```
xfreerdp3 \
  /v:192.0.2.14:3389 /u:lab /p:"$RDP_PASS" \
  /w:1280 /h:720 /dynamic-resolution -decorations \
  /cert:ignore \
  /sound:sys:pulse \
  /gfx:rfx /rfx \
  /network:lan \
  -wallpaper -themes -menu-anims -window-drag \
  +clipboard +auto-reconnect /auto-reconnect-max-retries:0
```

- **`/sound:sys:pulse`** — the audio link. Redirects the Windows session's audio
  endpoint over RDPSND into PulseAudio. With `PULSE_SERVER=unix:/tmp/pulseaudio.socket`
  in the environment, FreeRDP loads its **pulse backend for rdpsnd** and opens a
  playback stream on neko's default sink `audio_output`, whose `.monitor` is what
  neko records. (Log line: `rdpsnd_load_device_plugin: Loaded pulse backend for rdpsnd`.)
- **`/w:1280 /h:720 /dynamic-resolution`** — critical fix. `/f` (fullscreen) on
  the headless neko X server picked a **1920x1080** RandR mode, so neko (a
  1280x720 capture) only saw the top-left corner. Opening at an explicit 1280x720
  + `/dynamic-resolution` makes FreeRDP ask Windows (DisplayControl DVC) to resize
  the desktop to match, giving a clean 1:1 fill.
- **`/gfx:rfx /rfx`** — RemoteFX graphics pipeline: smooth, low-latency, low CPU.
- **`/network:lan` + `-wallpaper -themes -menu-anims -window-drag`** — LAN profile
  and stripped eye-candy for responsiveness.
- **`+auto-reconnect`** — self-heals across RDP drops / session log-offs. Confirmed
  it reconnects within ~5s and re-authenticates with the stored creds.

## PulseAudio wiring (the important part)

- neko's pulse socket: **`unix:/tmp/pulseaudio.socket`** (world-writable; also
  neko's default `PULSE_SERVER`).
- Default sink **`audio_output`** (index 0). neko captures its monitor:
  `pactl list source-outputs` shows neko reading `audio_output.monitor` @ 48kHz.
- FreeRDP's `/sound:sys:pulse` opens a **sink-input on sink 0** → the monitor →
  neko → WebRTC. Nothing else to configure; it "just works" once `PULSE_SERVER`
  points at that socket (set in `rdp.conf`).

## Compose service (generated by setup.sh)

`setup.sh` gained a small, additive **RDP-tiles** section that runs *after* the ISO
loop and reuses the same sequential port/EPR allocator, so it never collides with
the QEMU tiles:

```yaml
windows11:
  image: neko-rdp:latest
  ports: ["8083:8080","52040-52059:52040-52059/udp"]   # next slot after tinycore
  environment:
    NEKO_SCREEN: "1280x720@30"
    NEKO_EPR: "52040-52059"
    NEKO_ICELITE: "true"
    NEKO_NAT1TO1: "192.0.2.12"          # the LXC IP
    NEKO_PASSWORD: "neko"
    RDP_HOST: "192.0.2.14"
    RDP_PORT: "3389"
    RDP_USER: "lab"
    RDP_PASS: "<REDACTED-see-private-notes>"
    RDP_RES: "1280x720"
```

Driven by an `RDP_GUESTS` variable (`"label|host|port|user|pass|WxH"`, newline for
more), so extra RDP tiles are one-liners and the whole thing stays reproducible.
The gallery `index.html` gets a **"Windows 11"** tile with the same `?usr=guest&pwd=neko`
auto-login param as the other tiles (no neko login screen).

> Note: the suggested EPR range 52060 was aligned to **52040-52059** — the next
> block after tinycore's 52020-52039 — so the sequential allocator stays collision-free.

## Verification (observed, not inferred)

- **Tile serves:** `curl http://192.0.2.12:8083/` → **HTTP 200**; container healthy.
- **Desktop streams:** browser screenshot shows the live Win11 desktop (taskbar,
  Start, Edge, Recycle Bin, clock) filling a 1280x720 WebRTC `<video>`
  (`videoWidth=1280, readyState=4, paused=false`). FreeRDP window on :99 is
  `1280x720+0+0` (1:1). Survives page reloads and RDP session churn.
- **Audio flows:** played `C:\Windows\Media\Alarm01.wav` inside the *interactive*
  RDP session and observed, simultaneously:
  - pulse **sink-input on sink 0** (`audio_output`) from FreeRDP;
  - `audio_output.monitor` real sample **peaks ~8000-11000 / 32767** (`parec`);
  - browser WebRTC `inbound-rtp(audio).totalAudioEnergy` **+0.38 over 12 s**
    (vs a flat baseline; a direct pulse white-noise control gave +0.48).

## Pitfalls / gotchas (things that cost time)

1. **`/f` fullscreen picks the wrong resolution** on headless neko X (grabs a
   1920x1080 RandR mode). Use explicit `/w /h` + `/dynamic-resolution` = 1:1 fill.
2. **Making Windows emit sound for the test is the hard part**, not the bridge:
   - The QEMU-guest-agent (`qm guest exec`) runs as **SYSTEM / session 0**, whose
     audio does **not** route to the RDP-redirected endpoint. Sounds played there
     are silent to FreeRDP.
   - **Interactive scheduled tasks** (`/IT /RU lab`) **never fired** into the RDP
     session (Last Run stayed 1999), and on-demand `schtasks /Run` returned
     *"Element not found"* (no console-session token).
   - What worked: drop a launcher in **`lab`'s Startup folder** and **force a fresh
     logon** (`logoff <sessionid>` → FreeRDP `+auto-reconnect` re-logs-in with the
     stored creds → Startup runs the sound *in the interactive session*, so its
     audio routes to the RDP endpoint → FreeRDP → pulse). Remove the Startup file
     afterwards. (All test artifacts were cleaned up: no task, no Startup file, no
     C:\ProgramData scripts left behind.)
3. **Measurement, not inference:** neko's WebRTC audio does **not** carry the RTP
   audio-level header extension here, so `receiver.getSynchronizationSources()[0].audioLevel`
   is always 0 — misleading. Use `getStats()` **`inbound-rtp(audio).totalAudioEnergy`**
   delta (or `parec` on `audio_output.monitor`) as ground truth.
4. **Timing:** a fresh Win11 logon over RDP takes ~45-65 s; short audio clips can
   finish before/after a fixed measurement window. Loop the sound and use a
   generous window.
5. **NLA/Kerberos noise:** the log spams
   `kerberos_AcquireCredentialsHandleA ... no default realm` and
   `license binary blob BB_ERROR_BLOB` — both harmless; NLA falls back to NTLM and
   connects. `fuse: device not found` is also harmless (drive-redirection probe).
6. **Backslashes over `ssh → sh → qm guest exec`** get eaten in unquoted Windows
   paths (`C:\ProgramData\x` → `C:ProgramDatax`). Pass PowerShell as
   `-EncodedCommand <UTF16LE base64>` to sidestep all quoting.
7. Service name is derived from the label: `"Windows 11"` → compose service
   **`windows11`** (not `win11`); container `osgallery-windows11-1`.

## Fallback (not used) — boot the zvol directly in neko-qemu

If the RDP bridge had failed on latency/audio, the fallback was to stop VM 900 and
boot its disk `/dev/zvol/data/vm-900-disk-2` directly in a **neko-qemu** container
(OVMF + `-enable-kvm -cpu host` + AC97 audio; TPM likely omittable post-install).
This was unnecessary — the RDP bridge delivers low-latency video and working audio,
and keeps VM 900 running independently.
