# The Virtual OS Museum as a research reference

**What it is:** [virtualosmuseum.org](https://virtualosmuseum.org/) — Andrew
Warkentin's single Linux VM packing **1703 OS installations across 922 OS
families and 295 hardware platforms**, each with a working emulator
configuration. Source at [gitlab.com/virtualosmuseum](https://gitlab.com/virtualosmuseum/).

**Why it matters to us:** the expensive part of
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) §1 is finding out *which
emulator runs this OS, from which image, obtained where*. Someone has already
answered that 1703 times and published the answers with attribution. Treat this
as the first stop for any new candidate — before spending an agent on recon.

---

## READ THIS FIRST: the licence boundary

**Their launcher, scripts and metadata are CC BY-NC-SA 4.0** — the README states
"licensed for non-commercial redistribution only" — plus a MAME-licence file
covering vendored code. **Kernel Hive is MIT and its repo is public.**

Those do not mix. NonCommercial contradicts MIT's grant, and ShareAlike would
try to propagate into whatever it touches.

**So: this is a reference to read, never a source to copy from.**

| Allowed | Not allowed |
|---|---|
| Read a boot script to learn *which emulator and which image* | Copy a boot script, config, or metadata file into this repo |
| Follow their upstream link and fetch the media yourself | Vendor their `_config` directories or `info/` files |
| Cite the upstream project (bitsavers, the image author, the emulator) | Cite/import their packaging as our source |
| Derive our own launcher args independently | Paste their argument strings verbatim |

This is the same posture we already use for bitsavers and archive.org, so it
costs nothing: **learn the fact, then get the artifact from its origin.** If a
finding came from here, credit the Virtual OS Museum in prose — do not import
its files.

---

## The five repos

| Repo | What it holds | Use to us |
|---|---|---|
| `virtualosmuseum` | The launcher layer — **316 boot scripts**, 13 emulator backend wrappers, 164 emulator metadata files, `CREDITS.md` | **Primary.** Which emulator runs what, and how |
| `virtualosmuseum-site` | The Jekyll website, incl. **`installation-list.markdown`** | **The catalog.** Machine-readable index of all 1703 installations |
| `virtualosmuseum-host-scripts` | Host-side wrapper that launches the VM (`linux_wrapper/`, `main/`) | **How to run the VM here** — see below |
| `virtualosmuseum-site-test`, `-webtorrent-test` | Staging site, torrent-distribution experiment | Ignore |

Cloned locally, deliberately **outside** this repo so nothing NC-SA can be
committed by accident: `~/vom-repo` (launcher), `~/vom-site` (catalogue),
`~/vom-host-scripts` (VM runner).

### The media itself, and how to read it without running the VM

The full edition is downloaded to **`~/virtualosmuseum/virtual_os_museum-2026.06.12-full.zip`**
(130 GB), and its guest-image disk is extracted, kept, and reusable at:

**`~/vom-extract/guest_images.vdi`** — 173 GB apparent, ~126 GB on disk (written
sparse), a 5 TB VDI holding one **btrfs** filesystem with every installation
under `/images/<platform>/.../<name>_config/`.

Extract it again, if it is ever lost, with a sparse stream — no unzip to a
temporary file, and zeros never hit the disk:

```bash
unzip -p ~/virtualosmuseum/virtual_os_museum-2026.06.12-full.zip \
  "virtual_os_museum-2026.06.12-full/VirtualOSMuseum.utm/Data/guest_images.vdi" |
  dd of=~/vom-extract/guest_images.vdi bs=4M conv=sparse status=progress   # ~35 min
```

**Mounting it needs labhost**, because the dev container (CT950) has no
`/dev/nbd*`, no `/dev/loop-control` and no `/dev/fuse`. Serve it from wherever
the file is and attach from labhost, which has the kernel side:

```bash
# on the box holding the file (userspace server, no kernel module needed):
qemu-nbd --read-only --format=vdi --port 10809 --bind 0.0.0.0 --persistent --fork \
  ~/vom-extract/guest_images.vdi
# on labhost:
modprobe nbd max_part=8
qemu-nbd -c /dev/nbd0 --read-only nbd://<that-box-ip>:10809
mount -o ro /dev/nbd0p1 /mnt/vom      # btrfs; plain -o ro, NOT ext4's noload
# afterwards
umount /mnt/vom && qemu-nbd -d /dev/nbd0
```

What you can and cannot open once mounted: their **config directories are plain
files** (`cfg.emu`, `PASSWD`, `INFO/info`, the disk image) and readable, but a
guest's own filesystem usually is not — Tru64's `dka0.dd` is **AdvFS**, which
Linux cannot mount at all. For those, read the raw image with `grep -a` /
`strings`, which is enough to answer most questions, or boot it in an emulator.

The launcher repo is **3.5 MB and contains no media**. Images are delivered as
Debian packages named `os-museum-machine-<name>-image` from an apt mirror; the
mirror URLs committed to the repo are placeholders (`10.0.2.2`, the VM's SLIRP
host, plus `.invalid` entries), so the real ones live inside the distributed VM.

### `CREDITS.md` is the attribution index

**148 emulators and 116 pre-installed images, each with an upstream URL and the
person who made it** — neozeed, Peter Schorn, Bruce Ray, Dave Pitts, Seth
Morabito, Warren Toomey and others. When we need media provenance for
`ASSETS-MANIFEST.md`, this is the shortest path to the *real* origin.

Note the gap: **316 boot scripts against 116 credited images.** The other
two-thirds are installs Warkentin performed himself, so for those the boot script
is the only record of what configuration works.

### Running the VM on labhost

From `~/vom-host-scripts/main/scripts/run_qemu`, the shape they ship is
`qemu-system-x86_64 -enable-kvm -M pc,vmport=off -m 8G`, xHCI + `usb-mouse`,
AHCI, user networking, and a 9p `virtfs` share. Three things matter for us:

- **Two disks, and the split is useful.** `host_x86.vdi` is the Linux host
  system; **`guest_images.vdi` is the OS images**. The images are separable from
  the VM that browses them, so extracting one image does not require running the
  whole museum.
- **Pass `-n` on labhost.** The default uses `virtio-vga-gl` with `gl=on`, and
  labhost has no GPU; `-n` falls back to standard VGA. Also replace
  `-display sdl` with VNC or a headless display — there is no seat to attach to.
- **`-a` / `-A <dir>` puts the VM into "release preparation mode"**, mounting a
  host directory as its **apt repository** over 9p. That is the seam where the
  `os-museum-machine-*-image` packages come from, and it is how you would feed
  or inspect the media locally rather than chasing the placeholder mirrors.

8 GB and KVM is a real cost on labhost, already running the fleet — check for
in-flight measurement work before starting it.

---

## Querying the catalog

The catalog is a Markdown table with columns
`OS/distribution | Name | Version | Installation variant | Platforms`:

```bash
curl -s "https://gitlab.com/api/v4/projects/virtualosmuseum%2Fvirtualosmuseum-site/repository/files/installation-list.markdown/raw?ref=master" -o vom-list.md
```

Note `ref=master`, not `main` — the default branch is `master` and a wrong ref
returns `404 Commit Not Found` rather than an error you can read.

```python
rows = []
for line in open("vom-list.md"):
    if not line.startswith("|") or set(line.strip()) <= set("|-"):
        continue
    c = [x.strip() for x in line.strip().strip("|").split("|")]
    if len(c) >= 5 and c[0] != "OS/distribution":
        rows.append(c)   # [family, name, version, variant, platform]
```

Largest platforms: x86 PC (420), PDP-11 (48), Apollo Guidance Computer (38),
Altair (30), HP 21xx/1000/2000 (29), VAX (28), TRS-80 II/12/16/6000 (27),
PowerPC Mac (26), System/360 (25), 68k Mac (24).

---

## What it settled the day we found it

Four checks against studies that were open at the time, in minutes rather than
agent-hours.

### Longhorn — build 4051 exists and runs there

Five pre-reset builds are catalogued: **3683, 4008, 4020, 4032.Lab06, and
4051.idx02.031001-1340**. That last one is the PDC 2003 build — **the
WinFS-bearing one** — and someone has it booting on `x86 PC`. Directly relevant
to [`longhorn-add.md`](longhorn-add.md): it is strong evidence the build boots
under emulation at all, and 4051 is a candidate even though the operator's
reference screenshot is 4074. The list stops at 4051; **4074 is not there.**

### DEC Alpha — a negative result that was REFUTED, and the lesson from it

They run Alpha (boot script `alphavm`, using **AlphaVM Free** from EmuVM) and
catalogue **Tru64 UNIX 5.1B** and **OpenVMS Alpha 7.3-1** — but **no Windows NT
or 2000 for Alpha**, while **NT 4 for MIPS** *is* there.

I read that as strong evidence Alpha NT was materially harder than Alpha Unix.
**It was not.** [`alpha-nt-add.md`](alpha-nt-add.md) then built ES40-Emu/es40 on
labhost, flashed ARC/AlphaBIOS, and drove Windows 2000 RC2 for Alpha into its
file-copy phase with a framebuffer screenshot of every step.

The catalogue's silence had a mundane cause: **AlphaVM Free has no VGA at all**
(EmuVM's FAQ: supported guests are *"OpenVMS and Tru64/Digital Unix"*), so it
*cannot* boot NT, which needs ARC. VOM has no Alpha NT because of the emulator
it happens to use.

**The lesson, and it applies to every future use of this catalogue: absence is
evidence about their toolchain, not about the world.** A hit here is a strong
positive — someone has it working. A miss is only a hint, and it must never
outrank an experiment.

### Tru64 and the OSF-BASE PAK — they did not solve it either

Asked in 2026-08-17 whether VOM had an answer to the licence wall blocking
non-root logins on our `tru64` station (no OSF-BASE PAK -> dtlogin refuses a
non-root autologin with "Too many users logged on already"). Read out of their
own media, not inferred:

- **Their guest logs the identical complaint.** `vmunix: Can't find an OSF-BASE,
  UNIX-WORKSTATION, or UNIX-SERVER license PAK` appears in the syslog inside
  `dka0.dd`. A registered base PAK would silence it. They are running the same
  unlicensed state we are.
- **No PAK is registered.** The only PAK-shaped text in their disk is the blank
  `lmf` entry template (`Authorization Number:` with nothing after it).
- **Their exhibit is used as root.** Login records inside the image show only
  `root` on `:0`; there is no `Dtlogin*autoLogin` resource at all, so a visitor
  meets the CDE greeter and logs in with the password their config publishes
  (`PASSWD`: `root: decosf1`). A second account, `decuser`, exists in
  `/etc/passwd` — it appears in FTP contexts, never in a login record.
- **Their emulator is AlphaVM Free, not es40** (`cfg.emu`: `type = es40_833`,
  `ssn = 'AlphaVM-00000001'`, `ether ... dec21143 ... server = tap`, a
  `scsi_disk dka0.dd` and the 5.1B CD). Worth knowing for a different reason:
  AlphaVM exposes the **system serial number** as a config knob, and a Tru64 PAK
  binds to exactly that field. It is the seam a legitimately-held PAK would need;
  they do not use it for that, and neither can we without a PAK.

So the answer for our station is that there is nothing to copy: **the museum
that has run Tru64 the longest ships it root-only, exactly as ours does now.**
See [`docs/guests/tru64.md`](../../guests/tru64.md) for our side of the same wall.

### Xerox — Duchess confirmed, and a variant we missed

Catalogued: **`Pilot (GlobalView) 2.1 for Windows — variant "For Dwarf"`**. That
is exactly the Duchess route flagged as "worth an hour" in
[`xerox-add.md`](xerox-add.md) §3.8 — someone runs GlobalView's Mesa image under
Dwarf with no Windows and no QEMU, and it works well enough to ship. Also
present: **GlobalView 1.05 for X on SunOS**, **Pilot (XDE) 15.3**, and five
**Alto OS** variants (Games, Smalltalk-76, BravoX, BCPL, Diagnostics) — the
Smalltalk-76 pack is one our Alto study did not fetch.

### NeXTSTEP — the full version ladder

Fourteen NeXTSTEP installations, 0.8 through 3.3, plus **NeXTSTEP 3.3 for x86**,
all under **Previous** (the same emulator our `nextstep` station uses).

---

## What it deliberately excludes

Worth knowing before searching for something that will never be there. Their
policy excludes: emulators that boot a ROM but not an OS; user-level/syscall
emulators; ordinary console and arcade games; and **commercial OS versions newer
than 10 years old, still sold, or subject to known takedown requests.** That last
clause is why there is no modern Windows or macOS — and it is a more
conservative line than ours, since our gallery is private and passkey-gated.

---

## How to use it in practice

1. **New candidate?** Query the catalogue first. A hit tells you the platform
   name they use, the exact version that works, and — via the boot script — which
   emulator to reach for.
2. **Follow `CREDITS.md` to the upstream** and fetch media from there, recording
   URL + measured sha256 + licence class in `ASSETS-MANIFEST.md`. Never the bits;
   the repo is public.
3. **Derive our own launcher.** Read theirs for what works, then write ours
   against our bridge/QEMU conventions. Do not copy.
4. **A miss is evidence too** — see the Alpha NT case above. Absence from a
   1703-entry catalogue is a signal worth reporting in a feasibility study.

## Caveats

- Their goal is *boots and runs*, ours is *streams as an exhibit with an absolute
  pointer, a stable rest state and a checkpoint reset*. A machine being in the
  catalogue says nothing about whether it makes a good station.
- Emulator versions may be patched; `CREDITS.md` notes patches are common
  (usually to build on newer Linux or to relocate a hardcoded `$HOME` path).
- The catalogue records what is in the VM, not how hard it was to get there.
