# `xvfb-alloc` — how a lab rig gets an X display

Source of truth `scripts/lib/xvfb-alloc.sh`, box copy `/usr/local/bin/xvfb-alloc`
(byte-identical pair, see `scripts/README.md`). Proof harness:
`tests/xvfb-alloc-selftest.sh`.

## The incident it exists for

Rigs used to hand-pick a display number and then "verify" the server like this:

```bash
Xvfb "$DISP" -screen 0 "$GEOM" -nolisten tcp >"$D/xvfb.log" 2>&1 &
[ -S "/tmp/.X11-unix/X${DISP#:}" ] || die "Xvfb did not come up"
```

That test is satisfied by **someone else's** server. During a multi-agent
campaign two rigs both picked `:77`: the second Xvfb died immediately ("server
already running"), the socket test passed anyway because the first agent's socket
was there, and the loser drove — and screenshotted — its sibling's display for
about 12 minutes. Nothing failed; the contamination surfaced only at synthesis.
Some rigs made it worse with `rm -f "$XSOCK"` before starting, i.e. evicting the
rightful owner. A stale `:77` also outlived its owner by 23 hours.

The dangerous shape is not a crash. It is a **silent attach**.

## What the allocator guarantees

- **Atomic claim.** The claim is the X server's own kernel-atomic bind of
  `@/tmp/.X11-unix/X<n>`; the number is reported back *by that server* through
  `-displayfd`. Never check-then-create. (With `-displayfd` there is no
  `/tmp/.X<n>-lock` at all — the socket, not a file, is the authority. That is
  why ownership questions go through `ss`, not a lock file.)
- **No silent fallback, ever.** Success requires our own child alive, a display
  number reported by it, that number inside the requested range, the socket
  present, and the socket's listener to *be* that child. Anything else is a
  non-zero exit with a loud message. A caller that cannot get its own display
  stops.
- **Orphan-safe.** A crashed owner's leftovers never deadlock the pool: the X
  server reclaims a display whose owner is gone, `xvfb-alloc list` shows it as
  ORPHAN, and `xvfb-alloc reap [--force]` clears the files — only ever files
  whose owning process is provably gone, never a live display.
- **Released on exit,** including on signal (EXIT/INT/TERM/HUP, chained onto any
  handler the caller already installed). Rigs whose server must outlive the
  script pass `--no-trap` and release by pidfile at teardown.

> **The exit trap does NOT fire for a rig launched under `setsid nohup`** — the
> detaching process never runs the trap, so the display stays claimed after the
> emulator exits. A detached rig **must call `xvfb_release` explicitly** at
> teardown, exactly as if it had passed `--no-trap`. Observed 2026-08-10: three
> displays (`:64 :65 :66`) left claimed by one rig after its emulator was gone.
>
> Two practical notes from that cleanup. `xvfb-alloc list`'s **OWNER column
> names the claiming script**, which is how you prove a stale display is yours
> and not a sibling's before releasing it — do that check first, always.
> And **`release :N` silently does nothing**; only `release <pidfile>` or
> `release <pid>` actually frees it.

## Using it

```bash
source /usr/local/bin/xvfb-alloc
xvfb_alloc --screen 1280x1024x24 --tag myrig --pidfile "$D/xvfb.pid"
echo "$XVFB_DISPLAY"          # e.g. :66  — yours, provably
…
xvfb_release "$D/xvfb.pid"    # or let the exit trap do it
```

CLI: `xvfb-alloc alloc [--screen …] [--min N] [--max N] [--display N]
[--pidfile F] [--log F]` (prints eval-able `XVFB_DISPLAY=…`), `xvfb-alloc
release <pidfile|:N|pid>`, `xvfb-alloc list`, `xvfb-alloc reap [--force]`.

Pool is `:64..:191` (`XVFB_ALLOC_MIN`/`MAX`); nothing below `:10` may be claimed,
because **`:1` is the shared CT950 dev desktop** and `:0` is a real seat.
`--display N` pins a number for callers that need a fixed one (the IRIX tile's
`SH_X11_DISPLAY`) — pinned or pooled, a taken display is a loud failure.

## Converted callers

| caller | before | after |
|---|---|---|
| `scripts/build-guests/irix/irix-park-desktop.sh` | `--display`, default `:151`, `rm -f $XSOCK` | pool allocation; number recorded in `<park>/display`; failed park no longer leaks its Xvfb |
| `scripts/build-guests/irix/irix-apps/irix-apps-launch.sh` | fixed `:41` | pool allocation, recorded in `$D/display`; `IRIX_APPS_DISPLAY` still pins |
| `scripts/build-guests/irix/irix-apps/irix-apps-shot.sh` | fixed `:41` | reads `$D/display` (a shot can no longer be of another rig) |
| `scripts/build-guests/irix/irix-apps/irix-apps-kill.sh` | `clone-guard kill-pidfile xvfb.pid` | `xvfb_release` (proves ownership, then clears the display's files) |
| `streamhost/tiles/irix/x11-runtime.sh` | fixed `:40` + socket test + `rm -f $XSOCK` | pinned claim via the allocator; the socket `rm` is gone |

The production IRIX tile runs `IRIX_CAPTURE=shm` (`-video none`) and starts **no
X server at all**, so the tile's converted branch is its rollback path, not its
live path.

## Long tail on the box

`/data/vms/soltest/**` holds ~44 one-off copies of these rigs from past
campaigns, most with a hardcoded number (7 × `DISPNUM=151`, 2 × `:77`, plus
`:60`, `:99`, `:160`, `:170`, `:171`). They are spent experiment artifacts, not
templates; the fix is at the sources above, which is what new rigs get copied
from. Before reusing one, convert it or at least check `xvfb-alloc list`.
