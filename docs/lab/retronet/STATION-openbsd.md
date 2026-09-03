# openbsd on the retronet — web plane and ICQ plane (phase 3, 2026-09-03): NOT LANDED

Coordinator allocation (written on the box in `RETRONET_DHCP_RESERVATIONS`, hands
off): address `10.99.0.34`, MAC `52:54:00:52:4e:22`, tap `openbsdrn0` on
`vmbr-rn`, containment chain `OPENBSDRN-IN`, ICQ UIN `17700`.

## Status

The phase-3 attempt ran as one Opus subagent on a `rig-clone.sh` clone of the
openbsd smoke rig for ~2 h and was stopped at its bound without a proof frame.
The live station is unchanged (still the fvwm golden of `docs/lab/OPENBSD-WAVE.md`).

| Item | State | Evidence |
|---|---|---|
| Dillo 3.2.0 installed in the guest (`pkg_add dillo` from the fu-berlin package mirror over slirp) | PROVEN | `/data/vms/sandbox/openbsd-rn/s4.png` (pkg_add output, `rc=0`) |
| `rn-tapnet.sh` for the station | DRAFT, unproven | `streamhost/stations/openbsd/rn-tapnet.sh` — a copy of irix's, **not yet renamed/rewired** (still says irix, IRIXRN-IN, 10.99.0.24) |
| registry `retronet` block | NOT WRITTEN | the draft only added eraSoftware entries and a periodBrowser; no `retronet` block, `planes` untouched |
| tap link up in the guest (`vio1` on `openbsdrn0`, 10.99.0.34) | OPEN | no frame |
| browser rendering `http://search.retronet` through the plane | OPEN | no frame |
| ICQ client signed in as 17700 with HiveBot in the list | OPEN | climm 0.6.4 was named in the draft eraSoftware; nothing proves it was installed or connected |
| roster.json row / `RETRONET_ICQ_OPENBSD_PASS` in local.env | NOT DONE | `rn-tool.py user-set 17700 …` + `user-open 17700` not run; UIN exists server-side per the coordinator |
| new golden on the new device set | NOT BAKED | no `disk.rn.qcow2` |

## What the next attempt should do differently

1. **Split the brief at the first framebuffer that differs from the sibling**
   (playbook §0): one agent for the tap link + browser (web plane), a second for
   the IM client, each with a 30-minute stop and a frame per step. A single
   90-minute "network → client → browser → golden" brief produced two hours
   with one proof frame.
2. Guest files (`/etc/hostname.vio1`, `/etc/resolv.conf`, dillo/climm rc) must
   be **fetched from the loopback HTTP server or applied in single-user**; the
   typing helper eats backslash escapes and a heredoc typed into the guest
   becomes one broken line (fleet-wide finding from freebsd411). Working typed
   form: `sh -c '{ echo a; echo b; } > file'`.
3. Device set: keep `-smp 1` (two vCPUs lose keyboard interrupts under X,
   OPENBSD-WAVE.md) and ADD `-netdev tap,id=rn0,ifname=openbsdrn0,script=no,downscript=no
   -device virtio-net-pci,netdev=rn0,mac=52:54:00:52:4e:22` as `vio1`, keeping
   `vio0` on slirp for package fetches during the bake (the retronet doc for
   irix retires the internet link; decide per WEB-PLANE-PLAN.md whether the
   shipped station keeps vio0). The golden must be re-baked on that device set
   and restore-proven before the launcher changes land.
4. OpenBSD 7.9 client facts to verify in the guest before choosing: `pkg_info
   -Q climm`, `pkg_info -Q pidgin` (libpurple OSCAR), `pkg_info -Q dillo netsurf`.
   Dillo installs cleanly (17 dependencies, ~1 min over slirp).
5. `scripts/lib/box-sync-pairs.sh` is at the 600-line cap: do not append an
   rn-tapnet row; `origin/box-sync-pairs-rn-glob` (b19e9d73) globs
   `streamhost/stations/*/rn-tapnet.sh`.

## Landing checklist (when proven)

registry `retronet` block like irix's with `planes` `["web"]` (add `"icq"` only
with a signed-in frame), `joined` date, `doc` = this file; launcher + fixture +
`rn-tapnet.sh` rewired for openbsdrn0 / OPENBSDRN-IN / 10.99.0.34; roster row +
local.env append (single `printf >>`); golden swap via `checkpoint-guard`;
`docs/lab/retronet/WEB-STATION-openbsd.md` when the browser frame exists.
