# Integration seed — Palm/HP webOS

Tracking: #58  
Prep branch: `webos`  
Exhibition copy: `docs/lab/spa-drafts/webos.md`

## Proposed station shape

- **station id:** `webos`
- **runtime:** x86 QEMU/KVM from the preserved SDK emulator VMDK
- **closest sibling:** `android`
- **scene archetype:** `touch-phone`
- **input:** USB tablet/touch-style absolute input
- **audio:** off initially
- **network:** user-mode networking only if the SDK image already expects it; do not make web connectivity a launch gate

## Start here

```bash
scripts/dev/wt.sh new webos-work --from origin/webos
cd ../webos-work
scripts/dev/wave.sh alloc webos
python3 scripts/stations-registry.py new webos   --like android --production --slot auto
```

The Android sibling is for QEMU/touch mechanics only. Replace q35/virtio assumptions with hardware derived from the SDK appliance.

## Media acquisition

Use the preserved SDK appliance:

- https://github.com/webOSArchive/webos-emulator

The archive packages the original SDK emulator as an **OVA**. Stage the OVA and hash it.

Extract it:

```bash
mkdir unpack
cd unpack
tar xf ../webos-emulator.ova
ls -lh
```

Inspect the OVF before choosing QEMU devices:

```bash
xmllint --format *.ovf > appliance.pretty.ovf
qemu-img info *.vmdk
```

Record:
- guest RAM
- CPU count
- disk controller
- NIC model
- display controller
- any ACPI/PAE flags

Then convert:

```bash
qemu-img convert -p -f vmdk -O qcow2 <sdk-disk.vmdk> webos.qcow2
```

## First QEMU smoke

Do **not** guess the full VirtualBox hardware. Start from the OVF values.

The minimal expected shape is:

```bash
qemu-system-i386   -enable-kvm   -m <ovf-memory>   -drive file=webos.qcow2,format=qcow2,if=ide   -vga std   -usb -device usb-tablet
```

Add the exact NIC/controller only after comparing the OVF. If the image boots with no NIC, keep the first smoke offline.

Once Luna appears, switch to the normal streamhost D-Bus display path from the Android sibling.

## If the preserved phone/tablet image differs

The webOS Archive appliance currently emphasizes a TouchPad-style emulator. If the SDK archive exposes a **2.1 phone image**, prefer that for the museum because it pairs directly with the Palm Pre story. If only 3.0.5/TouchPad is readily reproducible, ship that honestly rather than blocking the station.

Keep the poster title generic “Palm webOS” until the final image is selected.

## Intended golden scene

Card view with:
- at least two cards open
- launcher/quick-launch visible
- no developer console

Useful keyboard equivalents in the preserved SDK:
- Home: minimize/maximize card
- End: launcher
- Left/Right: switch cards
- Esc: back

Map those to labeled on-screen controls if QEMU input makes them keyboard events.

## Builder target

`tiles/webos.sh` should:
1. fetch/pin OVA
2. extract OVF+VMDK
3. assert expected virtual-hardware metadata
4. convert VMDK → qcow2
5. stage pristine seed disk
6. make runtime work copies for visitor state

## Proof checklist

- [ ] OVA hardware inventory recorded
- [ ] converted qcow2 boots under QEMU/KVM
- [ ] Luna/card UI visible
- [ ] absolute input works
- [ ] reset replaces runtime disk from pristine seed
- [ ] no VirtualBox dependency remains in production
