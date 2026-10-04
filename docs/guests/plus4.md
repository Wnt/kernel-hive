# Commodore Plus/4 (PAL) — gallery station notes (udp/54086)

**Guest:** a captured **Debian 13 (trixie) x86_64 kiosk** running **VICE `xplus4`**,
emulating a **PAL Commodore Plus/4** at its power-on screen, one keypress from
the **3-plus-1** office suite that lives in the machine's ROM. A **kiosk** ("emulator bridge") — streamhost
captures the Linux framebuffer + AC97 audio exactly like every other station. See
**`streamhost/docs/BRIDGE.md`**.

**Shared seed:** `/data/vms/bridge/bridge-base-trixie.qcow2` — already contains the
whole VICE family.
**Build script (station):** `scripts/build-guests/tiles/plus4.sh` — thin overlay + kiosk
`launch.sh` + ROM repair + quiet console + checkpoint capture + a two-step
framebuffer proof of the suite route, fully automated, ~2 minutes.
**Station dir (labhost):** `/data/vms/streamhost/stations/plus4/`.
**Registry entry:** `registry/stations/plus4.json` (slot 86, udp 54086, VMID 222,
ssh hostfwd 127.0.0.1:5822).

## Media and license — there is none to stage

Like `vic20`, and for the same reason, but with a better payoff: VICE bundles
the Commodore ROMs, and for this machine that includes **both 3-plus-1 banks**
(`3plus1-317053-01.bin`, `3plus1-317054-01.bin`) alongside BASIC and the
KERNAL. The exhibit's entire subject — an office suite in ROM — therefore needs
no external media, no licensed image and no `check-assets.sh` row.

- **VICE 3.9** — GPLv2; bundles the Plus/4 BASIC/KERNAL/3-plus-1 ROMs for
  emulation use.

## The scene, and how a visitor drives it

The checkpoint is **the machine's own untouched power-on screen** —
`COMMODORE BASIC V3.5 / 60671 BYTES FREE / 3-PLUS-1 ON KEY F1 / READY.` —
black on a white page inside a lavender border. Nothing is curated and nothing
is typed into it.

**An earlier checkpoint was curated INSIDE the suite, resting in the spreadsheet,
and it was wrong.** On the exhibit floor a visitor arrived in the middle of one
application with no idea what it was, how it got there, or how to leave: it was
neither the machine's honest empty state nor a launcher. The power-on screen is
both, because the ROM's own second line tells you which key opens the suite.
That is the general lesson: prefer the state the machine itself chose, and put
the affordances in the exhibit UI around it.

From there, everything is the machine's own UI, verified by framebuffer:

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
phone there is no Tab at all, so the exhibit does not rely on it. The UI's
**`plus4` on-screen keyboard profile** puts the whole route on its base row, in
the order a visitor uses it:

| Button | Sends | From |
|---|---|---|
| `3-PLUS-1` | `F1`, `RETURN` | the power-on screen |
| `Word` | `C=`+`c`, `t`, `w`, `RETURN` | inside the suite |
| `Calc` | `C=`+`c`, `t`, `c`, `RETURN` | inside the suite |
| `File` | `C=`+`c`, `t`, `f`, `RETURN` | inside the suite |

with the bare `C=` key on the overflow row for anyone driving it by hand. Two
taps reach any application from the scene, on any platform.

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

Identical in shape to its kiosk siblings (`c64`, `vic20`, `apple2`, `atarist`,
`amiga`, `mpf2`) — see `streamhost/stations/plus4/qemu-streamhost.sh`. The kiosk
launcher is:

```
xplus4 -sounddev alsa -TEDdsize -TEDborders 0 -pal
```

on an 800×600 X root, which the doubled PAL frame fills edge to edge. As for
every VICE station, **the kiosk profile must not redirect `startx`'s output to a
file**: VICE 3.9 segfaults in `vice_banner()` whenever stdout is not a terminal
and prints nothing at all — the full backtrace and symptom are in
[`vic20.md`](vic20.md). `plus4.sh` also repairs the PLUS4 ROM set from the
retained source tree and asserts all four ROMs, the same `make install` gap the
C64 and VIC-20 hit.

## Keyboard pacing

The keys go host-native: browser key edges → the daemon's `vice_sock.rs` →
the fork's `vicectl` module, which paces them in the machine's own frames.
`SH_KEY_MIN_HOLD_MS=60`, `SH_KEY_MIN_GAP_MS=60` with `VICE_CTL_KEY_EXCL=1`,
the VICE family's floor since 2026-08-17 (vic20's re-bisect with overlapping
bursts: 40/40 corrupted 6 lines of 12, 60/60 none — see [`vic20.md`](vic20.md)).
PAL TED, 35 568 cycles a frame, so 60 ms is three frames.

**Shift is staged: `SH_KEY_MOD_LEAD_MS=40`, two frames (2026-10-04).** `:` `*`
`+` `@` are Shift+key on a US keyboard but plain Plus/4 keys (the keymap's
*deshift*), and `'` `[` `]` the reverse. VICE used to flip SHIFT and set the
key in one latch of the matrix, which a KERNAL scan straddling it read torn.
With the lead the module presents the Shift level the key needs two frames
ahead of the key, and a key also waits two frames behind a C= edge, which only
makes the profile's C= chords surer. Through the real daemon at the editor's
pace, on rigs: the old binary tore 9 lines in 3 passes of the 14-line CBM
stress listing, the new one none, and the three BASIC 3.5 examples typed 9 of
9. The station cold-boots (no checkpoint), and the power-on frame is
pixel-identical under both binaries. Method and the family's numbers:
[`../TYPE-IN-EDITOR.md`](../TYPE-IN-EDITOR.md#shifted-characters-the-modifier-lead);
evidence in
`/data/vms/streamhost/stations/plus4/evidence/shift-lead-2026-10-04/`. Live
since 2026-10-04: the real editor typed `draw.bas` on the live station, RUN
ran it, LIST was exact, and Restore to golden brought the scene back
(`live-smoke-*.png`).

`typeIn.perCharMs` is **170**, above the worst shifted character's HOLD +
max(GAP, LEAD) + LEAD = 160 ms.

No `demoProgram`: the interaction here is the suite, not a BASIC type-in.

## Verification (2026-08-09)

Evidence in `/data/vms/streamhost/stations/plus4/evidence/`:

| Artifact | Shows |
|---|---|
| `ready-before-golden.png` | the untouched power-on screen — the frame that was captured |
| `keyboard-1-suite.png` | `F1`+`RETURN` after the capture, leaving the white BASIC page for the suite |
| `keyboard-2-spreadsheet.png` | `C=`+`C` then `tc`, drawing the spreadsheet grid |
| `golden-restored-after-keyboard.png` | `loadvm golden` returning to the exact captured power-on screen |

The proof walks the **whole advertised route** and asserts each step by what is
on the screen — the suite is black where BASIC is a white page (white pixels
20000 → 131), and the spreadsheet's grid is an order of magnitude more ink than
an empty document (29713 > 25000). An earlier version asserted only "the
framebuffer changed" and passed while its keystrokes went into the cell editor
and typed a `0` into R1C1 — a proof that cannot fail is not a proof.

## Cold boot and rollback

Zero input is genuine, and since the checkpoint is now the power-on screen itself,
a cold boot and a restore reach the same place. See
`scripts/coldboot/plus4-zero-input-prep.md`.

To withdraw the station: `systemctl stop streamhost@plus4`, set `enabled: false`,
regenerate, republish the three runtime documents (tiles.json, gallery-manifest.json AND golden-manifest.json — the third is the reset allow-list). To rebuild:
`scripts/build-guests/tiles/plus4.sh --force`, which replaces `overlay.qcow2` and so
**destroys the checkpoint inside it**, then captures and re-proves a new one.
