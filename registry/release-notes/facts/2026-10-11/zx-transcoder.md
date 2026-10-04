# zx-transcoder — facts for release notes

**What arrived:** the type-in code editor now works on the two machines where
one key *is* a keyword: the **ZX Spectrum 48K** and the **ZX81**. A visitor
pastes an ordinary listing (`10 PRINT "Hi"`) and the editor presses the keys a
person would: P for PRINT at the K cursor, SYMBOL SHIFT for the quote, CAPS
SHIFT for a capital, extended mode for INK and CIRCLE, FUNCTION for INT and
RND on the ZX81. That brings the editor to 19 machines.

**How it knows the keys:** the keyword-to-key table is generated from each
station's own keymap, whose key names are MAME's printed key legends. Two gaps
were filled from the machines themselves: MAME has POINT and CAT swapped on
the Spectrum's 8 and 9, and its ZX81 names lack the FUNCTION legends, which
come from the keyboard drawing in the ZX81 manual. Both were checked against
the ROMs' own key tables.

**What it refuses to do quietly:** anything the machine cannot type as written
is painted red and listed, and typing waits: a PRINT in the middle of a
statement, `10 a=1` without LET, `!` or `^` on a ZX81, and a letter after `:`
in a Spectrum REM (the Spectrum ROM turns it into a keyword; measured).

**Measured along the way:**
- After `NEW` the 48K Spectrum ignores the keyboard for about two seconds while
  it re-tests its memory, so the editor waits 3 s after a NEW line.
- The 1 KB ZX81 rebuilds its display byte by byte: after each ENTER it takes
  about 90 ms longer per listed line, and after each key longer as the line
  grows. The editor's waits grow with it, so a listing arrives whole.

**Examples and manuals:** three original programs per machine. Spectrum: a
colour web that shows attribute clash, a times table, and Catch (O/P bat).
ZX81: a figure of eight in block pixels, square and cube with `**`, and
Letter dash. Links to Steven Vickers' manuals for both machines.

**The Spectrum's demo listing** is now an ordinary listing typed through the
same transcoder (it used to be written as raw keystrokes, `10 b1`).

Links: https://kernelhive.madekivi.fi/os/zxspectrum, https://kernelhive.madekivi.fi/os/zx81
