# bootos guest — bootOS, an operating system in one 512-byte boot sector

Status: **LIVE** (Tier 1, host-native, KVM), integrated 2026-09-02 in one parallel
wave ([`lab/BOOTOS-WAVE.md`](../lab/BOOTOS-WAVE.md)). The media is sourced,
hashed and staged; the launcher is the tracked verbatim one; the golden is baked
and restore-proven on a clone, the PC speaker is heard through the production
audiodev, the key pacing is bisected, and the type-in demo runs end to end on
the framebuffer. Everything below is first-hand from the upstream source at the
pinned commit or from framebuffer proofs taken during the wave.

The exhibit is the smallest operating system in the museum by four orders of
magnitude, and it is complete: a command shell, a 32-file filesystem on the
floppy, a hex loader that lets a visitor type a program in and run it, and five
services other programs can call. All of it assembles to **512 bytes**, the one
sector a PC BIOS loads. Óscar Toledo G. wrote it in two evenings —
*"Creation date: Jul/21/2019. 6pm 10pm"* is the first line of `os.asm` — and
shipped a floppy of his earlier boot-sector games to run on it: chess, a Doom,
a BASIC, a Flappy Bird, each exactly one sector too.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `bootos`
- Display name: **bootOS**
- Reserved slot / UDP port / VMID label: `174` / `54174` / `174`
- Archetype: `beige-ibm-pc`; era year **2019** (`museum.year` 2019; the OS is
  written for the 1981 IBM PC's 8088, but the artefact is a 2019 program)
- Tile UI kind: `text-console`. Pointer **none** (`SH_INPUT_BACKEND=disabled`).
  Audio on (`SH_AUDIO=on`, PC speaker) — see *Audio*. `resetMode: loadvm`,
  snapshot `golden`.
- Upstream: <https://github.com/nanochess/bootOS>, pinned at commit
  **`329b75e60d04e89616bc1844578098df43d4f432`** (master, 2026-08-01). Author
  Óscar Toledo G. (nanochess), first release **2019-07-22**; the source carries
  three revision dates, the last 2019-07-31 (service table; filenames from any
  segment; `del` reports errors). `cpu 8086` — it runs on the original PC.
- License class: **free/open** — bootOS is **BSD-2-Clause**. The bundled
  programs on `osall.img` are **separately licensed by their own authors**
  (eleven are Toledo's own, five are third-party — see the program list below); they are
  staged locally with bootOS's `LICENSE` beside them and **never committed**.
  The repo is public, so no image bits go in Git regardless of licence.
- No login, no credentials. `credentialsRef: guest/bootos` exists only because
  the schema requires one; there is no secret and nothing to keep outside Git.

### Media — acceptance criteria

| property | value |
|---|---|
| `os.img` | the bare 512-byte boot sector, `nasm -f bin os.asm` output — **512 bytes**, SHA-256 **`35e1231cf29f8750566a97dfb628b2bbe2c24a2f7d7518d7a94103f9976d3df8`** |
| `osall.img` | upstream's pre-built **360K floppy** (bootOS + directory + 19 entries) — **368 640 bytes**, SHA-256 **`20927188a96cca1cc41bd43a24186cd6fb3e68a4f82fdaf7c2e59c9bfd874653`** |
| `os.asm` | the source, for the record — SHA-256 `5d9cf205a76aae591aba2fed015d1bfbd10bab586441f32e9badac7c4bfec6d3` |
| `patch/mine.img`, `patch/snake.img`, `patch/sokoban.fdd` | upstream's `patch/` directory, staged with the rest; what the builder does with it is recorded by the builder and [`lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md) |
| Intake staging | `/data/assets-staging/bootos/` with `MANIFEST.sha256`, `LICENSE`, `README.md` |
| Builder | `scripts/build-guests/tiles/bootos.sh` (`build.rows` key `bootos`, class `fast`, `automation: full`) |
| Builder output | `/data/gallery-guests/BootOS/bootos-floppy.qcow2` — the 360K floppy **as qcow2**, pristine, no golden |
| Runtime path | `/data/vms/streamhost/stations/bootos/floppy.qcow2` — copied from the builder output on the station's first launch, and after the bake it **is** the golden |

`osall.img` is what the station boots; `os.img` is kept so the boot sector
inside it can be verified against the assembled source (the first 512 bytes of
`osall.img` should be `os.img` — the builder checks each file's size and the
`0x55AA` signature, and pins all eleven upstream files by SHA-256; it does not
compare the two sectors, and it stages the `patch/` images without applying
them — `osall.img` already carries `mine`, `snake` and `sokoban`.

The 19 directory entries that `dir` lists, as proven by the coordinator's smoke
run, are `fbird pillman invaders basic textmode counter data.bin bootslide
atomchess tetranglix snake mine rogue bricks cubicdoom sokoban heart pi bootle`.
Upstream attributes them as follows; `textmode`, `counter` and `data.bin` are
on the floppy but not in upstream's README list, and `data.bin` is a data
sector rather than a program: `counter` reads and rewrites it (`del data.bin`
then `counter` prints `?01` and recreates the file, framebuffer-proven on the
SPA stream's clone), and `textmode` is a text-mode demo.

| entry | program | author | note |
|---|---|---|---|
| `atomchess` | Toledo Atomchess | Óscar Toledo G. | chess in 512 bytes; needs a 286 |
| `cubicdoom` | cubicDoom | Óscar Toledo G. | ray-cast first-person shooter |
| `basic` | bootBASIC | Óscar Toledo G. | a BASIC interpreter |
| `fbird` | fbird | Óscar Toledo G. | Flappy Bird |
| `pillman` | Pillman | Óscar Toledo G. | Pac-Man |
| `invaders` | invaders | Óscar Toledo G. | Space Invaders |
| `rogue` | bootRogue | Óscar Toledo G. | a roguelike |
| `bricks` | bricks | Óscar Toledo G. | Breakout |
| `heart`, `pi`, `bootle` | heart, pi, bootle | Óscar Toledo G. | a heart animation, π digits, a Wordle |
| `bootslide` | BootSlide | XlogicX | sliding-tile puzzle; needs a 286 |
| `tetranglix` | tetranglix | XlogicX | Tetris; needs a 286 |
| `snake` | asm_snake | pmikkelsen | needs a 286 |
| `mine` | BootMine | io12 | Minesweeper; needs `rdtsc` (Pentium II) |
| `sokoban` | sokoban | ish.works | needs a 286 |

The processor requirements are moot on this station: `-cpu host` under KVM is
a modern x86, so every program's floor is met. bootOS itself needs only an 8088.

## Device set

The tracked launcher, `streamhost/stations/bootos/qemu-streamhost.sh`, is
deployed **verbatim** and is the device-set ledger. QEMU **11.0.2** (host
`pve-qemu-kvm` 11.0.2-1).

```
qemu-system-x86_64 -name streamhost-bootos \
  -enable-kvm -m 64 -smp 1 \
  -machine pc-i440fx-11.0,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -drive file=$BASE/floppy.qcow2,if=floppy,format=qcow2 -boot a \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  [-loadvm golden -S] \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off -pidfile $BASE/qemu.pid
```

Why each choice, so nobody "improves" it into a re-bake:

- **One block device, and it is the floppy, and it is a qcow2.** bootOS keeps
  its filesystem on the floppy — directory in track 0 sector 2, one file per
  track — and the guest **writes** to it: `enter` saves a file, `del` zeroes
  its directory entry, `format` wipes the directory and rewrites the boot
  sector. A raw image would carry those writes forward to the next visitor.
  QEMU's internal snapshots live in qcow2, so storing the floppy **as qcow2**
  lets `savevm golden` capture the floppy contents together with RAM and
  `loadvm golden` restore both: a visitor who deletes `fbird` has not deleted
  it for anyone else. There is no hard disk because bootOS has no use for one
  (it is a floppy-only OS, `int 0x13` drive 0), and every extra device is one
  more thing the checkpoint must match.
- **`-boot a`** — boot from the floppy. SeaBIOS prints `Booting from Floppy...`
  and jumps to 0000:7c00.
- **No pointer device.** bootOS reads the keyboard through BIOS `int 16h`
  (`input_key` in `os.asm`) and never touches a mouse; the boot-sector games
  are all keyboard games. There is nothing a tablet or PS/2 mouse could move,
  so the daemon runs with `SH_INPUT_BACKEND=disabled` and the registry says
  `pointer.transport: none`, `present: false`. The QEMU `pc` machine still
  instantiates its PS/2 keyboard and mouse ports — those are the i440FX
  chipset, not an added device — and the keyboard is what `send-key` feeds.
- **KVM, `-cpu host`, 1 vCPU.** A 16-bit real-mode guest runs fine under KVM
  on a modern host — real mode is virtualised, the BIOS runs in it every boot —
  and there is no reason to pay for TCG. `-cpu host` was what the coordinator
  proved; it also satisfies the `rdtsc` requirement of `mine`.
- **64 MB.** bootOS uses the first 32 KB of the address space (it relocates to
  0000:7a00, stack at 0x7700, programs load at 0000:7c00) and the games use
  nothing above 1 MB. 64 MB is the smallest round size that leaves SeaBIOS
  comfortable and keeps the golden's RAM image small; do not scale it up to
  match other stations.
- **`qemu-system-x86_64` for a 16-bit guest.** There is no `qemu-system-i386`
  on this box (pve ships only the x86_64 binary), and it makes no difference:
  the CPU model starts in real mode either way and bootOS never leaves it.
- **`-vga std`.** bootOS runs in the BIOS's default 80×25 text mode (mode 3),
  which `-vga std` renders as **720×400** with 9×16 cells; several games switch
  to 320×200 mode 13h graphics and back. The Bochs VGA BIOS handles both.
- **`-machine pc-i440fx-11.0,pcspk-audiodev=snd0`** routes the PC speaker into
  the dbus audiodev the daemon captures — the only audio path a boot-sector
  program has. See *Audio*.
- **`-rtc base=localtime`** is inherited boilerplate; nothing on the floppy
  reads the clock.
- **No NIC, no exec channel.** *"512 bytes leaves no room for a network
  stack"* (the registry's `periodBrowser`). `operator.labctl.exec_kind` is
  `null`, `console` is `fb`: drive the station with `labctl type` and read the
  framebuffer.

`SH_DBUS_UPDATE_MS` defaults to 4 in the launcher, the same fast-poll default 47
of the fleet's launchers carry.

**Host-native capture path:** this station ships host-native from day one — the
guest's VGA framebuffer is captured straight off QEMU's dbus display and
keystrokes go straight in through QMP, with no kiosk, bridge or second VM in the
path. There is no PoC form to retire.

## Audio

`stream.audio: true`, `SH_AUDIO=on`, `SH_AUDIO_BITRATE` 96000. The device is
the **PC speaker** (`pcspk-audiodev=snd0` on the i440FX machine), and the games
that beep (`fbird`, `invaders`, `pillman`, `bricks` and others) drive it with
the 8253 timer the way a 1981 program would. Note the honest limit before
anyone files a bug: **bootOS itself is silent** — the shell makes no sound —
so audio is only audible while a game is running and only for the games that
beep.

**Proven 2026-09-02 on the clone with the production dbus audiodev:** a 36-byte
8253 program typed in through `enter` produced a 999 Hz, 0.996 s tone (peak
24831) in the captured stream (`/data/vms/sandbox/bootos-golden/audio/beep.wav`).
`invaders` fired shots with no speaker output, so some games are simply silent.
If audio ever has to go, this section, `stream.audio`, `SH_AUDIO` and the
`pcspk-audiodev` machine option all flip together — the last one is a device-set change and
therefore precedes the bake, not follows it.

## Ready scene

The `$` prompt straight after an untouched cold boot: SeaBIOS's
`Booting from Floppy...` line, the `bootOS` banner (the `ver` string, printed
once at start-up), then `$` with the caret, white on black in 720×400 text
mode. **Nothing is typed into the golden.** This is the `reset.fixture` and it
is the first panel of the poster hero (`spa/public/posters/bootos/desktop.webp`:
`dir`, invaders, pillman, atomchess — all real frames from a clone).

Reject any capture with a command already echoed after `$`, a game's screen, a
`format`-wiped directory (`dir` prints nothing), or SeaBIOS still on its own
banner.

**There is no idle-deterministic frame.** The text-mode caret blinks, so two
captures of "the same" prompt differ by one 9×16 cell. Compare frames at a
fixed machine instant only:

```
stop ; loadvm golden ; stop ; screendump out.ppm ; cont
```

## Golden / reset

`resetMode: loadvm`, snapshot `golden`, carried by `floppy.qcow2` — the
station's **only** block device, so there is only one file to restore and no
multi-disk atomicity rule. `SH_GOLDEN_STATE_DISK` names it. The launcher's
create-if-missing copies the pristine builder output on the first run and adds
`-loadvm golden -S` (streamhost resumes it) whenever `qemu-img snapshot -l`
shows the tag; without the tag it cold-boots.

- **NEVER delete `floppy.qcow2`** — it is the checkpoint *and* the filesystem.
  Rollback is restoring it from the builder output, then re-baking.
- The device set above is **part of the checkpoint**. Adding a hard disk, a
  NIC, a USB controller or a mouse, or dropping the `pcspk-audiodev` machine
  option, is a cold re-bake, not a launcher edit.
- The bake itself is the standard `scripts/lib/checkpoint-verify.sh bootos
  --capture` shape on a namespaced sandbox clone with the exact launcher (it
  reads the station's `bootrec-tiles.conf` case, so that arm comes first): `stop` →
  `screendump` baseline → `savevm golden` → `query-snapshots` → dirty (type
  `dir`, or `del heart`) → `loadvm golden` → `screendump` at the fixed instant
  above → compare; then prove the floppy came back too by typing `dir` after
  the restore and seeing all 19 entries. A live recapture is
  `ssh lab 'checkpoint-guard recapture bootos'` and nothing hand-rolled.
- Golden proven 2026-09-02: `qemu-img snapshot -l` reports `golden` at
  1.29 MiB on `floppy.qcow2`; three in-process restores and one fresh-process
  `-loadvm golden -S` launch were byte-identical to the cold-boot frame (the
  only pixels that ever differ between two samples of the prompt are the 9×2
  caret's blink phase, which is display state, not vmstate); `del pi` + `dir`
  then `loadvm` then `dir` listed `pi` again. Staged floppy with the golden:
  sha256 `62d29dd6551d8ea119bc003fc4a0189329901cdc57115237e2757b353011edf0`.
- Cold boot is **zero-input**: the BIOS boots the floppy with no menu and
  bootOS asks nothing. Boot is a couple of seconds, so a boot video is not
  worth a clip; `spa.bootVideo` is unset. Cold-boot arm and audit:
  `scripts/coldboot/bootrec-tiles.conf` (`bootos` case: vmstate, 720×400 at
  30 fps, audio on, `BR_DISKS="floppy.qcow2"`) and
  `scripts/coldboot/bootos-zero-input-prep.md`.

A **warm reboot** (Ctrl+Alt+Del, below) is *not* a reset: it re-runs the BIOS
boot from the same floppy, so files a visitor entered or deleted survive it.
Only `loadvm golden` — the tile's Reset — puts the floppy back.

## Keyboard — the whole exhibit

- Path: QMP `send-key`/`input-send-event` into the i440FX PS/2 keyboard
  controller; bootOS reads it with `int 16h` AH=0 (`input_key`), one key at a
  time, and echoes through `int 10h` teletype. No pointer plane at all.
- Pacing: `SH_KEY_MIN_HOLD_MS=20` / `SH_KEY_MIN_GAP_MS=20` in
  `station.env.fixture`. The BIOS keyboard is interrupt-driven into a 16-key
  ring, not a frame-sampled matrix, so the frame-period derivation of the
  playbook's §5.1 does not apply and the floor is host scheduling alone.
  Bisected 2026-09-02 on a clone with `scripts/dev/emu-key-pacing-bisect.py`:
  a 43-character line, 10 trials per rung, at 10/10, 20/20, 30/30 and 40/40 ms
  → 0 of 10 corrupted at every rung; 20/20 ships as one rung of margin above
  the lowest tested value.
- `reset.keyboard` is **PASS** (2026-09-02): typed at a restored golden and read
  off the framebuffer, on the clone.
- Backspace works but does not erase on screen: `input_line` steps the buffer
  pointer back, while the BIOS teletype only moves the caret left, so the
  glyph stays until overwritten. Not a bug to chase.
- Ctrl+Alt+Del is a real key here (see *For visitors*). The station uses the
  `dos` on-screen keyboard family, whose rows lead with the Ctrl+Alt+Del key.
- The type-in demo (`demoProgram`) is the README's hello-world, at 80 ms per
  character. Its shape has a rule the demo validator did not allow when this
  was written: after the last hex line, bootOS's `enter` needs an **empty
  line** to leave the `h` prompt and ask for the name at the `*` prompt
  (`os.asm`, `enter_command`: `cmp byte [si],0 / je os20`). The validator and
  the SPA typist now admit an exact empty line (sent as a bare Enter), and the
  demo was typed line for line over QMP on a clone: `hello` printed
  `Hello, world` (`spa/public/posters/bootos/hello.webp`).

## For visitors — how to use bootOS

Everything below is verified against `os.asm` at the pinned commit; the
commands are matched by **prefix** (`rep cmpsb` against the 3–6 letter command
list), so `dir` and `director` do the same thing, and a file whose name starts
with a command word cannot be run.

- **`dir`** — list the floppy's directory, one name per line. 32 entries fit;
  this floppy ships 19.
- **`<name>`** — anything that is not a command is looked up on the floppy,
  loaded to 0000:7c00 and run. A name that is not there prints **`Oops`**.
- **`ver`** — prints `bootOS`. That is the whole version string.
- **`del <name>`** — zero the file's directory entry. Wrong name → `Oops`.
- **`format`** — wipe the directory and rewrite the boot sector. It asks no
  question. The next `dir` prints nothing. Reset the tile to get the programs
  back.
- **`enter`** — type a program in as hex. The prompt changes to `h`; each line
  is up to 128 characters of hex bytes with spaces (16 bytes a line is the
  comfortable width); an **empty line** ends the input, and the `*` prompt
  then asks for the file name. The README's hello-world, exactly as the
  demo button types it:

  ```
  $enter
  hbb 17 7c 8a 07 84 c0 74 0c 53 b4 0e bb 0f 00 cd
  h10 5b 43 eb ee cd 20 48 65 6c 6c 6f 2c 20 77 6f
  h72 6c 64 0d 0a 00
  h
  *hello
  $hello
  Hello, world
  $
  ```

  Pressing Enter at the **first** `h` prompt saves whatever is at 0000:7c00 —
  the last program run — under the new name: a one-command `copy`.

**Getting back to the `$` prompt.** bootOS gives programs one way out:
`int 0x20`, which warm-starts the shell (`restart` in `os.asm`; segments, stack
and prompt re-initialised, floppy untouched). A program written for bootOS —
the hello-world above ends with `cd 20` — returns that way. **The bundled
games are stand-alone boot-sector programs**, written to be booted directly
rather than for bootOS, and a boot sector has no OS to return to; unless one
happens to end with `int 0x20`, it runs until you leave it. So:

- If a program ends on its own, you are back at `$`.
- Otherwise press **Ctrl+Alt+Del**. SeaBIOS handles it as a warm reboot: the
  BIOS re-boots the floppy and bootOS is back at `$` in a couple of seconds,
  with everything you entered or deleted still on the floppy.
- Or press the tile's **Reset**, which is `loadvm golden`: back at `$` with the
  floppy as it shipped.

Which of the 19 return to `$` by themselves is not catalogued (`heart`, `pi`,
`textmode` and `counter` are demos rather than games and do); the visitor copy
says "Ctrl+Alt+Del or Reset", which is true for all 19. Ctrl+Alt+Del reaching
`$` was seen on the SPA stream's clone between game captures.

## Verification

Proven so far (coordinator, 2026-09-02, sandbox `/data/vms/sandbox/bootos/smoke/`):

- Cold boot under the device set above reaches `$` in 720×400 text mode.
- `dir` typed over QMP lists all 19 entries — keyboard reaches the guest and
  the floppy is read.

Done before listing (2026-09-02): golden baked and restore-proven on a clone
with the floppy-contents restore; audio heard; key pacing bisected;
`reset.keyboard` PASS; poster frames from real captures; the demo run end to
end. The operator validates the live station in the browser (Reset button,
type-in demo, a game).

The final gate is the framebuffer seen by streamhost, not a QMP log.

## Open items

- **Idle cost.** bootOS waits in `int 16h` AH=0. Whether SeaBIOS halts the
  vCPU in that wait or polls is not established here; if it polls, the vCPU
  spins at the prompt until idle-pause freezes it. Host CPU at an idle `$` with
  no client has not been measured; check `labctl ls` / `top` on the live
  station if the box looks busier after this add.
- **`format` is one word away.** A visitor can wipe the directory with a
  six-letter command and no confirmation. That is faithful to the OS and Reset
  undoes it; it is not being disabled.
- **Prefix matching** means a visitor-entered file named e.g. `directory` or
  `version` can never be run. Faithful; documented above; not being patched.
- The `patch/` images on the staging share are recorded by hash only here;
  their purpose is the builder's to state.

## Rollback

- The pristine media is `/data/assets-staging/bootos/osall.img`, hash-checked
  against `MANIFEST.sha256`. The builder output
  `/data/gallery-guests/BootOS/bootos-floppy.qcow2` is rebuilt from it by
  `scripts/build-guests/tiles/bootos.sh`; if the staging copy is lost, refetch
  `osall.img` from the pinned upstream commit and re-verify the SHA-256 before
  use.
- Golden rollback: stop only `streamhost@bootos`, stop its QEMU by the station
  pidfile, replace `/data/vms/streamhost/stations/bootos/floppy.qcow2` with the
  previous copy (or the pristine builder output, which forces a cold boot and a
  re-bake), then restart only this station's service. Never retire a golden
  before its replacement is restore-proven; checkpoint, binary and device set
  are one combination.
- Because the floppy is the only disk, there is no second file to keep in
  step. There is also no OVMF varstore, no overlay and no backing chain.
