# Add a new OS to the gallery

This is the end-to-end procedure for taking an arbitrary operating system from
source media to a reproducible, interactive streamhost exhibit. It fills the
gap between the per-guest notes in [`docs/guests/`](../guests/) and the
whole-lab rebuild in [`MASTER-REPRODUCE.md`](MASTER-REPRODUCE.md).

The canonical station registry makes repeated lineup metadata a one-entry
integration. A production station still has a build recipe, a QEMU/device set,
runtime sidecars where needed, a checkpoint, guest documentation, private
credentials outside Git, and optionally a boot video. Treat the checklist in
this document as a release gate. Do not make a station visible until its
framebuffer, input, and reset path have all passed.

Start every Tier 1–3 add with the scaffold command, then fill and prove what it
creates:

```bash
python3 scripts/stations-registry.py new <osId> \
  --tier <1|2|3> --archetype <existing-archetype-id> --slot auto
make station-registry-check
```

The command reserves `slot` and UDP `54000+slot`, writes a schema-valid disabled
candidate entry, copies the matching builder template, stubs the guest doc
and cold-boot arm, writes PLACEHOLDER poster prose (`registry/posters/<id>.md`)
with a 1024x768 placeholder hero (`spa/public/posters/<id>/desktop.webp`), and for
tier 1 scaffolds `streamhost/stations/<id>/qemu-streamhost.sh` and
`station.env.fixture` (loadvm golden, TODO media/devices) — so validate is green
the moment the entry is flipped to production. Disabled means it does not enter the streamhost, signaling,
reset, or UI lineups while its TODOs remain.

If the new station is a close relative of one already in the museum (same
archetype, same device family), scaffold from the sibling instead of the bare
Tier N template:

```bash
python3 scripts/stations-registry.py new <osId> \
  --like <siblingId> --production --slot auto
make station-registry-check
```

`--like` deep-copies the sibling's registry row, `qemu-streamhost.sh` and
`station.env.fixture`, rewrites every id/path/port that names the sibling, and
reassigns every render-order field (`signalOrder`, `stationsManifestOrder`,
`bindingOrder`, `goldenOrder`, `actionMapOrder`, `bringUpOrder`, the build row's
`order`/`defaultOrder`) to a free slot past the current max — the scaffold
that hand-copying a sibling used to get wrong. `--production` writes
`lifecycle: production, enabled: true` straight away (default, as with the bare
template, is `candidate`/disabled); `--tier`/`--archetype` are inferred from the
sibling and can be omitted. `museum`/`spa` prose is carried over prefixed
`TODO(<sib>): ` so validate stays green while the text is still the sibling's.
The paved path is now **scaffold →
fill → verify**: builders use [`scripts/lib/labqmp.py`](../../scripts/lib/labqmp.py)
for build-time QMP console/input, and clone-only checkpoint proof uses
[`scripts/lib/checkpoint-verify.sh`](../../scripts/lib/checkpoint-verify.sh).

All commands which affect labhost are examples for a planned maintenance
window. Develop and validate against a clone or scratch output first. Never
experiment against a live writable guest disk, and never use `/mnt/poc` as an
input or output.

## 0. The 10-minute procedure

**This section IS the procedure.** Target: viewable at `/os/<id>` in 5 minutes,
fully featured (listed, golden, poster, type-in demo, **absolute pointer,
retronet web plane, and an IM client signed in — all in the FIRST golden
bake**) in 10. "Fully featured" grew after the 2026-09-03 nine-station wave: a
station that ships with a relative pointer and no retronet needs a second and
third golden re-bake later — each one is a full device-set change (a new NIC or
a new pointer backend), so a new checkpoint and a new restore proof — which
measured ~2 h per station across that wave. The fix is to complete the device
set from minute 0: tap NIC (retronet) + slirp `restrict=on` (x11warp) + the
guest's own video/pointer devices, all present before the FIRST `savevm
golden`. Sections 1–8 below are the reference — open one only when a step here
fails or needs its reasoning, or the station is a harder tier than this spine
covers. Operator rules that make this legal: move fast, operator validates; a
restoring golden is enough proof; the framebuffer is the only proof a guest
reacted. Staff each stream deliberately
(AGENTS.md rule 12): `haiku-low` for mechanical rows/links/regenerate, `sonnet-low`
or `sonnet` for a builder or a doc from proven facts, Opus/Fable for the `golden`
stream of an unfamiliar guest, for any bring-up that misbehaves, and for the
poster's prose — a cheaper model that misreads the brief costs a whole 4-minute
stream, which is the one thing this plan cannot afford.

**Measure the run, never estimate it.** The clock starts at the operator's
message. After landing, run `scripts/dev/session-timeline.py` on the session
transcript (`ls -t ~/.claude/projects/<repo-slug>/*.jsonl | head -1`) and put the
measured milestones in the wave brief; the pcgeos run was reported from memory as
15/25/35 min and measured as 6/14/18.

### The two retros this procedure comes from

**bootos (2026-09-02, 45 min)** — one coordinator + 4 agents, nothing waited on
the operator. The sinks and their fixes:

| Sink (bootos) | Cost | Fix in this procedure |
|---|---|---|
| Reading playbook + sibling entries before touching anything | ~6 min | Read this section; one sibling entry, `grep` not read |
| Scaffold leaves validate failures (no poster md, no hero webp, demoProgram rules) | ~5 min | Scaffold `--like <sibling> --production` validates on the spot |
| Golden stream: key-pacing bisect | ~7 min | SKIP. Ship the fleet floor **40/40** for QEMU keyboard stations; measure only if characters drop |
| Golden stream: audio proof ceremony | ~4 min | SKIP. Declare `stream.audio`; operator hears it |
| Guest doc with ~15 TODO placeholders filled at integration from agent reports | ~4 min | One owner per file (below) |
| Separate TS+Python gate run, then the pre-push gate ran the same stages | ~5 min | Push; the pre-push gate IS the gate |
| Hand-rolled single-station emit, `current` symlink by hand, `manifests` failing inside `labrun` | ~6 min | `scripts/dev/station-up.sh <id>` |
| One cross-stream fact copied wrong by 3 streams (360K vs 720K in 4 files) | ~3 min | The ledger states measured facts (`stat -c %s` the image), never copies from a README |
| Merge conflict in the registry blurb | ~1 min | Only the spa stream edits visitor-facing prose |

**pcgeos (2026-09-02, viewable 6 min · live station 14 · featured 18)** — same
shape, and the transcript says where the 21 minutes went: **67% coordinator
model time, 24% tools, 10% waiting on agents.** The tools and the agents were
fast; the coordinator reading and writing was the cost.

| Sink (pcgeos) | Cost | Fix in this procedure |
|---|---|---|
| Hand-writing a 100-line registry entry + launcher + fixture that were the freedos ones with paths swapped; two failed scaffold runs (`--archetype` wants a SPA archetype, not a station; duplicate `bringUpOrder`) | ~4 min | `stations-registry.py new <id> --like <sibling> --production` — copies the sibling, auto-assigns every render order, validates immediately |
| Publishing the smoke rig by hand: `kh-claim` syntax, hand-written `stream.env`, hand-run daemon, guessing which manifest file to derive the entry from | ~3 min after the guest had booted | `scripts/dev/smoke-rig.sh <id> --like <sibling>` — one command, prints `/os/<id>` |
| Two streams owned `docs/guests/<id>.md`; a bad conflict resolution dropped the prose | ~1 min | One owner per file: the golden stream writes its facts into the fixture comments and its report; the docs stream runs AFTER golden (it takes 2.5 min; spa is the long pole anyway) |
| Two pushes to main, two gates, two box-deploys because the spa stream finished 3 min after the others | ~2.5 min | The coordinator ships the hero from its own smoke frame in the ledger commit; spa polish lands in one push with everything else or in the next wave |
| `station-up.sh` gave up 14 s before the daemon printed LISTENING; rerun | ~1 min | station-up polls up to 60 s |
| `labctl key ctrl-esc` / `ctrl+esc` / `ctrl-escape`: three failed guesses | ~1 min | qcodes are space- or `+`-separated: `labctl key <id> ctrl esc`; the error now says so |
| `here.sh` printed 60 claim lines, 50 of them stale, paid for on every turn | model time | stale claims are folded into one summary line |
| Memory notes + a long final report written serially after the station was featured | ~2 min | Off the clock: hand the retro to a `sonnet-low` agent with the transcript and `session-timeline.py` |
| 99 s idle "waiting for agents" | ~1.5 min | Use the wait: draft the framebuffer-proof commands and the report while streams run |

### Minute 0–3: spine (you, alone)

```bash
scripts/dev/wt.sh new <id> --from origin/main            # full stack + KH_SESSION=<id>
scripts/dev/wave.sh alloc <id> --retronet --x11warp      # ONE atomic claim: slot/UDP/VMID,
                                                           # x11warp display :<slot-100> (loopback 6<slot-100>),
                                                           # retronet 10.99.0.N + MAC + tap <id>rn0 + chain
                                                           # <ID>RN-IN + ICQ UIN <slot>00 — appends local.env,
                                                           # re-renders DHCP, prints the ledger row + .wave.env
# stage media: fetch, hash, keep the byte size — it is a ledger fact
ssh lab 'mkdir -p /data/assets-staging/<id> && cd /data/assets-staging/<id> && sha256sum * > MANIFEST.sha256 && stat -c "%n %s" *'
# smoke boot in YOUR sandbox with the sibling's device set PLUS the tap NIC + x11warp slirp line
# from .wave.env (vom-reference.md names the emulator/machine; os-media-catalog.md may already hold
# the recipe — pcgeos's was there). Launch exactly as the sibling's launcher does (dbus display,
# -qmp unix:<sandbox>/smoke/qmp.sock, namespaced -name), then:
python3 scripts/dev/qmp-type.py --qmp smoke/qmp.sock 'dir\n' && qmp screendump smoke/frame.png
# PUBLISH THE SMOKE RIG NOW — this is the 5-minute target: operator watches /os/<id>
scripts/dev/smoke-rig.sh <id> --like <sibling>            # claims slot/port/vmid, stream.env, daemon, dark-launch
python3 scripts/stations-registry.py new <id> --like <sibling> --production --slot auto   # validates on the spot
scripts/retronet/rn-onboard.sh <id> --address 10.99.0.N --mac <mac> --uin <uin> \
  --planes web,icq --apply     # rn-tapnet.sh from the template, launcher netdev lines, registry
                                 # retronet block, ICQ account, docs/lab/retronet/STATION-<id>.md
```

Then the ledger commit on branch `<id>`: `docs/lab/<ID>-WAVE.md` with the allocation
table (slot/UDP/VMID/display/retronet address+MAC+UIN as printed by `wave.sh alloc`,
render orders as assigned, device set, measured media size, upstream pin), the
scaffolded entry with only the fields that differ from the sibling edited (media,
museum, spa, reset fixture), the launcher and fixture (tap NIC + slirp
`restrict=on` + x11warp already wired), **and the hero**
(`spa/public/posters/<id>/desktop.webp` from the smoke frame — a 4:3 upscale is
fine; the spa stream replaces it if it does better), and the stream table below.
Commit, push (recipe below). Do not fix validate failures by hand for more than
one minute — leave the field as the scaffold wrote it and assign it to a stream.

### Minute 3–7: 3–4 parallel streams off the ledger, each with a 4-minute stop

Each: `scripts/dev/wt.sh new <id>-<stream> --from <id>`, commit on its branch, push,
report the branch. **Hard stop at 4 minutes** — report what is proven and what is
not; the coordinator ships what exists. **One owner per file**: the table names it;
a stream that needs a fact from another stream's file reads it from the ledger or
waits for that stream's report — it never edits the file.

| Stream | Owns | Skips by default |
|---|---|---|
| `build` | `scripts/build-guests/tiles/<id>.sh` (pinned fetch, SHA-256, compose disk, framebuffer-verify boot); RUN it so the pristine output exists; `check-assets.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` rows | No bisecting machine types — use the device set from the ledger |
| `golden` | bake `golden` on a sandbox clone with the **complete** device set from `.wave.env` (tap NIC + slirp `restrict=on` + x11warp, wired by `rn-onboard.sh` in the spine): one `loadvm` restore proof, one `scripts/dev/x11warp-probe.py` two-target warp+readback proof, `scripts/retronet/rn-verify.sh <id>` green, an IM client signed in and visible in the scene (`docs/lab/retronet/ICQ-CLIENTS.md` has the proven client per era/OSCAR-vs-legacy-door); stage the disk into the station dir; `bootrec-tiles.conf` arm; registry `runtime`/`reset`/`operator`/`retronet` truth; the checkpoint facts go into `station.env.fixture` comments and its report — NOT the guest doc | Pacing bisect (ship 40/40), audio proof (declare it), reset-N-times loops |
| `spa` | `registry/posters/<id>.md`, a better hero + extra frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram`; the only stream that edits visitor-facing prose | Playtesting the demo beyond one `labctl type` + `shot` |
| `docs` (start when `golden` reports) | `docs/guests/<id>.md` including §Checkpoint from golden's report, `GUEST-TIERS.md`, release-notes JSON, `docs/README.md` index | — |

The GUI wizard an IM client needs (server host/port, screen name, password) is
driven the same way any keyboard-only GUI is driven on these guests:
`x11warp-probe.py --warp X Y --click --qmp <sock>` places the X pointer where
`XQueryPointer` confirms it landed, then a button-only QMP event clicks there —
never a QMP `abs` move, which several of these window managers ignore. A
wizard that cannot be reached this way (freebsd411/Kopete 0.9.1, 2026-09-03) is
an OPEN item for the stream to report, not a wall to grind on inside the
4-minute stop.

**When a stream hits a wall (netbsd14, 2026-09-03: the installed kernel hung in
the ISA probe after `lpt0`, and the golden agent bisected it one reboot at a
time), the stream STOPS and reports the frame; the coordinator races it** —
OPERATING-RULES §13: theories written down, one cheap agent per theory on its
own `scripts/dev/rig-clone.sh new <id> <theory> [-- qemu args]` clone, 3-minute
stops, `rig-clone.sh keep <id> <winner>`. Inside every stream, waits are
`scripts/dev/fb-wait.py --qmp <sock> --settle S` / `--change` on the box, never
`sleep N` then look: the boot prompt's 5-second window and a 40-second stare at
a hang are the same mistake. Three more pitfalls from that run: the golden brief
carried install + X config + bake in one agent — split it at the first
framebuffer that differs from the sibling's; `/data/assets-staging` is a
different mount inside CT950 than on labhost, so give a stream the measured
hashes and sizes inline instead of a path; and a stream that reports "hard stop
reached" after two minutes has stopped early — resume it with the missing facts
rather than redoing its work.

**When the station needs a real OS install (debian22, 2026-09-03: 93 active
minutes, nine concurrent waves), time the installer's FIRST disk write in the
spine.** A Linux 2.2 guest kernel writes the emulated IDE disk in 16-bit PIO
under KVM at ~27 KB/s (one VM exit per `outw`); its `mke2fs` never finishes and
two golden agents burned their budgets on it before racing. The route that
works, from minute 3: compose the root filesystem ON THE HOST (`mke2fs -I 128`,
the release's base tarball, `dpkg-deb -x` a Depends closure of the desktop
packages from the ISO, boot the CD kernel with `root=/dev/hda1`) — recipe
`scripts/build-guests/tiles/debian22.sh`; the XFree86 3.3.x trap list is in
`docs/guests/debian22.md` §Install recipe — hand it to the next 1990s Linux/BSD
stream before it boots anything. Give such a golden stream one agent and a
30-minute stop, not two racing agents with 4-minute stops.

Facts flow one way: a stream that *measures* a fact corrects the ledger in its own
commit and says so in its report; nobody copies a number from a README. While the
streams run, the coordinator is not idle: it prepares the framebuffer-proof
commands, the merge order and the report skeleton.

### Minute 7–10: integrate and ship (you)

```bash
# merge the stream branches into <id> (ledger is a union; generated files: regenerate, never hand-merge)
git merge --no-edit origin/<id>-build origin/<id>-golden origin/<id>-spa origin/<id>-docs
# the whole landing window as one command, run from the /data sandbox worktree:
# wave.sh land begin -> fetch+merge main -> rebuild the two SPA tables at the lineup
# position (spa-scene-rows.py <id>, never a union) -> validate+generate -> vitest ->
# push main (pre-push gate is the gate) -> box-deploy --apply -> stop unit, park the
# old disk, copy in --golden -> smoke-rig --down -> station-up.sh -> re-home claims
# from $KH_SESSION to the station session -> proofs (labctl shot; x11warp-probe
# two-target; rn-verify.sh) -> SPA build+deploy -> re-arm every OTHER wave's
# darklaunch.d overlay -> wave.sh land end
scripts/dev/station-land.sh <id> --golden /data/vms/sandbox/<id>-golden/disk.qcow2
```

`station-land.sh` prints what each step did and stops at the first failure with
a rollback line (launcher + disk are one unit). It IS the landing lock —
`wave.sh land begin` blocks until any other wave's window is free instead of a
person relaying "ready to land" → "go" → "landed"; `wave.sh land status` shows
who holds it and since when.

Land main **once**. If one stream is late, ship without it and let it land in the
next wave; a second `station-land.sh` run costs ~2.5 minutes.

Done means: `/os/<id>` shows the real station with an **absolute** pointer, on
the **retronet web plane**, with an **IM client signed in** — the station-land
proofs (`labctl shot`, the x11warp two-target readback, `rn-verify.sh`) are what
prove it, not a log line — the grid lists it, the smoke rig is down and the
stream sandboxes are removed (`wt.sh rm <id>-<stream>`; the claims for
slot/port/VMID/display/retronet pass to the station session), and the report
names the checks above with measured times from `session-timeline.py`.
**The IM proof is not "signed in once" — it is "signed in AGAIN after a
reset"**: `labctl reset <id>` (`loadvm golden`) restores the checkpoint with
the OLD TCP socket, which the server has already dropped, so the client must
notice and reconnect, not just sit on stale state. Proof = TWO things:
`labctl reset`, wait up to 4 min AWAKE (hold a wake lease; an idle-paused guest
never counts the seconds), then `labctl shot` shows the client online (not
"signed off" or a login dialog) AND a NEW `login successful uin=<uin>` line
dated after the reset in the gateway's ICQ journal (CT 951; `rn-verify.sh <id>
--icq <uin> --since <reset-ts>`). The frame alone lies: suse64's GtkICQ showed
"Online" for minutes while the gateway answered every packet NOT_CONNECTED.
The same reconnect fires in steady state: an idle-paused station sends no
keepalives, the gateway reaps its session, and the client must re-login on
wake (debian22's GnomeICU did, unaided, in ~2 min).
Measured: Gaim 0.59.9 reconnects at ~3 min by itself, Kopete 0.12 at ~1 min,
mICQ 0.4.12 at ~70 s; Gaim 1.0 and GtkICQ 0.60 never (autorecon plugin /
restart wrapper needed); micq 0.4.3 exits, so an exit-driven loop works.
Tear-down is part of done.

### Push recipe (3 lines)

1. `SKIP_GATE=1` ONLY on feature branches (`<id>`, `<id>-*`); never on `main`.
2. `GIT_SSH_COMMAND="ssh -i /home/wnt/.ssh/id_github -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20" git push -u origin <branch>`
3. Push `main` from a `/data` worktree (`/data/vms/sandbox/<name>/repo`, `git push origin HEAD:main`), never the shared clone — the box-state gate needs it.

### What NOT to skip

The golden must restore once (`loadvm golden` on the exact device set); the
launcher must be the one the golden was baked with; addresses stay placeholders
(`192.0.2.10`, `labhost`); every claim goes through `kh-claim`; the framebuffer
is the proof, not a log line.

### Several waves at once: the tools (2026-09-03, nine stations, then tooled)

Nine station waves ran in parallel on one box (pcbsd, ubuntu, slackware,
netbsd14, redhat62, openbsd, freebsd411, debian22, suse64) behind one
coordinator session that did nothing but relay traps and run two single-run
fleet steps (see [`WAVE-COORDINATION.md`](WAVE-COORDINATION.md)). What that
run cost — ~150 coordinator messages over ~9 hours of allocation bookkeeping,
landing serialisation and status sweeps, most of it mechanical — is now three
tools instead of a person. A wave session runs itself:

- **`scripts/dev/wave.sh alloc <id> [--retronet] [--x11warp]`** replaces
  hand-assigned slots. It is the single atomic claim for everything a wave
  shares (slot/UDP/VMID, the X-warp display, and with `--retronet` the
  10.99.0.N address, MAC, tap, chain and ICQ UIN), appends the BOX-side
  `local.env` rows and re-renders retronet DHCP in one call, and refuses
  loudly if anything is already held — two waves starting in the same minute
  can no longer collide on `--slot auto`.
- **`scripts/dev/wave.sh land begin/end/status`** replaces the "ready to
  land" → "go" → "landed" relay with a `kh-claim` FIFO queue on the box: a
  wave blocks (bounded poll, never a guessed sleep) until the landing window
  is free, and a stuck window past N minutes prints a chase hint on its own.
  `station-land.sh` calls `begin`/`end` around the whole window, so a wave
  never runs `box-deploy --apply` — the one command that reverts every OTHER
  wave's uncommitted live edits — outside a window it actually holds.
- **`scripts/dev/station-land.sh <id> [--golden …] [--merge …]`** is the
  window itself: fetch+merge main, gate, push, deploy, golden swap,
  `station-up`, claim re-homing, proofs, SPA deploy, and re-arming every OTHER
  wave's `darklaunch.d` overlay (the SPA-deploy trap) — one command instead of
  the eight hand-run steps that used to cost 5–25 minutes per landing, most of
  it the pre-push gate re-run (shfmt, ruff, the scene tests) and hand-resolving
  the four append-only shared files (`assembliesByTile.ts`,
  `machineIdentity.ts`, `release-notes*.json`, `bootrec-tiles.conf`). Its
  `spa-scene-rows.py <id>` rebuilds the two SPA tables from main's table plus
  this station's row **re-inserted at its lineup position** — never a union,
  which is what used to double a row. The scene test then wants a **distinct
  hardware tuple** (body|monitor|keyboard|mouse) per station: `new --like`
  refuses (or takes `--tuple`) when a copy would keep the sibling's.

What still needs a human, because the tools cannot decide it: the **load
rule** (operator) — saturating the cores is fine, 1-min load above 50 means
scale down; each wave holds at most three guests, a race is three runners and
the losers die on the first frame, nothing hung is left spinning — and
**cross-wave relay** of a finding that applies to a sibling wave (two KDE 3
installs, three XFree86 3.3.6-on-cirrus desktops told each other directly in
2026-09-03; the tools do not read each other's frames for you). See
[`OPERATING-RULES.md` §14](OPERATING-RULES.md#14-parallel-waves) for the
reasoning behind the load rule and the landing lock, and
[`WAVE-COORDINATION.md`](WAVE-COORDINATION.md) for the message protocol
reduced to what the tools cannot do (the resume-after-usage-limit recipe
included). [`WAVE-TEMPLATE.md`](WAVE-TEMPLATE.md) is the wave-brief skeleton
every wave copies.

Facts every 1990s guest wave paid for once and should not pay again:

| Wall | Measured cause | Fix |
|---|---|---|
| Linux 2.2 / FreeBSD 4.x install crawls (70 KB/s CD or disk) | 16-bit PIO is a KVM exit per `outw`; no KVM-side flag helps | Install under `-accel tcg` (~20x faster), bake the golden under the shipped launcher; FreeBSD 4.11 has no busmaster DMA on PIIX3, so its station disk lives on `lsi53c895a` (sym) |
| Installed Linux 2.2 loops `hda: lost interrupt`, keyboard "not present" | anaconda / YaST install the **SMP** kernel on `-smp 2`; IO-APIC routing on i440fx with `acpi=off` drops IRQs under both accels | Boot the **UP** kernel (`noapic` also works); with `hdparm -d1` PIIX DMA runs 58–70 MB/s under KVM, so the station stays KVM |
| OpenBSD 7.9 drops key releases under X | `-smp 2` on the i440fx IOAPIC loses keyboard IRQs | `-smp 1` (or `acpi=off`); pick one vCPU first for any 1990s guest |
| `mke2fs` of a 4 GiB root takes 17 min | same PIO path | 1.5–2 GiB disk, or compose the root filesystem on the host (`mke2fs -I 128 -O none -d <tree>`; 2.2 rejects 256-byte inodes) and boot the CD kernel |
| `-kernel <2.2 bzImage>` hangs at "Booting from ROM" | both accels | boot from a boot loader on the disk; `sendkey spc` (not shift) stops LILO's timeout |
| xterm text does not paint on XF86_SVGA + cirrus 5446 | BitBLT path | `Option "no_bitblt"` (depth 8 and 16 proven) |
| Typed characters drop under XFree86 over QMP | 40/40 key pacing floor | 60/60 measured on wscons+X (netbsd14); measure, ship the number |
| Pixel-diff pointer proof passes a pointer that never moved | X root cursor parked at screen centre after startx | take the reference frame after moving to a corner; prove two targets |
| `stations-registry.py new --like` left `operator.labctl.dir` on the sibling | slash-anchored rewrite | fixed 2026-09-03; the scaffold test covers the bare dir |
| x11warp's slirp NIC hands the guest a default route via 10.0.2.2 (the host stack), which fights the tap's own DHCP route | the guest chooses whichever NIC answered last | `restrict=on` on the x11warp `-netdev user` (hostfwd still works); the tap's DHCP lease/resolv.conf must win. Pre-DHCP guests keep the retronet reservation anyway — it is the uniqueness ledger, not a live lease |
| `RETRONET_DHCP_RESERVATIONS` edited in local.env is not live for the next boot | `install-dhcp.sh` has not re-rendered `/etc/retronet/dhcp.env` in CT 951 yet | `wave.sh alloc --retronet` re-renders it as part of the atomic append; a guest that boots before the render leases the pool's `.101` instead of its reservation |
| First retronet launch dies with no MAC | the launcher reads `RN_<ID>_MAC` from the BOX-side `/data/kernel-hive/registry/local.env`, not a CT-side copy | `rn-onboard.sh` writes it to the right side; check the BOX file, not CT951's, when a launch fails on the NIC |
| `qmp-type.py` types Enter/Tab instead of the literal characters `\n`/`\t` | the tool decodes `unicode_escape` by contract, so a typed `printf 'a\nb'` or heredoc line lands as one line | write guest config with `sh -c '{ echo l1; echo l2; } > f'`, type `\\` for a literal backslash, or use `qmp-type.py --raw` |
| A keyboard-only GUI wizard (IM client server/screen-name/password) cannot be reached with QMP `abs` events on these guests | several window managers ignore an absolute QMP move | `x11warp-probe.py --warp X Y --click --qmp <sock>`: warp the X pointer (readback via `XQueryPointer`), then send a button-only QMP event — the click lands where X thinks the pointer is |
| A station with no viewer answers no TCP on its X display when probed | idle-pause stops the guest (QMP `stop` / SIGSTOP) after ~2 min | probe with a wake lease, or view `/os/<id>` live; the daemon log line is `[idle] driver active but guest paused -> resumed` |
| A landed station's claims (tap, chain, retronet address, slot/port/vmid) are still held by the wave session | claims are not transferred automatically | `station-land.sh` re-homes them from `$KH_SESSION` to the station session; the next `kh-claim` on the wave session would otherwise say "not yours" |
| An unproven `rn-tapnet.sh` committed anyway gets deployed fleet-wide | `box-sync-pairs-retronet.sh` is one glob loop over every committed `rn-tapnet.sh`, not a hand-maintained row per station | commit a station's `rn-tapnet.sh` only once that station is proven (openbsd, 2026-09-03, deliberately withheld it) |
| Host ping to a retronet address "succeeds" or "fails" and neither proves the station is on the plane | containment: the tap is not routed to the host | the real check (`rn-verify.sh`): tap UP with master `vmbr-rn`, the systemd unit active, the tap named in the launcher/env, the reservation rendered in CT 951's `dhcp.env`, and the MAC seen on the bridge fdb while the guest is awake |
| An IM client that was signed in when the golden was captured shows signed OFF (or a login dialog) after `labctl reset` | `loadvm golden` restores the checkpoint with the OLD TCP socket, already dropped by the server; the client must notice and reconnect, not sit on stale state | Gaim 0.59.9 (redhat62) signs off and does not retry — needs a watchdog; micq (slackware) with a watchdog and mICQ 0.4.12 (netbsd14) both re-log in within ~70 s unassisted. Proof is `labctl reset` → wait up to 90 s awake → `labctl shot` shows the client online, not "signed in once" at bake time |

## 1. Current scope and candidate backlog

`registry/stations/` is the source of truth for the current lineup. Each entry has
an explicit `lifecycle`; `streamhost/stations-manifest.sh` is generated from its
production entries rather than maintained as an independent inventory. At the
current registry revision, `python3 scripts/stations-registry.py count` reports
**39 lineup entries: 37 streamhost production stations and 2 showcase posters**.
Use that command for the current roster count and `labctl ls` for observed live
service state; do not copy the number into another inventory.

### Two standing constraints on every add

**Source your own media.** Install ISOs, floppies and ROMs are fetched from the
lab's archival sources and recorded with hashes in
[`../catalog/os-media-catalog.md`](../catalog/os-media-catalog.md); the operator
supplies only Windows licensing. Pre-built collections are **reference material,
not a supply** — but read the reference first: the Virtual OS Museum
([`research/vom-reference.md`](research/vom-reference.md)) has 1703 working
installations and usually already answers which emulator, which machine and
which settings this OS needs, plus an attribution index pointing at each image's
real upstream. It is CC BY-NC-SA and this repo is MIT and public, so **read the
facts and write our own recipe; never copy its files, configs or argument
strings**, and never take a disk image, ROM or media file from it.

**Land host-native.** The shipped form of every station is direct framebuffer
capture plus input forwarding — Tier 1 (QEMU over dbus) or Tier 3 (the emulator
running on the host with `-video none`). A Debian/trixie kiosk running the
emulator inside a captured Linux guest is acceptable **only as a throwaway
proof-of-concept**, to prove an emulator reaches a desktop at all, and must not
be the form the station ships in. The 28 remaining Tier-2 bridges are a legacy
population being converted
([`DEBRIDGE-CONVERSION-BRIEF.md`](DEBRIDGE-CONVERSION-BRIEF.md)), not a pattern
to extend. Plan the host-native path before you build the PoC, and say in the
station's guest doc what the host-native capture path will be.

Difficulty tiers used below:

- **Tier 1 — direct:** pinned live ISO or prebuilt free disk; stock QEMU devices;
  deterministic framebuffer in minutes.
- **Tier 2 — install:** ordinary unattended install or offline image injection;
  no new guest driver. (A captured-Linux emulator bridge is a PoC step here, not
  a delivery form — see the standing constraints above.)
- **Tier 3 — legacy/gated:** licensed or account-gated media, fragile old
  drivers, manual calibration, multiple install stages, or a non-QEMU backend.
- **Tier 4 — research:** emulator incompatibility, bespoke kernel/device work,
  or a platform whose streaming path has not yet been designed.

The planned/recovery set is:

| OS / exhibit | State and blocker | Rough tier |
|---|---|---|
| `macos` | Showcase poster. The proven Sequoia VM 925 and VNC/WebSocket bridge were deleted; recreation needs Apple-compatible OpenCore/QEMU work, substantial disk space, and a new streamhost-era capture path. Tahoe is not viable without working accelerated graphics on this host. | **4** |
| `nextstep` | Not live and not in the UI lineup. The builder reaches device detection, but NeXTSTEP 3.3 loses IDE/SCSI I/O under current QEMU; the likely paths are a QEMU 0.9 sidecar or Previous plus a licensed NeXT ROM. The ISO is also not staged. | **4** |
| `riscos` | Showcase poster. Its former RPCEmu/neko backend was retired. ROOL media and a builder exist, but it needs a streamhost-compatible captured-Linux/RPCEmu bridge and a new checkpoint. | **3** |
| `win11` | Showcase poster. VM 900 was deleted with the legacy RDP/neko path. Re-entry needs user-supplied licensed media plus a supported UEFI/TPM guest and streamhost/RDP capture design. | **3–4** |
| `winxp` | Fully registered and previously built, but currently inactive. A clean rebuild is blocked on the operator's licensed XP SP3 ISO, product key, and administrator password; the consumed ISO has no recorded hash. | **3** |
| `sailfishos` | Fully registered and previously built, but currently inactive. A clean two-stage rebuild needs an account/EULA-gated Sailfish SDK emulator VDI; the source VDI was not retained. | **3** |

`amiga500` is not a missing candidate: it is the active production station
`amiga`, a Debian kiosk running FS-UAE with Kickstart/Workbench. It is distinct
from the active x86 AROS station `aros`. It is also one of the bridges still
awaiting conversion — read it to understand FS-UAE's media and settings, but
build new emulator stations host-native (the nine converted MAME stations are
the template).

Candidate details and the live bridge distinction are recorded in the existing
guest notes: [`macos.md`](../guests/macos.md),
[`nextstep.md`](../guests/nextstep.md),
[`riscos.md`](../guests/riscos.md), [`win11.md`](../guests/win11.md),
[`winxp.md`](../guests/winxp.md), [`sailfish.md`](../guests/sailfish.md),
and [`amiga500.md`](../guests/amiga500.md). These notes include historical
neko-era material; the canonical registry and a current read-only `labctl ls`
result take precedence for lineup and live status respectively.

[`docs/guests/UNDOCUMENTED.md`](../guests/UNDOCUMENTED.md) is a documentation
gap list, not a candidate list: its rows are already-live stations. At the time of
this inventory its heading says seven but its table contains six (`android`,
`postmarketos`, `serenityos`, `toaruos`, `win2000`, and `win311`).

## 2. Establish identity and acceptance criteria

Choose these names before downloading anything:

```text
builder key   lower-case build-all key, e.g. solaris-cde
osId          public SPA/signal/reset identifier, e.g. solaris
stationDir       runtime directory and systemd instance — MUST equal osId
displayName   museum label, e.g. Solaris CDE
```

`osId` and `stationDir` are the same string, and `stations-registry.py` fails
validation if they differ; the builder key may differ (it names a build script,
not a running station). The two exhibits that once diverged
(`solaris` → `solariscde`, `aros` → `amigaos`) required repeated special-case
mapping and should not be copied.

Write the acceptance criteria into `docs/guests/<os>.md` before implementation:

- exact stable release, architecture, source/license class, and expected hashes;
- canonical output disk/ISO path;
- pinned QEMU binary, machine, accelerator, CPU, display, storage, NIC, audio,
  and input devices;
- the exact GUI/console state that proves success in a framebuffer;
- reset mode: `loadvm` with snapshot `golden`, or deterministic `restart`;
- pointer path and a visible motion/click/drag test;
- whether a login exists, with values kept outside Git;
- optional boot-video ready state and zero-input policy.

A serial log is supporting evidence, not proof that a graphical exhibit works.
The final gate is the captured framebuffer seen by streamhost.

## 3. Acquire and record media

### 3.1 Select the source

At execution time, re-check the upstream and select the latest **stable**
release that the guest can actually run. Do not interpret a nightly, rolling
`latest`, beta, or an old URL already present in a script as stable without
checking. If the newest stable release regresses under the pinned QEMU, document
the failing framebuffer evidence and pin the newest proven-compatible stable
release instead (ReactOS is the existing pattern).

**The normal mode is that the AGENT researches and sources the media.** Do not
stop and ask the operator to hand you an ISO or a ROM — find it, verify it,
record its provenance. The archival sources this lab uses are listed at the top
of [`docs/catalog/os-media-catalog.md`](../catalog/os-media-catalog.md)
(archive.org, WinWorld, Macintosh Garden / Macintosh Repository, TUHS,
fsck.technology, PalmDB, and the canonical project release pages). Operator
staging is the **exception**, not the default, and it applies only to the
`licensed` and `account/EULA gated` classes below — today that is essentially
just Windows media (`win11`, `win2000`, the `w2kalpha` beta). Preservation-class
media is agent-sourced like anything else.

Classify every external input:

- **free/open:** fetch from the canonical project/release service and verify the
  publisher's checksum or signature;
- **licensed:** require the operator to stage their own media; never commit it,
  embed a key, or invent a public mirror;
- **account/EULA gated:** accept an explicit local path/environment variable and
  fail with a precise staging message;
- **preservation source:** record provenance, copyright status, stable item URL,
  size, and a locally measured SHA-256. Treat the artifact as private unless its
  redistribution terms are clear.

**Pulling one file out of a huge preservation set.** archive.org's download
endpoint can extract a single member from a ZIP stored at an item's root:

```text
https://archive.org/download/<item>/<file>.zip/<path-inside-the-zip>
```

On the MPF-II add this fetched a 16 KB ROM in 1.4 s instead of a 20 GB merged
MAME set. It works only where the item stores per-game ZIPs at its root
(`MAME_0.224_ROMs_merged` does); a `.tar.gz` item cannot serve it, because gzip
is not seekable. In a **merged** MAME set a clone's ROM lives in the **parent's**
ZIP — `mpf2` ships inside `tk2000.zip` — which is the usual cause of a
"ROM not found" after an otherwise correct download.

**The media can answer questions the wiki cannot.** Dumping the BASIC keyword
table straight out of `mpf_ii.rom` proved the MPF-II carries the full Applesoft
graphics set (`HGR`, `HCOLOR`, `HPLOT`, `DRAW`), which decided what its demo
program could use. Before trusting a secondary source about what a machine can
do, look in the ROM.

### 3.2 Stage and hash

Use `/data/assets-staging/<osId>/` for the immutable intake copy. Builders
should place or derive their canonical artifacts beneath
`/data/gallery-guests/<GuestName>/`; only shared live ISOs which launchers
explicitly reference belong under `/data/isos/`.

```bash
# On labhost, after you have fetched the media (or, for the licensed/EULA-gated
# exceptions only, after the operator has staged it).
install -d -m 0750 /data/assets-staging/<osId>
sha256sum /data/assets-staging/<osId>/<media> \
  | tee /data/assets-staging/<osId>/MANIFEST.sha256
sha256sum -c /data/assets-staging/<osId>/MANIFEST.sha256
```

Record the filename, full SHA-256, size, license class, canonical source, stage
path, builder, and **environment-variable names only** in
[`docs/lab/ASSETS-MANIFEST.md`](ASSETS-MANIFEST.md). Extend
`scripts/build-guests/check-assets.sh` so `build-all.sh --check-assets --only
<key>` fails before a long build. Do not print or record product keys,
passwords, tokens, private keys, or private download URLs.

The builder must download to a temporary filename, verify it, then atomically
move it into the cache. A size-only check is a last resort and must be called
out as a reproducibility gap.

## 4. Author `scripts/build-guests/tiles/<os>.sh`

The scaffold has already copied a tier-specific starting file here. Fill its
TODOs rather than copying another complete builder. Import `labqmp.QMPClient`
from `scripts/lib/labqmp.py`, or invoke its qdrv-compatible CLI from shell. It
provides the single keymap plus `type`, `sendkey`, `screendump`, `savevm`,
`loadvm`, `hostfwd_add`, and `assert_idle_deterministic`. This is the
**build-time** helper; it does not replace the operator-side `/root/cdrv.py`
used by `labctl` on labhost.

Make the builder idempotent, fail-fast, and isolated. It must own a namespaced
work directory, unique sockets and ports, and a pidfile. Stop only its own QEMU
through QMP/HMP or its pidfile; never use `pkill qemu` or a shared fixed socket.
Support an explicit force/rebuild option and a verification opt-out consistent
with existing builders.

Register the builder through `build.rows` in
`registry/stations/<osId>.json`; `scripts/build-guests/build-all.sh` is generated
from those rows, including `DEFAULT_ORDER`. The rendered row fields are:

```text
KEY | SCRIPT | OUTPUT_DIR | CLASS | EST_TIME | AUTOMATION | PRODUCES [| media]
```

Use these templates by difficulty:

| Tier | Start from | Why |
|---|---|---|
| 1 | `alpine.sh`, `kolibrios.sh`, `reactos.sh` | Stable-media resolution, checksum validation, LiveCD/scratch snapshot, automated framebuffer gates. |
| 2 install | `haiku-install.sh`, `win2000.sh` | Real install, scene provisioning, final device-set snapshot and restore proof. |
| 2 bridge | `bridge-base.sh`, `c64.sh`, `amiga.sh`, `streamhost/docs/BRIDGE.md` | Captured-Linux kiosk around a non-QEMU architecture/emulator. |
| 3 graphical | [`scripts/install-vision/README.md`](../../scripts/install-vision/README.md) plus `redstar3.flow.yaml` | Declarative screenshot/OCR/template state machine, capture helper, optional dialogs, secret injection, and framebuffer checkpoints. |
| 3 unattended | `win2000.sh` plus `docs/lab/research/unattended-install-win2000.md` | Secret-free answer-file template; secrets supplied only at execution. |
| 3 legacy | `os2warp.sh`, `win95.sh`, `win98.sh` | TCG/legacy chipset, old display/audio/input drivers, exact checkpoint parity. |
| 4 negative research | `nextstep.sh` and `docs/guests/nextstep.md` | How to retain a reproducible failure without advertising a broken station. |

For the two nontrivial automation styles, also read
[`unattended-install-win2000.md`](research/unattended-install-win2000.md) and
the declarative [install-vision guide](../../scripts/install-vision/README.md).

### 4.1 Pick a pinned virtual machine

Start with the smallest plausible device set and change one variable at a time.
The builder's final QEMU launch and the production launcher must enumerate the
same guest-visible devices and properties.

**Machine and accelerator decision:**

1. Use KVM first for a normal x86/x86_64 guest. Confirm `/dev/kvm` and boot with
   the final CPU model.
2. If an old kernel hangs, triple-faults, depends on historical timing, or has a
   known virtualization incompatibility, reproduce the failure under a clone
   and try `-accel tcg`. OS/2 Warp is the reference TCG-only guest. Do not choose
   TCG merely because installation automation is slow.
3. Use the oldest chipset the guest has drivers for: i440fx/`pc` for most legacy
   systems, q35 for guests that require newer PCI/UEFI behavior.
4. Resolve the alias to the host's current versioned type (today's rebuild uses
   `pc-i440fx-11.0` or `pc-q35-11.0`) and pin it. Re-check on a future QEMU
   upgrade; do not silently retarget an existing checkpoint.
5. Pin CPU model, vCPU count, memory, ACPI/APIC/USB properties, RTC behavior,
   firmware/varstore, and boot order. A change to any guest-visible device can
   invalidate `loadvm golden`.

**Display decision:**

1. Prefer a device with an inbox driver in the target release, not the newest
   emulated GPU. Test the install mode and the final desktop mode.
2. Modern/hobby guests with VBE support can begin with `-vga std`. If a fixed
   canvas is required, use an explicit `-device VGA,...,edid=on,xres=...,yres=...`
   and omit built-in VGA (`--vga none`); Haiku is the reference.
3. NT-era and older guests should use the device their installed driver expects
   (`cirrus` is a common safe choice). **Win9x must not ship on bare `-vga std`
   merely because setup renders:** its 16-colour planar std-VGA path has shown
   tearing. Use `-vga cirrus`, or install and framebuffer-prove a VBE/VBEMP
   driver before selecting `std`.
4. If the desktop is black, corrupted, palette-torn, or only partially updated,
   change the emulated adapter/guest driver before changing capture code.
5. Verify with QMP `screendump` and the streamhost D-Bus capture. A VNC view or
   guest log alone does not establish framebuffer compatibility.

**Kiosks — fitting an emulator window to the captured root.** The
captured surface is the kiosk's X root, so the emulator must fill it:

- **Do not force the emulator's `-resolution` to the machine's raw pixel
  count.** That number is the pixel count, not the picture's shape, and setting
  it defeats the emulator's aspect correction. MPF-II at `-resolution 1120x384`
  sat as a 2.92:1 strip in the middle of a black root; fullscreen plus
  `-keepaspect` on the bridge seed's stock root reconstructs the roughly 4:3
  image the real machine drew on a television.
- **Where the emulator's window cannot grow, shrink the root to it.** VICE's SDL
  window is a fixed 719×544 at `-VICIIdsize`, so the X root drops to the smallest
  advertised mode that contains it (800×600). Do not reach for SDL real
  fullscreen instead: it renders BLACK under std-VGA capture (see the note in
  `scripts/build-guests/tiles/amstradcpc.sh`).
- Any change to the launcher or the X geometry invalidates the checkpoint. Recapture
  it, or reset restores the old layout and the fix appears not to have worked.

**Other devices:**

- Disk: prefer qcow2 for installed guests and internal snapshots; use IDE/SATA
  for old inbox drivers, virtio only where supported. UEFI guests need a
  per-station writable varstore, never a shared writable template.
- NIC: use virtio-net for modern guests; e1000/rtl8139/pcnet for older inbox
  drivers. Put host forwards on the existing `-netdev user` backend so a later
  reset does not accidentally add a guest-visible device.
- Audio: `intel-hda` for modern guests, AC97 for many NT/Unix guests, SB16 for
  DOS/Win9x, or none. The guest must have a real driver. Match the production
  D-Bus audiodev and sample format during the checkpoint capture.
- Keyboard/input: USB tablet/PS2/virtio choice is part of the device set. Decide
  it before saving the snapshot; Section 5 gives the pointer policy.

### 4.2 Automate the install as a state machine

Choose the least fragile mechanism the OS supports:

1. **Unattended answer file/cloud-init/offline configuration** — preferred.
   Keep the template secret-free and substitute gated values at runtime. Verify
   that the target installer version actually consumes every directive.
2. **In-guest SSH/serial/bootstrap payload** — type only a short command, then
   transfer an idempotent script through a namespaced host forward.
3. **Machine vision** — for a graphical installer with no unattended interface,
   author an `install-vision run <flow.yaml>` flow following
   [`scripts/install-vision/README.md`](../../scripts/install-vision/README.md).
   Detect screen state from QMP screenshots, then click/type. Harvest stable
   crops with `install-vision capture`, use bounded waits, optional steps for
   branch dialogs, and post-action framebuffer checkpoints. Coordinates alone
   are acceptable only after resolution and screen state are positively
   identified.
4. **Manual VNC** — acceptable only for initial research. Convert the observed
   sequence into an answer file or framebuffer-driven state machine before the
   builder is called reproducible. If a one-time calibration truly cannot be
   removed, label the build honestly as `1-click` and document it.

Every phase should be restartable or should fail with the last framebuffer,
serial tail, command, and expected next state. Never treat a timeout followed by
blind input as success.

### 4.3 Create and prove the checkpoint

Curate an idle, deterministic, input-ready screen: no setup wizard, modal error,
screen saver, changing clock where avoidable, or unknown login prompt. Run the
standard clone-only proof on labhost:

```bash
# Capture/recapture on copied disks, then independently verify the retained tag.
scripts/lib/checkpoint-verify.sh <stationDir> --capture
scripts/lib/checkpoint-verify.sh <stationDir>
```

**The fast first bake (brand-new Tier-1 station).** `checkpoint-verify.sh` has
no cold-boot-plus-fixed-settle mode (only `--capture`, driven by the station's
`bootrec-tiles.conf` ready metadata, which a new station does not have yet).
For the very first golden, boot the sandbox clone, wait a fixed settle you
chose by eye, then drive QMP/HMP by hand on the clone's monitor socket:

```bash
Q=scripts/lib/labqmp.py; S=<clone-qmp-socket>
python3 $Q $S stop
python3 $Q $S savevm golden
python3 $Q $S querysnap                 # 'info snapshots' — the golden tag must be listed
python3 $Q $S loadvm golden
python3 $Q $S screendump /tmp/golden-restore.ppm   # the framebuffer is the proof
```

Then wire up `bootrec-tiles.conf` and run the standard proof above; the
recapture path (`checkpoint-guard recapture`) is for live stations only.

The helper uses the station's `bootrec-tiles.conf` disk/port/ready metadata, copies
every writable disk under a namespaced `/data/vms/sandbox/golden-verify-*`
directory, statically checks the rewritten launcher, gates destructive QMP by
`clone-guard`, and tears the clone down. Its required sequence is:

```text
stop/pause guest at the ready state
delete an obsolete snapshot only on the disposable build artifact
savevm golden
query snapshots and require the `golden` tag
dirty the framebuffer/input state
loadvm golden
capture again and compare the expected region/frame
restart QEMU with the final production device set and `-loadvm golden`
repeat the visible input proof
```

That sequence is for a **first** capture, on the disposable build artifact, where
there is no live checkpoint to lose. It is not how you recapture a station that is
already live: for that, the one command is
`ssh lab 'checkpoint-guard recapture <station>'` — it backs the disk up, stages the
new state under `cpg-staging`, proves the restore on the framebuffer *and* that the
restored guest is running, and only then retires `golden`. Never hand-type
`delvm golden; savevm golden` on a live station, and never stage under `golden-new`
(the launcher's `grep -qw golden` probe matches it, and an interrupted run then
leaves QEMU refusing to start). See [`checkpoint-guard.md`](checkpoint-guard.md).

On a first capture (no tag), the configured cold-boot driver/detector must reach the
ready scene; on a recapture, the existing tag is the ready seed. Without
`--bake` the helper refuses to create or replace a snapshot and verifies the
existing `golden`. Set `GOLDEN_VERIFY_DIRTY_TEXT` only when the scene needs a
different visible keyboard string; a dirty action which does not change the
framebuffer is a failure, not a skipped assertion.

The disk containing the internal snapshot must be writable during `savevm` and
normal production restore. Do not combine an internal snapshot with QEMU
`-snapshot` mode unless the design explicitly proves where the vmstate persists.
For immutable ISOs/raw bases or non-migratable devices, use
`resetMode=restart` and prove the cold boot is deterministic.

**Capture from a clean cold boot, and let the restore finish alone.**

- The screen you capture is the screen every visitor sees for the life of the
  exhibit. A checkpoint captured while the framebuffer still carried output from a
  verification run gave the MPF-II an exhibit that restored to a scrolled screen
  with the banner gone and two prompts stacked. Cold-boot the scene, leave it
  untouched, capture that.
- **Do not inject keys after `loadvm`.** mpf2 sent `scroll_lock,f3,scroll_lock`
  after a restore purely to replay the ROM power-on beep; it raced the restore
  and intermittently corrupted the screen, and was removed. Note also that
  MAME's F3 is a *warm* start — RAM survives, so an Apple-family ROM skips its
  banner entirely; Shift+F3 behaves the same.
- **Use the sibling pattern.** `resetMode: loadvm` plus an internal `golden`
  snapshot is what every restorable station does. A bespoke reset mode with a station
  name hardcoded in the generic `scripts/serve/reset-tile.sh` was tried on this
  add and reverted: per-station behaviour belongs in the registry entry, never in a
  case statement in shared code.

Keep the launcher and checkpoint as an atomic pair. Adding/removing a disk, tablet,
NIC, serial device, firmware property, PCI device, or machine version after
`savevm golden` requires a new golden. Display/audio **backends** can sometimes
vary without changing guest-visible state, but prove this rather than assuming.
A **firmware image** (`-bios`, option ROMs) is the sneaky case: the ROM bytes are
RAM blocks inside the vmstate, so `loadvm golden` silently restores the *old*
ROM whatever the launcher now passes, and a recapture that seeds from the
existing golden carries it along. Re-bake from a **cold boot** and prove the
guest's ROM bytes match the new file
([win311 example](win311-interrupts-disabled-freeze.md#the-fix)).

## 5. Choose and wire pointer/input transport

Select the first path in this table which the guest supports correctly. Test
motion to all corners, click, drag, wheel, key make/break, pointer re-entry, and
input immediately after a reset.

| Path | Choose when | Production wiring |
|---|---|---|
| Absolute HID | Guest has USB HID or virtio-input and maps the full display correctly. This is the default and lowest-effort path. | Emit `--pointer abs --input-backend dbus-abs --input-dev usb` for `-usb -device usb-tablet`, or `--input-dev virtio` for virtio keyboard/tablet. `station.env` gets `SH_INPUT_BACKEND=dbus-abs`. Add cursor scale/offset only from measured framebuffer calibration. Do not set UI `pointerRel`. |
| Direct relative PS/2 | Guest only has a good PS/2 relative mouse and browser Pointer Lock produces usable 1:1 deltas. | Emit `--pointer rel --input-backend dbus-rel --input-dev ps2`; no tablet. Set `pointerRel: true` in the UI binding so raw relative movement is sent. QNX is the reference. |
| TCP warpd / hybrid | Existing baked guest exposes a trustworthy absolute cursor API but its virtual HID is absent, range-limited, accelerated, or otherwise wrong. | Warpd is frozen: reuse only for its six existing stations; do not add another agent or protocol verb. Their emit form is `--pointer warpd --input-backend warpd --warpd-addr 127.0.0.1:<hostPort>`. Optional `--warpd-buttons qemu` keeps motion on the agent while real QEMU mouse buttons preserve window-manager semantics. |
| Serial warpd agent | Existing baked guest has no reliable NIC/TCP path but reads COM1 and calls an absolute cursor API. | Warpd is frozen: retain the existing Unix socket chardev and `--pointer warpd --input-backend warpd --warpd-addr unix:<stationDir>/serial.sock` only for Win3.11/OS2/TempleOS. New OS work must not create another guest agent. |
| `gallery-hid` | Only after the OS-specific kernel driver and patched QEMU device have passed latency, restore, and fallback gates. It is not the generic first choice. | Follow `docs/lab/research/low-latency-input/qemu-transport.md`: pinned patched QEMU; `-chardev socket,id=ghid0,path=<stationDir>/gallery-hid.sock,server=on,wait=off`; `-device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=pci.0,addr=0x1e`; guest driver installed/armed before a new checkpoint; `SH_GHID_SOCKET=<path>` in `station.env`. Keep the old HID/warpd route available for rollback until the station is promoted. |

The experimental transport contract and its promotion/rollback requirements are
in [`qemu-transport.md`](research/low-latency-input/qemu-transport.md).

### 5.1 Keyboard-only exhibits — pacing, layout, and the type-in demo

For a machine with no pointing device (MPF-II, Amstrad CPC) the keyboard *is*
the exhibit, and it has its own failure modes. All the numbers below were
measured on labhost during the MPF-II add (2026-08-06).

**Pace the release→press GAP, not just the hold.** An emulator samples its input
ports once per emulated frame, so a press+release completing inside one frame is
never observed. The quantity that must survive a frame is the gap *between*
successive keys. Bisected on mpf2 (MAME, 60 Hz), typing a 16-key line:

| Inter-key gap | Keys that landed |
|---|---|
| 0 ms | 0 of 16 |
| 8 ms | 4 of 16 |
| 12 ms | 12 of 16 |
| 16 ms (one frame) | 16 of 16 |

The knobs are `SH_KEY_MIN_HOLD_MS` and `SH_KEY_MIN_GAP_MS` (declared per station in
`runtime.stationEnv`; reference in `streamhost/docs/CONFIG.md`). **Derive the values
from the machine's frame period**, with two frames as the shipped margin: mpf2 at
60 Hz → `32`/`32`; amstradcpc, whose PSG scans the matrix at 50 Hz → `40`/`40`.
An earlier empirical 80/250/500 ms triple also worked but was never bisected and
is roughly 6× the physical requirement — extrapolating from it makes every
type-in glacial.

**Two frames is a floor, not an answer — measure it.** vic20 shipped at the
frame-derived `40`/`40` and a visitor's type-in still came back with two
characters missing. Bisected with
[`scripts/dev/emu-key-pacing-bisect.py`](../../scripts/dev/emu-key-pacing-bisect.py)
on a clone: 40/40 corrupted 1 line in 22, 60/60 and 80/80 none in 14 and 22.
The residual failure is **host scheduling, not frame quantisation** — this box
runs 30+ emulators, and when the emulator's thread is starved for longer than
the hold, the press *and* the release land between two of its input pumps and
the key is never sampled at all. That margin does not scale with the frame
period, so derive a starting value from the frame period and then *measure* on
a clone before shipping. Two traps make the measurement lie: QEMU's `send-key
hold-time` releases asynchronously and overlapping calls lose characters on
their own (use explicit `input-send-event` press/release pairs), and the
guest's cursor blinks, so two captures of the *same* state hash differently.

Do not mask the differing pixels — **sample at a fixed machine instant**, which
is exact rather than fuzzy:

```
stop ; loadvm golden ; stop ; screendump out.ppm ; cont
```

On `armeval` that turns "two hashes across three samples, differing by exactly
one ~40 px cursor cell" into four byte-identical captures — taken before and
after the keyboard proof, from two separately captured checkpoints. Any MODE 7 or
text-prompt exhibit (`bbcmicro` too) needs it; it is a property of the machine,
not of one add.

**A MODIFIER IS A KEY: give it its own event and its own dwell.** The rule is
about event *shape*, not about a magic number.

*The diagnostic.* Shifted characters that fail **selectively** — letters fine,
punctuation dead, varying key to key — mean the modifier is racing the key, not
that the keymap is missing an entry. On the Xerox stations (2026-08-10) `Shift+;` →
`;` and `Shift+a` → `a` while, **in the same sweep**, `Shift+1` → `!`,
`Shift+8` → `*`, `Shift+[` → `{` and `Shift+=` → `+` all shifted correctly. A
real keymap gap cannot do that: it would not pass `" { } < > ? _ + | * ( )`
while dropping the shift on `;` alone.

*The cause.* Batching the modifier and the key into **one** input event — both
transitions land in the same instant and the toolkit can dispatch the key before
the modifier state has updated.

*The fix, in order.* First correct the shape: modifier press as its own **earlier**
event, **held across** the key, released after. Only if it still fails, lengthen
the lead and bisect it.

*The lead is per-machine — measure it, do not inherit it.* Two machines, two
answers, both measured:

| Emulator | Lead that works | Lead that fails |
|---|---|---|
| Dwarf (Java/Swing) | 150 ms — and 250/350 ms, all equal | **0 ms only** (batched into one event) |
| Darkstar (mono/WinForms+SDL) | 350 ms | **200 ms** |

So Dwarf ships `SH_KEY_MIN_GAP_MS=150` unchanged, while Darkstar needs roughly
double. Quoting either number as *the* figure will slow a fast machine down for
nothing, or under-serve a slow one and be blamed on the keymap.

The UI's shift latch already has the right shape (shift as a separate
`sendKey`, paced by `SH_KEY_MIN_HOLD_MS`); the trap lives in the ad-hoc
XTEST/`send-key` helpers written during a bring-up.

**Turn X's auto-repeat OFF in any kiosk driven by synthetic keys — before you
touch the pacing at all.** On the Oric Atmos add (2026-08-09) the pacing was
never the problem. Every key a kiosk sees is an injected press/release
pair, and when the release arrives late — this box runs thirty emulators — X's
typematic repeat starts hammering the key that is still "held". The demo
listing's line 40 came out as `PRINT "ORIC ATMOS 19999999999`: one late
release, eleven nines. The flood then left the emulated machine **deaf** —
nothing typed afterwards landed, until the next `loadvm` — and that symptom
impersonates, in turn, frame quantisation, host starvation and an emulator
freeze. `xset r off` in the station's `/etc/bridge/launch.sh` fixes it; the checkpoint
must be recaptured afterwards, because the X state is inside it. Three cheap
discriminators, in the order they pay off:

1. the guest kernel's `/proc/interrupts` i8042 counter proves whether QEMU
   delivered the keys at all (on that station it always had);
2. a screen that keeps changing while keys do nothing is an INPUT fault, not a
   frozen emulator — but pick a test pattern that actually changes, since a
   screen scrolling identical characters compares equal frame to frame;
3. a station with no viewer is idle-paused (`[idle] no sessions for 60s -> guest
   paused`), and a paused guest swallows every key. A bare QMP harness must
   send `cont` after each `loadvm`; `labctl` does it for you.

**The bisect's 250/250 reference is an assumption, not a law.** On that same
Oric station a LONG hold was the failure mode: 40/40, 60/60 and 80/80 all typed a
40-character line intact in 10 of 10 trials, while the harness's "pacing nobody
disputes" reference dropped 7 characters of 40 — so
`emu-key-pacing-bisect.py` reported every rung as corrupt against a reference
that was itself broken. Look at the reference frame before believing a rung.

**Raising the pacing obliges the typist to slow down too.** The UI waits
`line.length * perCharMs` before submitting the next line; below the station's
hold+gap drain rate a backlog builds and BASIC loses the characters that arrive
while it is tokenising. Declare `demoProgram.perCharMs` in the registry when a
station drains slower than the fleet default — `validate_demo_pacing` in
`scripts/stations-registry.py` fails the build if the two disagree.

**One rejected line can impersonate a broken input plane — check the LISTING
before you touch the pacing.** A BASIC that rejects a line may leave the
rejected text sitting in its edit buffer for correction, and then every
subsequent line *appends to it* instead of starting fresh. On the QL
(2026-08-17) a listing whose line 120 read `END PROC` — not SuperBASIC; the
terminator is `END DEFine` — produced this, and it reads exactly like keys being
dropped:

```
10..110 stored fine, LIST shows them
120 END PROC130 FOR a=0 TO 315 STEP 45140 PROC petal(...)150 END FOR160 ...
bad line
```

The apparent "first 11 lines work, then ENTER stops landing" boundary is
**content**, not count, and no amount of extra delay moves it — an agent spent
$2.47 of model time bisecting delays against it. Two cheap discriminators, in
order:

1. type N trivial numbered lines (`10 REM A` … `150 REM A`) and LIST them. All
   present ⇒ the plane is fine and your listing has a syntax error;
2. type one deliberately invalid line between two valid ones and watch whether
   the next line concatenates onto it — that identifies the edit-buffer
   behaviour for this machine in one shot.

Syntax-check a type-in listing against the machine's *own* dialect before
blaming delivery. `END DEFine`/`END FOR`/`END REPeat` on the QL are not the
`NEXT`/`RETURN` of the 8-bit BASICs the other exhibits use.

**A guest's keyboard is not necessarily laid out like a PC's.** The UI's
`typeText()` maps ASCII to US set1 scancodes. The MPF-II's 8×8 matrix puts `=` on
Shift+O, `-` on Shift+I and `+` on Shift+P, and its shifted number row is offset
by one (Shift+8/9/0 give `( ) *` where a PC gives `* ( )`). Untranslated, `=` and
`-` **vanish** — those PC keys do not exist in the matrix — and every bracket
lands one key over. The fix is the registry-declared `spa.demoProgram.keyMap`
(applied by `applyKeyMap()` in
`spa/src/ui/grid/StreamView/typeDemoProgram.ts`). To check a new guest, read the
`PORT_CHAR` pairs in its MAME driver (e.g. `src/mame/apple/tk2000.cpp`): they
give the exact unshifted/shifted pairing of every key in the matrix.

**Wait in proportion to LINE LENGTH, not on a fixed tick.** `typeText()` returns
immediately and streamhost drains the queue at the station's paced rate (~64 ms per
character on mpf2), so a 25-character line is still arriving 1.6 s later.
Submitting the next line on a fixed tick overruns the queue and loses characters
— it shows up as the first character after each ENTER going missing, in a
regular pattern. `DEMO_PER_CHAR_MS` in `typeDemoProgram.ts` is the per-character
budget; keep the delay proportional.

**`labctl type` is not a fair test of a guest's keyboard.** It drives QMP
directly and therefore gets none of streamhost's pacing, so it drops characters
while printing `ok: typed N chars`. Judge a keyboard through the UI path, or
through a proof the builder runs, and check the framebuffer.

If a USB tablet covers only part of a high-resolution desktop (the Solaris VUID
case), do not hide the defect with arbitrary client scaling if an in-guest
absolute API can solve it. Conversely, do not write a guest agent where native
absolute HID already works.

## 6. Register the station everywhere

The scaffolded `registry/stations/<osId>.json` is the source of truth. It begins as
an inert candidate with the slot/port reservation; fill it using `alpine.json`
and `android.json` as complete streamed-station examples, then set `enabled: true`
and promote its lifecycle only after its proof passes. Audit the
entry's `schemaVersion`, `id`, `stationDir`/`aliases`, `lifecycle`, `enabled`,
`build`, `stream`, `runtime`, `reset`, `operator`, `spa`, `museum`, `guestDoc`,
`credentialsRef`, and `render` fields. Do not add a field that is absent from
the schema or infer that a sidecar will be created merely because the registry
references it.

Regenerate and prove byte parity after every registry edit:

```bash
make station-registry-validate
make station-registry-generate
make station-registry-check
```

`station-registry-check` recomputes every output and fails on drift. The **Station
registry** GitHub Actions workflow runs the same check for pull requests and
pushes to `main`. The generated surfaces and their actual inputs are:

| Generated artifact (do not hand-edit) | Registry fields used |
|---|---|
| `streamhost/stations-manifest.sh` | Production rows ordered by `render.stationsManifestOrder`; `render.stationsManifestPrelude` plus the emit invocation rendered from `stationDir` and `runtime.qemu.emitArgs` (`runtime.x11.emitArgs` for x11 stations). |
| `streamhost/bring-up-all.sh` | Production `stationDir` values grouped by `render.bringUpGroup` and ordered by `runtime.bringUpOrder`. |
| `scripts/build-guests/build-all.sh` | `build.rows` entries (`order`, `prelude`, typed `value`, and optional `defaultOrder`) rendered as aligned manifest lines, plus shared rows in `registry/registry-v1.json`. |
| `spa/src/three/archetypeRegistry.ts` | `id` and `spa`, rendered as an OS binding line (`render.bindingPrelude` kept, optional `render.bindingComment` appended) and ordered by `render.bindingOrder`. |
| `spa/src/data/posterIndex.ts` | Poster existence + hero path per `registry/posters/<id>.md` (the prose ships separately at runtime). |
| `registry/generated/labctl-declarations.json` | Streamhost `stationDir` plus the declared keys in `operator.labctl`. Live observed checkpoint state is intentionally excluded. |

Two more documents are **rendered, never committed** — they have no copy in the
tree to hand-edit or to go stale, and `stations-registry.py render` (into the
gitignored `build/registry/`) or `emit <name>` (to stdout) resolves them from
the registry whenever something needs them:

| Rendered artifact | What it takes from the entry |
|---|---|
| `gallery-manifest.json` | The public lineup the UI fetches at runtime: `museum` + `spa`, ordered by `render.bindingOrder`. Published to the labhost webroot by `serve-https-spa.sh manifests`. |
| `poster-docs.json` | The full poster documents compiled from `registry/posters/*.md`, fetched by the UI at runtime. |
| `tiles.json` | Every streamhost row's `id`, `stream.udpPort`, `stationDir`-derived certificate-hash path, and `render.signalOrder`. The live `SIGNAL_CONFIG`. |
| `golden-manifest.json` | Production `id` and `reset`, ordered by `render.goldenOrder`. The reset allow-list `reset-tile.sh` reads. |
| `gallery-action-map.json` | `operator.actionMap`, ordered by `render.actionMapOrder`. |
| `fleet-table.json` | The `/fleet` view's runtime source: per-station emulator, machine, capture, pointer, pacing, golden and exec detail. Fetched by `spa/src/data/fleetTable.ts`; nothing is bundled. |
| `mock-manifest.json` | `museum` for entries that have `render.mockManifestOrder`. |
| `index.json` | The aggregate of every entry — `runtime.stationEnv` merged with the station's `station.env.fixture` — excluding generator-only `render` data. |

Use this table as an exhaustive audit of the JSON entry, not as an edit list for
derived files. `python3 scripts/stations-registry.py explain <osId>` is useful for
reviewing one entry's principal derived values.

### 6.0 Writing the entry: rendered blocks and visitor-facing fields

- The OS binding line, emit invocation, and build-manifest rows are **rendered
  from the typed fields** (`spa`, `runtime.*.emitArgs`, `build.rows[].value`) —
  there is no pre-rendered string twin to keep in sync. Edit the typed field,
  then regenerate.
- A key defined in the station's `station.env.fixture` must NOT also appear in
  `runtime.stationEnv` — the fixture is the single source for its keys and
  `validate` fails on the overlap. The generator merges the fixture into the
  env view that the rendered `index.json` and the validators see.
- **`museum` describes the real machine, never how the gallery runs it.**
  `lineage` is a heritage — "Windows NT 3.x", "Multitech (Taiwan)" — not a
  paragraph. `notes` is the one operator-facing field; `blurb` is what the
  public placard shows, and the UI test suite fails any manifest row without
  one. Always set `blurb`.
- `ramMB` cannot express a sub-megabyte machine. Use `ramKB` (the MPF-II has
  64 KB); both are accepted by the schema and the museum renderer.

### 6.1 Build registry

- `registry/stations/<osId>.json`: add the typed `build.rows` entry;
  use its `order` and optional `defaultOrder` for the manifest/default sequence.
  Gate licensed media with class `licensed`; gate account media with the
  `media` flag. Regeneration writes `build-all.sh`.
- `scripts/build-guests/tiles/<os>.sh` remains hand-managed: implement the complete
  build, framebuffer verification, and golden/reset proof. The registry names
  the script but does not generate it.
- `scripts/build-guests/check-assets.sh` and `docs/lab/ASSETS-MANIFEST.md`: add
  the source inputs and checks. Store variable names, never secret values.
- `docs/guests/<os>.md` remains hand-managed: set `guestDoc` to it and document
  status, exact media, device-set rationale, automation, golden, pointer,
  verification, blockers, and rollback notes.

### 6.2 Streamhost registry and station directory

Describe the stream in `stream`, the declared emitted environment in
`runtime.stationEnv`, the pinned device set in `runtime.qemu`, and startup order in
`runtime.bringUpOrder`. Put the exact emitter argument vector in
`runtime.qemu.emitArgs` and its validated shell rendering/order in `render`.
Regeneration writes the production `emit` stanza and ordered bring-up list; do
not edit either generated shell script.

Add `streamhost/stations/<stationDir>/` when the station needs tracked runtime material.
These source sidecars remain hand-managed even when the registry references
their paths through `runtime.qemu.launcher`, `envFixture`, or `auxFiles`:

- `qemu-streamhost.sh`: required for a **verbatim** launcher; it is the complete
  guest-visible device-set ledger, creates only namespaced sockets/files, kills
  only by pidfile, and conditionally uses `-loadvm golden` where appropriate;
- `station.env.fixture`: appended metadata/reset stanza such as
  `SH_RESET_MODE`, `SH_GOLDEN_*`, and fixture notes;
- `qemu-setup.sh` or equivalent: optional one-time, clone-safe setup/calibration;
- `golden-bake.sh`: optional reproducible fixture creation and dirty→restore
  framebuffer proof;
- any helper used at runtime: pass it through `--aux-file` or reference a
  tracked deployed path. Do not depend on an unrecorded box-only file.

For a verbatim runtime, set `runtime.qemu.mode` to `verbatim`, point `launcher`
at the tracked script, and keep `launcherParity` honest. The generator records
and reports launcher parity but does not synthesize the launcher or
`station.env.fixture`. The emitter produces the deployed `station.env`, launcher, and
`ROLLBACK.md` from the generated invocation and referenced source material.
Ensure `runtime.stationEnv.SH_STATION` and paths use `stationDir`, while public maps use
`id`.

Choose `runtime.bringUpOrder` and `render.bringUpGroup` after every build or
runtime prerequisite and in a sensible memory/boot order. One-time varstore,
reattach, or cgroup behavior belongs in the hand-managed template/control-flow
code, not in an operator's shell history or the generated `TILES=(...)` row.

Validate generation in scratch before deployment:

```bash
scripts/dev/verify-emit.sh --host lab --pin-machine --verbose
# Fresh-box/local form:
# bash scripts/dev/verify-emit.sh --local --pin-machine
```

Do not save the golden until the launcher has the pinned production device set.

### 6.3 Serve, reset, and operator maps

Set `stream.udpPort` and `render.signalOrder`; generation derives the public
signal row from `id`, `stationDir`, and that port. The HTTPS server reads the
signal JSON and certificate hash fresh on every request, but the **live**
`SIGNAL_CONFIG` copy must still be updated. The UI deploy helper preserves an
existing host copy, so do not assume an UI deploy has copied a changed map.

For production, fill `reset` and `render.goldenOrder`. Use
`resetMode: "restart"` with `snapshot: null` only when the launcher creates a
fresh deterministic fixture. `mouse` and `keyboard` are evidence (`PASS`,
`SKIP`, or `UNVERIFIED`), not desired outcomes. Keep `reset.pointer` consistent
with `stream.pointer.transport`.

Put the performance/input probe under `operator.actionMap` and order it with
`render.actionMapOrder`. Use `mouse: null` for a text-only surface. Its `key`
may be an `id`, `stationDir`, or retained historical tool spelling; prefer an
alias-free `id` for new entries.

Declare `dir`, `qmp`, `pointer_mode`, `warpd_port`, `warpd_addr`, `ssh_port`,
`exec_port`, `exec_kind`, `exec_user`, `exec_key`, `console`, `udp_port`, and
`notes` in `operator.labctl`. Set the exec kind, port, user, and private-key
**path** only when a captured-output exec channel is proven; otherwise use null
declarations. Regeneration writes the committed declaration seed. After the
runtime station directory, launcher, and emitted `station.env` exist, run:

```bash
ssh lab 'labctl gen'
ssh lab 'labctl ls'
```

This verifies the declarations against live files, adds observed golden state,
and regenerates `/data/vms/streamhost/stations.json`; do not hand-edit it.

### 6.4 Runtime UI manifest (no rebuild for an existing archetype)

The public lineup is served from `/gallery-manifest.json`, rendered from each
registry row's `museum` + `spa` data. It carries the display metadata,
archetype/transport binding, order, and `/signal/<osId>.json` reference. It does
**not** carry `credentialsRef`, logins, passwords, keys, tokens, or other private
operator data. The UI fetches it with `cache: "no-cache"` and validates every
row; there is deliberately **no** bundled copy behind it, so a 404 or an invalid
shape leaves the gallery empty and says so in the console rather than quietly
showing a lineup from whenever the bundle was built.

For an ordinary OS using an existing `ArchetypeId`, do not edit UI TypeScript or
run Vite. After updating `registry/stations/<osId>.json`:

```bash
make station-registry-generate
make station-registry-check

# On an authorized deploy run (not from a source-only task), publish the
# generated signaling map and public lineup with atomic per-file replacement:
scripts/serve-https-spa.sh manifests
```

That command re-renders the lineup and copies both documents to
`/data/vms/streamhost/serve/tiles.json` and
`/data/vms/streamhost/serve/webroot/gallery-manifest.json`; the new OS then
appears without `npm ci`, `npm run build`, or a bundle deployment. The
equivalent by hand is `python3 scripts/stations-registry.py emit
gallery-manifest.json` piped to the live webroot path, and the same for
`tiles.json` at the live `SIGNAL_CONFIG`; never hand-edit the live JSON.

**A station in the registry lineup is not finished until the 3D scene knows it.**
The runtime manifest carries the placard, but the WebGL museum and the on-screen
keyboard are compiled in, and they are hand-managed:

- `spa/src/ui/keyboard/keyboardProfiles.ts` — add the station to `OS_FAMILY`, or its
  virtual keyboard falls back to `generic`;
- `spa/src/scene/machines.ts` — `ASSEMBLIES_BY_TILE` places the exhibit;
  **order matters** and must follow the registry lineup order, not alphabetical;
- `spa/src/scene/machineIdentity.ts` — a `Record<keyof typeof
  ASSEMBLIES_BY_TILE, ExhibitIdentity>` exhaustiveness check. A missing station is a
  **type error caught only by `npm run build`**, never by vitest, so a branch can
  be green on tests and still fail the build.

Posters are two artifacts, both required: `registry/posters/<id>.md` for the
prose and `spa/public/posters/<id>/desktop.webp` for the 1024×768 hero image.
mpf2 shipped with neither and had to be fixed up afterwards.

A Vite build is still required when adding a genuinely new Three.js/React
archetype or changing UI/schema code. Such a scheduled build also refreshes the
embedded last-known-good copy. `spa/src/data/credentials.ts` remains
hand-managed, gitignored, bundle-side, and keyed by OS id; add only local
credential/sentinel values there. Never put a real credential in the public
manifest, tracked source, docs, screenshots, or logs.

### 6.5 Cold boot and boot video

Boot video is optional. Even without publishing a clip, audit the cold-boot
behavior so the guest cannot stop on first-run input.

- Add `scripts/coldboot/<stationDir>-zero-input-prep.md` describing the ready state,
  blockers, automation, and clone proof.
- Add a `case` arm to `scripts/coldboot/bootrec-tiles.conf`: `BR_BOOT_KIND`, final
  canvas, FPS/audio, every writable disk to clone, port rewrites, detection tier,
  timeout, and optional automated record driver.
- Run `record-boot.sh <stationDir> --dry-run` and inspect the rewritten clone launcher
  before a real capture. It must never attach a live writable disk.
- A published clip's last frame must match the golden's first live frame. Follow
  `scripts/coldboot/README.md`; do not publish a clip merely because it plays.

On an authorized box-side run:

```bash
export SH_DBUS_TAP=/data/vms/streamhost/build/target/release/bootrec-tap
export WEBROOT=/data/vms/streamhost/serve/webroot
scripts/coldboot/record-boot.sh <stationDir> --dry-run
scripts/coldboot/record-boot.sh <stationDir>
scripts/coldboot/postprocess-boot.sh <stationDir>
scripts/coldboot/gen-boot-manifest.sh <stationDir>
```

The runtime `/boot/index.json` supplies detailed clip metadata without an UI
rebuild. The current grid badge/mount also reads `OSBinding.bootVideo`, so a
newly published station still needs `spa.bootVideo` in its registry entry followed
by regeneration and an UI rebuild until the architecture is fully
runtime-driven.

## 7. Deploy and verify

### 7.1 Pre-deploy checks

```bash
make station-registry-validate
make station-registry-generate
make station-registry-check
bash -n scripts/build-guests/tiles/<os>.sh
bash -n streamhost/stations/<stationDir>/qemu-streamhost.sh  # if verbatim
python3 scripts/stations-registry.py render     # renders every runtime document
jq empty build/registry/stations.json
jq empty build/registry/golden-manifest.json
jq empty build/registry/gallery-action-map.json
scripts/build-guests/build-all.sh --list
scripts/build-guests/build-all.sh --check-assets --only <builderKey>
(cd spa && npm ci && npm run build)
```

Run the builder against its own namespaced artifact. Require its checksum,
framebuffer, input, and golden round-trip gates before registration is deployed.

### 7.2 Supervised station deployment

Follow Phase 5 of `MASTER-REPRODUCE.md` for repository-to-box sync. In outline:
(steps 5–8 below are ONE command once the tree is deployed:
`scripts/dev/station-up.sh <stationDir>` — it emits the single station, links the
fleet binary, starts the unit, publishes the five runtime documents, runs
`labctl gen`, shoots a frame and checks signal / manifests / `POST /restore`;
re-running it on a live station is safe.)

1. finish `registry/stations/<osId>.json` and any hand-managed builder, guest doc,
   launcher, `station.env.fixture`, or coldboot sidecar; prepare the gitignored
   credential separately when required;
2. run `make station-registry-generate`, then `make station-registry-check`;
3. sync the tracked tree, including the registry, generated streamhost/serve/UI
   files, generated labctl declarations, and hand-managed tracked sidecars;
4. emit with pinned machine types into scratch and pass `verify-emit`;
5. emit/deploy the new station directory — `bash streamhost/stations-manifest.sh --only <stationDir> --pin-machine` emits just that one station (the flag is repeatable; the fixture preflight still runs fleet-wide);
6. launch only its `qemu-streamhost.sh`, wait for `qmp.sock`, then start
   `streamhost@<stationDir>`;
7. publish the **five** runtime documents with
   `scripts/serve-https-spa.sh manifests`. That one command writes
   `tiles.json` to the live `SIGNAL_CONFIG` path and `gallery-manifest.json`,
   `poster-docs.json` and `fleet-table.json` into the webroot, plus
   `golden-manifest.json` beside the HTTPS server — **use it rather than
   hand-copying**, precisely because the count keeps growing.
   Two of the five fail in ways that do not look like a missing document:
   - `golden-manifest.json` keys are the allow-list for `POST /restore/<osId>`
     (`_restore_osids()` in `scripts/serve/osgallery-https-server.py`), so a
     station missing from the live copy streams perfectly while its "reset to
     golden" button returns `404 unknown osId`;
   - `fleet-table.json` is what `/fleet` fetches at runtime
     (`spa/src/data/fleetTable.ts`); nothing about it is bundled, so a station
     missing from the live copy is simply absent from the fleet table while the
     main grid shows it correctly.
   **This line is load-bearing and has been wrong twice.** It said "the two
   runtime documents" until 2026-08-09, which is exactly how the Commodore wave
   shipped with dead reset buttons; it then said "three" until 2026-09-02, by
   which time `poster-docs.json` and `fleet-table.json` had joined the set — a
   ravynos deploy that hand-copied the three named here published a station that
   was invisible in `/fleet`. If you add a runtime document, fix this step, the
   rendered-artifact table in §6, and the `msg` line in `serve-https-spa.sh`;
8. run `labctl gen` so the generated declarations are checked against the live
   runtime and observed state is added;
9. do not rebuild the UI for a station that uses an existing archetype; a new
   compiled archetype or UI/schema feature follows the coordinated UI build and
   deploy path.

Do not run the full `bring-up-all.sh` merely to test one new station if that would
restart unrelated guests. Once the station is proven, run the full ordered path in
a planned fleet-rebuild test.

### 7.2.1 Traps that make a correct fix look broken

Four of these cost time on the MPF-II add. Check them before you conclude a
change did not work.

- **The station is running an old binary.** streamhost deploys are per-station
  canaries: `scripts/dev/build-deploy.sh` swaps a `current` symlink under
  `/usr/local/lib/streamhost/stations/<tile>/`, and the fleet is **not** promoted
  automatically. A station can therefore be running a binary that predates the knob
  you just declared in its `station.env`. Confirm with
  `ssh lab 'readlink -f /usr/local/lib/streamhost/stations/<tile>/current'` before
  debugging the knob.
- **UI changes are invisible until the bundle is deployed** to
  `/data/vms/streamhost/serve/webroot/`. A local `npm run build` proves nothing
  about what the browser is loading.
- **Stations idle-pause with no viewer attached**, so a raw `ssh` into a bridge
  guest simply hangs. `labctl` auto-resumes and is the supported path. A
  freshly-resumed VM also swallows the first characters sent to it.
- **A silent emulator segfault reads as an X or systemd fault.** On the vic20
  add, `xvic` died instantly with no output; what was observable was X exiting a
  second after it started and `getty@tty1` looping to `start-limit-hit`, with no
  `(EE)` in the Xorg log and nothing from the emulator in the startx log.
  **VICE 3.9 segfaults in `vice_banner()` whenever its stdout is not a
  terminal** (`log_helper()` hands a NULL to `strlen`), so copying mpf2's
  `exec startx … >"$HOME"/startx.log 2>&1` — correct and harmless for MAME —
  kills a VICE station. Leave stdout on tty1, as the stock bridge profile and the
  c64/vic20 stations do. A *second*, independent fault has the same signature: VICE's
  `make install` skips some ROM data files and the emulator segfaults with no
  output when one is missing (the C64 BASIC ROM for c64, `basic-901486-01.bin`
  for vic20). Reach for `script -qec '<cmd>' /dev/null` (a pty makes the first
  fault vanish) and gdb, not for the X log. See
  [`docs/guests/vic20.md`](../guests/vic20.md).
- **A `/proc` scan matches the shell running it.** The `pkill -f` self-match trap
  in `AGENTS.md` applies equally to
  `for p in /proc/*/cmdline; do grep <pattern> ...`: it reported 9 stray
  processes here when the true answer was 0. Resolve each candidate through
  `/proc/<pid>/exe` and check the actual binary.

### 7.3 Acceptance matrix

Use the real HTTPS origin and public `osId`:

```bash
# Signaling exists and describes the intended UDP port/hash.
curl -ksS -o /tmp/<osId>-signal.json -w '%{http_code}\n' \
  https://192.0.2.10:8443/signal/<osId>.json
jq '{host,udpPort,hasHash:(.certHashB64|type=="string" and length>0)}' \
  /tmp/<osId>-signal.json

# Operator inventory and framebuffer.
ssh lab 'labctl ls'
ssh lab 'labctl shot <stationDir> /tmp/<stationDir>-accept.png'

# Reset (safe restore only; never savevm through this endpoint).
curl -ksS -X POST https://192.0.2.10:8443/restore/<osId>
ssh lab 'labctl shot <stationDir> /tmp/<stationDir>-restored.png'

# Only where a captured-output exec channel was explicitly configured.
ssh lab 'labctl exec <stationDir> "uname -a"'
```

Then verify in a browser, not only with curl:

- the exhibit appears once with the right placard/archetype;
- `/signal/<osId>.json` returns 200 and the browser receives moving frames and
  audio (where enabled);
- absolute or relative pointer reaches all edges without scaling drift; click,
  drag, wheel, keyboard, pointer-lock exit/re-entry, and touch semantics work;
- reset restores the exact curated fixture and input works immediately after;
- cold restart reaches the same fixture with no human action;
- optional boot clip has audio, scrubs, and hands off without a visible seam;
- stopping/restarting this station by pidfile/systemd does not affect another station;
- no secret appears in the UI bundle, network response, Git diff, or logs.

Finally, run `make station-registry-check`, compare the live signal and labctl
outputs with the canonical entry, and keep the pre-change launcher+golden pair
until repeated cold boots and restores have passed.

## 8. Worked friction example: `soltest-warpd` / `soltest-ghid`

The Solaris A/B pair records the friction the canonical registry removed.
Before the registry landed, making two experimental streams browser-visible
required independent edits to:

- two station directories with `station.env` and bespoke launchers;
- two signal rows in the serve `tiles.json` for UDP 54911/54912 and the
  corresponding certificate-hash paths;
- two bundled `OS_BINDINGS` rows in `archetypeRegistry.ts` (before the runtime
  manifest migration);
- `labctl gen` after runtime files existed;
- a complete UI rebuild and deployment.

Today a registry row declares lifecycle, signal, public museum/binding data, and
labctl capabilities. Regeneration updates those derived surfaces together; the
two runtime JSON files can be published without rebuilding the UI, while
lifecycle still controls inclusion in production station and golden manifests.

The remaining friction is real but no longer duplicated registry work. The pair
still needs hand-managed verbatim launchers/runtime sidecars and live runtime
proof. Any registry change still needs the generated signal map copied to
`SIGNAL_CONFIG`, `labctl gen` run after the runtime files exist, and an UI
rebuild because bindings/catalog data remain bundled. For a normal new station,
the repeated lineup metadata is principally one registry file plus regeneration;
the OS-specific builder, guest doc, golden, and optional launcher/fixture remain
authored artifacts.
