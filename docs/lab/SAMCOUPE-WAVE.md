# samcoupe wave — SAM Coupé, host-native MAME, a boot menu of the software people ran on it

Operator ask (2026-09-08): add the SAM Coupé and "the most versatile and legendary
of the Atari 8-bits", each with applications and games reachable the way the
apple2e station does it (a one-key boot menu; `docs/lab/APPLE2E-WAVE.md`).
This brief is the SAM Coupé's. Rule 13: host-native on the MAME path from
day one (`stations/mame-native/x11-runtime.sh`, drawshm frames, ctlsock keys,
FIFO audio); `apple2e` is the shape sibling (its registry entry is what this
one is derived from), `mpf2`/`zxspectrum` the keyboard-only precedents.

## Ledger (allocated by `wave.sh alloc samcoupe`, session `samcoupe`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| samcoupe | samcoupe | 187 / 54187 / 187 | — | — (no network plane on an 8-bit micro) |

| Fact | Value | Measured by |
|---|---|---|
| Display bookkeeping (inert, `runtime.x11.display`) | `:75` | spine |
| Scene tuple | `amstradCpc,homeCrtD,none,none` | spine (scaffold refused every tuple already in the lineup) |
| MAME pin | `mame0289` (fleet pin, `build-mame-native.sh`) | spine |
| Driver | `samcoupe` — src/mame/samcoupe/samcoupe.cpp (MACHINE_SUPPORTS_SAVE) | spine |
| Device set (target) | samcoupe, BIOS v3.1 (rom31.z5), -drive1 floppy (3.5" DD, `-flop1` .mgt/.dsk), -drive2 floppy (`-flop2`), mouseport left empty (keyboard-only, see OPEN) | spine from stock MAME 0.276 `-listslots/-listmedia` on labhost; **native stream confirms on 0.289** |
| ROMs | rom31.z5 (v3.1, default BIOS) sha1 c86601633fb61a8c517f7657aad9af4e6870f2ee; the other 14 z5 variants are optional BIOS choices — staged at `/data/assets-staging/samcoupe/roms/` (MANIFEST.sha256, `.staged`), from archive.org `MAME_0.224_ROMs_merged` | spine |
| Keyboard ioports | 9 matrix ports kbd_0..kbd_8 (CTRL on LALT, SYMBOL on LCONTROL, EDIT on RALT, F0 on keypad 0, cursor keys real), joy_0/joy_1 = Sinclair-style 6-7-8-9-0 keys, so games needing a joystick are driven from the keyboard | spine from source; native stream dumps the real tags with KEYDUMP |
| Published surface | 1024x768 (MAME aspect-corrects the native raster) | native stream re-measures |
| Media | TODO(media): an 800K MGT disk (819200 bytes) composed on the host: SAMDOS + an `auto` SAM BASIC menu + titles | media stream |
| Candidate titles | Lemmings (1991), Prince of Persia (1992), Manic Miner (1992), Defenders of the Earth / Sphera; apps: Flash! (paint), The Secretary or Outwrite (WP); [B] SAM BASIC | media stream picks what fits and BOOTS on the framebuffer; the ledger list is a shortlist, not a promise |
| Stock MAME for quick media boots | `/usr/games/mame` 0.276 on labhost has this driver (`-listroms` matched); ROMs in the staging dir above | spine |

## Streams

| Stream | Branch | Owns | Model |
|---|---|---|---|
| native | `samcoupe-native` | `scripts/build-guests/emulators/native.d/samcoupe.sh`, the built binary under `/data/vms/streamhost/assets/samcoupe/mame-native/`, `streamhost/stations/samcoupe/samcoupe.keymap` (generated + override rows), `station.env.fixture` (MAME_NATIVE_*, pacing), registry `runtime`/`stream`/`emulator` truth | sonnet |
| media | `samcoupe-media` | `scripts/build-guests/tiles/samcoupe.sh` (fetch, SHA-256, compose the boot disk with the menu), `/data/assets-staging/samcoupe/media/`, the composed disk under `/data/vms/streamhost/assets/samcoupe/media/`, `check-assets.sh` / `ASSETS-MANIFEST.md` / `os-media-catalog.md` rows | opus |
| golden (after native + media) | `samcoupe-golden` | golden savestate at the menu on a sandbox rig, restore proof, keyboard proof of the whole visitor path, `MAME_NATIVE_CHECKPOINT` decision, registry `reset` truth, staged station dir | sonnet |
| spa (after media reports the title list) | `samcoupe-spa` | `registry/posters/samcoupe.md`, hero + frames, `museum`/`spa`/`demoProgram`, `keyboardProfiles.ts`, `machineIdentity.ts` tints | opus (museum voice) |
| docs (after golden) | `samcoupe-docs` | `docs/guests/samcoupe.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` index | sonnet-low |

One owner per file. A stream that needs another's fact reads this ledger or
waits for the report. Facts flow one way: the stream that measures corrects
the ledger in its own commit and says so.

## The selector (what "a boot menu" means on this machine)

SAMDOS boots the disk (F9 / BOOT) and auto-LOADs the first file when it is a BASIC program named auto*; that program is the menu: CLS, boxed list, `PAUSE 0`/INKEY$, per choice LOAD "name" (a CODE file with an autostart or a BASIC loader). Titles that are whole bootable disks go in drive 2 only if nothing else works; prefer file-based copies on the one disk.

## Walls hit

(none yet)

## Proofs

- framebuffer of the menu after a cold boot, and after a relaunch restore
- one title launched from the menu by keys, on the framebuffer
- `labctl shot` / `type` on the live station after landing

## OPEN items

- Pointer: the driver has a mouse device, but the station ships keyboard-only
  (`stream.pointer.transport: none`), as apple2e does — a relative-only mouse
  has no honest absolute contract yet.

## Measured timeline

| Milestone | Wall clock | Minute |
|---|---|---|
| `wave.sh alloc` / ledger committed | | |
| `/os/samcoupe` viewable (smoke-rig.sh) | | |
| streams merged | | |
| landed | | |

## Teardown

(filled at landing)
