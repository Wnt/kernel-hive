# fmtowns wave — Fujitsu FM TOWNS, Towns OS V2.1 L51 (TownsMENU)

Part of the five-station wave of 2026-09-13 (`vision`, `oberon`, `fmtowns`,
`magiccap`, `perq`). This is the FM TOWNS: Fujitsu's 1989 CD-ROM-first 386
home computer, whose operating system boots from the System Software CD into
**TownsMENU**, an icon desktop over an MS-DOS kernel. The fact that the
Virtual OS Museum runs this OS (on Tsugaru) is credited as a fact; nothing of
theirs is copied.

Read `docs/guests/fmtowns.md` for the station's operating manual once it is
filled; this file carries the wave: the ledger, the race, the sandbox verdict
and what is still open.

## Ledger — `wave.sh alloc fmtowns --x11warp` (no `--retronet`: Towns OS V2.1 has no TCP/IP stack by default, so a tap NIC would be meaningless)

| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| fmtowns | fmtowns | 196 / 54196 / 196 | :96 (127.0.0.1:6096) | — |

| Field | Value |
|---|---|
| sibling (`--like`) | `samcoupe` (MAME host-native, 0.289, save-state golden), tuple `towerE,crtC,keyboardE,paramMouseC` |
| render orders | as scaffolded (build 82 / signal 86 / stationsManifest 84 / binding 97 / golden 84 / bringUp 97) |
| uid base (if the Tsugaru route had won) | 2228224 — unused, see §Sandbox |
| media | see §Media |

## The race (rule 14) — two theories from minute 0, first TownsMENU frame wins

| Theory | Runner | Sandbox | Result | Frame |
|---|---|---|---|---|
| A. MAME `fmtowns` family, host-native (fleet tier) | sonnet | `/data/vms/sandbox/fmtowns/race/mame/` | (pending) | |
| B. Tsugaru_CUI inside systemd-nspawn (uid base 2228224) | sonnet | `/data/vms/sandbox/fmtowns/race/tsugaru/` | (pending) | |

## Media — staged by the `fmtowns-media` agent on labhost (`/data/assets-staging/fmtowns/`), re-hashed by the lead

Fetched from archive.org origins; the bits stay under `/data` (the gallery is
private), the repo carries only URL + sha256 + size in
`scripts/build-guests/tiles/fmtowns.sh`. MEASURED 2026-09-13 (`sha256sum`,
`sha1sum`, `stat -c %s` on labhost):

| File | Bytes | sha256 | sha1 (MAME member match) |
|---|---|---|---|
| `roms/fmtowns.7z` — MAME 0.272 merged romset `mess/fmtowns.7z` (item `mame-0.272-romset-complete-merged`), 20 members incl. every regional variant + the 32-byte `mytowns*.rom` boot-select ROMs | 967 043 | `5856826e…5081ac` | — |
| `FMT_SYS.ROM` | 262 144 | `7d4e8935…7b9a` | `15d9cc70…` = base `fmtowns` (Model 1/2) `fmt_sys.rom` |
| `FMT_DOS.ROM` | 524 288 | `b760d991…f17f` | `57fd1464…` = every set's `fmt_dos.rom` |
| `FMT_F20.ROM` | 524 288 | `dca1f314…b774` | `1920711c…` = Towns II `fmt_f20.rom` |
| `FMT_DIC.ROM` | 524 288 | `fdec9c3b…cdc7` | `7564020d…` = Towns II `fmt_dic.rom` |
| `FMT_FNT.ROM` | 262 144 | `aa9e9565…b9d` | `a216482e…` = Towns II `fmt_fnt.rom` |
| `cd/towns-sysv21-l51-cd.7z` — "[OS] Towns System Software v2.1 L51 [CD].7z" from item `neo_kobe_fujitsu_fm_towns_2016-02-25-repack_20200803` | 252 788 766 | `43db0465…0648b85` | — |
| `cd/towns-sysv21-l51-cd.img` (CloneCD; 1× MODE1/2352 data track + 8 audio tracks; `.ccd`/`.sub` alongside) | 593 767 104 | `5adbae1b…50f8ab` | — |
| `optional/` MS-DOS 6.2 L10 FD sets, Towns OS V1.1 L20 **English** FD + HD sets | 0.5–2.7 MB each | in `SOURCES.md` | not used by this wave |

The five uppercase files are the set the Virtual OS Museum boots on Tsugaru;
by hash they straddle two MAME machines (SYS is the Model 1/2 ROM, the rest are
Towns II), which is why the rompath is assembled by `stage-romset.py` from the
extracted merged archive rather than from the five files.

## Sandbox verdict

(filled when the winner is known)

## Proofs

(framebuffer paths)

## Still open

(filled at the stop)

## Teardown

(filled at the stop)
