# daemon-mod-lead — facts for release notes

**What changed for visitors:**
- **Amstrad CPC 6128** types in listings without losing keys when the lab is
  busy. The CPC runs inside a small Linux guest, and when the box was loaded
  that guest stalled, so a key's press and release could reach the emulator in
  the same frame. A doubled `$$` became `$`, and line `110` became line `10`.
  Each key is now held and spaced 80 ms instead of 40. The code editor types a
  character every 170 ms instead of 90 to match.
- **The stations whose keys go in through X11** keep a fast run of keys in
  order: `eex` can no longer arrive as `exe`. These are Lisa, PERQ, Medley,
  VisiOn, AMIX and the Nokia 9300, plus the terminal machines 4.3BSD on the
  VAX, Multics, ITS and MVS 3.8. The fix rolled out to the whole fleet's
  daemon.

**Under the hood:** the daemon's QEMU keyboard path has the same
`SH_KEY_MOD_LEAD_MS` modifier lead as the MAME and VICE key modules, so a key
can be held back until its Shift has reached the machine. It was measured on
the three shapes of guest behind the daemon. PC guests decode scancodes in
order, X clients read Shift from each event, and the CPC never lost a Shift in
about 3,800 tries. So no station turns it on yet.

Links: https://kernelhive.madekivi.fi/os/amstradcpc
