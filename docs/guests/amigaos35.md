# AmigaOS 3.5 + AWeb II — gallery station notes

Status: **LIVE on the box (dark-launched)** since 2026-08-25 — streamhost@amigaos35
active on udp/54151, golden restore + XTEST input + standby freeze all proven on
the production rig. Hidden from the grid (`listing.state=hidden`) pending the
operator's eyeball at `/os/amigaos35`; promote by dropping the `listing` block.

**Guest:** an emulated **Commodore Amiga 4000/040** (Motorola 68040, AGA chipset,
Kickstart 3.1 r40.068) booting **AmigaOS 3.5** (Amiga Inc / Haage & Partner, 1999)
from an FFS hard-disk image, with the OS-bundled **AWeb II** browser as the
retronet exhibit hook. **HOST-NATIVE** per the standing constraint: **FS-UAE
3.2.35 (pinned source build, ONE lab patch) runs directly on labhost** (no
bridge kiosk), rendered into a pinned Xvfb :58 sized exactly to the emulator
window and captured with the daemon's generic `SH_CAPTURE=x11` backend; input
is the daemon's completed `x11test` backend (XTEST abs motion + paced buttons
+ keyboard, `SH_X11TEST_*`).

> Distinct from the `amiga` station (A500 / Workbench 1.3 bridge kiosk) and the
> `aros` station (x86 AROS reimplementation). This is the END of the classic
> line: the last 68k AmigaOS release of the 90s, on big-box AGA hardware.

## Identity and source

- Public ID / tile directory: `amigaos35`
- Reserved slot / UDP port: `151` / `54151`
- Archetype: `beige-tower-crt` (ideal: a bespoke big-box A4000 tower; same
  caveat as `amiga`/`aros`)
- Media (all staged in `/data/assets-staging/amigaos35/`, hash-verified,
  **never committed** — see `docs/lab/ASSETS-MANIFEST.md`):
  - `kick40068.A4000.rom` — Kickstart 3.1 r40.068 (A4000), 524 288 B, sha256
    `71236ed62c85394a3ad7d0d8d65405bac7a10083e06ba6b82120dacc7a00fe9a`
    (canonical sha1 `5fe04842…` matches the known-good dump). Source:
    archive.org item `commodore-amiga-firmware`.
  - `AmigaOS35.iso` (converted from the archive-verified `AmigaOS.bin`/`.cue`
    MODE1/2352 dump, item `amiga-os-3.5`), 98 510 848 B, sha256 `b035f179…`.
    Volume id `AmigaOS3.5`. **AWeb II confirmed on the CD** at
    `OS-Version3.5/Internet/AWeb/AWeb-II` (546 220 B, 1999-10-02).
  - Workbench 3.1 ADF set (install/workbench/locale/fonts/extras/storage),
    item `amiga-wb31_kryoflux`, all item-md5-verified — OS 3.5 upgrades an
    existing 3.1 install.
- License class: preservation-source, copyrighted (Amiga Inc). Fine to hold and
  run in this private, passkey-gated collection; never redistribute the bits.

## Emulator decision (2026-08-24 survey)

FS-UAE — chosen for: proven in-lab (the `amiga` bridge), A4000/040 + AGA +
KS3.1, `save_states`/`load_state`, and `bsdsocket_library` host-socket
networking for the retronet plane. Shipped as a **pinned 3.2.35 source build**
(`scripts/build-guests/emulators/build-fsuae-native.sh`) carrying one lab
patch, `fsuae-native.d/fsuae-mousehack-rearm.patch`: **every UAE savestate
restore runs customreset → mousehack_reset(), zeroing the host-side
mousehack_address, and the restored guest never re-issues the mode-5
registration trap — so absolute mouse is dead after every restore** (proven
identically on 3.1.66 and 3.2.35). The patch logs the address at registration
("mousehack registered at %08x") and re-arms the two host statics after
restore from `FS_UAE_MOUSEHACK_ADDR` — the address is PAIRED with the golden
.uss (same boot lineage; harvest it at every re-bake, it changes per boot:
sandbox 07804b50, production 07803d60). Surveyed alternatives, recorded for
the upgrade path:

- **Amiberry v8.3** (2026-08, WinUAE-derived): strongest core (RTG, JIT, CD32),
  but needs an shm/ctlsock patch and has SDL-headless friction (issue #1142).
- **libretro PUAE** (WinUAE 5.3.1 core): cleanest headless surface (a custom
  frontend gives shm/FIFO/savestate with zero patching) but no RTG and
  unverified bsdsocket.
- **Copperline** (pure Rust, v0.17.0 2026-08-22): 68060/AGA/RTG + bsdsocket +
  deterministic savestates + JSON-RPC control — architecturally our station
  model already built, but two months old; **watch, don't ship**.
- vAmiga/vAmigaWeb (what infinite-mac embeds): OCS/ECS only, no 68040 — wrong
  machine class for OS 3.5.
- Constraint that shaped the design: in every UAE descendant, **RTG and
  savestates conflict** (statefile with RTG active is unsupported). Hence AGA
  chipset screen + savestate golden, not an RTG desktop.

## Pinned machine (acceptance)

- `fs-uae 3.2.35` (pinned source build, patched), `--amiga_model=A4000/040`, Kickstart 3.1
  r40.068 (A4000), 2 MB chip + 8 MB Zorro-III fast RAM, AGA.
- Storage: `hard_drive_0` = FFS HDF (the installed system, canonical output
  `/data/gallery-guests/AmigaOS35/amigaos35-system.hdf`);
  `cdrom_drive_0` = the OS 3.5 ISO (removable; ejected in the shipped scene).
- Display: FS-UAE **windowed** (never SDL fullscreen — renders black under
  capture, same trap as the bridge), `LIBGL_ALWAYS_SOFTWARE=1` (llvmpipe; no
  GPU on labhost), window sized to the AGA productivity screen so the Xvfb
  root == the emulator window (**no letterbox**; geometry measured at bring-up).
- Input: `--automatic_input_grab=0 --initial_input_grab=0`; FS-UAE is Class A
  ("follows the host cursor 1:1", `docs/IO-PATHS.md`) → daemon XTEST absolute
  pointer + XTEST keyboard/buttons (new `x11test` capability, see below).
- Audio: OFF for the dark launch (`SH_AUDIO=off`); Paula-to-FIFO is a recorded
  follow-up (needs a non-timing-source raw-PCM sink — the VICE 24%-speed trap).
- Networking: none at capture time; retronet join is a separate phase (caged
  `bsdsocket_library=1` in a per-station netns holding the veth/MAC/IP on
  `vmbr-rn` — see `docs/lab/retronet/WEB-STATION-amigaos35.md` when it lands).

## Ready scene / golden

- Ready state: AmigaOS 3.5 Workbench desktop (GlowIcons, NewIcons-era look),
  idle, no requesters, AWeb II discoverable one obvious double-click away.
- Reset mode: `relaunch` (non-QEMU); restore via FS-UAE `load_state` from the
  golden statefile if restore proves reliable on this device set, else
  deterministic cold boot (~30 s to desktop under 68040 emulation).
- The proof gate is the captured framebuffer through streamhost, never logs.

## Daemon work this station needs (contained, no emulator patch)

`x11test` input backend today is pointer-motion-only (relative, MAME-homing
style) with buttons routed via the MAME cmd file and **no keyboard**. This
station adds, behind env flags so existing stations are byte-identical:
- XTEST `KeyPress/KeyRelease` (XT set1 scancode → X keycode map);
- XTEST `ButtonPress/ButtonRelease` (instead of the cmd file);
- true absolute XTEST motion (`MotionNotify` with root coords).

## Build and rollback

- Builder: `scripts/build-guests/tiles/amigaos35.sh` (media check + HDF
  assembly + install automation + verify). Install is driven under a
  namespaced Xvfb with xdotool + screenshot verification in CT950 (pure 68k
  emulation, no KVM needed); the golden HDF+statefile pair is the product.
- Credentials reference only (never values): `guest/amigaos35` (AmigaOS has no
  login; entry records any AWeb/config sentinels).
- Rollback: keep the pre-change HDF+statefile pair until the replacement is
  restore-proven (golden + binary + device set are ONE combination).
