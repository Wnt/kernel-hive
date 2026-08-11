# FreeDOS 1.3 retro-games station

The station boots a 512 MiB qcow2 directly to `MENU.BAT`, with eight DOS games and
Arachne 1.99 GPL. The authoritative launcher is the `freedos` stanza in
`streamhost/stations-manifest.sh`:
`pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0`, host CPU under KVM, 64 MiB, two
vCPUs, Cirrus VGA, SB16, an NE2000 PCI NIC, and a PS/2 relative mouse. The
machine's existing PC speaker is routed to the same `snd0` backend; this is
required by Commander Keen 1 and Cosmo's digital effects.

## Game audio configuration

FastDoom is staged with `FDOOM.CFG` selecting Sound Blaster digital effects and
no music device. Duke3D's captured config selects Sound Blaster for PCM effects and
no music device. QEMU's SB16 DSP works for both, while their FM detection fails
on this profile; selecting Sound Blaster music makes either title abort during
sound initialization. Quake and Jill use their existing configs. Keen 1 is
PC-speaker-only, while Cosmo auto-detects music and uses PC speaker for effects.

## Rebuild

Run `scripts/build-guests/tiles/freedos.sh` as root on the QEMU build host. `OUT_DIR`
and `WORK_DIR` select non-canonical artifact and cache directories; their
defaults remain `/data/gallery-guests/FreeDOS` and its `.build-work` directory.
The host needs the tools checked by the script plus `id-shr-extract` (Debian
package `dynamite`) for the Wolfenstein 3D shareware installer stream.

Important pinned inputs found during the 2026-07-14 trial:

- Wolfenstein 3D v1.4 shareware is `1wolf14.zip`, sha256
  `cb2a2ef7ecef14152c65ff93cc3b84fbd3e8eb0c5c1de41a6fc8cdef559451a8`.
  The builder accepts the freely distributable `*.WL1` episode only and refuses
  registered `*.WL6` data.
- Quake is the 18,079,976-byte `QUAKE_SW.zip`, sha256
  `b8e3e9c9f875dc6dda5ebdb9c2434bdfb3ece86c516089ebfe5c12106fffe7c1`.
- Arachne is `a199gpl.zip`, sha256
  `ecc820ddc33c2ecbe64113d773b05e8eaac8eedd32f1ac7768bf3091de1b5ac8`.

### Cosmo + Jill (not bundled in the repo)

`scripts/build-guests/assets/freedos/cosmo.zip` and `.../jill.zip` are **not
shipped in this repo**. Cosmo's outer archive.org zip also bundles the
registered (paid) episodes 2-3 alongside the freely-distributable episode 1
that the builder actually stages; keeping that zip out of a public repo
avoids redistributing the registered data even though only ep.1 is used.

`freedos.sh` handles both automatically: at build time it downloads them from
archive.org and verifies the result against a pinned hash —

- `cosmo.zip`: `https://archive.org/download/msdos_Cosmos_Cosmic_Adventure_-_Forbidden_Planet_1992/Cosmos_Cosmic_Adventure_-_Forbidden_Planet_1992.zip`,
  sha256 `d7197b6b86170c808714e591faa29b028b7ad13bf45c34d66425934c0c5245f8` (1 406 899 bytes)
- `jill.zip`: `https://archive.org/download/msdos_Jill_of_the_Jungle_1992/Jill_of_the_Jungle_1992.zip`,
  sha256 `ab09c4674f7c43e3ea80b9e22b250da442f471c3877e5d5410c9ba6c1366f837` (271 977 bytes)

For an air-gapped rebuild, drop a local copy at
`scripts/build-guests/assets/freedos/{cosmo,jill}.zip` (gitignored) and the
builder uses it in place of the download — still hash-verified against the
same pins, so a stale or wrong file is refused loudly rather than silently
captured in.

The Arachne outer zip contains an old solid-RAR DOS self-extractor. Current 7z
can create the directory names but leaves zero-byte files and reports an
unsupported method. The builder therefore rejects trees unless both
`ARACHNE.BAT` and `CORE.EXE` are non-empty, boots only its private raw disk to
answer the self-extractor's two `y` prompts, validates those files, and removes
the spent self-extractor before making the final qcow2.

## One-time Arachne runtime click

On Arachne's first launch, inspect the 720×480 framebuffer and click the button
labelled **Try selected graphics mode**. In the 2026-07-14 acceptance run the
software cursor began near `(326,244)`. Two QMP relative moves, `(38,46)` then
`(19,18)`, placed its visible tip at approximately `(494,428)` inside that
button. The exact click was one QMP `input-send-event` left-button down event,
followed 200 ms later by the matching left-button up event. The next framebuffer
showed Arachne's installation/defaults page, proving the click registered.
`Alt+X` then returned to the normal games menu for the checkpoint scene.

## Fresh builder trial (2026-07-14)

The final empty-directory run was
`/data/vms/soltest/repro-freedos-1784060537`. The builder took 262 seconds,
including the isolated Arachne extraction and a real QMP boot-menu screenshot.
It emitted a 320,654,848-byte qcow2 before snapshotting (512 MiB virtual).

Acceptance used a launcher equivalent to the manifest with private VNC/QMP
endpoints. QMP `send-key` `a` reached the Arachne video wizard; the click above
was visually checked; `Alt+X` returned to the expected menu. `savevm golden`
recorded a 2.4 MiB VM state. A fresh QEMU process with `-loadvm golden` reported
`running` and, after framebuffer refresh, showed the complete menu again. The
final qcow2 was 323,813,376 host bytes (306 MiB allocated); builder plus
acceptance took 808 seconds. The trial directory measured 1.5 GiB before
deletion.
