# shift-lead-vice — facts for release notes

**What changed for visitors:**
- **Every Commodore station types shifted punctuation exactly.** On the VIC-20,
  C64, C128 and Plus/4, `:` `*` `+` and `@` are plain keys that a PC keyboard
  types with Shift, and `'` `[` `]` are the reverse. Now and then the
  emulator changed the machine's Shift in the same instant as the key. If the
  machine read its keyboard at that moment, the key came out wrong: `:` turned
  into `[`, `+` into a graphics glyph, or a `*` went missing. Typed into the
  code editor, that line then failed with `?SYNTAX ERROR`. A Shift change now
  reaches the machine two frames before its key, as a real typist's Shift
  does.
- Measured through the code editor's own keystrokes, with a 14-line listing
  dense in those characters, three passes per machine. Before the fix the
  C64 got 20 lines wrong, the C128 10, the Plus/4 9 and the CBM 8032 1. After
  it, no machine got any line wrong. Every example program typed exactly, and
  each machine's start-up scene is pixel-identical to before. The PET 2001
  and the CBM 610 never showed the fault and run the same fix.
- On the GEOS C64, file names typed into GEOS's own rename box come out
  exactly too, capitals and symbols included.

**Under the hood:** the stations run a VICE build whose key module stages the
Shift level each key needs (`SH_KEY_MOD_LEAD_MS`, two of the machine's own
frames: 40 ms at 50 Hz, 33 ms on the 60 Hz PET 2001). vic20 had it first; this
rolls it out to pet2001, cbm8032, c128, plus4, cbm2, c64 and c64basic.

Links: https://kernelhive.madekivi.fi/os/c64basic ·
https://kernelhive.madekivi.fi/os/c128 · https://kernelhive.madekivi.fi/os/plus4
