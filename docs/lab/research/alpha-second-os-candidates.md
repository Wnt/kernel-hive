# A second OS on the w2kalpha machine — candidate survey

**Written 2026-08-11.** Desk research only: no box access this session, nothing
installed, nothing measured here. Every claim below is sourced or explicitly
marked **UNVERIFIED**. Companion to
[`alpha-nt-add.md`](alpha-nt-add.md) (how the ES40 machine was brought up) and
[`w2kalpha-HANDOFF.md`](w2kalpha-HANDOFF.md) (where everything lives).

**Question asked:** now that `w2kalpha` runs Windows 2000 RC2 on an emulated
AlphaServer ES40, what *other* OS could run on the **same emulated machine**,
and is its install media obtainable from the archival sources we already use?

**Short answer:** five OS families are compatible with that machine, and the
upstream emulator lists four of them as working **with graphics** — which is the
only property that matters here, because [the framebuffer is the only
proof](../../AGENTS.md). Ranked recommendation in §5. The single best
technical/legal package is **NetBSD/alpha 10.1**; the single best *exhibit* is
**Tru64 UNIX 5.1B** (CDE on DEC's own UNIX), and it is the one that overturns a
"dead-end" verdict currently recorded in
[`os-media-catalog.md`](../../catalog/os-media-catalog.md).

---

## 1. What "the same emulated machine" actually means

`w2kalpha` is **not** a QEMU tile. It is the es40 emulator (fork
[`Wnt/es40`](https://github.com/Wnt/es40) of
[`ES40-Emu/es40`](https://github.com/ES40-Emu/es40)) running headless, with our
own shm framebuffer export and `mamectl/1` input socket. The machine it presents
is fixed by `assets/w2kalpha/es40.cfg` and the flashed `rom/`:

| element | value | matters because |
|---|---|---|
| System | AlphaServer ES40, Tsunami/Typhoon chipset | every guest below must support Tsunami — all do (DS20/ES40 class) |
| CPU | 21264 EV68, 1× | Linux `CONFIG_ALPHA_DP264`, NetBSD `TSUNAMI`, VMS/Tru64 native |
| RAM | `memory.bits = 29` (512 MB) | W2K GUI setup needed it; others need less, but leave it |
| Firmware | SRM v7.3-1 **and** AlphaBIOS 5.71 in a persisted 2 MiB `flash.rom` | **SRM boots VMS/Tru64/BSD/Linux; AlphaBIOS/ARC boots Windows.** Both already flashed — this is the thing that is usually hard, and it is done |
| Video | S3 Trio64 (MAME port) | the framebuffer; every candidate must drive VGA or there is no exhibit |
| Disk/CD | `sym53c810` SCSI (`disk0.0` system, `disk0.4` CD); `ali_ide` present, no drives | upstream's reference layout; the IDE path is the slow one |
| Input | ALi M1543C PS/2 keyboard + mouse, reached over our `ctl.sock` | guest-agnostic: any guest with PS/2 drivers gets input for free |
| NIC | `dec21143` (tulip) | upstream: networking **confirmed only on OpenVMS**, "may work on Tru64" |
| Serial | two ports, both must have a client at startup (`pumps.py`) | a serial-console guest is *drivable* but produces no framebuffer |

Two consequences worth stating plainly:

- **Our runtime is already OS-agnostic.** shm capture is taken at the S3
  device and `mamectl` injects at the PS/2 controller — neither knows or cares
  what the guest is. A second tile reuses `x11-runtime.sh` and `pumps.py`
  essentially verbatim, with a different asset dir. The porting cost is the
  *guest install*, not the plumbing.
- **The `flash.rom` is per-golden.** Ours carries an SRM NVRAM script that runs
  `arc` at every power-up (the unattended path into AlphaBIOS for Windows). A
  SRM-booting guest (VMS/Tru64/BSD/Linux) needs its **own** `flash.rom` with a
  different `edit nvram` script (`boot dka0` or similar) — same file, different
  contents, staged in that tile's own asset dir. Do not share one flash image
  between two tiles.

## 2. What upstream says runs — the authoritative list

From the [ES40-Emu/es40 README](https://github.com/ES40-Emu/es40) status
section (our fork is pinned at upstream tip `a9bda96`, so these fixes are in):

> "OS Support list looks like this now: Windows NT4 **with graphics** · Windows
> 2K RCs and AXP64 2210 with some effort **with graphics** · OpenVMS 8.4-2L1 and
> 2L2 **with graphics** · Tru64 5.1B **with graphics** · SOME Linux — Red Hat
> Enigma / 7.2 tested, **X11 flawed, needs to be fixed** · NetBSD 6 through 10.1
> at minimum · OpenBSD 4.8, 7.7, and 7.8"

Also from the README: *"Networking is only confirmed working on OpenVMS, however
it may work on Tru64"*, OpenVMS *"boot to login and CDE desktop works"* with
mouse, and Tru64 *"X11 displays from the install CD 5.1B"* while installation
*"still fails on SCSI disk"*.

The 2026 issue tracker shows this is live work, not folklore: Tru64 boot-device,
SCSI-CAM and SDL-GUI panics all closed in July 2026 (one open: unaligned-access
fixup hang); NetBSD tulip/SCSI-CD issues closed May–June 2026; OpenVMS X11 login
failure closed May 2026 (one open BUGCHECK). **We are riding a moving target —
re-read the README and issue list at build time.**

## 3. Candidates, with media

Legal-posture buckets are the catalog's
([`os-media-catalog.md`](../../catalog/os-media-catalog.md) §"Legal posture").

### 3.1 Tru64 UNIX 5.1B — the exhibit-value pick

- **Compatibility:** native ES40 platform (this is literally the OS the hardware
  shipped with); upstream lists it **with graphics**.
- **Media:** [archive.org `tru-64-unix-5.1-b`](https://archive.org/details/tru-64-unix-5.1-b),
  the older [`compaqtru64unix51`](https://archive.org/details/compaqtru64unix51)
  (OS + Associated Products vols), the
  [Tru64/Digital UNIX/OSF-1 SPL collection](https://archive.org/details/tru64-spl-collection),
  and [WinWorld `tru64/51b`](https://winworldpc.com/product/tru64/51b). All
  sources we already use. **UNVERIFIED:** none fetched or hashed this session.
- **Posture:** contested-commercial (HPE). Worse than NetBSD, comparable to the
  IRIX and Solaris tiles already on the wall.
- **The gating unknown — license PAKs.** Tru64 gates products behind `lmf`
  PAKs; whether a PAK-less install reaches **CDE** (as opposed to console
  multi-user) is **UNVERIFIED and is the first thing to settle** — it decides
  whether this is an exhibit or a login prompt. PAK lists circulate publicly;
  using one is an operator call, not an agent's.
- **Risk:** upstream's own "installation still fails on SCSI disk" note. The
  documented workaround shape is the reverse of ours (install from CD on IDE,
  run from SCSI) — cheap to try, **UNVERIFIED**.
- **Why it is worth it:** the gallery has no Tru64, `os-media-catalog.md`
  currently records Tru64 as a **dead-end** ("qemu-system-alpha `clipper` has no
  SRM firmware; commercial emulators are serial/headless only") — a verdict
  written before we had es40 with a working S3. If Tru64 comes up with CDE, that
  catalog row needs rewriting and the museum gains DEC's own UNIX on DEC's own
  64-bit hardware.

### 3.2 OpenVMS Alpha 8.4-2L1 / 8.4-2L2 — best-supported, licence-blocked

- **Compatibility:** upstream's *primary* guest — graphics, CDE desktop, mouse,
  and the only guest with confirmed networking.
- **Media:** [archive.org `alpha-0842-l-1`](https://archive.org/details/alpha-0842-l-1)
  — "OpenVMS Alpha V8.4-2L1 Install ISO and student kit", a 280 MB Windows
  installer bundle (`VSIOPENVMSSTUDENTPACKAGE.EXE`) whose `instructions.txt`
  says only "run it on Windows". Unpacking it on Linux (`7z`/`innoextract`) to
  get the ISO **and any PAKs** is **UNVERIFIED**.
- **Posture:** **the problem.** VSI pruned the hobbyist programme: Alpha/Itanium
  community licences were issued only until **March 2025**, and the Community
  Licence Program is now **x86-64 only**
  ([VSI](https://vmssoftware.com/community/community-license/),
  [The Register 2024-04-09](https://www.theregister.com/2024/04/09/vsi_prunes_hobbyist_prog/)).
  So there is no route to a *current* Alpha PAK. Any PAK inside the archived
  student kit is time-limited.
- **The one clever angle:** es40's `time = "YYYY-MM-DD"` knob — the same trick
  that defuses the RC2 timebomb on `w2kalpha` — pins the guest TOY clock, and an
  expired-PAK problem is a clock problem. Whether that satisfies VMS's licence
  checks, and whether doing so is acceptable, is **UNVERIFIED and an operator
  decision**, not a technical one.
- **Museum note:** we already exhibit OpenVMS 9.2 on x86-64 (poster + tile). An
  Alpha VMS tile would be a genuine *pairing* — the same OS, the same DECwindows
  desktop, two architectures and 25 years apart — rather than a duplicate. That
  is the strongest argument for it, and the licence is the strongest against.

### 3.3 NetBSD/alpha 10.1 — cleanest package, lowest risk

- **Compatibility:** upstream tests "NetBSD 6 through 10.1 at minimum";
  ES40/Tsunami is a supported NetBSD/alpha platform, and third parties have
  booted NetBSD on es40-family emulators for years (e.g. the
  [AXPbox NetBSD 9.2 guide](https://github.com/lenticularis39/axpbox/wiki/NetBSD-9.2-install-guide),
  [NetBSD 8 on es40](https://astr0baby.wordpress.com/2018/10/11/netbsd-8-on-alpha-es40-simulator/)).
- **Media:** [`NetBSD-10.1-alpha.iso`](https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/images/),
  362 MB, from the vendor CDN with published checksums. **Verified to exist this
  session** (directory listing fetched).
- **Posture:** **officially-free (BSD-2)** — the best licence class in the
  catalog, and the only candidate here with no archival or ownership question at
  all.
- **Risk:** the exhibit, not the boot. A console-only NetBSD is a text screen;
  X11 on the S3 Trio64 under NetBSD/alpha (select the X sets, `wsfb` vs a real
  S3 driver, `ctwm`) is **UNVERIFIED** and is the whole question.
- **Why it still ranks high:** it is the cheapest possible proof that our
  headless-es40 runtime is *generic* rather than a W2K one-off, and it can be
  attempted with zero legal deliberation.

### 3.4 Windows NT 4.0 for Alpha — lowest technical risk, lowest novelty

- **Compatibility:** upstream's best-rated Windows guest ("NT4 with graphics" —
  no "with some effort" qualifier, unlike our own W2K RC2). Same ARC/AlphaBIOS
  boot path already flashed and scripted. No timebomb.
- **Media:** retail NT 4.0 CDs are **multi-architecture** (`\ALPHA` beside
  `\I386`), so there is no separate SKU to hunt — the discs already catalogued
  for `nt4` carry it. SP6a for Alpha is on archive.org
  ([`WinNT40SP6aISOEXE`](https://archive.org/details/WinNT40SP6aISOEXE) and
  siblings). Posture: preservation-archive, same as the existing `nt4` tile.
- **Why it is not the recommendation:** [`alpha-nt-add.md` §4](alpha-nt-add.md)
  already settled this — with `nt4`, `win2000` and now `w2kalpha` on the wall, a
  fourth near-identical NT desktop adds a placard, not a screen. Keep it as the
  **fallback** if the interesting candidates fail.

### 3.5 Windows 2000 AXP64 build 2210 — the boldest story, the biggest risk

- **What it is:** the 64-bit Alpha compile of Windows 2000 — the *only* 64-bit
  Windows for Alpha, never released, rediscovered and reconstructed in 2023.
  Upstream explicitly lists it as running "with some effort, with graphics".
- **Media:** [archive.org `axp64-2210-installable`](https://archive.org/details/axp64-2210-installable)
  (~548 MB reconstructed installable ISO). Posture: **leaked pre-release
  Microsoft build** — the same class as our RC2, which the operator has already
  accepted once.
- **Risks, and they are real:** it is a **checked (debug) build** that
  [reportedly wants a kernel debugger attached to boot](https://virtuallyfun.com/2023/05/15/windows-2000-64-bit-for-alpha-axp/)
  (we have two emulated serial ports and already own both ends — plausible, but
  **UNVERIFIED**); the known-good hardware target there was a **Miata** HAL, not
  ES40; and there is **no WOW** — it runs only ALPHA64 binaries, so the desktop
  has no Solitaire, no IE, nothing period-familiar. A near-empty desktop is a
  weak exhibit even with a fantastic placard.
- **Verdict:** an experiment, not a tile plan. Cheap to *try* once another
  Alpha guest has proven the second-tile machinery.

### 3.6 The rest, and why they rank below

| candidate | status |
|---|---|
| **OpenBSD 7.8/alpha** | free, current, [`install78.iso` 232 MB](https://cdn.openbsd.org/pub/OpenBSD/7.8/alpha/), upstream tests 7.7/7.8. But OpenBSD/alpha graphics support is thinner than NetBSD's — likely a console tile. Take NetBSD first. |
| **Red Hat Linux 7.2 "Enigma" alpha** | period-perfect (2001 Linux/Alpha, SRM + `aboot`), media on [archive.org](https://archive.org/details/redhat-7.2-alpha-release). Upstream's own note is **"X11 flawed, needs to be fixed"** — i.e. the framebuffer, the one thing we cannot compromise on, is the known-broken part. Park until upstream fixes it. |
| **Debian/Gentoo Linux alpha** | Debian's last official alpha release is 5.0 lenny; Gentoo alpha stages still build. Not on upstream's tested list at all — strictly more risk than Red Hat 7.2 for the same "Linux on Alpha" story. |
| **Windows NT 3.51 for Alpha** | not on upstream's list; NT 3.51 predates the AlphaBIOS/ARC generation this firmware presents, and its Alpha HAL set does not cover ES40-class machines. **UNVERIFIED**, but the odds are poor and the payoff (a Program Manager desktop) is already covered by the x86 `nt351` entry. |
| **FreeBSD/alpha** | dropped after 6.x, not on upstream's tested list. No. |

## 4. What a second Alpha tile costs

This is the part that should decide how many of these we build, not which one:

- **One permanently saturated core, per tile.** es40 does not idle down
  ([`alpha-nt-add.md` §6](alpha-nt-add.md): ~330–390 MB RSS, ~101 % CPU
  continuous). `w2kalpha` already owns one core forever; a second Alpha tile owns
  a second. On a single box with 60 production tiles that is the real budget
  line, and the reason [§4 of the original study](alpha-nt-add.md) argued for
  **one** Alpha tile.
- **Fresh namespace claims, atomically** (AGENTS.md rule): a second tile needs
  its own udp port + slot, shm path, `ctl.sock`, X11 display slot, **and its own
  serial-port pair** — `w2kalpha` binds 21964/21965, and es40 blocks at startup
  until both have a client, so a collision is a hang, not an error.
- **Its own asset tree** — `assets/<tile>/{es40, es40.cfg, rom/, golden.img,
  root/}`. The es40 binary can be a hardlink to the same build; the `rom/` must
  not be shared (§1).
- **Install effort** is the same shape as the W2K install: hours of framebuffer-
  driven setup, then a golden bake. Budget 2–4 sessions per OS, as before.

## 5. Recommendation

1. **Try NetBSD/alpha 10.1 first** — one session, no licence question, free
   verified media, and it answers the load-bearing generic question ("does a
   non-Windows guest come up on our headless-shm/mamectl runtime?") for the
   price of a download. Its own exhibit value is modest; treat the result as
   infrastructure proof.
2. **Then decide Tru64 5.1B on evidence** — settle the PAK/CDE question and
   upstream's SCSI-install caveat *before* committing a session. If CDE comes
   up, this is the tile worth building, and the `os-media-catalog.md` "dead-end"
   row gets corrected.
3. **Escalate OpenVMS Alpha to the operator, not to a build** — technically the
   best-supported guest we could pick, but the Alpha community licence is gone
   since March 2025 and the only paths run through archived kits or clock
   pinning. That is a posture call.
4. **Keep NT 4.0 Alpha as the declared fallback** and **AXP64 2210 as a
   one-shot experiment**, neither as a plan.
5. **Do not build two Alpha tiles at once** — one more saturated core is the
   ceiling until es40 idle detection exists (`idle_nap` / the WIP
   `kleinmatic/es40:wtint-idle` work noted in
   [`es40-tuning-research.md`](es40-tuning-research.md)).

**Nothing in this document has been executed.** No media was downloaded, no
hashes taken, no guest booted; no lab resources were claimed and there is
therefore nothing to tear down. Every "works" above is upstream's claim or a
third party's, not our framebuffer.
