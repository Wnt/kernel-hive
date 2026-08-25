# amigaos35 on the retronet web plane

**LIVE 2026-08-25.** The AmigaOS 3.5 station browses the corpus seamlessly with
its OS-bundled **AWeb II 3.3 SE**; home page `http://www.amiga.de/` (the real
1999 Haage & Partner-era portal, mirrored in the corpus). Web plane only — no
ICQ (AmigaOS OSCAR clients are a possible future add; no roster row exists).

## What made this one different

Two firsts, both structural:

1. **The link is a NETNS CAGE, not a tap.** FS-UAE has no working tap/pcap
   backend on Linux (the A2065/NE2000 host side is winpcap-only; libpcap is
   not even linked), and its networking is `bsdsocket_library=1` — the
   emulated `bsdsocket.library` backed by the HOST process's own sockets.
   Bare, that is a containment hole and gives the station no identity. So the
   launcher runs fs-uae inside netns `rn-amigaos35`, whose ONLY interface is
   the guest end of a veth pair; the host end is a port on `vmbr-rn`.
   Everything the Amiga's TCP does — including the host-side
   `gethostbyname()`, which reads the netns' own `resolv.conf` → 10.99.0.2 —
   happens at the station's IP/MAC on the museum bridge, exactly like a tap
   guest. `streamhost/stations/amigaos35/rn-netns.sh` (a box-sync pair) is the
   whole lifecycle; the launcher calls `up` on every start when
   `FSUAE_NATIVE_NET=bsdsocket` and refuses to start networked if it fails.

2. **The join FORCED the reset architecture to cold boot.** UAE savestates and
   bsdsocket do not mix: a state restored with `bsdsocket_library=1` gurus
   nondeterministically (stale host-side library state — a state saved with
   AWeb running gurus on first use, Error 8000 0006; even an idle-desktop
   state sometimes crashes at restore), and the pre-crash flush can corrupt
   the fresh work disk. A restored mousehack also consumes tablet packets one
   event late even with the re-arm patch. So `FSUAE_NATIVE_CHECKPOINT=0`:
   reset = deterministic ~85 s cold boot; the standby SIGSTOP keeps ordinary
   visits instant. The mousehack re-arm patch stays in the pinned build for
   any future statefile revisit.

## The wiring, at a glance

| Thing | Value |
|---|---|
| Link | veth `amiga35-h` (bridge port) ↔ `amiga35-g` (in netns `rn-amigaos35`) on `vmbr-rn` |
| Mode switch | `FSUAE_NATIVE_NET=bsdsocket` in `station.env.fixture` (off = no sockets at all) |
| Guest IP | `10.99.0.26/24` static on the netns veth; reservation kept in `RETRONET_DHCP_RESERVATIONS` |
| MAC | fleet scheme, tail `:1a`; real value only in gitignored `registry/local.env` (`RN_AMIGAOS35_MAC`) |
| Default route | none — the netns has only the link route; the emulated OS cannot add one |
| DNS | `/etc/netns/rn-amigaos35/resolv.conf` → 10.99.0.2 (bind-mounted by `ip netns exec`) |
| Seamless web | yes — AWeb sends `Host:`, no proxy configured |
| Browser | AWeb II 3.3 SE (on the OS 3.5 CD; `Internet/AWeb`), desktop icon `AWeb-II`, home `http://www.amiga.de/` |
| Golden | `disk/amigaos35-system.hdf.golden` alone (no statefile) — cold-boot reset |
| Guard | `AMIGAOS35RN-IN` at INPUT 1, scoped to 10.99.0.26; per-interface suffix rule for rigs |
| Exec | none (no exec channel on this station) |

## Containment

Three layers, none load-bearing alone — topology (`vmbr-rn` has no uplink),
routing (no default route **in the netns**, stronger than a guest-side config),
filter (fail-closed `AMIGAOS35RN-IN`). Proven from inside the cage 2026-08-25:

| From the cage to… | Measured | Lock |
|---|---|---|
| `10.99.0.2` :53/:80 | ping replies; DNS answers `www.amiga.de` → 10.99.0.2; HTTP 200, 2206 bytes | intra-bridge L2 (the point) |
| `10.99.0.1` | 100% packet loss | the guard chain |
| `1.1.1.1` | "Network is unreachable" — no packet formed | no default route |

`rn-netns.sh up` reads its rules back out of the kernel (`verify_rules`) and
refuses to report up otherwise; it also refuses if the netns somehow has a
default route.

## Acceptance measured from the guest itself

Production streamhost instance (under `streamhost@amigaos35`, inside the
cage): cold boot → curated desktop → double-click `AWeb-II` → AWeb II loads
`http://www.amiga.de/` from the corpus — boing balls, language flags, the
"AMIGA OS3.5" banner — on the framebuffer. Also proven during bring-up:
`http://search.retronet/` renders (era-press HTML 3.2), and the first
corpus-miss browse journals into the crawl demand queue like every station.

## The bake, and the trap it set (READ BEFORE RECAPTURING)

The golden is captured by SIGSTOPping an idle session and copying the work
HDF over the master (`disk/amigaos35-system.hdf.golden`, then `chmod 444`).
**FFS sets the root block's bitmap-valid flag only on flush/unmount — an
idle capture is structurally consistent but always flag-dirty, and OS 3.5's
validator FAILS on a dirty xdftool-built volume** ("Error validating System /
Block 1146049281 out of range" — 0x444F5301 is the DOS\1 dostype read as a
block number) **instead of healing**. After every capture, set the root
`bm_flag` (offset 512-200 in root block 524288 for this 512 MiB/32-sector
geometry) back to `0xffffffff` and refresh the root checksum (longword 5;
whole-block sum ≡ 0). The bake steps live in `docs/guests/amigaos35.md`.

## Rollback

- `disk/amigaos35-system.hdf.golden.bak-preretronet` — the pre-join master
  (no AWeb home pref). Restore it + set `FSUAE_NATIVE_NET=off` in the fixture
  + re-emit + restart; `rn-netns.sh down` removes the cage; the local.env
  reservation stays (an address is never re-issued).
- The registry `retronet`/`network` blocks and this doc revert with git.

## Not done

- ICQ plane (no AmigaOS OSCAR client sourced; would need a roster row + UIN).
- Audio (station-wide follow-up, unrelated to the join).
- `network.status` still says `host-only` — no `retronet` enum value exists
  yet, same as every joined station.

## The shot

`AWeb II on the emulated A4000 rendering www.amiga.de` — captured 2026-08-25
from the production framebuffer during acceptance; the same scene is one
double-click from the golden desktop at `/os/amigaos35`.
