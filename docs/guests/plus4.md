# Commodore Plus/4 (PAL) — gallery tile notes (udp/54086)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **VICE `xplus4`**,
emulating a **PAL Commodore Plus/4** curated into the **3-plus-1** office suite
that lives in the machine's ROM. An **"emulator bridge"** tile — streamhost
captures the Linux framebuffer + AC97 audio exactly like every other tile. See
**`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` — already contains the
whole VICE family.
**Build script (tile):** `scripts/build-guests/plus4.sh` — thin overlay + kiosk
`launch.sh` + ROM repair + quiet console + fixture drive + golden bake +
framebuffer/keyboard proof, fully automated, ~2 minutes.
**Tile dir (host):** `/data/vms/streamhost/tiles/plus4/`.
**Registry entry:** `registry/tiles/plus4.json` (slot 86, udp 54086, VMID 222,
ssh hostfwd 127.0.0.1:5822).

## Media and license — there is none to stage

Like `vic20`, and for the same reason, but with a better payoff: VICE bundles
the Commodore ROMs, and for this machine that includes **both 3-plus-1 banks**
(`3plus1-317053-01.bin`, `3plus1-317054-01.bin`) alongside BASIC and the
KERNAL. The exhibit's entire subject — an office suite in ROM — therefore needs
no external media, no licensed image and no `check-assets.sh` row.

- **VICE 3.9** — GPLv2; bundles the Plus/4 BASIC/KERNAL/3-plus-1 ROMs for
  emulation use.

## The fixture, and how a visitor drives it

The golden rests **inside the suite, in the spreadsheet**: a yellow ruled grid
on black, cell R1C1. Everything used to get there is the machine's own UI,
verified on a clone by framebuffer:

| Step | Keys | Result |
|---|---|---|
| Enter the suite | `F1` then `RETURN` | what the power-on screen itself advertises: `3-PLUS-1 ON KEY F1` (it types `SYS1525`) |
| Open the command prompt | `C=` + `C` | a one-line prompt, `W>` in the word processor, appears at the foot of the screen |
| Choose a module | `tw` / `tc` / `tf` + `RETURN` | **t**o **W**ord, **t**o **C**alculator, **t**o **F**ile manager |

**The prompt is one-shot.** `C=` + `C` opens it, one command runs, and it
closes. This was measured, not assumed: typing `tw` at the `C>` the spreadsheet
shows after a `tc` does **not** switch module — that line is the cell editor,
and the keystrokes enter `0` into R1C1. So every module switch needs the
Commodore key again.

### Which key is the Commodore key

**`Tab`**, under VICE's symbolic keymap. That is not discoverable, and on a
phone there is no Tab at all, so the exhibit does not rely on it: the SPA's
**`plus4` on-screen keyboard profile** carries one-tap **Word / Calc / File**
buttons, each sending the whole documented sequence as a single macro (`C=`
held, `c`, then `tw`/`tc`/`tf`, then `RETURN`), plus a labelled `C=` key and a
`3-PLUS-1` button (`F1`,`RETURN`) for anyone who has left the suite. A visitor
on a Mac, a PC or a phone therefore never needs to know about Tab.

### Known cosmetic artefact

Under VICE's symbolic keymap, `C=` + `C` **also** delivers a literal `c`. In the
word processor that lands in the document; in the spreadsheet it lands in the
cell line and is discarded with the command.

It is worth recording why this is not a pacing bug, because the obvious
diagnosis is wrong. The natural theory — the matrix is scanned once per frame,
so the letter is sampled before the modifier is established — predicts that
leading with the modifier fixes it. Measured on a clone: **0 clean chords out of
11**, across 0.30 s and 0.50 s leads (15 and 25 PAL frames) on an empty
document, i.e. no better than pressing both at once. The positional keymap
(`-keymap 1`) does not leak, but there Tab is not `C=` at all and the prompt
never opens. The leak is what the symbolic keymap does; no host-side timing
changes it.

## Device set and launcher

Identical in shape to its bridge siblings (`c64`, `vic20`, `apple2`, `atarist`,
`amiga`, `mpf2`) — see `streamhost/tiles/plus4/qemu-streamhost.sh`. The kiosk
launcher is:

```
xplus4 -sounddev alsa -TEDdsize -TEDborders 0 -pal
```

on an 800×600 X root, which the doubled PAL frame fills edge to edge. As for
every VICE tile, **the kiosk profile must not redirect `startx`'s output to a
file**: VICE 3.9 segfaults in `vice_banner()` whenever stdout is not a terminal
and prints nothing at all — the full backtrace and symptom are in
[`vic20.md`](vic20.md). `plus4.sh` also repairs the PLUS4 ROM set from the
retained source tree and asserts all four ROMs, the same `make install` gap the
C64 and VIC-20 hit.

## Keyboard pacing

`SH_KEY_MIN_HOLD_MS=80`, `SH_KEY_MIN_GAP_MS=80` — four PAL frames each way.
**Carried over from the VIC-20's bisect rather than re-measured**: same
emulator, same 50 Hz frame, same host, and the failure those numbers guard
against is a host scheduling stall rather than a property of the emulated
machine (see [`vic20.md`](vic20.md) for the measurements). Re-bisect with
`scripts/dev/emu-key-pacing-bisect.py` if this tile ever drops characters.

No `demoProgram`: the interaction here is the suite, not a BASIC type-in.

## Verification (2026-08-09)

Evidence in `/data/vms/streamhost/tiles/plus4/evidence/`:

| Artifact | Shows |
|---|---|
| `ready-basic-prompt.png` | the untouched cold boot — `COMMODORE BASIC V3.5 / 3-PLUS-1 ON KEY F1` |
| `ready-before-golden.png` | the curated fixture: the 3-plus-1 spreadsheet, the frame that was baked |
| `keyboard-tw-wordprocessor.png` | the real visitor action after the bake — `C=`+`C` then `tw` — landing in the word processor |
| `golden-restored-after-keyboard.png` | `loadvm golden` returning to the exact baked spreadsheet |

The keyboard proof asserts the **module actually changed** (ink count drops
from the spreadsheet's ~36k to the word processor's ~3k), not merely that the
framebuffer differed. An earlier version asserted only "something changed" and
passed while its keystrokes went into the cell editor and typed a `0` into
R1C1 — a proof that cannot fail is not a proof.

## Cold boot and rollback

Zero input is genuine: the ROM reaches its BASIC prompt unattended. Note that a
**cold boot lands at BASIC, not in the suite** — the suite is a curated state
that only `loadvm golden` restores, which is exactly why `resetMode` is
`loadvm`. See `scripts/coldboot/plus4-zero-input-prep.md`.

To withdraw the tile: `systemctl stop streamhost@plus4`, set `enabled: false`,
regenerate, republish the two runtime documents. To rebuild:
`scripts/build-guests/plus4.sh --force`, which replaces `overlay.qcow2` and so
**destroys the golden inside it**, then re-curates and re-proves a new one.
