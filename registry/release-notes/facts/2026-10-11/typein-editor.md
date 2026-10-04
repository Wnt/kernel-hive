# typein-editor — facts for release notes

**What arrived:** a type-in code editor on the BASIC machines. Seventeen
stations that boot into an interpreter now have **✎ Code editor** in the ☰
menu: VIC-20, PET 2001, CBM 8032, C128, Plus/4, CBM-II, BBC Micro, ARM
Evaluation System, Dragon 32, Oric Atmos, MSX2, SV-728, SV-328, Amstrad CPC,
MPF-II, Sinclair QL and SAM Coupé. The panel opens beside the picture (under
it on a phone). It highlights line numbers, keywords, strings, numbers and REM
in the machine's own BASIC dialect.

**Where it came from:** a visitor asked how to send the clipboard into the
window as keystrokes, suggesting an AutoHotkey script, so they could type in
listings from old computer magazines. They also noticed that "some buffer runs
out" on a longer line on the VIC-20. The editor does the first part in the
browser: paste with Ctrl+V or ⌘V, or open a `.bas`/`.txt` file, then
**⌨ Type into machine**. The daemon side of the second part was a separate
fix (keyfeed).

**What a visitor can do:**
- Paste or open a listing, or start from the machine's demo listing or one of
  its example programs.
- Press Type and watch it go in one key at a time at that machine's own
  measured pace, with "Typing line 3 of 12", a progress bar and a Stop that
  really stops.
- Type RUN themselves.

**What it refuses to do quietly:**
- Characters the machine cannot receive (a curly quote from a web page, a
  pound sign) are painted red and block typing; one click swaps the
  typographic ones for ASCII.
- On the Commodores, lines longer than the machine's screen line (88
  characters on a VIC-20) are struck through past the limit.
- Magazine control codes like `{CLR}` are flagged.

**Shift rules, per machine:** VIC-20, PET and BBC listings are printed in
capitals, but Shift+letter there is a graphics glyph, or with CAPS LOCK on a
lower-case letter. The editor sends what the machine needs; a registry `case`
rule per station decides it.

**Manuals:** each machine's manual links show in the editor and at the end of
its exhibit notes, as the per-machine content lands in `registry/examples/`.

**Not there yet, and why:**
1. ZX Spectrum and ZX81 have no editor. One key there *is* a keyword (P gives
   PRINT), so typing letters one by one produces garbage.
2. Tokenised `.prg` files cannot be opened, only text listings.
3. `{CLR}`-style codes are not yet translated into the real Commodore keys.
