# Integration seed — early Mac OS X on PowerPC

Tracking: #50  
Prep branch: `macosx`  
Exhibition copy: `docs/lab/spa-drafts/macosx.md`

## Proposed station shape

- **station id:** `macosx`
- **runtime:** QEMU PowerPC
- **closest sibling:** `macos9`
- **machine:** `mac99,via=pmu`
- **CPU:** start with `g4`
- **RAM:** 512 MB
- **scene archetype:** keep `apple-studio` initially; scene can later gain period Power Mac hardware
- **first target OS:** Mac OS X 10.2 Jaguar; 10.3 Panther is fallback

10.2/10.3 preserves early Aqua while avoiding the worst 10.0 rough edges and 10.4 TCG cost.

## Start here

```bash
scripts/dev/wt.sh new macosx-work --from origin/macosx
cd ../macosx-work
scripts/dev/wave.sh alloc macosx
python3 scripts/stations-registry.py new macosx   --like macos9 --production --slot auto
```

Keep the PowerPC/QEMU structure from `macos9`, but do **not** reuse its golden or assume its mouse calibration.

## Media acquisition

Use a PowerPC retail install set for Jaguar or Panther.

Preservation index:
- https://www.macintoshrepository.org/45-mac-os-x-for-ppc-and-ppc64-osx-10-0-10-1-10-2-10-3-10-4-10-5-

Stage:
- install CD image(s)
- blank qcow2 system disk
- optional second CD images for multi-disc installs

Record exact image size/hash after download.

## First smoke command

A practical first attempt:

```bash
qemu-system-ppc   -M mac99,via=pmu   -cpu g4   -m 512   -g 1024x768x32   -drive file=macosx.qcow2,format=qcow2   -cdrom jaguar-cd1.iso   -boot d
```

For Kernel Hive, replace the normal display with the same D-Bus display path as `macos9` once the installer is proven.

If input is problematic, explicitly add the USB controller/input devices QEMU exposes for mac99 rather than copying a PC USB-tablet line blindly.

## Installation strategy

Do one assisted installation first. Do not automate the installer until:
- installer display is stable
- disk is detected
- first boot reaches Aqua
- keyboard/mouse are usable

Then decide whether the builder should automate it or compose/stage a known-good installed disk.

## Network decision

If Retronet is desired, put the eventual NIC in the **first final device set** before capturing the golden. A `sungem`/mac99-compatible NIC is the natural path. If networking becomes a device-driver wall, ship the first exhibit without it rather than delaying Aqua itself.

## Intended golden scene

- Finder open
- Dock visible
- Terminal one click away
- no Setup Assistant
- no update dialogs

Guided demo:
1. open Terminal,
2. run `uname -a`,
3. switch back through Dock/Finder,
4. reset.

## Proof checklist

- [ ] installer boots under the same QEMU build intended for production
- [ ] Aqua desktop reached
- [ ] mouse/keyboard measured
- [ ] first boot/setup dialogs fully cleared
- [ ] golden restore works under exact mac99 device set
- [ ] reset returns to Finder/Dock scene
