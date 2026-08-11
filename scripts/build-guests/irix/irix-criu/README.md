# CRIU instant restore for the IRIX tile

A working checkpoint/restore procedure that resets the IRIX exhibit in **~1.2 s
median instead of a 258–275 s cold boot (~210×)**, with no MAME source changes
at all. **It is not shipped**, and may never be — the live tile still resets by
relaunching. This directory exists so the procedure, its evidence and its traps
survive, because every one of the traps below passes a smoke test while broken.

Proved on the real tile: the production launcher, the shipped golden
`irix65-apps-v7.chd`, a private netns and double NAT.

| what | measured |
| --- | --- |
| restore to *demonstrably interactive* | 1.23 s median, n=8 (0.68 / 1.02 / 0.68 s on the netns rig, 3/3) |
| bake freeze with `--leave-running` | 0.38 – 0.77 s |
| ZFS snapshot inside that freeze | 0.06 – 0.29 s |
| image size | 626 MiB apparent, **179 MiB lz4** (58% of it is the DRC cache) + a 0.25–4.3 MB ZFS snapshot |
| cost in launcher changes | 4 hunks (`patchns.py`) + one ZFS dataset |

"Interactive" is not "the process exists": the harness reads the cursor out of
the shm framebuffer, appends a `MOVEP` to the **production** command file, and
stops the clock only when the cursor moves in a real capture.

## The files

| file | what it is |
| --- | --- |
| `ckpt.sh` | the bake/restore pair, with every invariant written into it |
| `nsnet.sh` | the private netns + veth network the procedure needs |
| `patchns.py` | the four launcher deltas, applied to a **copy** of `streamhost/stations/irix/x11-runtime.sh` |
| `curs.py` | the cursor probe the restore clock stops on |

Everything is namespaced through environment variables; nothing has a default
that points at a live tile. Run only against a clone under `/data/vms/soltest`.

## Every attachment survives, simultaneously

This was the open question, and the answer is yes for all of them, verified
channel by channel on every cycle:

- **keyboard** — a Left Shift *held across the checkpoint* still produced
  uppercase after restore.
- **mouse** — the Lua queue resumed mid-drain (12,000 queued = 5,400 + 6,600
  applied, zero counts lost).
- **serial pty** — same `/dev/pts` index, termios restored, no `stty` needed.
- **shm framebuffer** — criu never copies it: same inode, same virtual address.
- **streamhost** — never stopped, reconnected or re-mapped. A real headless
  Chrome WebTransport + WebCodecs viewer rode a full cycle: 177/177 access units
  decoded, `decodeError: ""`, correct decoded frame 1.7 s after the SIGKILL.
- **tap + live guest TCP** — one `connect`, no EOF, across 8 cycles.
- **the 264 MB `rwxs` PROT_EXEC DRC cache** — restored at the byte-identical
  address (`711555de9000`) every cycle. This is a NON-ISSUE; do not re-litigate.

A live guest TCP session survives the **bake** freeze (it kept reading across
iterations straddling it, never reconnecting) but **not a restore**: the guest
rewinds ~20 s while the peer moved on. That is not a defect — a restore rewinds
to bake state, where no visitor session exists. Separately, a surviving
connection can stall up to **43.6 s** after restore while the guest re-sends
already-ACKed bytes; it survives, but it is not usable immediately.

## Required configuration, each found the hard way

- **`-midiprovider none`.** MAME opens `/dev/snd/seq` through the MIDI provider
  **even with `-sound none`**, and criu cannot dump that fd. `--external
  dev[116/1]` does NOT rescue an already-open fd. (Earlier probes also passed
  `-keyboardprovider/-mouseprovider/-joystickprovider none`; the rule is that no
  provider may hold an undumpable fd, and `/dev/snd/seq` is the one that bites.)
- **`nsenter --net=`, never `ip netns exec`** — the latter also unshares the
  mount namespace and dies on Proxmox's `/etc/pve`.
- **`--shell-job --file-locks --manage-cgroups=ignore --join-ns net:…`.** The
  restore wrapper must re-apply the 3 GiB memory cap and the `taskset` pin
  itself, because criu cannot re-create the dead `systemd-run` scope the dump
  recorded.
- **`start_mame` must be OFF the restore path** — it removes `fb.shm`,
  truncates the command file and re-copies the disk.
- **The watchdogs must be stood down.** They poll the framebuffer, **write
  `MOVEP` probes into `irix_cmd`**, and kill/relaunch by pidfile.
- **The command file must not change size by one byte inside the freeze
  window** — criu size-validates every regular-file fd, and one appended `MOVEP`
  fails the restore.

## Egress: solved, and it is not a tradeoff

`--external veth[$INNER]:$OUTER`. Instant restore **and** outbound NAT at kernel
speed. criu deletes and re-creates the veth pair at restore (new ifindex each
cycle) and the host end comes back **bare**, so `nsnet.sh up` is idempotent and
is re-run after every restore; it re-applies host addressing, per-interface
forwarding, the fail-closed chains and the masquerade in ~90 ms.

Verified on the real tile: guest pings 1.1.1.1 (5.7 ms) and the LAN gateway,
`nslookup www.sgi.com` resolves, telnet works. Inbound stays refused, tested
adversarially with static routes to the netns subnets **injected via the lab box
on purpose** to defeat the routing layer: all 15 scanned ports `filtered`, ICMP
100% loss, with a positive control (the same telnetd answers instantly from
inside the netns) proving the filter layer holds on its own.

### slirp4netns and pasta are DEAD ENDS. Do not adopt; do not re-probe.

The premise was right — both hold a tap fd inside the netns from a process in
the **host** namespace, no veth, no peer — and criu still refuses, on a
different rule: it must `TUNSETIFF` every tun/tap in a dumped netns whose fd is
outside the dump set.

- non-persistent tap → `criu/tun.c:275 No fd info for non persistent tun device`
- pre-created persistent tap → `criu/tun.c:248 Can't create tun device: Device
  or resource busy`
- `multi_queue` → slirp4netns dies on `ioctl(TUNSETIFF): Invalid argument`

The only working shape kills the router across both windows, which closes every
host socket it owns — **killing every live guest TCP session at every checkpoint
and every restore.** Also measured dead: `--empty-ns net`, running criu inside
the netns, and `--external net[inode]:name` + `--inherit-fd`.

And the performance was the opposite of pasta's reputation. 300 MB HTTP, 3 runs:

| transport | throughput | RTT |
| --- | --- | --- |
| kernel veth + NAT | **1.63 – 1.68 GB/s** | 0.181 ms LAN |
| slirp4netns | 1.14 – 1.18 GB/s (−29%) | |
| pasta | **0.80 – 0.88 GB/s (−50%)** | 3.56 ms avg, 33.4 ms max |

Debian's enforcing AppArmor profile for `/usr/bin/pasta` refuses `/run/netns/*`
(the probe needed an unprofiled copy). `slirp4netns` and `passt` were
apt-installed on the box during the probe, are unused, and are removable.

## Disk atomicity — solved by construction, because a mismatch is undetectable

Take the ZFS snapshot **inside criu's own freeze window** via `criu dump
--action-script <snap.sh>` at `post-dump`; restore is `zfs rollback -r` then
`criu restore`. The snapshot unit is the **whole tile dataset**, not the CHD —
criu size-validates `mame.log`, `geo.log`, `irix_cmd` and every other open
regular file. Consequently the **CRIU image dir and `fb.shm` must live OUTSIDE
the rolled-back dataset.**

A mismatched (memory, disk) pair is **invisible to criu, to the guest and to
`xfs_repair -n`**: the guest serves stale data behind a healthy
`uptime`/`df`/desktop. Safety is therefore **construction** — paired naming plus
a hard fail on a missing `PAIRED-SNAPSHOT` marker — **never detection.** Whether
a mismatch is *survivable* is unproven: XFS log replay after one was never
exercised.

## Three traps that pass a smoke test while being broken

1. **Re-creating `fb.shm` at the same path after deleting it.** The restore
   SUCCEEDS and streams a frozen picture forever, because MAME writes the `IFB1`
   header only on its own mmap path, which restore bypasses.
2. **A leftover `CRIU` iptables chain inside the netns** (what an aborted
   restore leaves). Perfect desktop, working serial, correct in-guest
   `ifconfig`, **zero packets**. `ckpt.sh` sweeps it on every restore.
3. **Missing `--manage-cgroups=ignore`.** The restore dies on the dead
   `systemd-run` scope.

Also: `read()` on a ZFS-backed `fb.shm` is **not coherent** with MAME's
`MAP_SHARED` writes — health checks must mmap.

> The procedure **passed a five-minute smoke test on the first bake and was
> still wrong three times over.** Screendumps were necessary and not sufficient;
> every channel had to be exercised separately, on every cycle.

## Why this is not shipped

CRIU versus fixing MAME savestates: the recommendation is CRIU, and **not** to
start the `sgi_mc` savestate work (GH #44). The savestate gap *as stated* is
about a day (`save_pointer` for `m_ram`, `device_post_load` re-running
`memcfg_w`) but that is the KNOWN gap, found by reading one file; the unbounded
part is auditing Newport, IOC2, HAL2 and WD33C93 mid-transfer state against a
CHD, plus the DRC — each failing the same way, with a state that loads, renders
a plausible frame, and dies minutes later.

CRIU's own bill: **any MAME rebuild or `apt upgrade` touching libc or SDL
invalidates every baked image** (re-bake is a 4-minute boot per tile — automate
it and trigger on rebuild), and images are not portable off this box.
Savestates keep two real advantages: they cannot corrupt the guest filesystem,
and they carry no DRC cache.

This is an **IRIX-only** decision. The other 29 QEMU tiles already have
`loadvm golden`.

One separate fix this campaign owes: `irixexec.py` **spins at 100% of a core
forever** on pty EIO/EOF and blocks the next restore. Treat EIO as "the emulator
went away" and exit.
