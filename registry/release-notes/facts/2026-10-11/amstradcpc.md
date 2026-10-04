# amstradcpc — facts for release notes

**What changed for visitors:** the Amstrad CPC 6128 types what you type. The
code editor's listings now arrive character for character, at 120 ms a
character instead of 180, however busy the lab is. Until now the CPC ran as
Caprice32 inside a small Linux guest, and whenever the lab was busy that guest
stalled long enough for a key's press and release to reach the emulator in the
same frame: `X,400` arrived as `X,40`, `FOR I=0` as `FOR 10`, and the
String Art example failed with a syntax error in every run through the editor.

**Under the hood:** the CPC is now MAME's `cpc6128` running directly on the
host, the same way as the BBC Micro, the Spectrum and the QL: no guest Linux,
no X, frames straight from MAME into the stream, and keys put into the CPC's
own keyboard matrix in emulated time, so a stall delays a key but can no longer
lose it. The CPC's firmware reads its keyboard once every 20 ms, and that was
measured: keys held 10 ms are missed almost entirely, 20 ms already works, and
the station holds each key 40 ms, with Shift down 20 ms before the key it
shifts. A 15-line test listing full of `"` `(` `)` `*` `$` `+` `&` `!` `<` `>`
and all three editor examples were read back from the screen, cell by cell,
against the CPC's own character ROM: every one exact, and each example ran.

**What a visitor will notice:** the screen is the same Ready prompt, drawn a
little smaller inside the CPC's blue border, and Restore starts the machine
from cold, which takes about a second. On a physical keyboard the keys follow
the CPC's own layout: Shift+2 is `"`, as on the real machine.

Links: https://kernelhive.madekivi.fi/os/amstradcpc
