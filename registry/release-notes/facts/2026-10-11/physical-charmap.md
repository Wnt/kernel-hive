# physical-charmap — facts for release notes

**What changed for visitors:** on fourteen machines whose keyboards are not
laid out like a PC's, the key you press on your own keyboard (or the on-screen
one) now types the character printed on it. Until now a visitor typing `"` on
the BBC Micro got `*`, `*` on the Atari 800XL came out as `@`, and on the
Japanese FM Towns and MSX turbo R half the punctuation landed one key over. The machines: BBC Micro, ARM Evaluation System, Amstrad CPC, Atari 800XL,
Dragon 32, FM Towns, KC 85/4, Kaypro (CP/M), MPF-II, MSX turbo R, SAM Coupé,
SV-328 (BASIC and CP/M) and SymbOS.

**How it was checked:** every map was typed through the gallery's own keyboard
code into a private copy of each machine, all 95 printable ASCII characters,
and each frame was read character by character. The check corrected maps, not
only switched them on: the FM Towns had inherited the SAM Coupé's map entry for
entry and now has its own JIS one (plus a key that was wired to a second Escape
and now gives `]` and `}`); SymbOS swaps `'`/`` ` `` and `"`/`~`; the Atari had
no map at all. The SAM Coupé gained `\`, the SV-328s `~`, the MSX turbo R `{` `}`
`~`.

**Letter case:** on the KC 85/4, whose plain keys are capitals, `a` is `a` and
Shift+`a` is `A`, with or without Caps Lock. On the MPF-II, a machine with no
lower case, a capital typed with Shift is now the capital instead of a symbol.

**Still not reachable:** a character the machine has no key for (the BBC's `\`
`|` and backtick, the Dragon's brackets, `_` on the Towns and the MSX) still
types whatever that key makes there, and the code editor marks it red.

Links: https://kernelhive.madekivi.fi/os/fmtowns
