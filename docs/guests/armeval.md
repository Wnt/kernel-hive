# armeval — Acorn ARM Evaluation System (1986)

Status: **PRODUCTION.** Live as `streamhost@armeval`, slot 135 / UDP 54135 /
VMID label 238 / ssh 5838. Built by `scripts/build-guests/armeval.sh`; checkpoint
captured and acceptance-tested on the production station 2026-08-09.

This station is the convergence of a two-angle bake-off
(`docs/lab/HARD-PROBLEM-METHODOLOGY.md`). **Angle A** reached ARM BBC Basic V
running on the emulated 1986 ARM and won on scene; **angle B** built the
supervisor exhibit and won on builder rigour. What ships is A's configuration
inside B's gates. Angle B's exhibit is not shipped, but everything it proved is
recorded below under [Proven dead ends](#proven-dead-ends), because a proven
dead end is a real result and re-deriving it costs a session.

## What the machine is

The ARM Evaluation System is **the first ARM product ever sold**: an ARM1 with
4 MB on a second-processor board that hangs off a BBC Micro's Tube interface,
sold to developers in 1986 (around £4,500) so they could write ARM code more
than a year before the Archimedes existed. It is act 2 of the ARM story, between
the BBC Micro (`bbcmicro`, act 1) and RISC OS.

It has no operating system. It has 16 KB of supervisor ROM — a monitor that
identifies itself, disassembles ARM instructions, displays memory and dumps
registers. **Its language comes off a floppy.** Disc 3 of the evaluation set
carries `$.AB`, ARM BBC Basic V 1.00, which loads into the co-processor's own
memory and runs *there*, while the 6502 that used to be the computer is demoted
to a keyboard, a screen and a disc controller.

That inversion is the exhibit.

## Identity and source

| | |
|---|---|
| Public ID / station directory | `armeval` |
| Emulator | MAME **0.289**, driver `bbcb` **with `-tube arm`** — the *same* purpose-built binary the `bbcmicro` station ships (`/data/vms/streamhost/assets/bbcmicro/mame/bbcb`), unmodified, carrying `mame-skip-warnings.patch` |
| Guest | Debian 13 (trixie) X kiosk on a thin overlay of the trixie bridge seed, 768 MB, 2 vCPU |
| X root | 800x600 (an emulation-**speed** choice inherited from `bbcmicro`, not a picture one) |
| Builder | `scripts/build-guests/armeval.sh` |
| Reset | internal qcow2 `golden` snapshot, `resetMode=loadvm` |
| Credentials | none — the machine has no login. `labctl exec armeval` reaches the *Debian kiosk*, not the BBC and not the ARM |

### The shipped invocation

```
nice -n 10 /opt/armeval/mame/bbcb bbcb \
  -tube arm \
  -fdc acorn1770 \
  -rom3 /opt/armeval/Acorn-ADFS-1.30.rom \
  -flop1 /opt/armeval/armevaluationsystem-disc3.adl \
  -rompath /opt/armeval/roms \
  -inipath /opt/armeval \
  -skip_gameinfo -artwork_crop -video soft -prescale 1 \
  -autoframeskip -keepaspect -nowindow -nofilter
```

Three arguments are load-bearing and each cost an experiment. Do not simplify
them:

- **`-fdc acorn1770`.** The ARM Evaluation System discs are **ADFS** `.adl`
  images, 640 KB, **double density**. The Acorn 8271 the `bbcmicro` station ships
  is single density and cannot read them at all. Swapping the FDC slot pulls in
  a second device romset, `bbc_acorn1770` (default BIOS `dfs223`), and drops
  `bbc_acorn8271`'s DNFS 1.20 — which is why this exhibit's `*HELP` reports
  `Advanced DFS 1.30` and `DFS 2.23` where `bbcmicro`'s banner says `Acorn DFS`.
- **`-rom3`, and specifically not `-rom1`.** ADFS has to live in a sideways
  socket. With ADFS in `romimage1` the Tube **never comes up**: the banner falls
  back to plain `BBC Computer 32K` and the exhibit is a `bbcmicro` duplicate.
  `romimage4` keeps the Tube but displaces host BBC BASIC (the `BASIC` line
  vanishes from the banner). `romimage3` keeps **both**.
- **`skip_warnings 1` in `/opt/armeval/ui.ini`.** It is a **UI** option, not a
  command-line one — `-skip_warnings` is rejected as an unknown option.

Paths differ from angle A's clone, which ran out of the `bbcmicro` station's
`/opt/bbcmicro` tree because it was cloned from it. A station built fresh on the
bridge seed has no `/opt/bbcmicro`, so everything here lives under
`/opt/armeval`. Nothing else about the invocation changed.

### `bbcb -tube arm`, not the `bbcmarm` driver

MAME also has `bbcmarm`: a BBC **Master** with the same ARM podule. Recon
compared them by frame. The Master boots in MODE 7 and MAME's SAA5050 renders
the supervisor prompt's blue control code as mosaic blobs that read as screen
corruption on a museum wall. `bbcb -tube arm` renders the same prompt cleanly.

### The media

Eight blobs staged at `/data/assets-staging/armeval/`. Four are `bbcmicro`'s,
unchanged. `dnfs120.rom` is **not** among them — `-fdc acorn1770` replaces the
8271 that needs it.

| file | in | sha1 | sha256 | size |
|---|---|---|---|---|
| `os12.rom` | `bbcb.zip` | `0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d` | `2d9fea69017864f6962704481829f95fee08446c8c3a13826d5d4e44000ac9de` | 16 384 |
| `basic2.rom` | `bbcb.zip` | `4a7393f3a45ea309f744441c16723e2ef447a281` | `45bd55dc0f6f0f8f1fe9e2481de7def206565eec8f600ba3068b849ca4132079` | 16 384 |
| `phroma.bin` → member `cm62024.bin` | `bbcb.zip` | `b369809275cb67dfd8a749265e91adb2d2558ae6` | `8c093401661f530032c5aca8fd80d91af58e596d082a51be58ce2ee063a89308` | 16 384 |
| `saa5050` | `saa5050.zip` | `6c8daba70374e5aa3a6402f24cdc5f8677d58a0f` | `9706945b02dd0e30823186ff0d73a49c0d98ed573499a057bab471add7ee28fb` | 960 |
| `armeval_101.rom` | `bbc_tube_arm.zip` | `f86bbc4894e62725b8ef22d44e7f44d37c98ac14` | `d6ef843f82d7308f0ee68b4b30b4e6c6a561e753991f5634dbe6ae969b4204a7` | 16 384 |
| `dfs v2.23,acorn.rom` | `bbc_acorn1770.zip` | `0d7ed0b0b3852cb61970ada1993244f2896896aa` | `964c9ab33650b9429dd3eb513150b3110c607e0344f90d00ffaa546f982f66db` | 16 384 |
| `Acorn-ADFS-1.30.rom` | `-rom3`, by path | `301fd05c475a629c4bec70510d4507256a5b00d8` | `4f785bb4572bde31a93f12687dec501c9005b6a0decc6ac943c657447095a563` | 16 384 |
| `armevaluationsystem-disc3.adl` | `-flop1`, by path | `f5114ff744f6f742da3959a91a1b98af0bd1db5d` | `c55f8a1c8abd2d1de4cb6afc4a96cbe72ed1446b39b1a3bbf06ef67698a29375` | 655 360 |

All sha1s and sha256s re-measured on labhost 2026-08-09.

`armeval_101.rom` is `bbc_tube_arm`'s **default** biosset in 0.289 — MAME offers
four (`101`, `100`, and two earlier "Brazil" builds) — and `101` is *Executive
v1.00 (14th August 1986)*, four months after the first ARM1 silicon ran. The
firmware says that date out loud when a visitor types `*HELP`.

**Provenance: preservation-source, NO authorised URL**, and a genuinely disputed
chain of title. The builder does not download: it requires the operator's staged
blobs, gates each on SHA-1, and assembles the four zips **by hash** against the
shipped binary's own `-listxml` (the staged file is `phroma.bin`, the member
MAME wants is `cm62024.bin`, and only the hash connects them). `-verifyroms` is
**not** a gate — on BIOS-selectable drivers it reports "bad" purely because the
alternative BIOS entries are absent, which is the point of a pinned set. **Never
commit the bits.**

All **six** `armevals` discs were obtained and all six sha1s match MAME 0.289's
`hash/bbc_flop_arm.xml` byte for byte, so discs 4-6 — **Cambridge LISP, PROLOG
and FORTRAN 77** — exist for a later exhibit. Only disc 3 is staged and used
here. That is a deliberate follow-up, not an omission.

## The checkpoint

```
ARM Second Processor 4096K

Acorn ADFS

BASIC

  A* *LIB $
  A* AB
ARM BBC Basic V version 1.00 for ARM Second Processor (C) Acorn 1986

>_
```

`A*` is drawn as a reverse-video field in teletext blue. The whole frame
contains exactly **three colours** — black, white, and pure `#0000FF`.

**The two `A*` lines are captured in, not typed by a visitor, and they are left on
screen deliberately.** They are the provenance of the `>` prompt below them: a
co-processor loading its language off a floppy, in public. This breaks the
Plus/4 rule that a checkpoint is the machine's own untouched first screen, and it
breaks it knowingly — the ARM Evaluation System's untouched first screen is a
bare supervisor prompt, and a machine that has no language of its own has
nothing to show at power-on. Angle B captured that screen and it is a worse
exhibit.

`*LIB $` is **required**: the ADFS library is `Unset` on a cold boot and both
`AB` and `*AB` answer `No directory (169)` without it. Disc 3's root catalogue
is `!boot / DeBug / AB / du / fpe / link / readme / rm`, and `AB` is ARM BASIC.

### The identity gates

Getting the banner wrong is **silent**. Without `-tube arm` (or with ADFS in
`-rom1`) the identical driver prints `BBC Computer 32K` and a white `>` prompt:
that is the `bbcmicro` station, and shipping it here would be a worthless
near-duplicate. Two capture-time gates, both on the same frame:

- **blue ink** — a plain BBC Micro power-on screen contains **zero** blue
  pixels. The bare supervisor screen carries **1644** (one `A*` cell); this
  checkpoint carries **3288** (two). The floor is 500.
- **white ink** — the bare supervisor screen is **4926** lit white pixels, this
  checkpoint **12647**. The floor is 9000, so a checkpoint that never got past `A*`
  fails the build.

## The visitor interaction

### The type-in (the headline)

`registry/stations/armeval.json` `demoProgram`, typed through the station's own key
path at its declared 80/80 ms pacing:

```
10 T%=TIME
20 FOR I%=1 TO 20000:NEXT
30 PRINT"20000 LOOPS ";(TIME-T%)/100
RUN
```

→ `20000 LOOPS 0.22`. Twenty thousand interpreted BASIC loops in a fifth of a
second on an 8 MHz ARM1 in 1986, on a machine whose 6502 host would need the
better part of a minute.

**The trailing space inside the quotes matters.** Without it BBC BASIC butts the
number straight against the word and prints `20000 LOOPS0.22` — angle A shipped
that frame before noticing.

`perCharMs` is **160**, the registry invariant's floor of
`SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS`. The UI default of 70 fails the gate.

### The on-screen keyboard

`spa/src/ui/keyboard/keyboardProfiles.ts`, family `armeval`. Every button was
driven against the restored checkpoint by framebuffer before it was written down:
**LIST**, **RUN**, **⏎**, **ESCAPE**, **⌫**, arrows. `LIST` and `RUN` are macros
of unshifted lowercase keysyms plus RETURN — the MOS turns CAPS LOCK on at
reset, so they arrive upper case, which is what BASIC's tokeniser wants — and
the steps go out through the normal `sendKey` path, so the station's pacing applies
to them.

**ESCAPE had to be measured, not assumed.** `Esc` is also MAME's own UI cancel
key. Driven on the production station against a running program it printed
`Escape`, returned the `>` prompt, and **MAME was still alive** afterwards; the
builder's proof asserts that second half explicitly.

### `*HELP` and `*CAT` — real, and deliberately not buttons

Both work from the ARM BASIC prompt and are the two best facts the machine will
tell you:

- `*HELP` → `Executive version 1.00 (14th August 1986)`, then
  `Advanced DFS 1.30 / ADFS`, `TUBE HOST 2.20`, `DFS 2.23 / DFS / UTILS`,
  `SRAM 1.03`, `OS 1.20`. The whole machine dating and naming itself.
- `*CAT` → Disc 3's catalogue: `Dir. "Unset"`, `Lib. $`, and
  `!boot / DeBug / AB / du / fpe / link / readme / rm`. Where the language the
  visitor is typing into came from.

Neither can be an on-screen **button**. `*` is not where a US PC puts it on this
keyboard — `keyboard.charMap` maps it to the `"` key, i.e. Shift+apostrophe — a
macro step is a bare keysym, and the profile invariant rightly rejects shifted
printables because `sendKey` discards the shift flag. The charMap is applied
only on the `demoProgram` path. A dead button is worse than a missing one, so
they stay in the builder's gates (where `*CAT` doubles as the proof that the
floppy is readable at all) and in this document.

## Proven dead ends

Angle B's exhibit was the supervisor, and its four keyboard actions were real
**there**. From inside ARM BASIC, which is where this station rests, all four are
gone. Each was driven against the restored checkpoint and screenshotted before it
was deleted:

| what | from the ARM BASIC `>` prompt | why |
|---|---|---|
| `*QUIT` | `Bad command` (after ~8 s of filing-system search) | **The supervisor cannot be re-entered from BASIC at all.** This is the finding that kills the other three. |
| `*DIS 3000000` | `Bad command` | `DIS` is a supervisor **built-in**, not an OSCLI `*` command, so there is no prompt to type it at. |
| `*SHOWREGS` | `Bad command` | same. |
| `BREAK` (F12) | **nothing** — not one pixel changed | Driven twice, through both QMP `sendkey f12` and `cdrv key f12`, on the restored checkpoint. No reset, no banner, and no MAME snapshot appeared anywhere in the guest either, so it is not being eaten by MAME's UI snapshot binding — the key simply does not reach the emulated BREAK. Note `bbcmicro`'s profile ships the same F12 BREAK button; that station is out of scope here and was not touched, but the observation is recorded. |

Angle B's facts about the supervisor itself remain true of the machine, and are
worth keeping because they are good history:

- **`HELP` at the `A*` prompt** → `Supervisor 1.00 / Executive version 1.00
  (14th August 1986) / DFS 1.20 / OS 1.20`.
- **`BASIC` at the `A*` prompt is an ERROR PATH, and the best frame angle B
  produced.** There is no ARM BASIC in the supervisor ROM, so `BASIC` hands the
  ARM the *host's* 6502 BASIC, the ARM is fed 6502 bytes, and the supervisor
  catches the branch through zero: `Not ARM code / Entering Supervisor because
  of branch through 0 / Register dump (stored at &E40) is: R0 = FFFFFF47 … /
  Mode SVC flags set: nzcvif / Finished after 0.08 sec.` It is measured **safe**
  — the supervisor returns to `A*` and accepts the next command. It is not the
  shipped exhibit because a visitor typing a BASIC line and watching a 1986 ARM
  execute it beats a visitor watching one refuse to.
- **`DIS 3000000` at the `A*` prompt** walks the bootstrap ROM in real ARM1
  mnemonics (`SUBS PC,R14,#4`, `STMDB R13!`, `BIC`, `TEQCCP`) and **pages**:
  it sits at `Any key continue, Return finish` and swallows the next keystroke.

- **The `bbcmarm` driver** (BBC Master + the same podule) renders the blue
  supervisor prompt as SAA5050 mosaic blobs. Rejected by frame.

## Measurements (production station, 2026-08-09)

- **Reset:** `loadvm golden` is byte-identical **with the VM stopped**. MODE 7
  blinks its cursor, so two screendumps of the same restored state taken at
  arbitrary wall-clock moments differ by exactly one ~40 px cursor cell and hash
  differently. Sample at a fixed *machine* instant instead:

  ```
  stop ; loadvm golden ; stop ; screendump out.ppm ; cont
  ```

  Two such cycles before the keyboard proof and two after it all hashed
  **`bc8ba12ebb064f00ca23304dc9aef1aca26f80bc2be4fd5ad8e1fbba083bdb56`** — the
  same value angle A measured on its own clone, from a separately captured checkpoint.
  The caveat applies to `bbcmicro` too; it is a property of the exhibit.
- **Key pacing:** shipped at **80/80 ms**, inherited from `bbcmicro`. The
  78-character demoProgram went out in **14.4 s** on a clone and **15 s** on the
  production station, i.e. **182-185 ms/char** (QMP round-trips add to the nominal
  160), with **zero characters dropped** in both runs. One character *was* lost
  in one of three ad-hoc type-ins done afterwards under load average ~6 — the
  same residual the `vic20` notes record, a property of labhost and not of the
  emulated machine. Keep any listing at or under ~80 characters to stay inside a
  15 s demo.
- **Post-restore settle:** the proof waits **60 s** after a `loadvm` before
  typing. `bbcmicro` measured a reproducible 45-character loss when typing 5 s
  after a restore, at 80/80 *and* at 160/160 — a clock-jump effect, not pacing.
- **Loading ARM BASIC is not instant.** `AB` is ~40 KB off an emulated 1770
  through ADFS. At 6 s after the keystroke the screen still shows both `A*`
  lines and an empty cursor row — a load in flight that a fixed sleep
  misreports as "ARM BASIC did not start". The builder polls for the banner.
- **Host QEMU RSS:** 770 004 kB at the capture, 808 900 kB with the streamhost
  daemon attached and encoding.
- **Guest MemAvailable:** 376 436 kB at 768 MB of RAM (floor is 200 MB).

### The red nag

`bbcb`'s driver status is `imperfect` (emulation `good`, sound imperfect) — not
`preliminary` — so MAME never paints the full-screen red **THIS SYSTEM DOESN'T
WORK** panel for it. Fitting a Tube co-processor does not change that: device
status is not driver status. The separate amber/red startup WARNINGS stage,
which `-skip_gameinfo` does *not* suppress, is gated by the shipped binary's
`skip_warnings` patch plus `/opt/armeval/ui.ini`.

Proven by frame, not by argument: `nag_sweep()` screendumps **30 frames at 1.5 s
intervals across the whole cold boot** and fails on **any** red pixel in any of
them. On the shipped build the worst red count over the sweep was **0**.

## Cold boot

`scripts/coldboot/armeval-zero-input-prep.md` and the `armeval)` arm in
`scripts/coldboot/bootrec-tiles.conf`. **Zero input is not genuine on this
station** — a cold boot stops at the supervisor prompt, 4926 lit pixels short of
the checkpoint's 12647 — so no clip is recorded and `spa.bootVideo` is unset. See
that file for what a record driver would have to do.

## Traps this station paid for

- `clone-guard check-launcher` **refuses** a builder that can reach a production
  station path through an unset variable, so `armeval.sh` deliberately has no
  `ARMEVAL_TILE_DIR`-style override. A sandbox run is made by rewriting the
  constants into a `/data/vms/soltest/<ns>` copy, which then passes
  `check-launcher` on its own.
- **The scaffold's port allocation was wrong and QEMU is what found it.** The
  reserved VMID 235 / ssh 5835 both belong to the live `kc854` station, and 5835 is
  a real hostfwd, so QEMU refused to start: `Could not set up host forwarding
  rule`. Slot 135 gives **238 / 5838** under the fleet's own arithmetic
  (vmid = slot + 103, ssh = slot + 5703).
- **A one-frame black-root check failed a perfect build.** The
  zero-byte-`.Xauthority` failure mode is real, but so is the second or two
  after `startx` before MAME paints; the gate now needs 20 consecutive black
  frames (40 s) with MAME already running before it is fatal.
- `-listxml bbcb` already carries `bbc_tube_arm` **and** `bbc_acorn1770`: they
  are slot options, so they have no driver entries of their own and need no
  extra `-listxml` argument.
- The headless probe recipe (`scripts/dev/armeval-headless-probe.sh`: a Lua
  autoboot script counting frames and calling `manager.machine.video:snapshot()`
  against the shipped binary inside the MAME build chroot) proved the exhibit
  frames in minutes, before a guest was booted. Two traps are baked into it: the
  value returned by `emu.add_machine_frame_notifier` **must** be kept in a
  global or the subscription is garbage-collected and the notifier silently
  stops firing after a few hundred frames; and `post_coded` does not interpret
  `\n` — use `{ENTER}`.

## Related

- `docs/guests/bbcmicro.md` — the host machine's own exhibit, and where the
  BBC-side romset, the keyboard charMap and the 80/80 pacing were derived.
- `docs/lab/ADD-NEW-OS-PLAYBOOK.md` §5.1 — keyboard-only exhibits.
- `registry/posters/armeval.md` — the placard.
