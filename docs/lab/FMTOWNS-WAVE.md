# fmtowns wave — Fujitsu FM TOWNS, Towns OS V2.1 L51 (TownsMENU)

Part of the five-station wave of 2026-09-13 (`vision`, `oberon`, `fmtowns`,
`magiccap`, `perq`). This is the FM TOWNS: Fujitsu's 1989 CD-ROM-first 386
home computer, whose operating system boots from the System Software CD into
**TownsMENU**, an icon desktop over an MS-DOS kernel. The fact that the
Virtual OS Museum runs this OS (on Tsugaru) is credited as a fact; nothing of
theirs is copied.

Read `docs/guests/fmtowns.md` for the station's operating manual once it is
filled; this file carries the wave: the ledger, the race, the sandbox verdict
and what is still open.

## Ledger — `wave.sh alloc fmtowns --x11warp` (no `--retronet`: Towns OS V2.1 has no TCP/IP stack by default, so a tap NIC would be meaningless)

| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| fmtowns | fmtowns | 196 / 54196 / 196 | :96 (127.0.0.1:6096) | — |

| Field | Value |
|---|---|
| sibling (`--like`) | `samcoupe` (MAME host-native, 0.289, save-state golden), tuple `towerE,crtC,keyboardE,paramMouseC` |
| render orders | as scaffolded (build 82 / signal 86 / stationsManifest 84 / binding 97 / golden 84 / bringUp 97) |
| uid base (if the Tsugaru route had won) | 2228224 — unused, see §Sandbox |
| media | see §Media |

## The race (rule 14) — two theories from minute 0, first TownsMENU frame wins

| Theory | Runner | Sandbox | Result | Frame |
|---|---|---|---|---|
| A. MAME `fmtowns` family, host-native (fleet tier) | sonnet | `/data/vms/sandbox/fmtowns/race/mame/` | **WON** — `fmtownsftv` boots the Towns System Software V2.1 L51 CD straight into a fully-rendered, settled TownsMENU desktop, ~80s wall-clock | `race/mame/frames/t90.png` |
| B. Tsugaru_CUI inside systemd-nspawn (uid base 2228224) | sonnet | `/data/vms/sandbox/fmtowns/race/tsugaru/` | not pursued once A won — reference only. Tsugaru_CUI needed a Linux build from source (no prebuilt binary for this arch/distro), an nspawn container per the sandbox contract, and a from-scratch X11/framebuffer capture path; none of that is proven, so this row records the theory's shape, not a result | — |

**finisher (this stream, sonnet, 2026-09-13)**: turned the race into the shipped
artifact — real fleet build (not the race sandbox's ad-hoc invocation), real
CHD compose via chdman, real keymap generated from KEYDUMP, keyboard proof via
the real ctlsock KEY path, golden bake + restore proof. See §Proofs.

## Media — staged by the `fmtowns-media` agent on labhost (`/data/assets-staging/fmtowns/`), re-hashed by the lead

Fetched from archive.org origins; the bits stay under `/data` (the gallery is
private), the repo carries only URL + sha256 + size in
`scripts/build-guests/tiles/fmtowns.sh`. MEASURED 2026-09-13 (`sha256sum`,
`sha1sum`, `stat -c %s` on labhost):

| File | Bytes | sha256 | sha1 (MAME member match) |
|---|---|---|---|
| `roms/fmtowns.7z` — MAME 0.272 merged romset `mess/fmtowns.7z` (item `mame-0.272-romset-complete-merged`), 20 members incl. every regional variant + the 32-byte `mytowns*.rom` boot-select ROMs | 967 043 | `5856826e…5081ac` | — |
| `FMT_SYS.ROM` | 262 144 | `7d4e8935…7b9a` | `15d9cc70…` = base `fmtowns` (Model 1/2) `fmt_sys.rom` |
| `FMT_DOS.ROM` | 524 288 | `b760d991…f17f` | `57fd1464…` = every set's `fmt_dos.rom` |
| `FMT_F20.ROM` | 524 288 | `dca1f314…b774` | `1920711c…` = Towns II `fmt_f20.rom` |
| `FMT_DIC.ROM` | 524 288 | `fdec9c3b…cdc7` | `7564020d…` = Towns II `fmt_dic.rom` |
| `FMT_FNT.ROM` | 262 144 | `aa9e9565…b9d` | `a216482e…` = Towns II `fmt_fnt.rom` |
| `cd/towns-sysv21-l51-cd.7z` — "[OS] Towns System Software v2.1 L51 [CD].7z" from item `neo_kobe_fujitsu_fm_towns_2016-02-25-repack_20200803` | 252 788 766 | `43db0465…0648b85` | — |
| `cd/towns-sysv21-l51-cd.img` (CloneCD; 1× MODE1/2352 data track + 8 audio tracks; `.ccd`/`.sub` alongside) | 593 767 104 | `5adbae1b…50f8ab` | — |
| `optional/` MS-DOS 6.2 L10 FD sets, Towns OS V1.1 L20 **English** FD + HD sets | 0.5–2.7 MB each | in `SOURCES.md` | not used by this wave |

The five uppercase files are the set the Virtual OS Museum boots on Tsugaru;
by hash they straddle two MAME machines (SYS is the Model 1/2 ROM, the rest are
Towns II), which is why the rompath is assembled by `stage-romset.py` from the
extracted merged archive rather than from the five files.

## Sandbox verdict

**Emulated machine under the fleet MAME (host-native template).** The visitor's
reach ends at the emulated FM Towns hardware — no nspawn audit is needed (per
WAVE-COMMON's tier table). Launcher line (real fleet build, real CHD, from the
shared `stations/mame-native/x11-runtime.sh`):

```
MAME_SHM_PATH=$BASE/fb.shm MAME_SHM_SIZE=1024x768 MAME_CTL_SOCK=$BASE/ctl.sock MAME_NO_UI=1 SDL_VIDEODRIVER=dummy \
/data/vms/streamhost/assets/fmtowns/mame-native/fmtowns fmtownsftv \
  -rompath /data/vms/streamhost/assets/fmtowns/mame-native/roms \
  -inipath $BASE -homepath $BASE -cfg_directory $BASE/cfg -nvram_directory $BASE/nvram \
  -video shm -nofilter -sound none -skip_gameinfo -throttle -frameskip 0 -noautoframeskip \
  -state_directory $BASE/sta -state golden \
  -pad1 townspad -pad2 mouse -cdrom /data/vms/streamhost/assets/fmtowns/media/townsos-v21l51.chd
```

No `-netdev`, no 9p/virtfs/`fat:` host directory, no monitor/QMP socket reachable
from the guest, no `-device virtio-serial`. Only `-cdrom` (a CHD, read-only image)
and `-pad1`/`-pad2` (emulated peripherals) touch the device set beyond the fleet
defaults.

## Proofs

All frames measured 2026-09-13, real fleet binary (`sha256
4bb3755496523d016d035b2afe8f4ed55ca2285d083428c05165c9fe7f580d46`) + real CHD
(`sha256 fde4fa2bc8ede2d260e9baf0dc7e832b0682222fa04fc480dace923445a00c4d`, 210
349 963 bytes), on `/data/vms/sandbox/fmtowns/golden2/` then the real station
dir `/data/vms/streamhost/stations/fmtowns/`.

| Proof | Shows | Path |
|---|---|---|
| Race frame (theory A win) | TownsMENU desktop, drive-select window, Q:TOWNSSYSTEM folder | `race/mame/frames/t90.png` |
| Real build boot gate | 50291 lit pixels on the published 1024x768 surface (floor 25000) | `race/mame/build-real.log` |
| Cold boot, early | `TownsOS V2.1 L51` boot banner | `golden/run/settled.png` |
| Cold boot, mid | loading clock icon | `golden2/run/s3-settled.png` |
| Cold boot → settled desktop (untouched, no keys sent) | TownsMENU desktop reached from a clean cold boot | `golden2/run/s5.png` — **this is the golden savestate's pixel source** |
| Keyboard proof: before | the settled desktop, no dialog | `golden/run/desktop-settled.png` |
| Keyboard proof: Ctrl+Esc pressed (ctlsock `KEY` verbs on `:key3 Ctrl` + `:key1 ESC`, real generated keymap fields) | the guest's own タスクリスト (Task List) dialog opens, showing `TownsMENU V2.1L51` and its buttons (サイドワーク/強制終了/選択/取消) | `golden/run/after-ctrlesc.png` |
| Keyboard proof: Ctrl+Esc pressed again | a DIFFERENT dialog (サイドワークリスト — Control Panel / Calculator / CD Player / Schedule / etc.), proving the guest is genuinely reading each keypress, not replaying a cached frame | `golden/run/back-to-desktop.png` |
| SAVEST at the settled desktop | `334ms ack, bytes=797714`, written to `sta/fmtownsftv/golden.sta` | `golden2/sta/fmtownsftv/golden.sta`, installed at `/data/vms/streamhost/stations/fmtowns/sta/fmtownsftv/golden.sta` |
| Restore proof: a FRESH process launched with `-state golden` against the REAL station dir | settled in 5.2s (includes CD mount); `PIL.ImageChops.difference` bbox against the golden capture frame is `(767, 60, 768, 69)` — a 1×9 px sliver at the on-screen clock glyph (real wall-clock time reads through to the guest's RTC), otherwise pixel-identical | `golden2/run/restored.png` vs `golden2/run/s5.png` |
| Hero / poster image | the settled TownsMENU desktop, converted to webp | `spa/public/posters/fmtowns/desktop.webp` (source `golden2/run/s5.png`) |

## Still open

1. **Pointer** — MOTION PROVEN 2026-09-13 (Sonnet, fmtowns-ptr stream), CLICK
   still open. Two bugs, both root-caused and fixed on the framebuffer: (1)
   the ctlsock module never bound the FM Towns mouse's axis fields — fixed,
   `axes=1` measured, four-target precise relative motion proven; (2) the
   mouse's BUTTONS port is `IP_ACTIVE_LOW` and the module's click engine
   always wrote the active-HIGH polarity — fixed and verified to bind and not
   regress motion, but a click still produces no visible guest reaction. See
   §Pointer, "Pointer stream 2026-09-13" for the full account, the four
   proven targets, and the click candidates for the next stream.

2. **`/os/fmtowns` publish** — **DONE 2026-09-13**, dark-launched. See
   §Publish below.

3. **Command Mode / MS-DOS prompt, TownsGEAR and the other TOWNSSYSTEM icons**
   — not opened (no proven pointer, and no keyboard-only launch path found for
   icons; `Ctrl+Esc`'s Task List / Sidework dialogs are the only reachable
   non-desktop screens without a pointer). OPEN for a future stream once
   pointer lands.

## Pointer — the root cause, and the race for the proof

The previous stream recorded "MOVEA + CLICK1 produce no cursor movement" and
read it as the domainos wall ("the pointer never leaves compatibility mode").
It is not that wall. Read in this order:

1. `src/mame/fujitsu/fmtowns.cpp:2626` —
   `MSX_GENERAL_PURPOSE_PORT(config, m_pad_ports[1], msx_general_purpose_port_devices, "mouse")`.
   `-pad2 mouse` is an **MSX-protocol mouse**, not a PS/2 one.
2. `src/devices/bus/msx/ctrl/mouse.cpp` — its ioports are tagged `BUTTONS`,
   `MOUSE_X`, `MOUSE_Y` (both axes `PORT_BIT(0xffff, 0, IPT_MOUSE_X/Y)`,
   so the accumulator modulus is the default 65536). The device is purely
   relative: on each pin-8 strobe it computes `m_data = (previous - current)`
   per axis and packs each into a **signed byte** — so the guest sees a delta
   whose SIGN is inverted relative to the accumulator's direction, and any
   step larger than 127 counts between two polls is truncated.
3. `scripts/build-guests/emulators/mamectl/src/osd/modules/ctlsock/ctlsock.cpp`
   (~line 920-950) — the fleet ctlsock binds its pointer engine by matching
   ioport tags ending `<MAME_CTL_PTR_PORTS>:mouse_buttons` / `:mouse_x_axis` /
   `:mouse_y_axis`, and button fields named `Left Button` / `Right Button` /
   `Middle Button`. **Those are the SGI Indy's `hle_ps2_mouse` names and no
   other machine in MAME has them.** `MAME_CTL_PTR_PORTS` only prefixes them;
   the `:mouse_x_axis` half is hardcoded.

So on `fmtownsftv`, `m_x_port`/`m_y_port` never resolve, `m_x_field`/`m_y_field`
stay `nullptr`, and `move_rel()` (ctlsock.cpp:1229) returns on its first line.
Every `MOVE`/`MOVEP`/`MOVEA`/`CLICK` is acked and discarded. The module prints
its own verdict at setup (ctlsock.cpp:1041) as `axes=0`.

This also **falsifies theory B by construction**: the daemon's rel-readback
bridge (`streamhost/streamhost/src/rel_bridge.rs`, the `SH_REL_*` route from
`docs/lab/SCULPT-WAVE.md`) converts an absolute target into relative motion and
then hands it to the input backend — and for `backend() == "mamesock"`
(`streamhost/streamhost/src/input.rs:702`) that motion goes out as the same
ctlsock relative verb, into the same unbound fields. No amount of pacing or
readback on the daemon side can reach a field the emulator never bound. Theory
B was retired on that reading rather than on a rig, which is the cheap half of
rule 14: falsify from the source when the source is decisive.

**The fix already exists in this repo, unapplied:**
`scripts/build-guests/patches/mame-ctlsock-ptr-tags.patch` adds exactly the
three knobs this needs — `MAME_CTL_PTR_TAGS` (`"<btn>,<x>,<y>"` tag suffixes,
replacing the hardcoded construction wholesale), `MAME_CTL_BTN_NAMES`, and
`MAME_CTL_PTR_MOD` (accumulator modulus = 1 + the axis field's mask). It was
written for the Atari ST's `:ikbd:MOUSEX`/`MOUSEY`, which is the same shape of
wall. `scripts/build-guests/emulators/build-mame-native.sh` deliberately keeps
it out of the default patch set ("the spike-only pointer patches (ptr-tags,
st-fastmouse) are NOT here"); a station opts in through `NATIVE_EXTRA_PATCHES`
in its `native.d/<id>.sh` stanza, which `fmtowns.sh` already uses for
`mame-irix-skip-warnings.patch`.

**MEASURED, on the running station (2026-09-13, not inferred from source):**
`/data/vms/streamhost/stations/fmtowns/mame.log` line 5, printed by the live
dark-launched station's own ctlsock at setup:

```
ctlsock: setup btns=0 axes=0 movea=0 devxy=0 swap=0 sig=1ebe131a entries=3330
```

`btns=0 axes=0` on a machine that plainly HAS a mouse (`-pad2 mouse`) is the
whole bug in one line, and the later heartbeats say the rest:
`conns=1 cmds=4` — commands arrive and are counted, and

```
ctlsock: MOVEA unsupported (no cursor items); interpreting MOVEA as open-loop
relative from the last target
```

— it then dead-reckons into two null pointers. That is exactly the liar's
paradox the ptr-tags patch's own rationale describes: "the module logs commands
arriving, the socket acks every one, and the cursor does not move a pixel."

**Race result (rule 14): NOT WON inside the 20-minute stop.** The theory-A
runner (sonnet) could not get a throwaway rig to `machine_phase::RUNNING` at
all: `ctlsock: init … phase=1` and `listening`, then nothing — no `setup` line,
a framebuffer frozen at 10 705 nonzero bytes, and every ctlsock verb timing out
because `tick()` early-returns while `!m_setup_done`. **Cause, found afterwards
from the live station's dir:** the rig's `-inipath $BASE` pointed at a fresh
empty directory, and `native.d/fmtowns.sh` sets `NATIVE_SKIP_WARNINGS=1`, which
needs the station's `ui.ini` — present at
`/data/vms/streamhost/stations/fmtowns/ui.ini`, absent in the rig. Every
machine in `fujitsu/fmtowns.cpp` is `MACHINE_NOT_WORKING`, so without that knob
MAME sits on its red warning panel waiting for a key, pre-RUNNING, forever.
**Any future fmtowns rig must copy the station's `ui.ini` into its `$BASE`.**
This cost the race its whole budget and is the single most useful thing the
runner found.

**Exact next step (one stream, no discovery left):**
1. `cp /data/vms/streamhost/stations/fmtowns/ui.ini $BASE/` in the rig — or
   just pass `-inipath /data/vms/streamhost/stations/fmtowns`.
2. Add `mame-ctlsock-ptr-tags.patch` to `NATIVE_EXTRA_PATCHES` in
   `scripts/build-guests/emulators/native.d/fmtowns.sh` and rebuild through
   `build-mame-native.sh` (ccache is wired there — never hand-run `make`).
3. Launch with (tags to be confirmed by `KEYDUMP :pad2:` against the rebuilt
   binary, which is the first thing to run):
   `MAME_CTL_PTR_TAGS=":pad2:mouse:BUTTONS,:pad2:mouse:MOUSE_X,:pad2:mouse:MOUSE_Y"`,
   `MAME_CTL_BTN_NAMES` from the same dump, `MAME_CTL_PTR_MOD` left at its
   65536 default (both MSX axes are `PORT_BIT(0xffff)`).
4. Confirm the setup line now reads `axes=1 btns>=1` — that is the gate; if it
   still says 0, the tags are wrong and nothing downstream matters.
5. Then `MOVE dx dy` in steps well under 127 counts, paced by
   `MAME_CTL_MOVE_STEP`/`MAME_CTL_MOVE_WINDOW` so the guest polls between them,
   **trying BOTH SIGNS** — `mouse.cpp` computes `(previous - current)`, so the
   delta the guest sees is inverted with respect to the accumulator.

Until `axes=1` is measured, `stream.pointer.transport` stays `none` and
`listing.state` stays `hidden`. The station ships keyboard-only, exactly the
domainos precedent — but unlike domainos this is now a KNOWN, located,
already-written fix rather than a wall.

### Pointer stream 2026-09-13 (fmtowns-ptr, Sonnet) — motion PROVEN, click OPEN

Worked in its own sandbox/branch, `/data/vms/sandbox/fmtowns-ptr/`, never
touching the live station dir. Two bugs found and fixed, both root-caused on
the framebuffer, not guessed.

**Bug 1 (the one this doc already located): `axes=0` despite matching tags.**
`MAME_CTL_PTR_TAGS=":pad2:mouse:BUTTONS,:pad2:mouse:MOUSE_X,:pad2:mouse:MOUSE_Y"`
bound `m_x_port`/`m_y_port` correctly (confirmed by `KEYDUMP :pad2` against the
rebuilt binary: those exact tags exist), but `setup()` still logged
`axes=0` — because the ptr-tags patch's field-NAME match for the axes was left
hardcoded to `"Mouse X"` / `"Mouse Y"` (only the BUTTON names were made a
knob). MAME appends a player-index suffix to a generic input-type's display
name for any port beyond the first, so pad2's fields are named
`"Mouse X 2"` / `"Mouse Y 2"`, not `"Mouse X"` — the literal match silently
never fired. **Fix**: match by `f.type() == IPT_MOUSE_X` / `IPT_MOUSE_Y`
instead of by name (that enum is the one thing the patch's own header already
claimed was universal — it was the NAME assumption that broke, not the type
one). Landed as an extended hunk in `mame-ctlsock-ptr-tags.patch` itself.
**Measured after the fix**: `ctlsock: setup btns=1 axes=1 movea=0 devxy=0
swap=0 sig=1ebe131a entries=3330` — signature `sig=` and `entries=` UNCHANGED
from the pre-fix line, so the golden savestate is not orphaned by this patch
(no save items touched, per its own covenant).

**Pointer motion — PROVEN on the framebuffer, four distinct targets, one
session, from the real golden `.sta`:**

| Step | Verb | Landed on (visual) | Frame |
|---|---|---|---|
| start (restored `-state golden`, no input sent) | — | cursor over "テキスト編集", the position baked into the golden save | `sandbox/fmtowns-ptr/frames/00-settled.png` |
| 1 | `MOVE 50 50` | bottom-right of the TOWNSSYSTEM window, empty space | `01-move5050.png` |
| 2 | `MOVE -67 -51` | dead center of the **TownsGEAR** icon | `02-move2.png` |
| 3 | `MOVE 24 25` | dead center of the **エンターテイメント** icon | `05-move3.png` |
| 4 | `MOVE 5 23` then `MOVE 3 -13` | dead center of the **コマンド モード** icon | `07-move5.png` |

Scale measured at roughly **6 px of cursor travel per count**, both axes,
**positive-sign, not inverted** (a positive MOVE dx moves the cursor right,
positive dy moves it down — `mouse.cpp`'s `previous - current` differencing
does NOT flip the sign the caller sees, at least not at this binding). Small
steps (all four moves above are ≤ 82 counts) landed exactly where aimed, on
the first try, every time. **The >127-count truncation this doc already
warned about is real and was reproduced**: a single `MOVE 149 162` (after a
fresh `LOADST`-equivalent restore) landed the cursor only ~65 px away instead
of the ~900 px four smaller moves of comparable total magnitude produced —
consistent with `mouse.cpp` packing each axis into a signed byte and the
149/162 counts wrapping. **Practical rule for any future move-issuing code
here: always chunk under 127 counts per `MOVE`, never send a raw pixel-to-count
translation of a big target in one shot.**

**Click — bug 2 found, fix landed, effect still NOT proven.** `CLICK1`,
`DCLICK1`, and a bare `DOWN1` held for a full framebuffer capture all
produced **zero visible change** on four different targets (TownsGEAR twice,
Command Mode twice) — not even the icon-select highlight a real click
produces, regardless of button field binding (`btns=1`, confirmed bound to
`:pad2:mouse:BUTTONS` field `"P2 Button 1"` via the same `KEYDUMP`). Read the
device source rather than guess further: `bus/msx/ctrl/mouse.cpp:17-18`
defines both buttons `IP_ACTIVE_LOW` —

    PORT_BIT(0x10, IP_ACTIVE_LOW, IPT_BUTTON1)
    PORT_BIT(0x20, IP_ACTIVE_LOW, IPT_BUTTON2)

— so `set_button()`'s `set_value(1)` for "pressed" (correct for the Indy's
`IP_ACTIVE_HIGH` PS/2 buttons, the only button polarity this module ever
served before today) was writing the RELEASED state for every click this
station ever attempted. Fixed with a new patch, `mame-ctlsock-btn-active-low.patch`
(`MAME_CTL_BTN_ACTIVE_LOW="1,1,"` for fmtowns), which compiles clean, binds,
and does not regress the pointer-motion path — but re-running the exact same
four click attempts with the fix loaded **still produced no visible reaction**.
The bug this doc set out to fix (`axes=0`) is closed; a SECOND, still-open bug
sits between "the button ioport now carries the correct logic level" and "the
guest's icon-select code notices." Candidates for the next stream, cheapest
first: (a) the FM Towns MSX-mouse driver may only sample `BUTTONS` at the same
strobe moment it samples `MOUSE_X`/`MOUSE_Y`, and `set_button()`/`set_value()`
outside that strobe may never be seen — try holding the button down across a
`MOVE` rather than a bare click; (b) `TownsMENU`'s icon click may require the
button transition to happen while the position is exactly settled for more
than one frame (there is no settle delay in `btn_click()`'s default 10/6-frame
timing) — try a longer hold; (c) confirm with `KEYDUMP :pad2` whether there
is a THIRD, unnamed field on the `BUTTONS` port (this stream's dump showed one
row printed as `???` with no name and no default-key token) that gates the
other two.

`stream.pointer.transport` stays `none`, `registry/stations/fmtowns.json`'s
`listing.state` stays `hidden` — motion is real and precise, but a pointer a
visitor cannot click with is not a shippable pointer contract. This is a
strictly smaller wall than the one this stream started with: one located,
reproducible bug, on a device whose motion is now fully worked out.

Sandbox rig (torn down after this stream, kept on disk for the next one):
`/data/vms/sandbox/fmtowns-ptr/rig/` (station's `ui.ini`/`fmtowns.keymap`
copied in, golden `.sta` copied in, never the original), binary
`/data/vms/sandbox/fmtowns-ptr/build/mame-fmtownsftv-ptr` (built through
`build-mame-native.sh fmtowns`, ccache 99.9% hit on the full 6-patch clean
build), frames under `/data/vms/sandbox/fmtowns-ptr/frames/`.

## Publish — `/os/fmtowns` is dark-launched

`scripts/dev/smoke-rig.sh` was not extended, because for a MAME-native station
it is the wrong tool by construction, and reading it said so:

- it fails loudly at step 0 without a real `qmp.sock`, hardcodes
  `SH_INPUT_BACKEND=dbus-rel`, and its `--like` sibling-env copy loop whitelists
  only `SH_*=*`, so every `MAME_NATIVE_*` line from the sibling fixture is
  silently dropped into its `*) continue` case;
- and the shared MAME-native launcher `streamhost/stations/mame-native/x11-runtime.sh`
  hardcodes `BASE=/data/vms/streamhost/stations/$SH_STATION`. It can never be
  pointed at a sandbox rig dir. **For a MAME-native station the rig IS the
  station dir** — which for fmtowns was already true, since the golden, ROMs,
  CHD and keymap were installed there by the previous stream.

`docs/lab/ADD-NEW-OS-PLAYBOOK.md` line 380 already documents this trap. The
documented route was used instead, with no code change:

```
scripts/dev/darklaunch-station.py publish fmtowns \
  --rig /data/vms/streamhost/stations/fmtowns --like atari800xl \
  --display-name "FM TOWNS (dark launch)"
→ declared darklaunch … published fmtowns: udp 54196 /os/fmtowns
```

with `station.env` written into the station dir from the registry's
`runtime.stationEnv` + the committed fixture (real host IP in place of the
repo's scrubbed placeholder), the shared `x11-runtime.sh` copied in and run (it
reaped the stale MAME by `/proc/<pid>/exe`, never a name match, and relaunched
with `-state golden`), and the generic streamhost daemon borrowed from
`atari800xl`'s `current` symlink.

| Check | Result |
|---|---|
| `curl -sk https://<box>:8443/os/fmtowns` | `200` |
| `…/signal/fmtowns.json` | real row — `cert_hash_b64`, udp 54196, WebRTC offer URL |
| Framebuffer (rule 9), captured fresh from the running rig via `fb-wait.py --shm … --settle 3` | TownsMENU desktop: ドライブ選択 window, Q:TOWNSSYSTEM folder open with TownsGEAR / TownsStaff / FM-OASYS icons, guest clock `2026.09.13(日) 08:47` — `/data/vms/sandbox/fmtowns/frames/dark-launch-awake.png` |

Running, deliberately LEFT UP for the operator: MAME pid in
`/data/vms/streamhost/stations/fmtowns/mame.pid`, daemon pid in
`daemon.pid`, log `daemon.log`. MAME self-pauses on the daemon's idle grace
(SIGSTOP after 60 s, SIGCONT on connect) — expected fleet behaviour. Withdraw
with `scripts/dev/darklaunch-station.py withdraw fmtowns`, then kill the daemon
and MAME by `/proc/<pid>/exe`.

**Left open for a shared-tooling stream (not this station's to fix alone):**
`smoke-rig.sh` drops `MAME_NATIVE_*` on a `--like` copy and hardcodes
`dbus-rel`. Every future host-native wave hits both.

## Teardown

- `golden` rig (`/data/vms/sandbox/fmtowns/golden/run/mame.pid`, pid 2691902) —
  killed via `/proc/<pid>/exe` match against the real fleet binary, then
  SIGKILL-verified dead (0.28s `SIGTERM`→exit path).
- `golden2` rig (`/data/vms/sandbox/fmtowns/golden2/run/mame.pid`, pid 2746459)
  — same kill path, dead before the golden.sta was copied out of it.
- The real station-dir process (pid 2772770, launched to prove the
  `-state golden` restore against the real `/data/vms/streamhost/stations/fmtowns`
  paths) — killed the same way (`/proc/<pid>/exe` match against the real fleet
  binary, SIGTERM then confirmed dead), after the restore frame was already
  captured. `/data/vms/streamhost/stations/fmtowns/{ctl.sock,fb.shm}` are now
  stale files from a dead process (no daemon manages this station yet); the
  next real launch (via `station-up.sh` after landing) removes and recreates
  them itself, same as any other station's `reap_previous`.
- Race sandboxes (`/data/vms/sandbox/fmtowns/race/{mame,tsugaru}/`) left on
  disk as provenance, per brief.
- **Correction 2026-09-13 (replacement lead):** the race's MAME instance
  pid 2545230 was NOT gone — it was still running 12 hours later, burning a
  core. `readlink -f /proc/2545230/exe` =
  `/data/vms/sandbox/fmtowns/race/mame/mame-native/fmtowns`, which is how it
  was identified and killed (SIGTERM, then SIGKILL when it did not exit;
  `ls /proc/2545230` → `DEAD_AFTER_KILL`). The lesson is rule 8's: the check
  that proves a release is `ls /proc/<pid>`, run AFTER the kill — not an
  assumption that a rig "was already gone".

## Teardown — this stream (replacement lead, Opus, 2026-09-13)

Rule 8: what was released, and the check that proved it.

| Released | Check |
|---|---|
| Leftover race MAME pid 2545230 (`/data/vms/sandbox/fmtowns/race/mame/mame-native/fmtowns`), running ~12 h after the previous stream declared it gone, holding a core | `readlink -f /proc/2545230/exe` matched the race dir before the kill; SIGTERM, then SIGKILL when it did not exit; `ls /proc/2545230` → gone |
| Theory-A rig pid 3197436 (the fleet binary, `race/ptr-tags/run/mame.pid`) | `readlink -f /proc/3197436/exe` matched the fleet binary; SIGTERM then SIGKILL; `/proc/3197436` absent |

Still running ON PURPOSE — the `/os/fmtowns` dark launch is the deliverable, not
litter: MAME `/data/vms/streamhost/stations/fmtowns/mame.pid`, daemon
`daemon.pid`. Withdraw + kill as in §Publish when the operator is done watching.

`race/{mame,tsugaru,ptr-tags}/` are left on disk as provenance. Note that
`race/ptr-tags/` holds a COPY of the golden savestate, not the original.
No claims were taken or dropped by this stream: slot 196 / UDP 54196 / VMID 196
/ display :96 were already held by session `fmtowns` and still are.

## Landed 2026-09-13 (LANDING stream, Sonnet)

`fmtowns` is on `main` and deployed. `streamhost@fmtowns` is `active`
(unit main PID owns MAME as a child, not a hand-launched rig), `/os/fmtowns`
returns 200, `/signal/fmtowns.json` carries a real cert hash + UDP 54196 +
WebRTC offer URL, and `gallery-manifest.json` lists `fmtowns` with
`listed: false` (hidden, per `listing.state`). Framebuffer proof after landing
(`labctl shot fmtowns`) is pixel-identical to the pre-landing dark-launch
frame: TownsMENU desktop, ドライブ選択 window, Q:TOWNSSYSTEM open with
TownsGEAR/TownsStaff/FM-OASYS icons.

Poster/registry prose merged from the `fmtowns-spa` branch (poster stream):
kept its museum-voice poster wholesale, but rewrote "What you're looking at"
to the golden scene actually proven rather than the drafts' generic
click-an-icon paragraphs (no pointer is proven, so "click the CD player" is
not an action this exhibit can offer yet). `museum`/`spa` fields (blurb,
accent, eraSoftware, iconicApps, archetype, eraLabel) came from the drafts;
the lead's `ramMB` (6, measured from the real `fmtownsftv` driver) and
`machineIdentity` row (also driver-measured: FreshTV II, 486SX-33, 1994, teal
TownsMENU-ground accent) were kept over the drafts' pre-golden guesses.
`spa.pointerRel: true` from the drafts was dropped — `validate` refuses it for
a `mamesock` backend with `stream.pointer.present: false`; the field doesn't
apply until the pointer patch (§Pointer) lands. `assembliesByTile`/
`machineIdentity` tuple fixed via `spa-scene-rows.py --tuple` (towerSetup, not
homeMicro — the FM TOWNS has a detached keyboard; keyboard/mouse fields were
missing entirely in the scaffolded row).

**`station-land.sh` did not complete unattended** — two blockers, both fixed
in-session rather than parked:

1. **Duplicate `keyboardProfiles.ts` row.** My merge-resolution added a
   `fmtowns:` entry near `chokanji` without noticing the lead had already
   added one (with a better, measured comment) further down the file. `tsc`
   caught it (TS1117) at the SPA-build step of landing. Fixed by dropping
   mine; a follow-up commit already on `main` (`a74c3f2e`) did the same
   independently.
2. **Step 9 (`station-up.sh`) failed: "no 'LISTENING udp/' line in the
   journal ... after 60s".** Two STALE fmtowns processes from the earlier
   dark-launch (MAME pid 3492009, daemon pid 3577164 — the ones the previous
   stream deliberately left running) still held UDP 54196 and the shared
   `ctl.sock`/`fb.shm`, so the freshly started `streamhost@fmtowns` unit could
   not bind and never printed its `LISTENING` line. Fixed by resolving both
   PIDs via `/proc/<pid>/exe` (not a cmdline grep, rule 5), confirming the exe
   matched the real fleet binaries, `kill -TERM` then verifying `/proc/<pid>`
   gone, clearing the stale `ctl.sock`/`fb.shm`/`*.pid` files, and
   `systemctl restart streamhost@fmtowns` — journal then showed `LISTENING
   udp/54196` within seconds. `station-land.sh` had already released the
   landing window at the point of failure (no other wave was landing
   concurrently, so re-running its remaining steps by hand was safe); steps 6
   (box-deploy), 7 (no golden swap needed — the MAME savestate golden was
   already installed), 8 (no smoke-rig socket, nothing to take down), 9
   (station-up, completed by hand as above), 11 (framebuffer proof), 12 (SPA
   build+deploy) and re-arming the dark-launch overlays (automatic, via
   `publish_manifests`/`serve-https-spa.sh deploy`) were all still carried out.
   Also had to `darklaunch-station.py withdraw fmtowns` BEFORE any of this —
   the running dark-launch declaration was an `atari800xl --like` copy
   (wrong OS metadata entirely) still overlaying `tiles.json`/
   `gallery-manifest.json`, which would have fought the real registry entry.
3. **Unrelated fleet-tooling blocker, fixed at its root because it blocked
   this landing's proof:** `scripts/gen_tiles_json.py` (which `labctl shot`
   depends on via `/data/vms/streamhost/stations.json`) refused fleet-wide
   with `declared/live mismatch indyr4400.ssh_port`. Cause: a **stale
   `qemu-streamhost.sh`** left in `indyr4400`'s station dir from before its
   2026-09-10 de-bridging to host-native nspawn (two backup copies of the
   same file already sit beside it — `.bak-preperf`, `.debridged-bak` — this
   one was just never renamed out of the live filename). Its
   `hostfwd=tcp:127.0.0.1:5839-:22` line made `gen_tiles_json.py` observe a
   live `ssh_port` the registry no longer declares (indyr4400 is host-native
   now, no QEMU, no SSH). Renamed it to
   `qemu-streamhost.sh.dead-post-debridge-fmtowns-landing-20260913`
   (`indyr4400`'s own launcher/registry are untouched — the file was dead
   weight, never read by anything with `x11-runtime.sh` as the live
   launcher). `gen_tiles_json.py` then wrote clean for all 96 tiles.

Teardown for this stream: nothing new was left running — `streamhost@fmtowns`
is the real production unit (systemd-managed, not a hand-launched rig), the
station-dir MAME + daemon it manages are the same one the wave doc's
`§Publish` frame was taken from. No sandbox rigs were started by this stream.
