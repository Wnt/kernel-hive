# suse64 wave — SuSE Linux 6.4 i386 (2000), KDE 1.1.2 on XFree86 3.3.6, absolute pointer

Operator ask (2026-09-02): "a new record in how fast we can integrate a new
station … early SUSE Linux". Procedure: `docs/lab/ADD-NEW-OS-PLAYBOOK.md` §0.
Scaffold sibling: `freedos` (cirrus + PS/2); runtime/pointer shape copied from
the concurrent `netbsd14` wave (x11warp over a loopback X forward, `/opt/qemu-beos`).
Coordination across the six concurrent waves: the "os station integrations
coordination" session allocated slot 180; landing is serialized through it.

## Allocation ledger

| Value | Allocation |
|---|---|
| id / stationDir / SH_STATION | `suse64` |
| slot / UDP / VMID | 180 / 54180 / 180 (kh-claimed by `smoke-rig.sh`, session `suse`) |
| X forward (host loopback → guest) | 127.0.0.1:6080 → 10.0.2.15:6000, `SH_X11WARP_DISPLAY=127.0.0.1:80` |
| render orders | as assigned by `stations-registry.py new --like freedos --slot 180` |
| QEMU | `/opt/qemu-beos/bin/qemu-system-x86_64`, `pc-i440fx-11.0,acpi=off`, KVM, `-cpu host`, guest kernel booted `noapic` (the INSTALL ran under TCG — see "The wall"), 256 MB, 1 vCPU, `-vga cirrus`, one IDE qcow2 (4 GiB), `ne2k_pci` on SLIRP, no audio |
| Release | SuSE Linux 6.4 (2000-03-28 README; retail six-CD set), i386: kernel 2.2.14, XFree86 3.3.6 (+4.0), KDE 1.1.2, YaST2 installer (YaST1 for admin) |
| Media | archive.org item `suse-linux-6.4`, `suse-linux-6.4-cd1.iso` — **663 029 760 bytes**, sha256 `5a835e4bba03485f17f31d6b8204881a77c1206571b27e8300c889e8bf721a33`; staged `/data/assets-staging/suse64/` (labhost path) with `MANIFEST.sha256`. Only CD1 is used. |
| Smoke rig | `/data/vms/sandbox/suse/smoke/` (`launch-smoke.sh [d|c]`, `run-daemon.sh`), published at `/os/suse64` |
| Golden disk | staged to `/data/gallery-guests/SUSE64/suse64.qcow2`; the launcher copies it to the station dir on first start |

Measured on the smoke boot (framebuffer, 640x480 text): the 2.2.14 install kernel
sees `hda` (QEMU HARDDISK, 4096 MB), `hdc` (ATAPI CD), `fd0`, and loads the
47 140 KB linuxrc ramdisk in ~8 s under KVM.

## Streams (each `wt.sh new suse64-<stream> --from suse`, 4-minute stop except golden)

| Stream | Model | Owns |
|---|---|---|
| golden | Fable | the smoke rig: YaST2 install from CD1, `/etc/XF86Config` (SVGA on cirrus, 1024x768x16), console autologin → `startx` → KDE 1.1.2, `xhost +10.0.2.2`, bake `golden` with the station device set (no cdrom), one `loadvm` proof, stage the disk; facts reported to the coordinator who fills `station.env.fixture` + registry truth |
| build | sonnet-low | `scripts/build-guests/tiles/suse64.sh`, `check-assets.sh`, `ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` |
| spa | Fable | `registry/posters/suse64.md`, hero + frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` in the entry (the scaffold carries netbsd14's demoProgram as a placeholder — replace it) |
| docs | sonnet-low (after golden) | `docs/guests/suse64.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` |

## Timeline (measured after landing with session-timeline.py)

TODO(coordinator)

## The wall, and the race (2026-09-03)

Under KVM the YaST2 install crawled: mke2fs of the 4 GiB root took 17 min and the
package copy ran at **70 KiB/s** (4 of 281 packages after 5 min). Cause, measured
by the concurrent redhat62 wave: the 2.2.14 kernel drives the emulated IDE disk in
16-bit PIO and every `outw` is a KVM exit (~28 µs; one 512-byte write per ~19 ms).
`ide0=dma`, `-cpu pentium3`, `kernel-irqchip=off` and a tmpfs disk all measure the
same; `-accel tcg` runs the identical install ~20x faster. Race (3-QEMU cap):

| Theory | Runner | Result |
|---|---|---|
| keep the KVM install running | baseline | LOSS — 70 KiB/s, hours |
| `ide0=dma` boot parameter | cancelled | redhat62 measured DMA flags as no-ops under KVM |
| rig restarted under `-accel tcg -cpu pentium3`, 1.5 GiB disk | golden (Fable) | **WIN** — CD boot to YaST2 60 s, copy 1.5 MiB/s (47.6 MB/31 s), all 281 packages + LILO in 10 min |
| `lsi53c895a` SCSI disk under KVM (DMA by design, `ncr53c8xx` module) | sonnet | UNMEASURED, killed at 12 min: under the same load the installer's own 47 MB ramdisk load from the ATAPI CD (PIO too) had not finished, so the theory never reached mke2fs; the 3-QEMU cap went to the TCG rig |

Decision (revised after wall 2): TCG is the install-time tool only; the station runs
under KVM with `noapic`, and the golden is baked under KVM (a TCG station burns a core
whenever unpaused).

## Wall 2: the installed SMP kernel loses every interrupt (2026-09-03)

YaST2 picked **k_smp** (the CD's boot kernel saw an MP table from QEMU). On the
first disk boot it prints `PIIX3: not 100% native mode`, `hda: IRQ probe failed (0)`,
`keyboard: Timeout - AT keyboard not present?`, then loops `hda: lost interrupt`
(one ~10 s timeout per sector) under TCG **and** KVM; the CD's UP install kernel had
booted the same disk fine under both. Raced with three clones off a sparse copy of
the installed disk, LILO driven at its prompt:

| Theory | Result |
|---|---|
| `-kernel <bzImage> -append root=/dev/hda3` (both kernels, both accels) | LOSS by method — QEMU's linuxboot hangs at "Booting from ROM…" with these 2.2.14 images; never use `-kernel` here |
| `linux noapic` at the LILO prompt, TCG | **WIN** — full boot into YaST2's second stage in ~65 s |
| `linux noapic`, KVM | WIN — fsck clean at 16 s; PIIX DMA state unmeasured |
| `linux ide=nodma`, TCG | untested (the first round's keystrokes never reached LILO, see trap) |
| `lsi53c895a` SCSI disk, KVM | killed unmeasured (see above) |
| CD `k_deflt` written over `/boot/vmlinuz.suse`'s blocks | abandoned — `debugfs blocks` lists the IND/DIND metadata blocks too; the first write clobbered an indirect block; superseded by noapic |

Permanent fix: `append = "noapic"` in `/etc/lilo.conf`, rerun `lilo`. Traps: a
`sendkey shift` does NOT stop LILO's 3-second `timeout`; `sendkey spc` does —
start QEMU with `-S`, `cont`, spam `spc` for ~6 s, then type the line
(`/data/vms/sandbox/suse/race/k/lilo-race.sh`). `qmp-type.py --out` treats the
path as a directory (`<out>/cur.png`). Relayed to the redhat62 wave, which hit the
same symptom with `kernel-smp`.
