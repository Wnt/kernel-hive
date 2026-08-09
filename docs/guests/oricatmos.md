# Oric Atmos (1984) — gallery tile notes (udp/54131)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **MAME's `orica`
driver**, emulating an **Oric Atmos** at its own power-on screen. An
**"emulator bridge"** tile — streamhost captures the Linux framebuffer + AC97
audio exactly like every other tile. See **`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` (frozen, read-only; the
tile is a thin qcow2 overlay on it).
**Build script (tile):** `scripts/build-guests/tiles/oricatmos.sh` — thin overlay +
ROM staging + kiosk `launch.sh` + quiet console + golden bake + a
framebuffer-asserted keyboard proof, fully automated.
**Emulator build:** `scripts/build-guests/emulators/build-mame-oricatmos.sh`.
**Tile dir (host):** `/data/vms/streamhost/tiles/oricatmos/`.
**Registry entry:** `registry/tiles/oricatmos.json` (slot 131, udp 54131,
VMID 234, ssh hostfwd 127.0.0.1:5834).

## Acceptance criteria

- **Ready framebuffer:** the untouched Oric Extended BASIC V1.1 banner —
  `ORIC EXTENDED BASIC V1.1`, `(c) 1983 TANGERINE`, `37631 BYTES FREE`,
  `Ready` — black on a white page filling an 800×600 root, with the machine's
  own `CAPS` marker in the top-right corner.
- **Reset:** `loadvm` of the INTERNAL `golden` snapshot. No post-restore keys.
- **Pointer:** none. Keyboard-only exhibit (`--pointer none
  --input-backend disabled`, X started with `-nocursor`).
- **Login:** none inside the emulated machine; the kiosk's own root SSH is on
  127.0.0.1:5834 with the shared bridge key, declared in `operator.labctl`.

## Media and licence

**One 16 KB ROM.** `basic11b.rom`, MAME `orica` BIOS `ver11`, sha1
`9451a1a09d8f75944dbd6f91193fc360f1de80ac`, sha256
`ed28568574716eef5d7c0fde2568d7a47a6e4b1fbca81daff3be05e45723466d`. It is
**preservation-source**: Tangerine Computer Systems and Oric Products
International are both long gone and no rights-holder can be identified. The
bits are never committed and never served — only the fetch URL and the measured
hashes are recorded, in
[`docs/lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md), with a matching row
in `scripts/build-guests/check-assets.sh`.

The builder fetches it itself when it is not staged. **`orica` is a CLONE of
`oric1`**, so in a merged set its BIOS variants live inside the PARENT's zip
under an `orica/` prefix — `oric1.zip` from the archive.org item
`MAME_0.224_ROMs_merged`, whose per-game zips sit at the item root, so the fetch
is 406 KB rather than a 20 GB set. The zip is checked by sha256 and the
extracted ROM by sha1 before either is used.

The `oric1` PARENT is a different matter and is **not** what this tile runs:
MAME 0.276+ wants `basic10uk.rom` for it, which post-dates the 0.224-era set.
The Oric-1 is a placard on this tile's poster, not a second exhibit.

## The emulator, and why it is built rather than installed

The emulator runs **inside the Debian 12 guest**, so the binary must be
Bookworm-ABI. Neither packaged option works:

| Candidate | Version | Why not |
|---|---|---|
| lab host `/usr/games/mame` | 0.276 (Debian **trixie**) | wrong glibc for the Bookworm guest |
| guest `apt install mame` | 0.251 (Bookworm) | four years old; not the latest stable |
| `bookworm-backports` | — | has no `mame` package at all (checked 2026-08-09) |

So the tile does what `mpf2` does: **MAME 0.289** (tag `mame0289`, commit
`f34f02505e32c1993c6a782b6814232cbfc74e36` — the latest stable release, and the
same commit the MPF-II tile ships), built in the shared Bookworm chroot with
`SUBTARGET=oricatmos SOURCES=src/mame/tangerine/oric.cpp`, which keeps the
binary at ~70 MB. **No patch is applied** — `mpf2` needs one only to suppress
MAME's red "system doesn't work" panel, and `orica` does not nag (below).

The distro `mame` package is still installed in the guest, purely for the
SDL2/X11/ALSA runtime the pinned binary links against. Its own 0.251 binary is
never launched.

## Verifying the romset against the binary that ships

**`-verifyroms` is not the gate.** `orica` offers **25** selectable BIOS
variants (`ver11`, `ver12`, `ver121`, `ver122` and their DE/ES/FR/SE/UK/GE/SW
translations) and this set holds exactly one, so `-verifyroms orica` reports
`bad` while the pinned BIOS is present and hash-perfect. The builder logs it and
ignores it.

The gate is instead: **ask the shipped binary itself.**

```bash
/opt/oricatmos/mame/oricatmos -listxml orica \
  | sed -n 's/.*name="basic11b.rom" bios="ver11".*sha1="\([0-9a-f]*\)".*/\1/p'
```

and require that sha1 to equal the staged file's. That survives a MAME version
bump, where a filename does not. Cross-checked here: the guest's Bookworm 0.251,
the host's trixie 0.276 and the shipped 0.289 all demand the same sha1 for
`orica:ver11`.

`-bios ver11` is **pinned explicitly** in the launcher rather than left to
MAME's default. That is the dragon32 lesson from the same recon: with slot and
BIOS defaults left implicit, a driver can happily boot something that is not the
machine you meant to exhibit.

## No red nag screen — checked, not assumed

MAME marks some drivers `preliminary` and paints a full-screen red *"THIS SYSTEM
DOESN'T WORK"* panel that `-skip_gameinfo` does **not** suppress, and which a
headless `-video none` build never sees. `orica` reports

```xml
<driver status="good" emulation="good" savestate="supported"/>
```

which the builder asserts against the shipped binary — and the framebuffer
evidence in `evidence/` is what actually settles it.

## Display: why the X root is 800×600

The Atmos's screen is 240×224 at 50.080128 Hz. MAME runs **fullscreen with its
own aspect correction** (`-keepaspect -nowindow`), so the emulator reconstructs
the roughly 4:3 picture the machine drew on a television, and any 4:3 root fills
the captured frame edge to edge with no black surround.

**Which 4:3 root was decided by measurement, not taste.** MAME's software blit
dominates the tile's cost, and a 6502 at 1 MHz cannot earn the frame rate back.
Measured in the guest, `-prescale 2 -nofilter`, 8 s each, with the box at load
~75:

| X root | emulated speed |
|---|---|
| 1280×800 (the mode the root defaults to) | ~35 % |
| 1024×768 | 53 % |
| **800×600** | **83 %** |
| 640×480 | 97 % |

800×600 is the compromise: 4:3, 2.7× the machine's own 240×224, and 1.6×
cheaper than 1024×768. `c64`, `vic20`, `pet2001` and `cbm2` sit on the same mode
for the same reason. (`-video none` runs at 98 % here, so the emulation itself
is nearly free — it is all blit.)

- **Do not force `-resolution 240x224`.** That is the pixel count, not the
  picture's shape — the trap the MPF-II add fell into.
- **The launcher re-asserts the mode itself.** The bridge base's `.xinitrc` asks
  for 1024×768 and was observed here not to get it (the root stayed at 1280×800),
  and X geometry is part of what the golden captures.
- `-prescale 2` renders 480×448 before the final scale, and measured faster than
  both `-prescale 1` (68 %) and `-prescale 3` (63 %) at this root; `-nofilter`
  keeps the text crisp.
- **Any change to the launcher or the X geometry invalidates the golden.**
  Re-bake it, or reset restores the old layout and the fix looks like it did
  nothing.

## The fixture

The golden is **the machine's own untouched power-on screen**. Nothing is
curated into it, nothing is typed into it, and no post-restore keys are sent.
That is the Plus/4 lesson applied up front: a golden baked inside an application
drops a visitor into the middle of something with no idea what it is or how to
leave.

The builder's keyboard proof therefore runs **after** the bake, against the
restored fixture, and finishes with a `loadvm golden` — so nothing it types can
reach the snapshot. It types `PRINT 6502*7` and requires new ink on the screen;
an assertion that merely said "the framebuffer changed" would also pass on a
blinking cursor.

## Keyboard: the auto-repeat trap, then the pacing

**The biggest thing this tile learned is not a pacing constant. It is that X's
typematic auto-repeat must be OFF in a kiosk driven by synthetic keys.**

Every key this exhibit ever sees is an injected press/release pair. When the
release is delivered late — and on a box running thirty emulators it sometimes
is — X starts repeating the key that is still "held". Measured here on
2026-08-09 with repeat on (the bridge base's default), the demo listing's line
40 arrived as

```
40 PRINT "ORIC ATMOS 19999999999
```

one late release, eleven nines. Worse, the flood left the machine **deaf**: not
one of the following characters landed, and it stayed deaf until the next
`loadvm`. That behaviour cost most of this add's debugging time and looked in
turn like frame quantisation, host starvation and an emulator freeze; it was
none of them. `xset r off` in `/etc/bridge/launch.sh` fixes it, and the same
listing then arrives byte-perfect (`evidence/demo-typein-listing.png`). The
setting is part of the golden — the tile was re-baked after it was added.

Two corollaries worth carrying to the next bridge tile:

- an emulation that keeps rendering while ignoring keys is not frozen, and the
  guest kernel's `/proc/interrupts` i8042 counter is the cheap way to prove
  QEMU delivered the keys (it did, every time);
- the other X-hosted bridge tiles run with auto-repeat on and may have the same
  latent fault. It is not fixed here for them, because their goldens capture
  their X state and would each need re-baking.

### Then the pacing

MAME samples the emulated keyboard matrix once per emulated frame. At
50.080128 Hz that is 19.97 ms, so the frame-derived two-frame floor is 40/40.
Bisected on this tile (40-character line, 10 trials per rung, auto-repeat off),
comparing each frame against a known-good complete render — the blinking cursor
costs exactly one 1260-byte cell and a dropped character costs about 3000:

| `SH_KEY_MIN_HOLD_MS` / `GAP_MS` | lines corrupted |
|---|---|
| 40 / 40 | 0 of 10 |
| 60 / 60 | 0 of 10 |
| 80 / 80 | 0 of 10 |
| 250 / 250 | the harness's own "undisputed" reference dropped **7 of 40** |

**On this machine a long hold is the failure mode, not a short one** — the
opposite of the vic20 result — which is also why
`scripts/dev/emu-key-pacing-bisect.py` cannot be run unmodified here: it builds
its reference at 250/250 and then reports every rung as corrupt against a
reference that is itself broken.

The tile ships **80/80** anyway: it is what every other 50 Hz tile in the fleet
uses, it is four frames of margin, and it measured no worse than the floor.
`spa.demoProgram.perCharMs` is **160** to match — `validate_demo_pacing` in
`scripts/tiles-registry.py` fails the build if the SPA's typist would outrun the
tile's drain rate. The whole 105-character listing types and `RUN`s correctly at
those values (`evidence/demo-typein-listing.png`, `evidence/demo-typein-run.png`).

**No `SH_KEY_MAP` is needed.** MAME maps the host's PC keys onto the Oric matrix
by position and the Atmos layout is ASCII-shaped, so the SPA's US set1 scancodes
arrive as the characters they print. The machine boots in CAPS — it says so in
the top-right corner — so typed lower case reaches BASIC as upper case.

**MAME's UI keys are off** because `orica` emulates a full 59-key keyboard: a
visitor pressing Tab gets the Oric's key, not MAME's menu. The MPF-II's
`scroll_lock` sandwich exists for the same reason and is not needed here,
because this tile sends no post-restore keys at all.

**A tile with no viewer is idle-paused, and a paused guest swallows every key.**
`[idle] no sessions for 60s -> guest paused` in the journal is normal; `labctl`
resumes automatically, and a bare QMP harness must send `cont` itself. Forty
characters typed at a paused tile land as nothing at all, which reads exactly
like a broken keyboard.

## Operating and verification

```bash
ssh lab 'labctl ls'
ssh lab 'labctl shot oricatmos /tmp/oricatmos.png'
ssh lab 'labctl exec oricatmos "uname -a"'    # the Debian kiosk, not the Oric
curl -ksS -X POST https://192.0.2.10:8443/restore/oricatmos
```

`labctl exec` reaches the **kiosk**, not the emulated machine — the Oric has no
network and never did. The framebuffer is the only proof of what the Oric is
doing.

## Rollback

The golden lives INSIDE `overlay.qcow2`; never delete or recreate that file.
To rebuild from scratch, `oricatmos.sh --force` (which refuses to run while
`streamhost@oricatmos` is active) replaces the overlay and re-bakes. The frozen
base is never written.
