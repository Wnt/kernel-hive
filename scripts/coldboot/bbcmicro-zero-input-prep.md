# bbcmicro boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `bbcmicro)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays read-only)
and rewrites SSH 5832→6832. Before recording it stops `getty@tty1` and the
kiosk's MAME; after capture it starts the kiosk again. Bridge kind intentionally
skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The BBC Micro's
MOS comes up unattended at

```
BBC Computer 32K

Acorn DFS

BASIC

>
```

which is exactly what the golden holds — nothing is curated into the fixture and
no keys are sent after a restore — so a clip's last frame would hand off to the
golden's first frame cleanly.

Ready means the four teletext lines painted in white on black with the block
cursor present at the `>` prompt. Canvas is the QEMU kiosk's scanout at 30 fps;
the X root is the bridge base's stock **1024×768** (unlike the VICE tiles, which
drop the root to fit a fixed SDL window — MAME runs fullscreen with
`-keepaspect` and fills it).

Two things that would make a correct capture look wrong:

- **`-artwork_crop` must stay in the launcher.** Without it MAME draws the Model
  B's three keyboard LEDs as a labelled strip under the screen and the composite
  view is 480×549, so the framebuffer is a picture with emulator chrome beneath
  it and a different letterbox from the golden's.
- **The kiosk's MAME must be resolved through `/proc/<pid>/exe`**, not by name,
  when the arm stops it. `pgrep -x bbcb` on the host would also match this
  tile's own tooling; inside the guest, check the target is
  `/opt/bbcmicro/mame/bbcb` before killing it.

Redirecting the kiosk session's stdout to a file is safe here — that is a VICE
3.9 hazard (`docs/guests/vic20.md`), not a MAME one.
