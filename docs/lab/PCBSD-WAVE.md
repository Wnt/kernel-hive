# PC-BSD 1.5.1 integration wave — 2026-09-03

Speed-record attempt #3 (bootOS 45 min, PC/GEOS 18 min): integrate **PC-BSD 1.5.1
"Edison"** (FreeBSD 6.3-RELEASE + KDE 3.5.8, i386, 23 April 2008 — the last
PC-BSD release before iXsystems' 7.x) as a fully featured Tier-1 host-native
station `pcbsd`. Branch `pcbsd` is the ledger; every stream branches from it.
Concurrent waves on the box: netbsd14 (176), openbsd (177), freebsd411 (178) —
this wave was allocated **179** by the coordination session; landing on main is
serialized through it ("ready to land pcbsd" → "go pcbsd").

## Proven in the spine (coordinator, alone)

- Media: archive.org item `pcbsd-1.5.1-x-86-cd-1`, file `PCBSD1.5.1-x86-CD1.iso`,
  **688930816 bytes**, sha256 in `/data/assets-staging/pcbsd/MANIFEST.sha256`
  (labhost path). CD1 alone installs the base system + KDE; CD2 was optional PBIs.
- Smoke boot on the reactos device set (`pc-i440fx-11.0`, KVM, `-cpu host`,
  1024 MB, `-vga std`, IDE disk + IDE cdrom, AC97 dbus audio, usb-tablet):
  X.org came up at 1024x768 at 26 s, the Qt installer ("Select Language and
  Keyboard") at ~35 s after power-on. Frame: `/data/vms/sandbox/pcbsd/smoke/frame2.png`
  (shipped as the placeholder hero).
- Dark-launched at `/os/pcbsd` via `smoke-rig.sh pcbsd --like reactos --slot 179`
  (rig `/data/vms/sandbox/pcbsd/smoke/`, `run-daemon.sh` restarts the daemon
  after every guest relaunch).

## Allocation ledger (claimed on labhost by session `pcbsd`)

| Thing | Value |
|---|---|
| id / stationDir / SH_STATION | `pcbsd` |
| slot / UDP / VMID label | 179 / 54179 / 179 (allocated by the coordination session; X11 warp forward, if ever needed, 127.0.0.1:6079 = display :79) |
| render orders | as assigned by `stations-registry.py new --like reactos` (duplicates with sibling waves are fixed in THIS entry at landing, then regenerate) |
| upstream | archive.org `pcbsd-1.5.1-x-86-cd-1` / `PCBSD1.5.1-x86-CD1.iso` (688930816 bytes; the builder pins the sha256 from MANIFEST.sha256) |
| builder output | `/data/gallery-guests/PCBSD/pcbsd.iso` (pinned CD1) + `pcbsd.qcow2` (installed, pristine, no golden) — install is GUI, so the builder is `automation: assisted` |
| station dir | `/data/vms/streamhost/stations/pcbsd/` — `disk.qcow2` = the ONLY block device, carries the `golden` vmstate; no cdrom at runtime |
| device set | `pc-i440fx-11.0`, KVM, `-cpu host`, 1024 MB, 1 vCPU, `-vga std`, IDE disk index 0, AC97 + dbus audiodev, PS/2 relative mouse only (usb-tablet dropped: inert in FreeBSD 6.3 X); **no NIC** |
| screen | 1024x768 (X.org 7.3 vesa on the Bochs VGA) |
| guest accounts | root / `kernelhive`; user `visitor` / `kernelhive`, KDM autologin (credentialsRef `guest/pcbsd`) |
| pointer | **`rel` (PS/2)** — measured by the golden stream: the usb-tablet is inert in FreeBSD 6.3 X (installer and KDE); PS/2 relative moves with X acceleration ≈3.5 px/unit under KDE, ≈2 px/unit in the installer. The tablet was dropped from the device set (the validator forbids an inert absolute device next to a `rel` method) and the golden re-baked without it |

## Streams (each: `scripts/dev/wt.sh new <name> --from pcbsd`, commit on its branch, push, 4-minute stop)

| Stream | Model | Deliverables |
|---|---|---|
| `golden` (runs on the smoke rig, not a worktree) | Fable | drive the installer, reboot without cdrom, KDE first-run + autologin + no screensaver, `savevm golden`, one `loadvm` proof, stage `disk.qcow2` into the station dir; reports pointer transport, VM_SIZE/VM_CLOCK, time to desktop |
| `pcbsd-build` | sonnet-low | `scripts/build-guests/tiles/pcbsd.sh` (fetch CD1 from archive.org, verify sha256, stage `pcbsd.iso`, create `pcbsd.qcow2` 8G and print the assisted-install instructions — do not attempt to automate the GUI), `check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` row |
| `pcbsd-spa` | Fable | `registry/posters/pcbsd.md` in the museum's voice, hero from a real KDE frame when the rig shows one (else the installer frame), `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa` polish (drop the `TODO(spa)` prefixes), a `demoProgram` typed into the focused editor |
| `pcbsd-docs` (after golden reports) | sonnet-low | `docs/guests/pcbsd.md` incl. §Checkpoint from golden's report, `docs/GUEST-TIERS.md`, release-notes JSON, `docs/README.md` index |

## Reserved to the coordinator

Merging, "ready to land" → `git push origin HEAD:main` from this sandbox worktree,
`box-deploy.sh --apply`, `smoke-rig.sh pcbsd --down`, `station-up.sh pcbsd`,
SPA build/deploy, final framebuffer acceptance, teardown of stream sandboxes.

## Golden stream report (measured)

- Install: installer wizard driven over QMP with PS/2 relative moves (driver
  `/data/vms/sandbox/pcbsd/smoke/drv.py`); copy phase ~4.5 min; whole-disk ad0,
  default KDE components; installer sets KDM autologin itself.
- First boot: one-time Display Settings wizard (vesa 1024x768x24 autodetected —
  "Apply" test fails, "Skip" keeps the working default); no Kpersonalizer; KTip
  and Konsole tips unchecked; `~/.kde/Autostart/noblank.sh` (`xset s off -dpms`),
  kdesktoprc ScreenSaver disabled. No xorg.conf written.
- Golden: VM_SIZE 388 MiB, VM_CLOCK 0:11:40, one loadvm proven pixel-identical.
  Fixture = clean desktop, Konsole focused at an empty `%` prompt, pointer at (450,680).
- Shared with the freebsd411 wave: PC-BSD's own X + KDM autologin need nothing
  hand-written; the usb-tablet route is dead on FreeBSD ≤6 — plan for `rel`.

## Measured milestones (from the session transcript, git and box timestamps)

Clock zero = operator's message, 2026-09-02 22:55:38Z. Coordinator + 4 Claude
agents (golden Fable 22 min + 4.5 min rebake, build sonnet-low 2 min, spa Fable
3 min, docs sonnet-low 1 min). Session split: 60% coordinator model time, 19%
tools, 21% waiting on agents (37 min span).

| Milestone | Wall clock | Minute |
|---|---|---|
| ISO fully on the box (7 MB/s from archive.org) | 22:57:30Z | 2 |
| Installer on screen in the smoke rig | 22:58:30Z | 3 |
| `/os/pcbsd` viewable (smoke-rig.sh, slot 179) | 22:59Z | **4** |
| Ledger commit pushed | 23:02Z | 6.5 |
| build / spa / docs merged | 23:08Z | 12 |
| First KDE desktop on the rig | ~23:15Z | 20 |
| First golden (with usb-tablet) staged | 23:21Z | 26 |
| Rebake without the tablet staged | 23:28Z | 32 |
| `main` pushed (7ace57e8), gate green | 23:24:35Z | 29 |
| streamhost@pcbsd LISTENING | 23:28:47Z | 33 |
| SPA + runtime manifests deployed | 23:31:42Z | **36** |

Where the time went vs. pcgeos (18 min): the GUI install itself (~5 min copy +
~5 min first boot with the Display Settings wizard) is irreducible for this OS;
**~9 min were lost to the usb-tablet** — declared `abs` in the ledger from the
reactos sibling, dead on FreeBSD 6.3 X, and the validator rightly refused a
`rel` method next to an absolute device, so the golden had to be re-baked on a
tablet-free set. Lesson for the next BSD/X11 wave: **pick the pointer transport
before the bake** — one PS/2 `rel` nudge and one tablet `abs` move on the
installer screen settle it in 20 seconds, and the launcher never carries a dead
device. Also: `station-up.sh` step 4 republishes the runtime manifests and wipes
every other wave's dark-launch overlay (seven this time), and `labctl gen`
refuses while undeclared station dirs from sibling waves exist — both are
coordination-level, reported to the coordination session.

## Phase 2 — absolute pointer via x11warp (2026-09-03)

Operator: "pointer-based graphical OSes need absolute cursor positioning before
they are considered fully integrated." The usb-tablet is dead on FreeBSD 6.3 X
(phase 1), so pcbsd takes the fleet's `x11warp` route proven the same night on
freebsd411 / netbsd14 / suse64 / redhat62: the daemon warps the pointer inside
the guest's X server over TCP and reads it back.

- Device set gains ONE device: `-netdev user,id=n0,hostfwd=tcp:127.0.0.1:6079-10.0.2.15:6000
  -device e1000,netdev=n0` (display :79 was this wave's allocation). Everything
  else unchanged, so a new golden was baked on a sandbox clone of the live disk
  (`/data/vms/sandbox/pcbsd/abs/`, never the station) and staged as
  `disk.qcow2.x11warp`, swapped in during the landing window.
- Guest: X listens on TCP (KDM `ServerArgsLocal` without `-nolisten tcp`),
  `xhost +10.0.2.2` appended to `~visitor/.kde/Autostart/noblank.sh`, `em0` on DHCP.
- Fixture: `SH_INPUT_BACKEND=x11warp`, `SH_X11WARP_DISPLAY=127.0.0.1:79`,
  `SH_CURSOR_SCALE=1.0`; registry `stream.pointer` = freebsd411's shape, emit
  `--pointer abs --input-backend x11warp`, no legacy `SH_POINTER`.
- **pf is the trap** (not in the fleet recipe until now): PC-BSD 1.5.1 ships
  `pf_enable="YES"` with `/etc/pf.conf`, which resets inbound :6000 even once X
  listens. Appended `pass in quick on em0 proto tcp from 10.0.2.2 to any port 6000`
  and `pfctl -f /etc/pf.conf`; the rule loads at boot via `pf_rules` and the
  running ruleset is inside the vmstate. kdmrc: `[X-:*-Core] ServerArgsLocal=`
  (was `-nolisten tcp`, line 469); no `Xservers` file on PC-BSD; `em0` was already
  `DHCP` in rc.conf. After reboot `sockstat -4l` shows `Xorg tcp4 *:6000`, `xhost`
  prints `INET:10.0.2.2`.
- Proof on the clone (golden stream, Fable, 15 min): `xdpyinfo -display 127.0.0.1:79`
  answers (X.Org, 1024x768); `scripts/dev/x11ptr.py 127.0.0.1 6079 X,Y q` warps read
  back **(100,100)** and **(900,650)** exactly, cursor sprite on both frames
  (`/data/vms/sandbox/pcbsd/abs/w1.png`, `w2.png`). Golden: VM_SIZE **296 MiB**,
  VM_CLOCK 0:12:55, restore pixel-identical and `query_pointer` = (450,680) after
  the restore; power-on → desktop ≈90 s. Staged as `disk.qcow2.x11warp`, swapped in
  during the landing window (old kept as `disk.qcow2.rel-bak` until the live proof).

## Phase 3 — retronet web + ICQ planes (2026-09-03)

Operator: join pcbsd to the museum's offline period internet on both planes.
Delegated to ONE Opus subagent (60 min, 205 tool uses); the coordinator briefed,
reviewed and landed. As-built: `docs/lab/retronet/STATION-pcbsd.md`.

- Device set gains a second NIC, a bridged tap: `-netdev tap,id=n1,ifname=pcbsdrn0,
  script=no,downscript=no -device e1000,netdev=n1,mac=$RN_PCBSD_MAC` (MAC from
  `registry/local.env`, placeholder in the launcher) → `em1`, DHCP-reserved
  **10.99.0.29**, guard chain `PCBSDRN-IN` armed by `rn-tapnet.sh up` on every launch
  (os2warp pattern; the `pcbsd-rn-tapnet` box-sync pair mirrors the script). The
  x11warp slirp NIC stays as `n0` and now runs **`restrict=on`** — without it the
  guest kept a default route into the host's stack; with it the containment table
  from inside the guest is: gateway :80/:5190/ping OK, host :8443/:22 blocked,
  1.1.1.1 no route. `restrict=on` is a netdev option, so the device set is unchanged.
- Guest: `ifconfig_em1="DHCP"`; the tap lease's `nameserver 10.99.0.2` wins over the
  slirp lease on its own; pf (on by default) gets `pass in quick on em1 from
  10.99.0.0/24 to any` + `pass out quick on em1 from any to 10.99.0.0/24`.
- Web: Konqueror 3.5.8 (KHTML, the 4th Kicker icon as shipped) renders
  `http://search.retronet/` with no proxy. `periodBrowser` corrected accordingly.
- ICQ: **Kopete 0.12.7 was already on the CD1 install.** UIN 17900, server
  10.99.0.2:5190, `AutoConnect=true`, auto-away off, started from
  `~/.kde/Autostart/kopete.sh`; roster row + `seed_contacts.py ssi --apply`. The wizard
  is drivable by x11ptr warp + QMP click; **the trap is KWallet** — Kopete 0.12 opens
  the wallet regardless of `kwalletrc Enabled=false`, and cancelling loses the
  password; run the KWallet wizard to Password Selection and Finish with "use the KDE
  wallet" UNCHECKED, then Kopete's "Remember password" sticks in kopeterc. Proven by a
  full power cycle: silent sign-in, roster populated, HiveBot greets.
- Golden: VM_SIZE **305 MiB**, VM_CLOCK 0:11:39, restore pixel-identical; after the
  restore HiveBot is online in the list and `x11ptr.py … 470,690 q` reads back
  exactly. Scene: Kopete contact list top-left showing HiveBot, **Konsole focused =
  keyboard surface**, no chat window baked, pointer at (470,690). KWin is
  ClickToFocus: the last click decides where keys land. Staged as `disk.qcow2.rn`.
- Unproven: Firefox (the panel's first icon) on the web plane; reconnect after a
  link loss; resolv.conf ordering observed, not pinned.
