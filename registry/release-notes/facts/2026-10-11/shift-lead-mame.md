# shift-lead-mame — facts for release notes

**What changed for visitors:**
- **Shifted characters arrive exactly on the MAME machines.** Whenever the code
  editor, the on-screen keyboard's character keys or a capital typed without
  Shift held sent a shifted character, Shift and the key reached the emulated
  keyboard at the same instant. Some machines then read the key without its
  Shift: the Oric typed `*` as `8` and `$` as `4` now and then, and the
  Macintosh 128K lost Shift on every capital and symbol. Shift now reaches the
  machine a few emulated milliseconds before its key, as a typist's does.
- Measured through the editor's own keystrokes, on a copy of each station: a
  16-line listing with `"A+B*C:D(E)$!";1+2*3` on every line, compared glyph by
  glyph with a slow reference. With the fix every line came out exact on all
  eighteen keyboard stations, every example program typed exactly, and every
  machine's start-up scene is pixel-identical to before.
- **The Apple //e joins the code editor**, with three new programs (a hi-res
  starburst, a prime checker and a letter-guessing game) and two manuals.
  Press B on the boot menu for the Applesoft prompt first.
- **The Kaypro II follows your keycaps.** Its CP/M is a German build (Y and Z
  swapped, symbols where a German keyboard has them), so `"` `+` `*` `:` `(`
  `)` and Y/Z used to come out as other characters. Your keys are now
  translated to the German layout. Characters that build has no key for
  (`# @ [ \ ] ^ ` { | } < >`) still cannot be typed.
- **Fast typing no longer drops or swaps letters** on the Atari 800XL (in The
  Last Word), the Kaypro II and the Apple //e. These machines read one key at
  a time, and a key pressed before the previous one was released vanished or
  came out in the wrong order.
- **The FM Towns command prompt** (コマンドモード) now takes a typed line
  exactly; before, most of a line typed at normal speed was lost.

**Under the hood:** the MAME key module holds a key press until the last
Shift or Ctrl change has been in the machine for `SH_KEY_MOD_LEAD_MS` emulated
milliseconds: 10 on most machines, 20 on the Oric (threshold 1–2 ms) and the
Macintosh (threshold 5–10 ms, its keyboard's own scan). Exclusive scan (one
key at a time) is now on for the Apple //e, the Kaypro, the Atari 800XL and
the FM Towns, whose earlier setting named key rows it does not have. A new
registry flag, `keyboard.physical`, applies a station's keyboard translation
to the visitor's own keys; the Kaypro is the first station with it.

Links: https://kernelhive.madekivi.fi/os/apple2e ·
https://kernelhive.madekivi.fi/os/cpm22 · https://kernelhive.madekivi.fi/os/oricatmos
