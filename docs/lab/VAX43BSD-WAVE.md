# vax43bsd wave brief — 4.3BSD on a SIMH VAX-11/780

Station id `vax43bsd` · issue #56 · record wave 2026-09-21, Lane B (terminal
stations) · branch `vax43bsd-work` from `origin/vax43bsd`.

**STATUS 2026-09-20T09:27Z: PAUSED by the wave coordinator** (labhost 1-min load
140 against the documented cap of 50; the lane is standing down until `mvs38`
publishes the shared terminal runtime). Nothing of this station is deployed,
listed, or running. The guest itself is **built and proven from a real console
transcript**; what is missing is the nspawn container launcher, the registry
scaffold, and the framebuffer proof. Resume at §Next step.

## Allocation ledger (`scripts/dev/wave.sh alloc vax43bsd`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| vax43bsd | vax43bsd-work | 209 / 54209 / 209 | — | — |

No `--retronet` and no `--x11warp`: the station has no pointer and its only
network is the simulator-internal DZ telnet listener, which lives inside the
container's private network namespace.

**Released again on 2026-09-20 at the pause** — see §Teardown.

## Media — measured, not copied from a README

Upstream: TUHS, `https://www.tuhs.org/Archive/Distributions/UCB/4BSD/4.3BSD/`.
Note the path: the `.../UCB/4.3BSD/` URL quoted in most guides 404s; the files
are one level down under `4BSD/`.

Staged at `/data/assets-staging/vax43bsd` (labhost):

| File | Bytes | SHA-256 |
|---|---|---|
| `stand.gz` | 23894 | `8f5f38d1c141f598bf4fca16277960f463486f5d678e883a7de97af11ab148a2` |
| `miniroot.gz` | 533449 | `9f3c27b7ea99cec22b22a9eb8e25f85287087d031681476158e98b6ffffdebb5` |
| `rootdump.gz` | 1654236 | `46d1ab1c41c330be47b04812f779c7e535b3e0d4d251b03670455660b212b125` |
| `usr.tar.gz` | 9803428 | `8565ff6f85ade24a1b63fdc5f7f5befe49b70bf4d44281cbfb015742ba379cc4` |
| `FORMAT` | 115 | `57aaa553ceccd59a4145a7c8696e614f21696404214d3ee7199e9c87fdccf624` |

`srcsys.tar.gz`, `src.tar.gz`, `vfont.tar.gz`, `new.tar.gz` and `ingres.tar.gz`
were deliberately **not** staged for the first release (see §OPEN).

Bootstrap: `boot42`, the 4.2BSD standalone boot, 6600 bytes, uudecoded from the
Computer History Wiki page `Boot42` (raw wikitext at
`https://gunkies.org/w/index.php?title=Boot42&action=raw` — the `/wiki/…?action=raw`
form 404s). SIMH cannot boot the emulated TS tape directly, so `boot42` is
`load`ed at address 0 and entered with `r10=9 r11=0`.

Emulator pin: Open SIMH `https://github.com/open-simh/simh`, commit
`a1f57fa3738ed31148d31126ba1a7278ff845c6d` ("PDP18B: Add delay to Type 647 line
printer"), reported by the binary as `VAX 11/780 simulator Open SIMH V4.1-0`.
`make vax780` on labhost; the built simulator passed its own diagnostic
supervisor run (EVKAC/EVKAD) at build time.

## Staged station assets (labhost, `/data/vms/streamhost/assets/vax43bsd`)

| Path | Apparent / on-disk | SHA-256 |
|---|---|---|
| `bin/vax780` | 2443056 | `100201455ccd7f37afa52b238ca1309334acbf4d980d944dcd2e20a3498702ab` |
| `media/bsd43-ra81.dsk` | 436M / 19M sparse | `a99158ea72e318f6f5bc8cf7705e0f07c28b3ac92576d11811165f8e90f77a5d` |
| `media/43.tap` | 37M / 18M sparse | `9f501bc368fbc660917a68620da880fc0a651e45133c904a7e25c6550d52d837` |
| `media/boot42` | 6600 | `a7bacc518350f4ebb1c21e7f578f91dd843ef42c26d912a1a9d227b2fac07eff` |
| `rootfs/` | 357M | Debian trixie minbase + xvfb, xterm, xfonts-base, x11-utils, xauth, inetutils-telnet, netcat-openbsd, procps, util-linux, ncurses-term; uid-shifted to 2490368 |

`media/*` are mode 0444; the seed disk is copied (`cp --sparse=always`) into the
station's writable `work/` on every launch, so the immutable seed is never the
file SIMH opens.

Container uid base **2490368** (38 × 65536). In use elsewhere and avoided:
65536, 200000, 1966080 (medley), 2031616 (indyr4400), 2162688, 2359296.

## Device set — frozen for the first release

```
rq0   RA81, work copy of bsd43-ra81.dsk   (root ra0a, /usr ra0h, /home ra0g)
ts    TS11, 43.tap attached read-only     (kernel probes ts0; mt/tar still work)
dz    DZ11, lines=8, 7b, telnet listener  (the visitor line, tty00..tty07)
rq1-3, rp, rl, tq, tu, lpt   disabled
tti/tto 7b · cpu idle=32v
```

No Ethernet. 4.3BSD's networking on the SIMH 780 is unreliable and the DZ line
is the whole visitor surface, so a NIC is out of the frozen device set on
purpose — this station is deliberately an island. There is no QEMU checkpoint
here: like `medley`, `lisa`, `perq` and `vision`, **reset = relaunch** from the
pristine seed, so a later device-set change costs a rebuild, not a re-bake.

## What was proven, and how

Everything below is from the SIMH console transcripts under
`/data/vms/sandbox/vax43bsd-work/build/inst/console*.log` on labhost. **None of
it is a framebuffer proof** — the station's X surface does not exist yet.

| Time (UTC, `date -u`) | Milestone |
|---|---|
| 08:55 | session start, brief read |
| 09:00 | slot/UDP/VMID 209 claimed; media staged and hashed; `vax780` built and diagnostics-clean |
| 09:03 | 43.tap built (4 files: stand@512, miniroot/rootdump/usr.tar@10240, tape marks between, double mark at EOT) |
| 09:04 | **phase 1 complete** — miniroot booted, `MAKEDEV ra1`, `disk=ra1 type=ra81 tape=ts xtr` → "Root filesystem extracted" (under 60 s wall) |
| 09:07 | **phase 2 complete** — `newfs ra0h`, usr.tar restored (`mt rew; mt fsf 3; tar xpbf 20 /dev/rmt12`), fstab from `fstab.ra81`, `newfs ra0g` |
| 09:12 | **first multiuser boot**, `login:` on the console, root logs in with no password |
| 09:13 | museum polish applied: hostname `kernelhive`, `/etc/ttys` terminal type `unknown` → `vt100` on the console and tty00–tty07 |
| 09:17 | **DZ visitor line proven** — host `telnet 127.0.0.1 18209` reached `login:`, `root` logged in, `who` reported `root tty00`, and `echo … > /dev/console` crossed from the DZ session to the console (see below) |
| 09:21 | clean `sync; sync; /etc/halt`, pristine seed snapshotted |
| 09:25 | **unattended boot proven** — SIMH `expect`/`send` in the ini file answers the `Boot` prompt with no driver attached, reaching `login: ` in **~53 s** from process start |

The DZ transcript that matters (host side, `dzprobe.py`):

```
Connected to the VAX 11/780 simulator DZ device, line 0
root
…
kernelhive# hostname; who; echo VAXDZPROOFOK > /dev/console
kernelhive
root     tty00   Sep 20 05:17
```

and the same string arriving on the simulator console a moment later — two
independent surfaces, one guest.

### The unattended-boot answer (this is the lane-shareable bit)

The seed brief and the draft runtime both assume something has to type
`ra(0,0)vmunix` at the `Boot` prompt. It does not: SIMH's own `EXPECT`/`SEND`
does it, which removes the pty/expect supervisor from the container entirely and
leaves SIMH as the single supervised process:

```
load -o boot42 0
d r10 9
d r11 0
expect "Boot\r\n: " send "ra(0,0)vmunix\r"; go
expect "login: " echo KHBOOTREADY; go
run 2
```

Proven at 09:25 with `set quiet` and stdin on `/dev/null`. The readiness probe
for a terminal launcher can therefore be either the DZ port accepting **or**
`KHBOOTREADY` in the console log; the port probe from
`docs/lab/record-wave/shared-terminal-runtime.sh` is the better one because it
proves the getty, not just the kernel.

### Measured boot cost

Cold boot of the pristine seed to `login:` on the console: **~53 s**
(09:24:21 process start → `login:` at 09:25:14 in the test run, `set cpu
idle=32v`). The largest part is the boot-time `fsck` of ra0a/ra0h/ra0g; the seed
is halted cleanly so fsck finds nothing to salvage.

## Museum shape as measured (corrections to the prep drafts)

- **`uname` does not exist in 4.3BSD.** Both `docs/lab/integration-seeds/vax43bsd.md`
  and `docs/lab/spa-drafts/vax43bsd.md` propose a rest scene with `uname`; the
  real commands are `hostname`, `machine`, `who`, `ls`, `netstat`. The poster's
  "What you're looking at" paragraph must be rewritten from this.
- The hostname is `kernelhive` (stock is `myname.my.domain`, which reads as a
  placeholder in a gallery). Set in `/etc/rc.local`.
- The authentic `/etc/motd` is kept verbatim — `4.3 BSD UNIX #1: Fri Jun 6
  19:55:29 PDT 1986` followed by *"Would you like to play a game?"* — and login
  prints *"Don't login as root, use su"*. That is the exhibit's voice; do not
  replace it with museum copy.
- `/usr/games` is fully populated (adventure, backgammon, boggle, chess, ching,
  cribbage, doctor, fortune, hangman, …) and is the obvious visitor hook.
- The kernel is the stock `GENERIC`: `4.3 BSD UNIX #1: Fri Jun 6 19:55:29 PDT
  1986  karels@monet.Berkeley.EDU:/usr/src/sys/GENERIC`, 8 MiB of memory,
  `avail mem = 7187456`.

## Next step (resume here)

1. `git fetch origin mvs38` and read `docs/lab/record-wave/shared-terminal-runtime.sh`
   for the lane's proven answers on Xvfb socket exposure, nspawn containment,
   supervision, terminal crop and reset. Contribute the `EXPECT`/`SEND` finding
   above if mvs38 has not already landed an equivalent.
2. Write `streamhost/stations/vax43bsd/{x11-runtime.sh,nspawn-inner.sh,station.env.fixture}`
   from `streamhost/stations/medley/*` — that launcher is the closest proven
   relative (nspawn, `--volatile=overlay`, `--private-users=<uidbase>:65536`
   `--private-users-ownership=off`, `--private-network`, host X socket dir bound
   over `/tmp/.X11-unix` plus a host symlink, reset = relaunch, pidfile contract
   `mame.pid`/`xvfb.pid`/`nspawn.pid`). Binds: `bin/` and `media/` read-only,
   one writable `work/`. Inner: Xvfb → `vax780 /work/boot.ini` → wait for the DZ
   port → `exec xterm … -e telnet 127.0.0.1 <port>`.
   Intended visitor surface: 1024x768 root, xterm 80x24, green on black, no
   scrollbar, centred — **unmeasured, pick the font from a real frame.**
3. `python3 scripts/stations-registry.py new vax43bsd --like medley --production --slot 209`,
   then fill from `docs/lab/integration-drafts/vax43bsd/registry-overrides.md`
   with the corrections above (archetype `mono-terminal`, `ui: text-console`,
   no pointer, accent `#67828f`).
4. `scripts/dev/smoke-rig.sh vax43bsd --like medley` → operator watches `/os/vax43bsd`.
5. The proofs that are still entirely OPEN: **framebuffer** (real guest pixels in
   the capture), **input from the real browser** (including the control keys a
   1986 shell needs — `^C`, `^D`, `^U`, `^Z`, ESC — through the on-screen
   keyboard, not host shortcuts), and **reset** (visible change → relaunch →
   original scene, twice, seed unchanged by `sha256sum`).

## OPEN

- No framebuffer, input or reset proof yet (above).
- `srcsys.tar`/`src.tar` are not on the tape, so `/usr/sys` and the kernel
  sources are absent. The compiler toolchain in `/usr` is present. Adding
  sources is a tape rebuild plus a second `tar` extract, not a reinstall.
- No Ethernet, so no retronet plane. Deliberate for the first release.
- Root has no password, which is stock 4.3BSD. Acceptable only because the whole
  guest is inside a private-network nspawn container and the disk is a throwaway
  copy — the containment, not the guest, is the security boundary
  (`docs/lab/record-wave/HOST-APP-CONTAINER-CONTRACT.md`, and the medley
  incident in `docs/guests/medley.md §Security`).
- The station has eight DZ lines; only one visitor terminal is planned. Whether
  a second line is worth exposing (two visitors, one machine — very much the
  1986 experience) is an open museum question.

## Teardown at the pause

Killed by resolving `/proc/<pid>/exe`, never by a cmdline grep: every `vax780`
under `/data/vms/sandbox/vax43bsd-work/` and under
`/data/vms/streamhost/assets/vax43bsd/bin/`, plus the `simhdrive.py`/`dzprobe.py`
supervisors. Claims released with `kh-claim release`. No station was ever
emitted, started, deployed or listed, and no smoke rig was published, so there is
nothing in the serving plane to undo. The build tree
`/data/vms/sandbox/vax43bsd-work/build/` and the staged assets are left in place
on purpose — they are the resume point, and the assets are inert until a station
entry references them.
