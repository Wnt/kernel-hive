# daemon-mod-lead — facts for release notes

**What changed for visitors:**
- **Amstrad CPC 6128** holds and spaces each key 80 ms instead of 40, and a
  shifted key waits 20 ms behind its Shift. The CPC runs inside a small Linux
  guest, and when the lab is busy that guest stalls, so a key's press and
  release can reach the emulator in the same frame: a doubled `$$` became `$`,
  line `110` became line `10`, and once `"` came out as `2`. The code editor
  now types a character every 180 ms instead of 90. Under heavy lab load it
  still dropped keys now and then, so the same evening the CPC left the guest
  altogether and became a host-native MAME station (see `amstradcpc.md`).
- **The stations whose keys go in through X11** keep a fast run of keys in
  order: `eex` can no longer arrive as `exe`. These are Lisa, PERQ, Medley,
  VisiOn, AMIX and the Nokia 9300, plus the terminal machines 4.3BSD on the
  VAX, Multics, ITS and MVS 3.8. The fix rolled out to the whole fleet's
  daemon.

**Under the hood:** the daemon's QEMU keyboard path has the same
`SH_KEY_MOD_LEAD_MS` modifier lead as the MAME and VICE key modules, so a key
can be held back until its Shift has reached the machine. It was measured on
the three shapes of guest behind the daemon. PC guests decode scancodes in
order and X clients read Shift from each event, so neither can lose it. The
CPC lost it once in about 4,500 shifted keys, and it was the one station that
turned the lead on, at 20 ms, until it went host-native.

Links: https://kernelhive.madekivi.fi/os/amstradcpc
