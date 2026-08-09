# ninefront (9front / Plan 9) warpd agent — STATUS: BAKED + LIVE (2026-07-15)

In-guest absolute-pointer agent for the `ninefront` tile. It speaks the
streamhost daemon's newline M/P/R/B protocol plus the bake-only acknowledged
`Q x y` probe over `tcp!*!7777`. Events use the kernel mouse's absolute
`A x y buttons msec` form, so movement and buttons are native Plan 9 input.

## Reproducible build

Run the guest-owned builder on the lab box:

    nice -n15 scripts/build-guests/tiles/9front.sh

The builder starts from the pinned official
`https://9front.org/iso/9front-11554.amd64.qcow2.gz` archive (sha256
`0e4a0808020c7845f854599b910d3a63ee56cbf3ebcd038332e22b7c1a272361`),
patches `plan9.ini`, boots the exact production device set, compiles `warpd.c`
in-guest with `6c`/`6l`, installs it, and creates the startup hook. It then
requires all of these gates before atomically promoting the staged image:

1. A cold boot reaches the real 1024×768 rio framebuffer and `Q 777 555`
   returns `K`.
2. `golden` is saved under `pc-q35-11.0`, 2 vCPU, `-cpu host`; `loadvm golden`
   reaches rio and returns the same acknowledgement.
3. The production service is started and reset through `labctl`; its D-Bus
   framebuffer places the cursor at exactly `(777,555)`.

The internal snapshot is saved only after rio, the TCP listener, and the lively
app fixture are settled. Clone proof established that the restored listener
accepts a new `Q` connection immediately. QEMU is explicitly paused at a
framebuffer-validated frame before `savevm`, so the snapshot and boot-video
poster name the same frame while the restored VM still resumes as running.

## Autostart installed by the builder

The pristine image has no `/cfg/cirno` directory, so the installer creates it
and writes `/cfg/cirno/termrc`:

    #!/bin/rc
    ip/ipconfig >[2]/dev/null
    ndb/cs >[2]/dev/null
    bind -a '#m' /dev >[2]/dev/null
    { while(! /amd64/bin/warpd >>/cfg/cirno/warpd.log >[2=1]) sleep 2 } &

The retry loop tolerates network startup ordering. Binding `#m` supplies
`/dev/mousein` before rio has completed its normal namespace setup. The agent
also reopens the mouse device for every event, and forks each accepted TCP
connection with `RFFDG`, so independent proof connections cannot block the
persistent streamhost connection.

## Host wiring

- Existing user netdev host forward:
  `127.0.0.1:57793` → guest `:7777`
- `tile.env`: `SH_POINTER=warpd`,
  `SH_WARPD_ADDR=127.0.0.1:57793`
- No exec channel is exposed for this tile.

## Fixture pitfalls captured in the builder

Fresh rio does not initially give the terminal keyboard focus. The fixture
moves the relative PS/2 pointer to the origin using twelve bounded moves,
moves to `(100,200)`, and left-clicks before typing. QMP `send-key` also needs
an explicit 20 ms hold with 60 ms spacing; its 100 ms default hold overlaps
faster keystrokes and corrupts the installer command. Launch the focused rc
terminal last, and pause only after a real framebuffer gate passes.
