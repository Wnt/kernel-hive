# riscos3 guest

Status: **LIVE** (Tier 1, production, host-native MAME). Bring-up record and
every measurement below: [`docs/lab/RISCOS3-WAVE.md`](../lab/RISCOS3-WAVE.md).

## Identity and source

- Public ID / station directory: `riscos3`
- Slot / UDP port / VMID: `213` / `54213` / `213`
- Archetype: `beige-tower-crt` (scene assembly `pizzaBoxF|crtD|keyboardA|paramMouseD`)
- Machine: Acorn Archimedes 310 (ARM2, 8 MHz, 4 MB), MAME driver `aa310`
  (`src/mame/acorn/aa310.cpp`), `-bios 311` = RISC OS 3.11, 29 Sep 1992
- **There is no installed OS and no disk image.** RISC OS 3.11 is entirely
  ROM-resident; the whole guest is the romset plus the binary.
- Media: archive.org `mame-0.264-roms-non-merged` —
  `aa310.zip` sha256 `04d17d96963816721219691857af17e6439ae30088ebf2e89fac9d8b12d7194b`,
  `archimedes_keyboard.zip` sha256 `1d02b14cd4d2ff80a343c3afb1ba43de0bd77815952816fc19d0736f8644664e`.
  Every member is re-verified by sha1 against the pinned binary's own
  `-listroms` at build time.

## Build and device set

- Media/ROM staging: `scripts/build-guests/tiles/riscos3.sh` — **run it on
  labhost**; `/data/assets-staging` is a different filesystem inside CT950.
- Emulator: `scripts/build-guests/emulators/build-mame-native.sh riscos3`,
  stanza `emulators/native.d/riscos3.sh` (MAME `mame0289`, `SUBTARGET=aa310`).
- Canonical output: `/data/vms/streamhost/assets/riscos3/mame-native/aa310`
  (sha256 `543678a737748099f306b861644e0c70c47675d1597f815fd797b8a3a2e7b31c`),
  rompath `.../mame-native/roms`.
- No QEMU, no chroot, no container: frames `drawshm` → `fb.shm`, input over
  the `ctlsock` socket, published surface 1024x768. No audio and no network
  in this wave.
- Device set = the romset and nothing else. Checkpoint, binary and device set
  are one combination (rule 6).

## Golden, input, and rollback

- Reset mode: `relaunch` with `MAME_NATIVE_CHECKPOINT=1` — the launcher
  restarts the binary with `-state golden` from
  `stations/riscos3/sta/aa310/golden.sta`.
- Fixture: the RISC OS 3.11 Desktop with the `Resources:$.Apps` Filer window
  open in the top left (`!Alarm`, `!Calc`, `!Chars`, `!Configure`, `!Draw`,
  `!Edit`, `!Help`, `!Paint`), icon bar along the bottom, pointer on open
  backdrop.
- **`-listxml` says `savestate="unsupported"` for `aa310` and is wrong here.**
  Proven, not assumed: `SAVEST` → perturb → `LOADST` restores a
  BYTE-IDENTICAL framebuffer (0 changed pixels of 786432) and the guest is
  still live afterwards. If the checkpoint ever stops restoring, delete
  `sta/aa310/golden.sta` — the same launcher cold-boots to the bare Desktop
  in 21 s.
- Pointer: 1:1 ABSOLUTE closed loop on the VIDC1a hardware-cursor registers.
  Ten spread targets over two laps, worst error 3 px X / 2 px Y, no give-ups.
  All three buttons proven: Menu (middle) drops the Pinboard menu, Select
  (left) opens the Apps window, Adjust is `CLICK2`.
  **The raster is letterboxed** — reachable published pixels are roughly
  x 118..905, y 43..722.
- Keyboard: `riscos3.keymap`, generated from the live ctlsock `KEYDUMP`
  (96 of 139 fields). Pacing 80/80 ms with `MAME_CTL_KEY_EXCL=:keyboard:ROW`.
  Proof: F12 held 0.4 s opens the RISC OS command line.
- Cold-boot zero-input state: the bare Desktop, reached in 21 s.
- Credentials reference only (never values): `guest/riscos3` — RISC OS 3.11
  has no login.
- Rollback: `MAME_NATIVE_CHECKPOINT=0` returns the station to a cold-boot
  reset; removing the two station-authored MAME patches
  (`mame-archimedes-kbd-mouse-carry`, `mame-ctlsock-item-window-sized`) and
  rebuilding returns the pointer to keyboard-only, which is what the station
  shipped before them.
