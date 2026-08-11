# win2000 — boot-video zero-input prep (+ startup sound)

What it takes to make Windows 2000 Pro **cold-boot to a settled desktop with ZERO
input** *and* play its **startup chime**, so `record-boot.sh win2000` (vmstate,
win95-style) can bake a clean seam-invariant boot video. Verified 2026-07-14 on a
`/data/vms/soltest` clone; promoted onto the live tile the same run.

## The guest

- Disk: `/data/gallery-guests/Win2000/win2k-pro.qcow2` (**outside** the tile dir),
  Windows 2000 Professional SP4, Administrator account.
- Live launcher `tiles/win2000/qemu-streamhost.sh`: `-machine pc -cpu host -m 512
  -smp 1 -vga cirrus`, dbus display, **AC97 dbus audio** (`out.frequency=48000
  out.channels=2 out.format=s16`), `usb-tablet` abs pointer, `rtl8139` user-net
  (**no** hostfwd), IDE golden. Launcher **cold-boots** (no `-loadvm`); the golden
  is jumped-to via QMP `loadvm golden` *after* launch.

## What was ALREADY on the disk (no change needed)

- **AutoAdminLogon** — `HKLM\…\Winlogon` `AutoAdminLogon="1"`,
  `DefaultUserName="Administrator"` (blank password ⇒ no `DefaultPassword` needed).
  Cold boot reaches the Explorer desktop with **no** Ctrl+Alt+Del / login prompt.
- **Startup sound** — `HKCU AppEvents\Schemes\Apps\.Default\SystemStart\.Current`
  (and `.Default`) = `Windows Logon Sound.wav` (present in `WINNT\Media\`).
- **AC97 driver** — `ichaud` (Intel 82801AA AC'97 WDM, `system32\drivers\ichaud.sys`)
  is installed and bound to the QEMU AC97 device `PCI\VEN_8086&DEV_2415`
  (`ConfigFlags=0`). So the logon chime actually **plays** through the card and is
  captured by the dbus audio tap. Measured on the baked clip: `max_volume −11.2 dB`.
- **GoldenNotepad** — `HKLM\…\Run\GoldenNotepad=notepad.exe` auto-opens an empty,
  focused Notepad (solid caret: `CursorBlinkRate=2000000000`) as the settle marker
  and input-reactive surface. Screensaver / monitor-powerdown already off.

## The ONE blocker — "Found New Hardware Wizard" every boot

A plain cold boot popped the **Found New Hardware Wizard** over the desktop on
*every* boot (this is why the live tile historically reset via `loadvm golden`,
not a cold boot). The device is the **QEMU VM-Generation-ID ACPI device**:

- Device Manager: *Other devices → Unknown device*, "on Microsoft ACPI-Compliant
  System", **Code 1** (not configured). No hardware-ID match, no driver anywhere.
- Registry: `SYSTEM\ControlSet00{1,2}\Enum\ACPI\QEMU0002\3&267a616a&0`,
  `HardwareID = ACPI\QEMU0002`. Stable instance id.

Cancelling at the wizard's **welcome page never sets a flag**, so PnP re-launches
it next boot (Device-Manager "Disable" also did **not** stick across an ACPI
re-enumeration — verified: wizard returned).

### Fix (offline, deterministic)

Set **`ConfigFlags = 0x00000002` (CONFIGFLAG_FAILEDINSTALL)** on the device
instance in **both** control sets. That tells PnP an install already failed, so it
stops auto-launching the wizard (the device stays a silent yellow-bang in Device
Manager only — invisible on the desktop / in the boot video).

```sh
# offline, disk NOT mounted by any running QEMU:
qemu-nbd -c /dev/nbd0 win2k-pro.qcow2 ; partprobe /dev/nbd0
ntfsfix -d /dev/nbd0p1 ; mount.ntfs-3g -o remove_hiberfile,force /dev/nbd0p1 /mnt/w2k
CFG=/mnt/w2k/WINNT/system32/config
cat > /tmp/q.reg <<'REG'
Windows Registry Editor Version 5.00
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Enum\ACPI\QEMU0002\3&267a616a&0]
"ConfigFlags"=dword:00000002
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Enum\ACPI\QEMU0002\3&267a616a&0]
"ConfigFlags"=dword:00000002
REG
hivexregedit --merge --prefix "HKEY_LOCAL_MACHINE\\SYSTEM" "$CFG/system" /tmp/q.reg
sync ; umount /mnt/w2k ; qemu-nbd --disconnect /dev/nbd0
```

Then boot once and **Start → Shut Down → Shut down** (clean ACPI power-off) so the
NTFS/registry is flushed and the disk is a pristine cold-boot source (no autochk),
with Notepad's window position saved. Verified: cold boot now reaches the settled
desktop with **zero input** and the chime plays.

## Record / detect

`bootrec-tiles.conf` `win2000` arm: vmstate, 1024×768@30, audio 48000/2, Tier-2
reference-region on the **Notepad title bar** (`crop=150:16:118:116` — the last
element to paint, away from the cursor rest, excludes the live taskbar clock).
Because the live launcher's disk is outside the tile dir and it already cold-boots,
stage a normalised src tile dir and point `BOOTREC_TILES_ROOT` at it:

```sh
ROOT=/data/vms/soltest/w2ksrc-root ; TD=$ROOT/win2000 ; mkdir -p "$TD"
cp --reflink=auto <prepped>.qcow2 "$TD/win2000-golden.qcow2"
sed -e 's#/data/vms/streamhost/stations/win2000#'"$TD"'#g' \
    -e 's#/data/gallery-guests/Win2000/win2k-pro.qcow2#'"$TD"'/win2000-golden.qcow2#g' \
    /data/vms/streamhost/stations/win2000/qemu-streamhost.sh > "$TD/qemu-streamhost.sh"
cp <settled-desktop>.png "$TD/boot-ref-desktop.png"
BOOTREC_TILES_ROOT=$ROOT SH_DBUS_TAP=/path/to/bootrec-tap \
  record-boot.sh win2000 && postprocess-boot.sh win2000 && trim-boot.sh $BOOTREC_STAGING_ROOT/win2000
```

Seam invariant verified md5-exact (poster.png == loadvm-golden screendump); the
trim was a no-op (Tier-2 stop already tight — chime runs to 37.6 s of the 39.3 s
clip, only 0.47 s removable < the 1.5 s floor).
