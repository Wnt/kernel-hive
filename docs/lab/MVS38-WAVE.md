# mvs38 wave — IBM MVS 3.8j under Hercules with an x3270 visitor terminal

Issue #49 · Lane B of the record wave · pathfinder for the shared heritage-terminal runtime.

**STATUS 2026-09-20T13:10Z: LIVE.** The station is in the registry, the
container runtime is committed, and the exhibit rests on the ISPF primary
option menu — proven on the framebuffer, not inferred. The measured facts for
the finished station live in [`docs/guests/mvs38.md`](../guests/mvs38.md); this
file is kept for the bring-up history, the readiness finding it contributed to
the lane, and the incident below.

**What changed between "stood down" and "live":**

| | |
|---|---|
| rest scene | the ISPF primary option menu, reached by a scripted TSO logon driven through x3270's own `-scriptport` / `x3270if`, gating every step on `Ascii()` screen text |
| terminal | x3270 `3279-2-E`, font `3270-20` — 821x513, the largest of six that fits 1024x768 |
| uid base | moved off **2031616**, which is indyr4400's range, to **2097152** |
| Hercules logo | replaced; the stock TK5 one printed the emulator version and labhost's name, kernel and core count onto the museum framebuffer |
| reset | ~103 s relaunch, PROVEN by `ALLOC` + `LISTDS` either side of it; the DASD copy is a ZFS block clone, ~1.2 s |
| bring-up gate | `work/logon.ok` (which screen) **and** a 20000 lit-pixel floor (whether there is a screen) |

**Five traps this bring-up added**, all written up in the guest doc: `-name`
silently disabling every `x3270.*` resource; x3270 finding a keymap only as an
X resource; `XK_Pause` not being on the wire, so Clear had to ride Alt+C;
`exec VAR=val cmd` not being a thing; and a stale
`/run/systemd/nspawn/unix-export/<machine>` mount wedging every restart of a
container that died untidily — **that last one is a fleet-wide risk for every
nspawn station, not an mvs38 bug.**

## Allocation (held by session `mvs38-work`)

| Station | Session | Slot / UDP / VMID | Display | Hercules CNSLPORT | retronet |
|---|---|---|---|---|---|
| mvs38 | mvs38-work | 214 / 54214 / 214 | `:114` | 13270 (smoke only, see below) | — none needed |

Claims taken through `kh-claim` under `KH_SESSION=mvs38-work`:
`sandbox/mvs38-work`, `slot/214`, `port/54214`, `vmid/214`, `display/:114`,
`port/13270` (temporary, smoke-only). `.wave.env` is in the worktree.

`--retronet` and `--x11warp` were deliberately NOT allocated: MVS 3.8j has no
web plane and no IM client, and the pointer is not the critical path — the
station is keyboard-only over XTEST, exactly like medley.

**The CNSLPORT claim is smoke scaffolding, not the station design.** In the
production shape Hercules runs inside a `--private-network` nspawn container,
so it binds the stock port 3270 on the container's own loopback and no host
port claim is needed at all. `port/13270` exists only because the first
timing smoke ran host-native, outside a container.

## Media (measured, not copied from a README)

| Fact | Value |
|---|---|
| filename | `mvs-tk5.zip` |
| byte size | `498312872` |
| SHA-256 | `710d002843631322810a276dd42c793fda458548dc64d86e2914a62db7425f84` |
| upstream pin | `https://www.prince-webdesign.nl/images/downloads/mvs-tk5.zip`, `Last-Modified: Wed, 18 Feb 2026 16:10:36 GMT`, `Content-Length: 498312872` |
| staged at | `/data/assets-staging/mvs38/mvs-tk5.zip` |
| unpacked size | 523 MB (`dasd/` 269 MB, `hercules/` 113 MB, `doc/` 94 MB, `Packages/` 47 MB) |

`mvstk5-update5.zip` (350462458 bytes) was **not** needed: the base archive's
own banner already reads `TK5 ... Update 5`, so the base zip IS update 5.

The seed pointed at `github.com/joergschultzelutter/tk5-hercules`. That was not
used — it is a Docker wrapper that downloads the same upstream zip. The zip is
pinned directly, as the seed itself instructs ("do not vendor a container image
as the canonical source").

### Media traps (both cost time in this run)

1. **The TK5 zip does not carry exec bits.** After `unzip`, `hercules` and
   every TK5 shell script are mode `0644`, and the first launch dies with
   `failed to run command 'hercules': Permission denied`. The builder must
   `chmod +x hercules/linux/64/bin/* hercules/linux/64/lib/hercules/* mvs
   mvs_ipl start_herc scripts/* unattended/*`.
2. **Never stage `dasd/` out from under a running Hercules.** The asset tree at
   `/data/vms/streamhost/assets/mvs38/tk5` was copied while the timing smoke
   was still IPLed, so its `dasd/*.298/.299/.390/.391/.249/.248` are a DIRTY
   mid-write snapshot. **This tree must be re-staged from a fresh `unzip`
   before it is used as the pristine seed.** That is step 1 of resuming.

## What Hercules/TK5 actually does (measured)

TK5 bundles its own SDL Hyperion Hercules for `linux/64` — do not use Debian's
`hercules` 3.13. Unattended (daemon) IPL is:

```bash
cd <tk5 tree>
export PATH="$PWD/hercules/linux/64/bin:$PATH"
export LD_LIBRARY_PATH="$PWD/hercules/linux/64/lib:$PWD/hercules/linux/64/lib/hercules"
export HERCULES_RC=scripts/ipl.rc
hercules -d -f conf/tk5.cnf          # -d = daemon: no curses console
```

`conf/tk5.cnf` defaults `TK5CONS` to `intcons`, i.e. the MVS operator console is
device `0009 3215-C`, an *integrated* console that writes to the Hercules log —
**not** a 3270. So the operator console never competes for a 3270 connection,
and the first client to reach `CNSLPORT` lands on `00C0 3270` (a VTAM local
terminal). That satisfies the seed's "Hercules operator console stays hidden"
requirement with no extra work. `TK5CONS=extcons` (what `start_herc` sets) would
put the operator console on 3270 device `0010` and MUST NOT be used here.

Machine as configured by TK5: `CPUMODEL 3033`, `ARCHLVL S/370`, `MAINSIZE 16`
(MB), `NUMCPU 1`, DASD 3390/3380/3350 images under `dasd/`.

### Measured boot timeline (host-native smoke, box at load ~139)

| t | event |
|---|---|
| +0 s | `hercules -d -f conf/tk5.cnf` exec (12:01:49) |
| +8 s | `CNSLPORT` listening (12:01:57) |
| +47 s | `IST020I VTAM INITIALIZATION COMPLETE` (12:02:36) |
| +47 s | `IKT007I TCAS ACCEPTING LOGONS` / `IKT005I TCAS IS INITIALIZED` (12:02:36) |
| +100 s | TK5 init script (`scripts/tk5.rc`) ends (12:03:29) |

**`IKT005I TCAS IS INITIALIZED` is the readiness gate**, not the open port.
See `docs/lab/record-wave/shared-terminal-runtime.sh` for why this matters to
every sibling.

## Container (built, not yet run)

- rootfs `/data/vms/streamhost/assets/mvs38/rootfs`, 347 MB, debootstrap
  `minbase` trixie, uid-shifted to **UIDBASE 2031616** (= 31 × 65536; medley
  holds 30 × 65536 = 1966080). Siblings should take 32/33/34 × 65536 =
  2097152 / 2162688 / 2228224.
- packages: `xvfb x3270 netcat-openbsd procps iproute2 util-linux x11-utils
  xauth libbsd0 xfonts-base fonts-dejavu-core` plus, added in a second pass,
  **`xfonts-x3270-misc`** and `xterm`.
- **Trap: `xfonts-x3270-misc` is a `Recommends` of `x3270`, and
  `debootstrap --variant=minbase` does not install Recommends.** Without it
  x3270 has no 3270 font at all. Install it explicitly. (17 `3270*` fonts
  appear in `usr/share/fonts/X11/misc` when it is right.)

A single shared record-wave rootfs was considered and rejected for now: an
nspawn tree is uid-shifted ONCE to one UIDBASE, so four stations sharing one
tree would share one uid range, which weakens the isolation the
HOST-APP-CONTAINER-CONTRACT is for. Each station builds its own tree from the
same package list instead. 347 MB × 4 is cheap; a shared uid range is not.

## Resume command

```bash
cd /data/vms/sandbox/mvs38-work/repo     # worktree already exists, claims held
git fetch origin && git log --oneline -3

# STEP 1 (mandatory): re-stage a CLEAN TK5 tree — the current asset tree is dirty
ssh lab 'rm -rf /data/vms/sandbox/mvs38-work/tk5 && mkdir -p /data/vms/sandbox/mvs38-work/tk5 \
  && cd /data/vms/sandbox/mvs38-work/tk5 \
  && unzip -q /data/assets-staging/mvs38/mvs-tk5.zip \
  && cd mvs-tk5 && chmod -R a+rX . \
  && chmod +x hercules/linux/64/bin/* hercules/linux/64/lib/hercules/* mvs mvs_ipl start_herc scripts/* unattended/* \
  && rm -rf /data/vms/streamhost/assets/mvs38/tk5.staging \
  && cp -a . /data/vms/streamhost/assets/mvs38/tk5.staging \
  && rm -rf /data/vms/streamhost/assets/mvs38/tk5 \
  && mv /data/vms/streamhost/assets/mvs38/tk5.staging /data/vms/streamhost/assets/mvs38/tk5'

# STEP 2: write streamhost/stations/mvs38/{x11-runtime.sh,nspawn-inner.sh,station.env.fixture}
#   x11-runtime.sh   = medley's, with ASSETS/UIDBASE/display swapped (see "next step" below)
#   nspawn-inner.sh  = docs/lab/record-wave/shared-terminal-runtime.sh, with
#                      KH_TERM_READY_LOG_RE='IKT005I TCAS IS INITIALIZED'
# STEP 3: run it by hand on display :114, then `xwd -root -display :114` for the frame
```

## Proven by framebuffer

**Nothing for mvs38 yet.** No mvs38 frame exists. The only framebuffer proofs
this session produced were the five recovery shots in the incident below.

Proven from the Hercules log only (explicitly NOT a framebuffer proof): the
MVS 3.8j IPL completes unattended and TSO accepts logons 47 s after exec.

## Next concrete step

Write `streamhost/stations/mvs38/nspawn-inner.sh` as a thin wrapper that sets

```
KH_TERM_DISPLAY=:114
KH_TERM_WORK=/work
KH_TERM_EMULATOR_CWD=/work/tk5
KH_TERM_EMULATOR_CMD='PATH=hercules/linux/64/bin:$PATH LD_LIBRARY_PATH=hercules/linux/64/lib:hercules/linux/64/lib/hercules HERCULES_RC=scripts/ipl.rc hercules -d -f conf/tk5.cnf'
KH_TERM_READY_PORT=3270
KH_TERM_READY_LOG_RE='IKT005I TCAS IS INITIALIZED'
KH_TERM_CLIENT_CMD='x3270 -model 3279-2 127.0.0.1:3270'
```

and sources `shared-terminal-runtime.sh`; copy medley's `x11-runtime.sh` as the
outer launcher with `ASSETS=/data/vms/streamhost/assets/mvs38`,
`UIDBASE=2031616`, `SOCKDIR=/run/streamhost/x11/mvs38`, binding
`$ASSETS/tk5` and `$ASSETS/rootfs` read-only and `work/` read-write, and having
the launcher build `work/tk5` as symlinks to the read-only tree
(`conf scripts hercules jcl Packages local_scripts ctca_demo herclogo.txt`)
plus real copies of the writable dirs (`dasd log prt pch rdr tape local_conf
unattended`) — `dasd/` is the 269 MB per-launch copy and is the thing to time.
Then capture the first frame on `:114` and iterate on x3270 geometry.

## OPEN (nothing below is proven)

- x3270 crop geometry / font choice for 1024x768 — completely unmeasured.
- Whether a fresh 3270 connection lands on the TK5 VTAM welcome screen, and
  what the rest scene actually looks like.
- PF/PA/Clear key exposure through the on-screen keyboard.
- Reset/relaunch timing (the 269 MB `dasd/` copy per launch).
- Whether MVS needs a clean shutdown (`scripts/shutdown`) or tolerates a kill.

## INCIDENT 2026-09-20T09:08Z — I broke five live stations

While cleaning up the timing smoke I ran `pkill -x Xvfb` inside `ssh lab`.
**This is precisely what AGENTS.md rule 5 forbids.** It killed the Xvfb of every
`SH_CAPTURE=x11` station on the box: `medley`, `lisa`, `vision`, `perq`, `amix`.
All five went to `labctl shot: Connection refused`. No other station class was
affected (`systemctl list-units 'streamhost@*'` stayed all-active; the two
failed units, `kh-instana-forward` and `kh-trace-ship`, are pre-existing).

Recovery: `systemctl restart streamhost@<tile>` for all five. Four came back at
once. `medley` would not: its `start-pre` hit the unit's 90 s timeout on every
attempt.

**Root cause of the medley failure — a fleet-wide fragility, not a medley bug.**
`x11-runtime.sh`'s `station_vm_pids()` resolved processes by forking
`readlink /proc/<pid>/exe` once per PID. With 1322 PIDs on a box at load 139
(ten station waves at once, 16 cores) **one scan measured 13.4 s**, and the
launcher calls it to reap and again on every wait iteration — so the launcher
could not finish inside the unit's 90 s `start-pre` window. Under normal load
the same code is fast, which is why it has never been hit before.

Fix (committed on this branch, and installed live at
`/data/vms/streamhost/stations/medley/x11-runtime.sh`, old file kept as
`x11-runtime.sh.bak-2026-09-20`): resolve with a single
`find /proc -mindepth 2 -maxdepth 2 -name exe -lname "$ASSETS/maiko/*"` — still
`/proc/<pid>/exe`, never a cmdline grep, but one fork instead of 1322. Restart
then completed in **29 s**.

Verified after the fix, by framebuffer:

```
medley SHOT OK 14160 bytes
amix   SHOT OK 10344 bytes
lisa   SHOT OK  5061 bytes
perq   SHOT OK  7956 bytes
vision SHOT OK  6586 bytes
```

**Every other station whose launcher resolves processes with a per-PID
`readlink` loop has the same latent failure** and will not restart while the box
is loaded. The medley copy is fixed; the other host-app launchers
(`vision`, `perq`, `lisa`, `amix`, and any new record-wave station copied from
medley) have NOT been audited. That audit is an OPEN fleet item.
