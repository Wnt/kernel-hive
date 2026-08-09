# Licensed / external assets manifest (build-guests inputs)

Every **external input** the `scripts/build-guests/` builders consume, cross-
referenced against what is actually staged on the box (verified + hashed
2026-07-14). The repo itself carries everything needed to rebuild the lab
**except** the media below (staged externally) and the gitignored secrets.

Preflight checker: **`scripts/build-guests/check-assets.sh`** verifies
presence + sha256 of the required staged set and prints a missing-list;
`build-all.sh --check-assets` runs it first.

License classes:

- **licensed** — user-supplied media, no download URL shipped (or SSO-gated).
  Copyright software used privately in this collection; never committed, never
  redistributed.
- **abandonware-URL** — commercial-era copyright media the builder auto-fetches
  from archive.org / preservation mirrors. Same private-collection stance;
  the bits are never committed — only the URL + pin are.
- **freely-fetchable-pinned** — free/open upstream, fetched at build, pinned by
  hash or version.
- **preservation-source** — historical copyrighted media from a preservation
  archive. Provenance and a locally measured hash are recorded, but the bits
  stay private on the lab box because redistribution terms are unclear.
- **VSI Community** — account/application-gated OpenVMS Community media. It is
  usable for this private community-system exhibit but is not redistributable;
  the archive and derived disks are publish blockers and remain off-repo.

Sizes/hashes marked *(measured)* were computed on the box copies; *(pin)* are
the pins baked into the builder.

## Staging bundle

The migration bundle is at `/data/assets-staging/` on the lab box, created
2026-07-14 from this manifest at git revision
`d15f1488643ef5c57026fa8f4a9e5e303fe23c65`. Verify its licensed and
abandonware inputs with:

```bash
scripts/build-guests/check-assets.sh --root /data/assets-staging \
  --class licensed --class abandonware-URL
```

The expected report remains nonzero while the known WinXP ISO/key and Sailfish
VDI gaps are unresolved; payload hashes can also be checked with
`(cd /data/assets-staging && sha256sum -c MANIFEST.sha256)`.

---

## 0. preservation-source — private lab intake

**Sourcing warning (2026-08-09).** Every `trailing-edge.com` host — `simh.`,
`www.`, `ftp.`, `mini-me.` — is **offline**, and it is the canonical DEC
hobbyist archive that essentially every RT-11/RSX/RSTS howto on the internet
links to. The surviving routes are the Wayback raw form
(`web.archive.org/web/<ts>id_/…`, enumerable via the CDX API) and bitsavers.
Those hosts also carry AAAA records the box cannot reach, so any `curl` at them
needs `-4` or it hangs ~40 s before failing. **Treat all DEC media as one-shot
fetches: stage the bits on the box; no builder may fetch them at build time.**

| file | sha256 | size | builder | source / staging path | copyright note |
|------|--------|------|---------|-----------------------|----------------|
| `redstar.iso` (volume label `REDSTAR DESKTOP 2.0`, bootable i386 desktop installer) | `69a45d07c302782cb777d03abd39c5b45b4099e5c994a74a77bb71ab5d229997` *(locally measured 2026-07-16)* | 1 416 017 920 | `redstar2.sh` | Internet Archive item [`redstar_20181224`](https://archive.org/details/redstar_20181224), original file `redstar.iso`; `/data/assets-staging/redstar2/redstar.iso` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | DPRK-origin proprietary distribution; copyright and redistribution terms unclear. Private preservation exhibit only; ISO is not committed or publicly served. |
| `redstar_desktop3.0_sign.iso` (volume label `RedStar Desktop 3.0`, i386; contains `redstar-release-3.0-1.rs3.0.i386.rpm`) | `895ad0e01ae0d35a65e9ac42dd34d0a1d685d6dfa331ce5b4f24bbc753439be3` *(locally measured 2026-07-16; archive original MD5 `acf53d2b50ecb1391044b343502becf5` also matches)* | 2 614 644 736 | `redstar3.sh` | Internet Archive item `https://archive.org/details/redstar_desktop3.0_sign`; `/data/assets-staging/redstar3/redstar_desktop3.0_sign.iso` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | DPRK-origin proprietary distribution; redistribution terms unclear. Private preservation exhibit only; ISO is not committed or publicly served. |
| `fsn.tar.Z` (SGI **File System Navigator 1.2** — the 3D file browser from *Jurassic Park*; ELF o32 MIPS-I binary dated 1996-12-13, plus the `Fsn` app-defaults, `Fsn.icon` and the `fsn(1)` man page) | `53ad2649c78798acd52f16fca2fde769d5df1f50645b496d8818f0ba76ab07ef` *(locally measured 2026-08-03; archive-recorded MD5 `7437bf5ba70ac4eb4f748d8f1be8ef13` matches)* | 215 881 | baked into `irix65-apps-v8.chd` (see `docs/guests/irix.md`) | Internet Archive item [`fsn.tar_202201`](https://archive.org/details/fsn.tar_202201), file `fsn.tar.Z` — a copy of SGI's own `ftp.sgi.com:/sgi/fsn/fsn.tar.Z`; staged `/data/vms/streamhost/assets/irix/fsn/fsn.tar.Z` (444) with adjacent `SHA256SUMS` — **PRESENT + verified** | **PUBLISH BLOCKER.** SGI-copyright freeware, binary-only: the program's own banner reads *"(c) Copyright 1992, 1993, 1996, Silicon Graphics, Inc. All rights reserved … provided for demonstration purposes only … Sorry, source code is not available."* SGI published it for free download but granted no redistribution licence, and SGI is defunct, so no one can grant one now. Private preservation exhibit only — neither the tarball nor `irix65-apps-v8.chd` may be committed or publicly served. |
| `mpf_ii.rom` (Multitech Microprofessor II monitor + Applesoft-clone BASIC) | SHA1 `92378b0db561632b58a9b36a85f8fb00796198bb`, CRC32 `8780189f` *(MAME driver pin; record SHA-256 after local intake)* | 16 384 | `mpf2.sh` | MAME `mpf2` clone ROM: in merged sets extract it from `tk2000.zip`; in split sets use `mpf2.zip`. Stage only the verified blob at `/data/assets-staging/mpf2/mpf_ii.rom`. Candidate sources: [MAME 0.224 merged](https://archive.org/details/MAME_0.224_ROMs_merged), [MAME 0.239 merged](https://archive.org/details/mame-0.239-roms-merged). | ROM copyright status is unclear. Private preservation exhibit only; never commit or publicly serve the ROM. |
| `2.11BSD_rq.dsk.zip` (2.11BSD, UC Berkeley 1991 — Don North's prebuilt MSCP pack; unzipped `2.11BSD_rq.dsk` is 1 000 047 616 B, sha256 `2f100ee585f229fd55923e1d1c44108e72df96f649f28a31df35985e6a481805` **pristine**, before the tile's four in-guest site-config edits) | `94abeca02f001619e7aa2252cb2336ffe79af0cb3fb35cbd8c14240af3125a6b` *(locally measured 2026-08-09)* | 49 850 663 | `pdp11.sh` | [`ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip`](https://ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip); staged `/data/vms/streamhost/tiles/pdp11/media/` | Predates the Net/2 split, so **NOT** covered by the Caldera 2002 Ancient-Unix letter, and the prebuilt image carries no licence statement. Preservation-source: stream-only pixels, never committed, never served, no download affordance. |
| `rtv53swre.tar.Z` (RT-11 V5.3 kit: `Disks/rtv53_rl.dsk` RL02 distribution pack + `Licenses/pdp11_license.txt`) | `9fdad10969f1f391b13d9d97aa8fc1aa8fcb44472dac363d23eb2d31500207bc` *(locally measured 2026-08-09)* | 1 373 083 | `decos.sh` | `http://simh.trailing-edge.com/kits/rtv53swre.tar.Z` — **origin host offline** (Cloudflare 520); retrieved through the Wayback raw form, snapshot `20020108101052`. Staged `/data/assets-staging/decos/` with adjacent `SHA256SUMS` | **Mentec hobbyist grant (1997-07-31): "use and copy … solely for personal, non-commercial uses in conjunction with the EMULATOR" — NOT distribute.** Private exhibit only; never committed, never served, no download affordance. Licence text itself is at `docs/guests/decos-mentec-license.txt` (a licence text is not licensed software). |
| `rsx11m42.zip` (RSX-11M **V4.2 BL38** TK50 kit: `m42kit.tap` + `build.txt`) | `c8766a53ae5b32c060560d5cea6302715c046322c80dbc234cc7e63ab2391ba1` *(locally measured 2026-08-09; re-fetched same day, byte-identical)* | 6 155 772 | `decos.sh` | [`bitsavers.org/bits/DEC/pdp11/rsx11m/rsx11m42.zip`](https://bitsavers.org/bits/DEC/pdp11/rsx11m/rsx11m42.zip) — live | Same Mentec grant. **V4.2, not the V4.3 ceiling** — no reachable copy of V4.3 exists anywhere (see `docs/guests/decos.md`). Do NOT substitute `rsx11m.com`'s `PiDP11_DU0.zip`: that is RSX-11M-**PLUS** V4.6, outside the grant. |
| **BBC Micro Model B ROM set** — five blobs staged at `/data/assets-staging/bbcmicro/`: `os12.rom` (Acorn MOS 1.20, SHA-1 `0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d`, sha256 `2d9fea69017864f6962704481829f95fee08446c8c3a13826d5d4e44000ac9de`, 16 384 B); `basic2.rom` (BBC BASIC II, SHA-1 `4a7393f3a45ea309f744441c16723e2ef447a281`, sha256 `45bd55dc0f6f0f8f1fe9e2481de7def206565eec8f600ba3068b849ca4132079`, 16 384 B); `phroma.bin` (TMS5220 speech PHROM, SHA-1 `b369809275cb67dfd8a749265e91adb2d2558ae6`, sha256 `8c093401661f530032c5aca8fd80d91af58e596d082a51be58ce2ee063a89308`, 16 384 B); `saa5050` (SAA5050 teletext character generator, SHA-1 `6c8daba70374e5aa3a6402f24cdc5f8677d58a0f`, sha256 `9706945b02dd0e30823186ff0d73a49c0d98ed573499a057bab471add7ee28fb`, 960 B); `dnfs120.rom` (Acorn DNFS 1.20, SHA-1 `7e3c536baeae84d6498a14e8405319e01ee78232`, sha256 `e745e34895225a6650b712c1dd0656cb0b0b15f072a8ae6d9ea8d1ac257eb3d6`, 16 384 B) | *(per-file sha256 in the left column — all five measured locally 2026-08-09)* | 66 496 total | `bbcmicro.sh` | **PRESERVATION-SOURCE, NO AUTHORISED URL.** No rights holder publishes these dumps and none authorises a mirror; the only routes that exist are bulk MAME romset dumps nobody was authorised to upload, so this manifest deliberately records **no** fetch URL. The builder does not download: it requires the operator's own staged blobs at `/data/assets-staging/bbcmicro/` and gates each on the SHA-1 above, then assembles `bbcb.zip` / `bbc_acorn8271.zip` / `saa5050.zip` itself. Note `saa5050` is a THIRD zip, in no BIOS set — MODE 7 has no glyphs without it and MAME refuses to start. | Acorn MOS and BBC BASIC are unlicensed for redistribution, and there is documented doubt that Acorn's successors hold clean assignment of the original MOS work — so there is no party who could grant one. Private preservation exhibit only: stream-only pixels, never committed, never served, no download affordance. |
| `rsts_v9_6_install.zip` (RSTS/E V9.6 installation tape, TPC format, 11 850 records / 175 tape marks) | `aaf4aa978e13318fe304dfbf75e20090206e17caa5b76bab69bec2704d9c694f` *(locally measured 2026-08-09)* | 8 071 836 | `decos.sh` | `https://ftp.trailing-edge.com/pub/rsts_dists/rsts_v9_6_install.zip` — **origin host offline**; retrieved through the Wayback raw form. Staged `/data/assets-staging/decos/` | Same Mentec grant (V9.6 is exactly the recital's ceiling). **Do NOT substitute RSTS/E V10.1** — outside the grant. |
| `cpm.system.6228151676.d64` (Commodore **CP/M 3.0 / CP/M Plus** system disk for the C128 — the Z80 side of the machine) | `.gz` `6ed0da2d8a6fa74ae7b6e6cb67d78e1806a2a625ca839b4d93558c5ce7f44cb9`; decompressed `.d64` `69159226bf1996d8fc8c8921f094cd03955c7a8b9ecf800069d1c369dc6e5a1d` *(both locally measured 2026-08-09)* | 76 230 (`.gz`) / 174 848 (`.d64`) | `c128.sh` | [`zimmers.net/anonftp/pub/cbm/demodisks/c128/cpm.system.6228151676.d64.gz`](https://www.zimmers.net/anonftp/pub/cbm/demodisks/c128/cpm.system.6228151676.d64.gz); staged into the tile overlay and attached by VICE `-8` (a VICE argument, not a QEMU device, so the golden device set is unaffected) | **The one external file in the Commodore wave** — VICE bundles the C128 ROMs, including the CP/M Z80 BIOS, but not the CP/M system DISK. Commodore/DRI-era copyright, terms unclear. Private preservation exhibit only; never committed, never served, no download affordance in the tile. |

---

## 1. licensed — user-supplied, staged by hand

| file | sha256 | size | builder | expected staging path | env vars (names only) |
|------|--------|------|---------|----------------------|-----------------------|
| Solaris 10 U11 GA x86 DVD ISO (`sol-10-u11-ga-x86-dvd.iso`) | `e8b86de15de374f93d356a6cc4c73952a365294fe82aa0f278cd028054ad57ea` *(measured)* | 2 254 110 720 | `solaris-cde.sh` | `/data/gallery-guests/SolarisCDE/sol10.iso` — **PRESENT on box** | `SOL10_ISO`, `SOL10_ISO_URL` (Oracle OTN is SSO-gated; an archive.org mirror URL is the shipped fallback) |
| Windows XP Pro SP3 ISO (integrated-SP3 repack, label `GRTMPVOL_EN`, ≥500 MB) | n/a — **not on the box any more** (consumed at build 2026-07-04, since deleted; no hash was recorded) | ~624 MB | `winxp.sh` | `/data/gallery-guests/WinXPpro/winxp-sp3.iso` (or `XP_ISO_LOCAL=`) — **MISSING: must be re-staged for any rebuild** | `XP_ISO_LOCAL`, `XP_ISO_URL`, `WINXP_PRODUCT_KEY` (**required**, volume-license key), `XP_ADMIN_PW` |
| Sailfish SDK emulator VDI | n/a — not retained (the built `sailfishos.qcow2` exists) | ~ GBs | `sailfishos.sh` | `SFOS_VDI=<emulator.vdi>` (ships with the free Sailfish SDK; account/EULA flow, not curl-able) | `SFOS_VDI`, `SFOS_EMULATOR_URL`, `SFOS_SKIP_DOWNLOAD` |

## 1a. VSI Community — private community-system media

| file | sha256 | size | builder | source / staging path | publish blocker |
|------|--------|------|---------|-----------------------|-----------------|
| `community_2026.zip` (pre-installed OpenVMS x86-64 V9.2-3 descriptor + flat VMDK pair) | `ceae51ded68e96861e7211b30ef837e8d101eb5d3a3ddb78c13d5d7619ddfb83` *(locally measured 2026-07-28; full `unzip -t` passed)* | 1 897 009 259 | `openvms.sh` | [VMS Software Community package](https://events.vmssoftware.com/hubfs/VMS%20-%20Files/community_2026.zip) (requires a browser user-agent); `/data/gallery-guests/OpenVMS/community_2026.zip` — **PRESENT + verified** | **PUBLISH BLOCKER — VSI Community media and every derived VMDK/qcow2 remain private; do not commit or publicly serve them.** |

## 2. abandonware-URL — auto-fetched commercial-era media

### OS base media

| file | hash | size | builder | staging / cache path | notes |
|------|------|------|---------|----------------------|-------|
| MS-DOS 6.22 install Disk1/2/3 `.img` | sha256 `b88030401122d2…`, `e1d48a41549…`, `52a3b4e7f597…` *(measured)* | 3× 1 474 560 | `msdos-win1.sh` | `/data/gallery-guests/MSDOSWin1/.build-work/dl/Disk{1,2,3}.img` — **PRESENT** | archive.org item `disk-1_202101` |
| Windows 1.01 floppy `win101.img` | sha256 `621e0e4e284359864a4a6d7eb702b4bc37b258c8ce82744f8ac29e89fec57397` *(measured)* | 1 474 560 | `msdos-win1.sh` | `…/MSDOSWin1/.build-work/dl/win101.img` — **PRESENT** | archive.org item `windows-1.01_1floppy` |
| “Windows 95 for UTM.zip” (OSR2 disk image) | md5 `9ccbf5b59f1ddf82f2ad007ff9471814` *(pin)* | ~500 MB | `win95.sh` | fetch cache (purged; re-fetched on build) | archive.org item `windows-95-for-utm` |
| Win98SE VMware VM `.7z` (WinWorld repack) | none (size-sanity only) | ~ GB | `win98.sh` | fetch cache (purged) | archive.org item `Microsoft_Windows_98_Second_Edition_Virtual_Machine_VMware_WinWorld` |
| Win2000 Pro SP4 VMware VM `.7z` | none | ~ GB | `win2000.sh` | fetch cache (purged) | archive.org item `Microsoft_Windows_2000_Professional_SP4_Virtual_Machine_VMware_WinWorld` |
| Windows 3.11 prebuilt `hda.img` | sha256 `0aa6e4a593e4cc762306a9dfcfe262001672185bc66ba17ae69b593925e62340` *(measured)* | 268 435 456 | `win311.sh` | `/data/gallery-guests/Win311/hda.img` — **PRESENT** | fetched from `rtts.eu/download/win311/hda.img` — third-party mirror, **single point of failure** |
| OS/2 Warp 4 prebuilt `os2.qcow2` | sha256 `2b166b8d75912feb189945ee77480b2889f3c2554ca16fdf39e432e6656653bc` *(measured)* | 501 809 152 | `os2warp.sh` | `/data/gallery-guests/OS2Warp/os2.qcow2` — **PRESENT**, but **evolved in place**: it IS the live golden lineage, not the pristine download | archive.org item `os2warp4_20240227`; IBM-copyrighted, used privately here |
| QNX 6.5.0 live ISO `QNX650Live.iso` | sha256 `e22a2a75b2f4ec4be4a933590fd2bf9c9d8b6466b7c0b3553521d6ef005e4077` *(pin, measured-match)* | 111 167 488 | `qnx.sh` | `/data/gallery-guests/QNX/QNX650Live.iso` — **PRESENT + verified** | archive.org item `qnx-650-live` |
| NeXTSTEP 3.3 User ISO | none | ~640 MB | `nextstep.sh` | **not located on the box** — builder exists but the guest is not part of the 28-tile fleet (never staged/built here) | archive.org item `NeXTSTEP33CISC` |
| Amiga Kickstart 1.3 ROM `kick13.rom` | md5 `82a21c1890cae844b3df741f2762d48d` *(pin, measured-match in-kiosk)* | 262 144 | `amiga.sh` (+ URL also in `bridge-base.sh`) | amiga kiosk guest `/opt/bridge/media/amiga/kick13.rom` — **PRESENT in-guest** (baked into the bridge overlay golden; re-fetched by the builder) | archive.org item `commodore-amiga-firmware`; Amiga ROMs are Cloanto/Amiga-copyrighted |
| Workbench 1.3 boot ADF `workbench13.adf` | md5 `d10f4907697c4eafcf976b4ef6ea829b` *(pin, measured-match in-kiosk)* | 901 120 | `amiga.sh` | kiosk `/opt/bridge/media/amiga/workbench13.adf` — **PRESENT in-guest** | amigamuseum.emu-france.info mirror |
| GEOS 2.0 for C64 `.d64` | md5 `709bec31c3502cbcf5d4761c38dcfa9e` *(pin)* | ~170 KB | `bridge-base.sh` / `c64.sh` | c64 kiosk media dir (in-guest) | archive.org item `geos64_J1AD`; Berkeley Softworks. VICE itself bundles the C64 kernal/basic ROMs (fetched as VICE 3.x source from SourceForge) |
| GEOS for Apple II `.hdv` | none | ~800 KB | `apple2.sh` | apple2 kiosk media dir (in-guest) | mirrors.apple2.org.za (asimov mirror); linapple bundles the Apple //e ROM |
| RISC OS 5.30 IOMD ROM + HardDisc4 | none | ~4 MB + ~50 MB | `riscos.sh` | showcase-only tile (neko backend retired) — no live staging | riscosopen.org zipfiles; RISC OS Open licence (free download) |

**Atari ST needs NO TOS ROM** — `atarist.sh` boots EmuTOS (GPL,
`emutos-1024k-1.3` pinned via `bridge-base.sh`).

### Era app/game packs (fetched per builder; commercial-era items flagged)

| item | used by | hash/size *(measured where cached)* | class note |
|------|---------|--------------------------------------|-----------|
| Cosmo's Cosmic Adventure zip | `freedos.sh` (prefers the **repo copy**, see §4) | sha256 `d7197b6b86170c808714e591faa29b028b7ad13bf45c34d66425934c0c5245f8`, 1 406 899 | **contains registered episodes 2–3** — see §4 publish blocker |
| Jill of the Jungle zip | `freedos.sh` (repo copy preferred) | sha256 `ab09c4674f7c43e3ea80b9e22b250da442f471c3877e5d5410c9ba6c1366f837`, 271 977 | archive.org 1992 item; episode content unverified — review before any publish |
| Commander Keen 1 (shareware) | `freedos.sh` | — | shareware |
| Wolfenstein 3D v1.4 `1wolf14.zip` | `freedos.sh` | sha256 `cb2a2ef7ecef14152c65ff93cc3b84fbd3e8eb0c5c1de41a6fc8cdef559451a8`, 856 401 | classicdosgames.com mirror of the original Apogee installer; `id-shr-extract` yields only the freely-distributable shareware episode (`*.WL1`) |
| Wolfenstein 3D `wolf3dsw.zip` (Win2000 cache) | `win2000.sh` | sha256 `76ee5e73e7d6341aefff620989bb5f828e9d295982afd5415b62dee7fe54eb64`, 670 522 | archive.org 1992 item — likely more than the shareware episode; commercial-era; staged in the assets bundle |
| Quake 1.06 `QUAKE_SW.zip` | `freedos.sh`, `win311.sh`, `win98.sh` | sha256 `b8e3e9c9f875dc6dda5ebdb9c2434bdfb3ece86c516089ebfe5c12106fffe7c1`, 18 079 976 | shareware; builder rejects the former 589 MiB `msdos_Quake_1996` archive |
| Duke Nukem 3D 1.3D shareware | `freedos.sh`, `win311.sh` (sha-pinned), `win98.sh`, `win2000.sh`, `winxp.sh` | win311 pin + Win2000 cache `c7e380b2a2e3faed8b7008e3e1306b360405138ac7407cef2d3bb00b5663b65a`, 15 052 933 | shareware |
| DOOM 1.9 shareware / DOOM1.WAD | `freedos.sh`, `win311.sh` (pin `63ad7609f2e9…`, 2 451 850), `win98.sh` (+`doom95.zip`), `winxp.sh` | | shareware |
| Quake 1.06 shareware | `win311.sh` (pin `b8e3e9c9f875…`, 18 079 976), `win98.sh`, `win2000.sh`, `winxp.sh` | win2000 cache `quake_msdos.zip` sha256 `920f4609801d0bdbea5b6738cec49da846df4ff8ce0d46c901ea080dd4437833`, 9 050 608 | shareware |
| GTA 1 `GTAINSTALLER.exe` | `win98.sh`, `win2000.sh`, `winxp.sh` | — | Rockstar's own free re-release (archive.org `rockstar-classics_202107`) |
| Winamp 2.95 | `win98.sh`, `win2000.sh`, `winxp.sh` (+ repo tarball, §4) | — | Nullsoft freeware |
| WINSKI | `win311.sh` (sha-pinned `660beefbfffc…`) | — | era freeware |
| Firefox 2.0.0.20, DOSBox 0.74-3, ZDoom 2.8.1, Freedoom, FTEQW, CWSDPMI, VBEMP `vbempk.zip`/`191201.zip` | winxp/win2000/win98/freedos builders | — | free/open (FTEQW is a **moving** unversioned URL; VBEMP from bearwindows.zcm.com.au) |
| Arachne 1.99 GPL `a199gpl.zip` | `freedos.sh` | sha256 `ecc820ddc33c2ecbe64113d773b05e8eaac8eedd32f1ac7768bf3091de1b5ac8`, 2 224 788 | GPL; outer zip contains an old solid-RAR DOS SFX, so the builder performs and validates an isolated DOS extraction boot |
| Netscape 4.x installer | `win95.sh` | — | **optional**, `NETSCAPE_URL` env (WinWorld, no stable URL — left empty by default) |

## 3. freely-fetchable-pinned — open upstreams

| file | pin | builder | staging path (box state) |
|------|-----|---------|--------------------------|
| FreeDOS 1.3 FullUSB + choice/ctmouse pkgs | official ibiblio URLs (unpinned hashes) | `freedos.sh` | `.build-work/dl` cache |
| 9front `9front-11554.amd64.qcow2.gz` | release 11554 | `9front.sh` | `/data/gallery-guests/9front/` |
| Haiku R1/beta5 anyboot ISO x86_64 | sha256 `22ae312a38e98083718b6984186e753d15806bd6ea44542144fdcef42c4dcb69` *(pin, measured-match)*, 1 477 246 976 | `haiku.sh` | `/data/gallery-guests/Haiku/haiku.iso` — **PRESENT + verified** |
| HelenOS 0.14.1 ia32 ISO | version-pinned; measured `1b15da0459cbfe28a6d3058675c2c20a4b03584cfb4d034c0ccb17b521791ccb`, 25 792 512 | `helenos.sh` | `…/HelenOS/` — PRESENT |
| KolibriOS `latest-iso.7z` | **moving** “latest” URL; measured iso `dc3e3726f2495df7eef93e89bd2362c693afcaa7e466cd837607fbe8a60a18a0`, 99 358 720 | `kolibrios.sh` | `…/KolibriOS/kolibri.iso` — PRESENT |
| ReactOS 0.4.14 live zip | build `0.4.14-release-125-g5b02d38`; measured iso `9b39db9d930c919060379c8b3f1406d5cc8821e019fc3ccecf6e2dce9d1d0c7e`, 263 192 576 | `reactos.sh` | `…/ReactOS/ReactOS.iso` — PRESENT |
| ToaruOS v2.3.2 `image.iso` | sha256 `b1dc51bd48f2b4613237185c9acb1a9beb13ab6acdd2e01d9722f77343e4c9ea` *(pin)*; box copy measures `fda58cd13612…` (**modified in place by the games bake** — expected) | `toaruos.sh` | `…/toaruos/image.iso` |
| TempleOS ISO | sha256 `5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26` *(pin, measured-match)*, 17 350 656 | `templeos.sh` | `…/TempleOS/TempleOS.ISO` — PRESENT + verified (public domain) |
| Android-x86 9.0-r2 ISO | sha256 `91cedb534ba095a0c9b3eceede4147967fd27beea9bba640776f787dc3555021` *(pin, measured-match)*, 761 266 176 | `android-x86.sh` | `…/Android/` — PRESENT + verified |
| postmarketOS v26.06 phosh generic-x86_64 `img.xz` | build `20260703-0246`, upstream `.sha256` sidecar verified at fetch | `postmarketos.sh` | `…/postmarketOS/pmos-phosh.img` (unpacked) |
| AROS nightly i386 boot ISO + contrib | nightly resolver + pinned fallback; APL licence file kept alongside | `amigaos.sh` | `…/AmigaOS/aros-pc-i386.iso` (measured `5aff10ed5ff1…` — post-bake state) |
| SerenityOS / ToaruOS sources, VICE 3.x, hatari, caprice32, linapple, EmuTOS 1.3, RPCEmu 0.9.5 | git/tarball pins in each builder | `serenityos.sh`, `bridge-base.sh`, `riscos.sh` | built in place |
| Debian 12 genericcloud qcow2 (bridge kiosk base) | `latest` channel | `bridge-base.sh` | `/data/vms/bridge/bridge-base.qcow2` (built, 3 567 255 552) |

## 4. repo-tracked binary assets (and publish blockers)

Tracked in `scripts/build-guests/assets/` so builds don't depend on flaky
mirrors. **Review before ANY public release of this repo:**

| repo file | sha256 | size | status |
|-----------|--------|------|--------|
| `assets/freedos/cosmo.zip` | `d7197b6b86170c808714e591faa29b028b7ad13bf45c34d66425934c0c5245f8` | 1 406 899 | **REMOVED from the repo 2026-08-07** (contained registered Cosmo episodes 2-3, only ep 1 is shareware). `freedos.sh` now fetches it from archive.org at build time and verifies this same hash; an operator may still stage a local copy at this path (gitignored) for an air-gapped rebuild. See `docs/guests/freedos.md`. |
| `assets/freedos/jill.zip` | `ab09c4674f7c43e3ea80b9e22b250da442f471c3877e5d5410c9ba6c1366f837` | 271 977 | **REMOVED from the repo 2026-08-07** (Jill of the Jungle, 1992 archive.org zip). Same fetch-with-hash-verification treatment as cosmo.zip. |
| `assets/winxp/Winamp-2.95-installed.tar.gz` | `cd0bbbc4ceebfc2fd8c9b22d63a03fdb3c7a182be680af6dcea032f33c2a8dd9` | 1 797 575 | **REMOVED from the repo 2026-08-07** (Nullsoft freeware, custom installed-tree repack). No stable public URL for this exact repack was found/verified, so it is NOT auto-fetched — `winxp.sh` skips the Winamp desktop shortcut if the file is absent and logs where an operator should stage their own copy. See `docs/guests/winxp.md`. |
| `assets/win311/GALLERY.GRP`, `assets/toaruos/Desktop/*.launcher`, `assets/amigaos/{backdrop,icons/**}`, `assets/apple2/{linapple-kiosk.patch,pointer-watchdog.py}`, `assets/*/PROVENANCE.txt`, `assets/freedos/proof/*.png` | (see git) | small | project-authored / config artifacts — fine to publish |

## 5. gaps found (could NOT be located on the box)

- **WinXP SP3 ISO** — consumed at build, deleted; **no recorded hash**. Re-staging
  requires the operator's own media (the builder's WINNT.SIF automation was
  validated against a `GRTMPVOL_EN` SP3+IE8 repack).
- Win95/Win98SE/Win2000 source archives — fetch caches purged post-build
  (URLs + the win95 md5 pin remain in the builders).
- Sailfish SDK emulator VDI; NeXTSTEP 3.3 ISO (builder never exercised here).

## 6. out-of-scope builders (not `build-guests/`)

- `scripts/provision/pve-macos-vm.sh` (VM 925) — macOS via OSX-PROXMOX/OpenCore; Apple
  installer media pulled by that tooling, nothing staged in this repo.
- `scripts/provision/pve-win11-vm.sh` (VM 900) — **retired**: windows11 is a
  showcase-only SPA exhibit; VM 900 was deleted 2026-07-08.

## Env vars referenced by builders (names only — values live outside git)

`WINXP_PRODUCT_KEY`, `XP_ISO_LOCAL`, `XP_ISO_URL`, `XP_ADMIN_PW`,
`SOL10_ISO`, `SOL10_ISO_URL`, `SFOS_VDI`, `SFOS_EMULATOR_URL`,
`SFOS_SKIP_DOWNLOAD`, `BASE_SHA256` (win311), `WOLF3D_URL`, `NETSCAPE_URL`,
`VBE_ZIP_URL`, `VBE9X_URL`, `GALLERY_ROOT`/`GUESTS_ROOT`, per-builder
`ISO_URL`/`SRC_URL` overrides.
