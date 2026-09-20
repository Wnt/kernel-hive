# mvs38 guest — IBM MVS 3.8j under Hercules, on one 3270

LIVE 2026-09-20. Tier 3, **emulated but contained**, no checkpoint: the exhibit
is a mainframe emulator plus one terminal inside a `systemd-nspawn` container,
and reset is a relaunch from the pristine DASD volumes.

## Identity and source

- Public ID / station directory: `mvs38`
- Slot / UDP port / display: `214` / `54214` / `:114`
- Archetype `mono-terminal`, `ui: text-console`, keyboard family `tn3270`
- Guest: IBM OS/VS2 MVS 3.8j, the 1981 service level — the last release IBM put
  into the public domain, which is why it can be exhibited at all
- Distribution: **TK5** by Rob Prins (successor to Volker Bandke's TK3 and
  Jürgen Winkelmann's TK4-), `mvs-tk5.zip`, **498312872 bytes**, sha256
  `710d002843631322810a276dd42c793fda458548dc64d86e2914a62db7425f84`, pinned in
  `assets/mvs38/MANIFEST.sha256`. `mvstk5-update5.zip` is **not** needed: the
  base archive's own banner already reads `TK5 ... Update 5`.
- Emulator: the SDL Hyperion **Hercules 4.9.1.0-SDL that TK5 bundles** for
  `linux/64`. Debian's `hercules` 3.13 will not run this configuration.
- Builder: `scripts/build-guests/tiles/mvs38.sh` — nothing is compiled; the
  builder fetches and hashes the zip, unpacks it, restores the exec bits and
  debootstraps the container rootfs.

## Runtime and device set

`conf/tk5.cnf` as TK5 ships it: `CPUMODEL 3033`, `ARCHLVL S/370`, `MAINSIZE 16`
(MiB), `NUMCPU 1`; 3390/3380/3350 DASD under `dasd/`, a 3211 printer, a 3505
reader, a 3525 punch, a 3420 tape, and local 3270s at `00C0`–`00C6`.

Three environment values are set by the station and must not drift:

| Variable | Value | Why |
|---|---|---|
| `TK5CONS` | `intcons` | Puts the MVS operator console on `0009 3215-C`, an *integrated* console that writes to the Hercules log. `extcons` — what TK5's own `start_herc` sets — would put it on 3270 device `0010`, where it would compete for the visitor's terminal and appear on screen. |
| `CNSLPORT` | `3270` | Stock. Bound on the **container's** loopback behind `--private-network`, so it claims no host port and is unreachable from labhost. |
| `HERCULES_RC` | `scripts/ipl.rc` | TK5's unattended IPL script. `-d` (daemon) means no curses console and the whole operator log on stdout, which is the stream the readiness gate reads. |

**The readiness gate is a log line, not a port.** MEASURED 2026-09-20:

| t from Hercules exec | event |
|---|---|
| +8 s | `CNSLPORT` listening — means nothing, MVS has not IPLed |
| +55 s | `IST020I VTAM INITIALIZATION COMPLETE` / `IKT005I TCAS IS INITIALIZED` |
| +72 s | the scripted logon has the ISPF menu on screen |

`KH_TERM_READY_LOG_RE='IKT005I TCAS IS INITIALIZED'`. A client started on the
open port alone attaches 47 seconds before TSO will accept a logon. This is
finding 1 of `docs/lab/record-wave/shared-terminal-runtime.sh`, and mvs38 is
where it was measured.

## The rest scene, and why it needs driving

The exhibit rests on the **ISPF primary option menu**. Nothing gets there by
itself, and each step was a wall:

1. **Hercules paints its own device logo** on a 3270 the moment it connects,
   before the guest writes anything. Its fields are **protected**, so typing
   into them only locks the keyboard with `X SYSTEM`. `Clear` blanks the screen
   locally and unlocks it — that is the move, and it is not discoverable.
2. **VTAM says nothing until it is spoken to.** `Clear`, then `TSO`, then Enter.
3. TSO then asks for a userid, then a password, then shows the site welcome and
   a TK5 fortune, each ending in a `***` "press Enter" page. The number of those
   pages is a TK5 customisation, not a constant.

`streamhost/stations/mvs38/x3270-session.sh` drives this through **x3270's own
scripting interface** (`-scriptport`, `x3270if`), gating every step on the
screen's actual text via `Ascii()`. That matters: four consecutive screens here
differ by one line, and a lit-pixel or "did it change" wait cannot tell
`ENTER USERID` from `ENTER CURRENT PASSWORD`. Nothing waits on a sleep.

### The Hercules logo is replaced, on purpose

Stock `herclogo.txt` prints `$(VERSION)`, `$(HOSTNAME)`, `$(HOSTOS)`,
`$(HOSTARCH)`, `$(HOSTNUMCPUS)` and `$(LPARNAME)` across the top of the first
screen any 3270 sees — the emulator's version and **labhost's** name, kernel
and core count, on the museum's own framebuffer. `stations/mvs38/herclogo.txt`
keeps TK5's artwork and credits and only the two facts that belong to the
emulated machine (device number, subchannel). The launcher installs it as a
real file over the symlinked tree.

### Credentials

The station logs itself on, so it needs a TSO password. It is **not in this
repository**. `MVS38_TSO_USER` (a userid, printed on the panel, not a secret)
is in the committed fixture; the password is read from `MVS38_TSO_PASS_FILE`
(default `/data/vms/streamhost/assets/mvs38/tso.pass`, mode 0600, box-local).
The value is TK5's own stock password for that userid and is documented inside
the distribution, in `doc/MVS_TK4-_v100_Users_Manual.pdf`. Install it with:

```bash
MVS38_TSO_PASS=... scripts/build-guests/tiles/mvs38.sh --secret
```

With no such file the station still comes up and simply rests on the VTAM
screen, saying so in the log — degraded, not broken.

## The terminal, and the keyboard

x3270 as `3279-2-E` — the colour 24x80 model TSO/ISPF was written for. A 3278
would lose ISPF's colour fields; a `-4`/`-5` model gives a screen size MVS
3.8j's VTAM does not negotiate.

**The font is bounded by the root window, not chosen for looks.** A 3270 is a
fixed 80 columns, so the cell width must be ≤ 1024/80 = 12.8 px or x3270 maps
itself wider than the framebuffer and the right-hand columns are simply not in
the stream. MEASURED, menu bar off:

| font | window |
|---|---|
| `3270gt32` | 1461x816 — too big |
| `3270gt24` | 1141x614 — too wide |
| **`3270-20`** | **821x513 — the largest that fits** |
| `3270gt16` | 741x412 |
| `3270gt12` | 581x311 |
| `3270` | 741x361 |

A 3270 has no pointer and this station publishes none. Every AID key a visitor
needs is on the face of the SPA's on-screen keyboard (family `tn3270`), and the
host half of that mapping is the committed keymap in `nspawn-inner.sh` — the
two ends are one contract, not x3270's defaults.

| key | keysym sent | x3270 action |
|---|---|---|
| PF1–PF12 | F1–F12 | `PF(1..12)` |
| PF13–PF24 | Shift+F1–F12 | `PF(13..24)` |
| Enter | Return | `Enter()` |
| Clear | Alt+C | `Clear()` |
| Reset | Escape | `Reset()` |
| PA1/PA2/PA3 | Alt+1/2/3 | `PA(1..3)` |
| Attn / SysReq | Alt+A / Alt+S | `Attn()` / `SysReq()` |
| Erase EOF / Erase Input | End / Alt+E | `EraseEOF()` / `EraseInput()` |
| Dup / Field Mark | Alt+D / Alt+M | `Dup()` / `FieldMark()` |
| Tab / BackTab | Tab / Shift+Tab | `Tab()` / `BackTab()` |

### Trap 1 — `-name` silently disables every `x3270.*` resource

`-name 'MVS 3.8j'` with `x3270.menuBar: false` did nothing, and the station came
up with x3270's File/Options menu bar over a blank 3270. `-name` **replaces the
resource instance name**. The station uses loose binding (`*menuBar`) and leaves
the instance name alone.

### Trap 2 — x3270 finds a keymap only as a resource

`-keymap /work/kh.keymap` and `-keymap kh` with the file at `$HOME/.x3270/kh`
both answer `Cannot find keymap`. What works is `-keymap kh` together with a
`*keymap.kh:` resource whose value is the table with literal `\n` separators.

### Trap 3 — XK_Pause is not on the wire

The key a desktop tn3270 client gives `Clear` is `XK_Pause`, which is not in
`guestQuirks.keysymToScancode` and would have shipped as a silently dead
button. Clear rides Alt+C.

### Trap 4 — `exec VAR=val cmd` is not a thing

The shared runtime runs the emulator through `bash -lc "exec $EMU_CMD"`, and
`exec` takes the first word as the program, so an assignment prefix becomes the
command name: `PATH=...: No such file or directory`. Use `env`.

### Trap 5 — a stale nspawn export mount wedges every restart

A container that dies without its supervisor leaves
`/run/systemd/nspawn/unix-export/kh-mvs38` mounted, and the next start refuses
with `Mount point ... exists already`. From outside that is a permanently dead
exhibit. The launcher's reap clears it once nothing of ours is alive.

## Reset and standby

`SH_RESET_MODE=relaunch`, no statefile. Kill Hercules by `mame.pid`, wipe
`work/`, rebuild `work/tk5` and start again: **~103 s to the ISPF menu** at box
load 45.

`work/tk5` is a hybrid tree — the inert 254 MB (the Hercules build, the docs,
the optional packages) are symlinks into the read-only bind, and only what MVS
writes is copied. That copy is the 270 MB of DASD, and on this ZFS it is a
block clone: **~1.2 s and no space** (`zpool feature@block_cloning` is active).

PROVEN 2026-09-20:

- `ALLOC DA(VISITOR.TEST) NEW CATALOG` in the guest; `LISTDS` showed
  `HERC01.VISITOR.TEST` on volume `TSO003`. After a relaunch the same `LISTDS`
  answered `DATA SET HERC01.VISITOR.TEST NOT IN CATALOG`.
- The seed's DASD volumes hash **identical to a fresh unzip** of the pinned
  archive, either side of a session with writes — the read-only bind holds.
- Idle standby: Hercules `SIGSTOP`ped for 180 s (state `T`) and `SIGCONT`ed,
  after which TSO answered `TIME` normally.

## Driving it by hand

There is no QMP and no exec channel; `labctl shot` reads the X root. The 3270
port and x3270's script port are both container-private:

```bash
H=$(ssh lab 'cat /data/vms/streamhost/stations/mvs38/mame.pid')
# read the screen exactly as the guest painted it
ssh lab "nsenter -t $H -m -p -u -i -n -- x3270if -t 4001 'Ascii()'"
# and drive it
ssh lab "nsenter -t $H -m -p -u -i -n -- x3270if -t 4001 'PF(3)'"
```

Only while no visitor is attached.

## Security — CONTAINED (systemd-nspawn, 2026-09-20)

Own PID/mount/net/IPC/UTS/user namespaces; `--private-users=2097152:65536`
(clear of medley 1966080, indyr4400 2031616, its 2424832, vax43bsd 2490368 —
the rootfs was shifted off 2031616 during bring-up precisely because it
collided with indyr4400); `--volatile=overlay`; the TK5 tree bound read-only at
its host path; `work/` the only writable bind; `CAP_SYS_ADMIN` and friends
dropped; `--system-call-filter='~@mount'`; `--no-new-privileges`. MVS 3.8j has
no security model worth the name — the container, not the guest, is the
boundary.

## OPEN

- **ISPF help panels are missing.** PF1 on the primary option menu answers
  `PANEL NOT FOUND`. That is TK5's install, not the station, but a visitor who
  presses the help key gets an error; worth either installing the panels or
  teaching the poster not to promise them.
- **A benign startup warning in the station log.** The Athena widgets ask for a
  100dpi helvetica the minbase tree does not carry, so every launch logs
  `Cannot convert string "-*-helvetica-bold-r-normal--14-*..."`. Harmless —
  `*font: fixed` does not silence it because it comes from the popup shells —
  but it is noise that looks like a fault. Adding `xfonts-100dpi` to the rootfs
  would clear it.
- **No audio, no network, no pointer**, all deliberate.
- **PF3 from the rest scene leaves ISPF** for TSO's bare `READY`. That is
  authentic and recoverable (`ISPF` brings it back) but it means the exhibit
  does not always look like its own hero image.

## Rollback

Delete `registry/stations/mvs38.json` and `streamhost/stations/mvs38/`, rerun
`make station-registry-generate`, deploy. Nothing else in the fleet depends on
this station; the shared terminal runtime it uses is `vax43bsd`'s and is
untouched by it.
