# chokanji guest — 超漢字 / B-right/V (BTRON3)

Status: **LIVE (host-native QEMU-x86), listed on the grid.** Slot 149,
UDP 54149, archetype `beige-tower-crt`, `ui: desktop`, relative pointer.
On the **retronet web plane** since 2026-08-23 (rtl8139 → `vmbr-rn`, static
`10.99.0.21`); its 基本ブラウザ browses the period corpus with no proxy.

超漢字 (Chokanji) / B-right/V is the commercial **BTRON3** desktop from Ken
Sakamura's TRON project. The exhibit hook is the TRON story: the operating system
Japan planned for its schools — and, in ambition, for the world — until the US
Trade Representative named TRON under the 1989 **Super-301** trade action and the
school-computer adoption collapsed. It survived commercially through Personal
Media Corporation. The visual star is the "real object / virtual object"
(実身/仮身) desktop and a colossal kanji character set.

## Identity and source

- Public id / stationDir / SH_STATION: `chokanji` (one name).
- Emulator: **QEMU 11.0.2** (`pve-qemu-kvm 11.0.2-1`), machine `pc-i440fx-11.0`,
  KVM. Host-native: `-display dbus,p2p=on`, no kiosk.
- Media set (operator-provided): Internet Archive item
  [`chokanji`](https://archive.org/details/chokanji), file `chokanji.zip`
  — sha256 `b8fd99a928d5564e53b58d2b8853b05f799a3fc32ba09cee0714a66c675039df`,
  850 274 156 bytes (archive.org MD5 `6d68e525…`, SHA1 `35b928a4…` and size all
  match). Archived in the lab media cache (`media_cache_put`) at
  `/data/media-archive/blobs/b8/b8fd99a9…`. **Never committed** (preservation,
  Personal Media proprietary; the set also carries a product key). Full
  provenance: `docs/lab/ASSETS-MANIFEST.md`.
- Inside `chokanji.zip`:
  - `qemuckj.7z` → a QEMU-0.14-for-Windows port + **`mc.img`**, a *pre-installed,
    bootable* raw disk (MBR: FAT16 boot partition + a BTRON system partition),
    **B-right/V Kernel Ver 4.202**. This is the runnable exhibit.
  - `CKV4540.iso` → **超漢字V 4.540**, the consumer edition: a Windows/VMware
    installer (`ckv-setup.exe`, a Delphi self-extractor that deploys a VMware VM;
    `VMware-player-3.1.4-…exe`; `.bpk` update packages). **Its disk image is not
    host-extractable without Windows** — see Known limitations.
  - `BRIGHTV4500.iso` → B-right/V 4.500 OEM component files (fonts, dictionaries,
    kernel modules) — not a bootable image.
  - `cygwin-brightv.7z` → CygWin/B-right/V host-side components.

The Virtual OS Museum catalogues "Chokanji 4 (B-right/V) 4.104" on x86 PC under
QEMU 5.2 (read for facts only, CC BY-NC-SA — nothing copied): it confirmed the
family runs on stock QEMU `pc`/x86_64 and, via its `-M pc,vmport=off`, pointed at
the vmmouse trap below.

## Build and device set

- Builder: `scripts/build-guests/tiles/chokanji.sh` — no install to automate; it
  resolves `chokanji.zip` from the media cache by sha256, extracts `qemuckj/mc.img`,
  and repacks it to the canonical qcow2, then framebuffer-smoke-tests the boot.
- Canonical output: `/data/gallery-guests/Chokanji/chokanji.qcow2` (qcow2 from the
  raw `mc.img`; **convert with `qemu-img convert -S 0`** — plain zero-run detection
  produced an empty qcow2 on the ZFS store, though `qemu-img compare` still reads
  the source back byte-identical).
- Verbatim launcher: `streamhost/stations/chokanji/qemu-streamhost.sh`. Device set:
  `qemu-system-x86_64 -enable-kvm -m 256 -smp 1 -machine pc-i440fx-11.0,vmport=off
  -cpu host -rtc base=localtime -boot c -vga cirrus -display dbus,p2p=on -drive
  file=…/chokanji.qcow2,format=qcow2,if=ide -netdev tap,id=rn0,ifname=chokanjirn0
  -device rtl8139,netdev=rn0,mac=…,romfile=` (default i8042 PS/2 keyboard+mouse;
  no audio device). `SH_DBUS_UPDATE_MS=4` fast-poll capture.
- **`vmport=off` is load-bearing.** `mc.img` is an ex-VMware guest, so QEMU's
  default VMware I/O port makes the `vmmouse` device the current pointer
  (`query-mice`: vmmouse current, `absolute=false`), and it **swallows all injected
  motion** — the BTRON hand cursor never moves. BTRON does not poll the VMware
  port, so vmmouse never reaches absolute mode either. `vmport=off` removes it and
  the default PS/2 mouse becomes the live pointer.
- **Pointer = relative (PS/2).** With vmmouse gone, PS/2 relative motion reaches
  BTRON (cursor tracked to the corners under QMP `input-send-event rel`). BTRON has
  no absolute/tablet driver — `-device usb-tablet` (absolute) does **not** move the
  cursor — so `SH_POINTER=rel`, UI `pointerRel=true`; browser Pointer Lock feeds
  1:1 deltas. `-device usb-mouse` also works but PS/2 is cleaner (a valid
  `qemu-ps2-relative` transport, no extra device).
- **Display = Cirrus GD5446 @ 800×600.** BTRON's screen driver in this disk is
  Cirrus-specific; `-vga std` renders black. 800×600 is the disk's configured mode.
- **NIC = RTL8139 on the retronet** (added 2026-08-23). The model was read out of
  the media, not guessed: `qemuckj/q.bat` — the launch script the original
  packagers shipped alongside this very `mc.img` — reads `-net nic,model=rtl8139`,
  and `pxe-rtl8139.bin` is the only NIC option ROM in that port. It worked on the
  first cold boot with no in-guest driver work. `romfile=` pins the PXE option ROM
  OFF: the ROM is a migratable ramblock, so a golden baked with it present refuses
  to load where it is absent (`Unknown ramblock 0000:00:03.0/rtl8139.rom`); this
  guest boots from its IDE disk and never PXE-boots. Adding the PCI NIC did **not**
  disturb the vmmouse trap — PS/2 is still the current pointer.
  The tap `chokanjirn0` (persistent, on `vmbr-rn`) and its fail-closed
  `CHOKANJIRN-IN` guard chain are brought up by
  `streamhost/stations/chokanji/rn-tapnet.sh`, called `up` from the launcher on
  every start. **The guest is addressed statically in-guest** at `10.99.0.21/24`,
  DNS `10.99.0.2`, with no default route — B-right/V 4.202 has no DHCP client.
  Full as-built: [`docs/lab/retronet/WEB-STATION-chokanji.md`](../lab/retronet/WEB-STATION-chokanji.md).
- RAM 256 MB (what this B-right/V build is tuned for; boots in ~40 s).

## Golden, input, and rollback

- Reset: `resetMode=loadvm`, snapshot `golden`, inside `chokanji.qcow2`. The disk
  runs WITHOUT `-snapshot` so `savevm golden` persists; the launcher boots straight
  into `-loadvm golden -S` (frozen at the fixture, ~0 CPU) once the tag exists.
- First bake on the box (the launcher writes the runtime dir):
  `bash streamhost/stations/chokanji/qemu-streamhost.sh` (cold boot, no tag),
  wait for the desktop, then `ssh lab 'checkpoint-guard recapture chokanji'`;
  relaunch and confirm it comes up `-loadvm golden -S`. (Operator policy: a
  restoring golden is proof enough; no separate checkpoint-verify ceremony.)
  Every later recapture of the live station is that same one command — it backs
  the disk up, stages under `cpg-staging` and proves the restore before retiring
  the old checkpoint
  ([`../lab/checkpoint-guard.md`](../lab/checkpoint-guard.md)).
- Fixture: clean idle BTRON3 desktop — the 超漢字 real-object window and the
  原紙箱：B-right/V virtual-object box open on the blue kanji-watermark wallpaper,
  hand cursor at rest.
- Input proof: **pointer (relative) PASS** (framebuffer-verified cursor motion).
  Keyboard **PASS** since 2026-08-23 — ASCII typed over QMP lands cleanly (proven
  by configuring the network panel by hand). Note the layout is **JIS**: `:` is its
  own key (where a US board has the apostrophe) and `shift-semicolon` yields `+`,
  so `scripts/dev/qmp-type.py`'s US map mistypes `:` and `=` on this guest.
  BTRON text entry is otherwise Japanese-IME/menu-driven, virtual-keyboard profile
  `generic`.
- Credentials: none — BTRON boots straight to the desktop, no login. `credentialsRef`
  `guest/chokanji` is a placeholder reference (no values).
- Rollback: the pre-retronet disk (carrying its own pre-change `golden`) and
  launcher are kept beside the guest as
  `/data/gallery-guests/Chokanji/chokanji.qcow2.prern-2026-08-23` and
  `qemu-streamhost.sh.prern-2026-08-23` — copy the disk back over
  `chokanji.qcow2` and revert the launcher. The disk is *also* reproducible from
  the archived media via the builder, but that is a rebuild, not a rollback: it
  would not carry the network configuration, which lives in the disk.
  Bring-up work is namespaced under `/data/vms/sandbox/`; the live station is
  touched only to install a proven result.

## Listing

Listed on the grid since `890d312` (promoted off dark launch). It is an ordinary
grid station now: no `darklaunch.d` overlay to re-arm after a
`serve-https-spa.sh` manifests deploy.

## Known limitations

- **Version.** The runnable exhibit is B-right/V **4.202** (the 超漢字4-era kernel
  in `mc.img`), not the consumer **超漢字V 4.540** the operator's set also contains.
  4.540's `ckv-setup.exe` is a Windows-only Delphi self-extractor that deploys a
  VMware VM; its disk is not extractable on the host without running Windows, and
  the in-system `.bpk` upgrade path from 4.202 is not supported/attempted. The
  museum value (the BTRON3 real/virtual-object desktop and the kanji set) is
  identical. A future upgrade to 4.540 would need a Windows/wine pass to unpack
  `ckv-setup.exe`, or a separately-sourced 4.540 disk image.
- **Resolution.** 800×600 (the disk's configured Cirrus mode); higher res would
  need reconfiguring BTRON's screen driver in-OS.
- **Audio.** None wired (the desktop is effectively silent). QEMU-CKJ's `q.bat`
  used SB16+AdLib — a possible future add. Adding it would change the device set
  again and so needs another cold golden re-bake, exactly as the NIC did.
- **No DHCP.** B-right/V 4.202's ネットワーク環境設定 panel is static-only (one
  fixed-size アドレス tab, no DHCP option) and the guest sends no DISCOVER at boot.
  The address lives in the disk, so changing it means editing the guest's own panel
  and **re-baking the golden** — it is not a launcher flag.
