# armeval — Acorn ARM Evaluation System (1986)

Status: **CANDIDATE, proven in a sandbox — not promoted, not deployed.**
Built and gated as angle **B** of the armeval bake-off (the "bare supervisor
prompt, zero extra media" angle) under
`docs/lab/HARD-PROBLEM-METHODOLOGY.md`. Everything below was measured on
2026-08-09 in `/data/vms/soltest/ARMEVAL-supervisor/`, which has since been torn
down; the builder that reproduces it is `scripts/build-guests/tiles/armeval.sh`.

## What the machine is

The ARM Evaluation System is **the first ARM product ever sold**: an ARM1 on a
second-processor board that hangs off a BBC Micro's Tube interface, sold to
developers in 1986 so they could write ARM code more than a year before the
Archimedes existed. It is act 2 of the ARM story, between the BBC Micro
(`bbcmicro`, act 1) and RISC OS.

It has no operating system. What it has is 16 KB of ROM containing a
**supervisor** — a monitor that identifies itself, disassembles ARM
instructions, displays and alters memory, and dumps the registers of whatever
just went wrong. So the exhibit is that supervisor, and the exhibit's point is
that a visitor can make a 1986 ARM talk about itself.

## Identity and source

| | |
|---|---|
| Public ID / tile directory | `armeval` |
| Emulator | MAME **0.289**, driver `bbcb` **with `-tube arm`** — the *same* purpose-built binary the `bbcmicro` tile ships (`/data/vms/streamhost/assets/bbcmicro/mame/bbcb`), unmodified |
| Guest | Debian 12 X kiosk on a thin overlay of the frozen bridge base, 768 MB, 2 vCPU |
| X root | 800x600 (an emulation-**speed** choice inherited from `bbcmicro`, not a picture one) |
| Builder | `scripts/build-guests/tiles/armeval.sh` |
| Reset | internal qcow2 `golden` snapshot, `resetMode=loadvm` |
| Credentials | none — the machine has no login |

### `bbcb -tube arm`, not the `bbcmarm` driver

MAME also has `bbcmarm`: a BBC **Master** with the same ARM podule. Recon
compared them by frame. The Master boots in MODE 7 and MAME's SAA5050 renders
the supervisor prompt's blue control code as mosaic blobs that read as screen
corruption on a museum wall. `bbcb -tube arm` renders the same prompt cleanly.
Use `bbcb`.

### The ROMs

Five of the six blobs are `bbcmicro`'s, unchanged, and for the reasons derived
there (see `docs/guests/bbcmicro.md`): the `saa5050` character generator is a
third zip without which MODE 7 has no glyphs, and the Acorn 8271 disc interface
is the driver's own default and cannot simply be omitted. The sixth is the ARM
Evaluation System's own bootstrap:

| file | sha1 | sha256 | size |
|---|---|---|---|
| `armeval_101.rom` | `f86bbc4894e62725b8ef22d44e7f44d37c98ac14` | `d6ef843f82d7308f0ee68b4b30b4e6c6a561e753991f5634dbe6ae969b4204a7` | 16 384 |

It is `bbc_tube_arm`'s **default** biosset in 0.289 — MAME offers four
(`101`, `100`, and the two earlier "Brazil" builds), and `101` is
*Executive v1.00 (14th August 1986)*, four months after the first ARM1 silicon
ran. The firmware says that date out loud when a visitor types `HELP`, which is
why the exhibit ships the default rather than an earlier build.

**Provenance: preservation-source, NO authorised URL**, and a genuinely disputed
chain of title. The builder does not download it: the operator stages all six
blobs at `/data/assets-staging/armeval/` and the builder gates each on SHA-1,
then lets the shipped binary's own `-listxml` name the zip members (assembling
by hash, never by filename — MAME renames members between versions). **Never
commit the bits.**

## The golden: the machine's own untouched power-on screen

```
ARM Second Processor 4096K
Acorn DFS
BASIC
 A*
```

with `A*` drawn as a reverse-video field in teletext blue. Nothing typed,
nothing curated — the Plus/4 rule.

**The banner is the whole identity test, and getting it wrong is silent.**
Without `-tube arm` the identical driver prints `BBC Computer 32K` and a white
`>` BASIC prompt: that is the `bbcmicro` tile, and shipping it here would be a
worthless near-duplicate. The builder gates on it twice — a white-ink band, and
a **blue-ink floor**, because a plain BBC Micro power-on screen contains not one
blue pixel and this one contains ~1 644.

## The visitor interaction

Four keyboard actions, all reachable from the SPA's `armeval` keyboard profile
(`spa/src/ui/keyboard/keyboardProfiles.ts`) as one-tap macros. Each is a macro
of **unshifted lowercase** keysyms plus RETURN: the BBC MOS turns CAPS LOCK on
at reset, so they arrive upper case, which is what the supervisor's parser
wants — and the macro steps go out through the normal `sendKey` path, so the
tile's `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` pacing applies to them.

| Row key | Keys sent | What appears |
|---|---|---|
| `HELP` | `h e l p ⏎` | `Supervisor 1.00 / Executive version 1.00 (14th August 1986) / DFS 1.20 / OS 1.20` |
| `DISASSEMBLE` | `d i s ␣ 3 0 0 0 0 0 0 ⏎` | the supervisor's own ARM disassembler walking the bootstrap ROM: `SUBS PC,R14,#4`, `STMDB R13!`, `BIC`, `LDR`, `TEQCCP` … |
| `BASIC → register dump` | `b a s i c ⏎` | `Not ARM code / Entering Supervisor because of branch through 0 / Register dump (stored at &E40) is: R0 = FFFFFF47 … / Mode SVC flags set: nzcvif / Finished after 0.08 sec.` |
| `SHOWREGS` | `s h o w r e g s ⏎` | re-shows the registers saved by the last trap |

### Two things the exhibit has to be honest about

**`BASIC` is an error path, deliberately.** There is no ARM BASIC in this ROM.
Typing `BASIC` hands the ARM the *host's* 6502 BASIC ROM, the ARM is fed 6502
bytes, and the supervisor catches the resulting branch through zero and prints a
1986 register dump. It is arguably the best frame in the collection — a 1986 ARM
telling you what it just refused to execute — but the placard must frame it as
what it is, not as a feature.

**It is safe to offer.** Measured: after the dump the supervisor returns to the
`A*` prompt and the next command is accepted (verified by typing at the prompt
afterwards, and by the blue-prompt assertion in the builder's keyboard proof).
No reset is needed, so the row is **not** marked `danger`.

**The disassembler pages, and the pager eats the next keystroke.** After `DIS`
the machine sits at `Any key continue, Return finish`; any further button a
visitor taps pages the listing instead of running. RETURN finishes it. The
profile therefore keeps a plain `⏎` on the base row next to `DISASSEMBLE`, and
the builder's proof sends that RETURN.

## Measurements (2026-08-09, sandbox `/data/vms/soltest/ARMEVAL-supervisor`)

- **Key pacing:** shipped at **80/80 ms** hold/gap, inherited from `bbcmicro`.
  Independently probed here: `HELP SUPERVISOR` (15 characters) typed **complete
  and correct at 40/40 ms as well as at 80/80 ms**, so 80/80 carries real
  margin on this tile. That is because the emulator keeps up — `-autoframeskip`
  on an 800x600 root reaches ~99% of real speed, and on `bbcmicro` it was the
  *emulator running at half speed*, not the pacing number, that punched holes in
  long bursts. 80/80 is shipped anyway; there is nothing to buy by going faster.
- **Post-restore settle:** the proof waits **60 s** after a `loadvm` before
  typing. `bbcmicro` measured a reproducible 45-character loss when typing 5 s
  after a restore, at 80/80 *and* at 160/160 — a clock-jump effect, not pacing.
  The same wait is kept here.
- **Host QEMU RSS:** 795 244 kB with the kiosk up and MAME running.
- **Guest MemAvailable:** 377 244 kB at 768 MB of RAM (floor is 200 MB);
  MAME's own RSS in-guest is 212 140 kB.

### The red nag

`bbcb`'s driver status is `imperfect` (emulation `good`, sound imperfect) — not
`preliminary` — so MAME never paints the full-screen red **THIS SYSTEM DOESN'T
WORK** panel for it. Fitting a Tube co-processor does not change that: device
status is not driver status. The separate amber/red startup WARNINGS stage,
which `-skip_gameinfo` does *not* suppress, is gated by the shipped binary's
`skip_warnings` patch plus `/opt/armeval/ui.ini`.

Proven by frame rather than by argument: a kiosk restart was screendumped **55
times at 0.6 s intervals**, covering the whole window from a dead X root through
MAME's startup to the settled banner. Red-pixel count was **0 in every one of
the 55 frames** — black, then straight to the ARM banner. The builder also
refuses to bake a frame with more than 20 000 red pixels, so a binary rebuilt
without the patch fails the build instead of shipping a red panel.

### Reset is byte-identical, and the cursor is why that needs care

MODE 7 blinks its cursor, so two screendumps of the *same* restored state taken
at arbitrary moments differ by exactly one 40-pixel cursor cell (4 746 vs 4 786
lit pixels — that alternation in the sweep above is the blink, not instability).
The honest comparison stops the VM first:

```
loadvm golden ; stop ; screendump ; cont
```

Three such captures, with the screen dirtied by `HELP` and then by `BASIC`
between them, all hashed **`ad0377d9fb4a282a7bfc112cbaf97b94e0a9d84502575ec4f0ff830f5c00f51b`**,
while the two dirtied frames in between hashed `dec9456f…` and `535c595d…`.
Restore is byte-identical.

## Traps this angle paid for

- `clone-guard check-launcher` **refuses** a builder that can reach a production
  tile path through an unset variable, so `armeval.sh` deliberately has no
  `ARMEVAL_TILE_DIR`-style override. A sandbox run is made by rewriting the
  three constants (`VMID`, `SSH_PORT`, `TILE_DIR`) into a
  `/data/vms/soltest/<ns>` copy, which then passes `check-launcher` on its own.
- `-listxml bbcb` already carries `bbc_tube_arm`: it is a slot option of the
  Tube, so it has no driver entry of its own and needs no extra `-listxml`
  argument.
- The headless probe recipe (Lua autoboot script counting frames and calling
  `manager.machine.video:snapshot()`, run against the shipped binary inside the
  Bookworm chroot) proved all four exhibit frames in **under three minutes**,
  before a single guest was booted. On this angle it was worth far more than it
  cost. `post_coded` does not interpret `\n` — use `{ENTER}`.
