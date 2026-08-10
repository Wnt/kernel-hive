# Licensed / external assets manifest (build-guests inputs)

Every **external input** the `scripts/build-guests/` builders consume, cross-
referenced against what is actually staged on the box (verified + hashed
2026-07-14). The repo itself carries everything needed to rebuild the lab
**except** the media below (staged externally) and the gitignored secrets.

Preflight checker: **`scripts/build-guests/check-assets.sh`** verifies
presence + sha256 of the required staged set and prints a missing-list;
`build-all.sh --check-assets` runs it first.

**What a green preflight does and does not prove (2026-08-10).** The checker was
extended on this date to cover the bridge fleet's external inputs — the DEC media
(decos, pdp11), the five atarist app archives, the c128 CP/M disk, the apple2 GEOS
media, the derived indyr4400 asset drive, and a new **`base-media`** class for the
four blobs baked into the frozen bridge base. Some tiles still have **no row on
purpose**, and that is the honest answer rather than a gap: the six VICE tiles
(c64, vic20, plus4, pet2001, cbm8032, cbm2) and gt40 consume **no external media
whatsoever**, and alto's disk packs ship inside the pinned ContrAlto2 git tree. A
hollow row would make the report look better while telling you less.

**Not assets:** the host-built MAME binaries under
`/data/vms/streamhost/assets/<tile>/mame/` — the six `build-mame-*.sh` products
`bbcb` (122 MB), `dragon`, `kc85`, `mpf2`, `oricatmos`, `zx81` (68-80 MB each),
plus the irix tile's separately-built `sgi` and its two superseded candidates.
They are **build artifacts**: losing one costs a chroot rebuild, not the tile.
They are deliberately absent from both this manifest's asset tables and
`check-assets.sh`.

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
- **base-media** — media that is not staged anywhere, because it is BAKED INTO
  the frozen bridge base qcow2 and inherited by every bridge tile's overlay. The
  hash record is the whole point; there is no path to stat. Its underlying terms
  are per-file (see the `base-media` table in §2).
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
| `zx81a.rom` (Sinclair ZX81 **second-revision** 8 KB ROM — Sinclair BASIC with floating point, the SLOW/FAST display driver and the character set; MAME `zx81` `-bios 2nd`) | `14ad84f4243efcd41587ff46ab932d11087043e8d455a1ed2a227b9657828dfa` *(locally measured 2026-08-09)*; SHA1 `7b143ee964e9ada89d1f9e88f0bd48d919184cfc`, CRC32 `4b1dd6eb` *(MAME 0.289 driver pin — matched against the shipped binary's own `-listxml`, not a filename)* | 8 192 | `zx81.sh` | Internet Archive item [`MAME_0.224_ROMs_merged`](https://archive.org/details/MAME_0.224_ROMs_merged), single-member extraction `https://archive.org/download/MAME_0.224_ROMs_merged/zx81.zip/zx81a.rom`; staged `/data/assets-staging/zx81/zx81a.rom` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | **Preservation source, and NOT covered by the Amstrad permission.** Amstrad's 1986 purchase of Sinclair's computer business took the Spectrum and QL rights; the ZX80/ZX81 ROM was written by and remains the copyright of **Nine Tiles Networks Ltd**, who have never issued the blanket emulation permission Amstrad gave for the Spectrum ROMs. Private preservation exhibit only: streamed as pixels, never committed, never served, no download affordance in the tile. `-bios 3rd` (`zx81b.rom`) could not be sourced and is not pursued. |
| `2.11BSD_rq.dsk.zip` (2.11BSD, UC Berkeley 1991 — Don North's prebuilt MSCP pack; unzipped `2.11BSD_rq.dsk` is 1 000 047 616 B, sha256 `2f100ee585f229fd55923e1d1c44108e72df96f649f28a31df35985e6a481805` **pristine**, before the tile's four in-guest site-config edits) | `94abeca02f001619e7aa2252cb2336ffe79af0cb3fb35cbd8c14240af3125a6b` *(locally measured 2026-08-09)* | 49 850 663 | `pdp11.sh` | [`ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip`](https://ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip); staged `/data/vms/streamhost/tiles/pdp11/media/` | Predates the Net/2 split, so **NOT** covered by the Caldera 2002 Ancient-Unix letter, and the prebuilt image carries no licence statement. Preservation-source: stream-only pixels, never committed, never served, no download affordance. |
| `rtv53swre.tar.Z` (RT-11 V5.3 kit: `Disks/rtv53_rl.dsk` RL02 distribution pack + `Licenses/pdp11_license.txt`) | `9fdad10969f1f391b13d9d97aa8fc1aa8fcb44472dac363d23eb2d31500207bc` *(locally measured 2026-08-09)* | 1 373 083 | `decos.sh` | `http://simh.trailing-edge.com/kits/rtv53swre.tar.Z` — **origin host offline** (Cloudflare 520); retrieved through the Wayback raw form, snapshot `20020108101052`. Staged `/data/assets-staging/decos/` with adjacent `SHA256SUMS` | **Mentec hobbyist grant (1997-07-31): "use and copy … solely for personal, non-commercial uses in conjunction with the EMULATOR" — NOT distribute.** Private exhibit only; never committed, never served, no download affordance. Licence text itself is at `docs/guests/decos-mentec-license.txt` (a licence text is not licensed software). |
| `rsx11m42.zip` (RSX-11M **V4.2 BL38** TK50 kit: `m42kit.tap` + `build.txt`) | `c8766a53ae5b32c060560d5cea6302715c046322c80dbc234cc7e63ab2391ba1` *(locally measured 2026-08-09; re-fetched same day, byte-identical)* | 6 155 772 | `decos.sh` | [`bitsavers.org/bits/DEC/pdp11/rsx11m/rsx11m42.zip`](https://bitsavers.org/bits/DEC/pdp11/rsx11m/rsx11m42.zip) — live | Same Mentec grant. **V4.2, not the V4.3 ceiling** — no reachable copy of V4.3 exists anywhere (see `docs/guests/decos.md`). Do NOT substitute `rsx11m.com`'s `PiDP11_DU0.zip`: that is RSX-11M-**PLUS** V4.6, outside the grant. |
| **BBC Micro Model B ROM set** — five blobs staged at `/data/assets-staging/bbcmicro/`: `os12.rom` (Acorn MOS 1.20, SHA-1 `0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d`, sha256 `2d9fea69017864f6962704481829f95fee08446c8c3a13826d5d4e44000ac9de`, 16 384 B); `basic2.rom` (BBC BASIC II, SHA-1 `4a7393f3a45ea309f744441c16723e2ef447a281`, sha256 `45bd55dc0f6f0f8f1fe9e2481de7def206565eec8f600ba3068b849ca4132079`, 16 384 B); `phroma.bin` (TMS5220 speech PHROM, SHA-1 `b369809275cb67dfd8a749265e91adb2d2558ae6`, sha256 `8c093401661f530032c5aca8fd80d91af58e596d082a51be58ce2ee063a89308`, 16 384 B); `saa5050` (SAA5050 teletext character generator, SHA-1 `6c8daba70374e5aa3a6402f24cdc5f8677d58a0f`, sha256 `9706945b02dd0e30823186ff0d73a49c0d98ed573499a057bab471add7ee28fb`, 960 B); `dnfs120.rom` (Acorn DNFS 1.20, SHA-1 `7e3c536baeae84d6498a14e8405319e01ee78232`, sha256 `e745e34895225a6650b712c1dd0656cb0b0b15f072a8ae6d9ea8d1ac257eb3d6`, 16 384 B) | *(per-file sha256 in the left column — all five measured locally 2026-08-09)* | 66 496 total | `bbcmicro.sh` | **PRESERVATION-SOURCE, NO AUTHORISED URL.** No rights holder publishes these dumps and none authorises a mirror; the only routes that exist are bulk MAME romset dumps nobody was authorised to upload, so this manifest deliberately records **no** fetch URL. The builder does not download: it requires the operator's own staged blobs at `/data/assets-staging/bbcmicro/` and gates each on the SHA-1 above, then assembles `bbcb.zip` / `bbc_acorn8271.zip` / `saa5050.zip` itself. Note `saa5050` is a THIRD zip, in no BIOS set — MODE 7 has no glyphs without it and MAME refuses to start. | Acorn MOS and BBC BASIC are unlicensed for redistribution, and there is documented doubt that Acorn's successors hold clean assignment of the original MOS work — so there is no party who could grant one. Private preservation exhibit only: stream-only pixels, never committed, never served, no download affordance. |
| **ARM Evaluation System media** — four blobs staged at `/data/assets-staging/armeval/` ON TOP OF the bbcmicro set above (`os12.rom`, `basic2.rom`, `phroma.bin`, `saa5050` are the same files and the same hashes, staged again in this tile's own directory): `armeval_101.rom` (ARM Tube co-processor bootstrap, Executive v1.00 14th August 1986 — MAME `bbc_tube_arm` default BIOS `101`, SHA-1 `f86bbc4894e62725b8ef22d44e7f44d37c98ac14`, sha256 `d6ef843f82d7308f0ee68b4b30b4e6c6a561e753991f5634dbe6ae969b4204a7`, 16 384 B); `Acorn-ADFS-1.30.rom` (Acorn Advanced Disc Filing System 1.30, loaded by PATH into sideways socket 3 — `-rom3`; SHA-1 `301fd05c475a629c4bec70510d4507256a5b00d8`, sha256 `4f785bb4572bde31a93f12687dec501c9005b6a0decc6ac943c657447095a563`, 16 384 B); `dfs v2.23,acorn.rom` (Acorn DFS 2.23 — MAME `bbc_acorn1770` default BIOS `dfs223`, SHA-1 `0d7ed0b0b3852cb61970ada1993244f2896896aa`, sha256 `964c9ab33650b9429dd3eb513150b3110c607e0344f90d00ffaa546f982f66db`, 16 384 B); `armevaluationsystem-disc3.adl` (ARM Evaluation System Disc 3, "Utilities 2 / BASIC" — carries `$.AB`, ARM BBC Basic V 1.00; MAME softlist `bbc_flop_arm:armevals` part `flop3`, SHA-1 `f5114ff744f6f742da3959a91a1b98af0bd1db5d`, sha256 `c55f8a1c8abd2d1de4cb6afc4a96cbe72ed1446b39b1a3bbf06ef67698a29375`, 655 360 B) | *(per-file sha256 in the left column — all four measured locally 2026-08-09)* | 704 512 total | `armeval.sh` | **PRESERVATION-SOURCE, NO AUTHORISED URL, AND A DISPUTED CHAIN OF TITLE.** Same position as the BBC Micro set: no rights holder publishes these dumps and none authorises a mirror, so this manifest deliberately records **no** fetch URL. The builder does not download — it requires the operator's own staged blobs and gates each on the SHA-1 above, then assembles `bbcb.zip` / `saa5050.zip` / `bbc_tube_arm.zip` / `bbc_acorn1770.zip` BY SHA-1 against the shipped binary's own `-listxml` (the staged file is `phroma.bin`; the member MAME wants is `cm62024.bin`, and only the hash connects them). Note `bbc_acorn8271`/`dnfs120.rom` is NOT part of this tile: `-fdc acorn1770` replaces it, because the ADFS `.adl` discs are double density and the 8271 cannot read them. All SIX `armevals` discs were obtained and all six SHA-1s match MAME 0.289's `hash/bbc_flop_arm.xml`, so discs 4-6 (Cambridge LISP, PROLOG, FORTRAN 77) exist for a later exhibit; only disc 3 is staged and used here. | Acorn's ARM bootstrap, ADFS, DFS and the evaluation-system discs are all unlicensed for redistribution, and the chain of title through Acorn's successors is genuinely disputed — there is no party who could grant one. Private preservation exhibit only: stream-only pixels, never committed, never served, no download affordance. |
| `rsts_v9_6_install.zip` (RSTS/E V9.6 installation tape, TPC format, 11 850 records / 175 tape marks) | `aaf4aa978e13318fe304dfbf75e20090206e17caa5b76bab69bec2704d9c694f` *(locally measured 2026-08-09)* | 8 071 836 | `decos.sh` | `https://ftp.trailing-edge.com/pub/rsts_dists/rsts_v9_6_install.zip` — **origin host offline**; retrieved through the Wayback raw form. Staged `/data/assets-staging/decos/` | Same Mentec grant (V9.6 is exactly the recital's ceiling). **Do NOT substitute RSTS/E V10.1** — outside the grant. |
| `spectrum-roms_20081224-5_all.deb` (Debian **non-free** `spectrum-roms`; the tile uses only its `usr/share/spectrum-roms/48.rom`, which is byte-identical to MAME's `spectrum.rom`) | `.deb` `8d25dd300a0c86b4459e152de3bc657dca894b167e6a6419eb195d9669bfe950`; extracted `48.rom` sha256 `d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42`, sha1 `5ea7c2b824672e914525d1d5c419d71b84a426a2` *(all locally measured 2026-08-09; the sha1 is also MAME 0.251's and 0.276's pin for `-bios en`)* | 202 748 (`.deb`) / 16 384 (`48.rom`) | `zxspectrum.sh` | [`deb.debian.org/debian/pool/non-free/s/spectrum-roms/spectrum-roms_20081224-5_all.deb`](https://deb.debian.org/debian/pool/non-free/s/spectrum-roms/spectrum-roms_20081224-5_all.deb) — live; the builder fetches and verifies it into `/data/assets-staging/zxspectrum/` if absent | **freely-fetchable-pinned, and the cleanest permission in this table.** `usr/share/doc/spectrum-roms/copyright` inside the package quotes Cliff Lawson of Amstrad plc's 1999 posting verbatim: *"Amstrad are happy for emulator writers to include images of our copyrighted code as long as the (c)opyright messages are not altered"*, conditioned on nobody charging for the ROM code and on emulator (not hardware) use. Both hold here, and the first is honoured on screen: the exhibit's idle fixture IS the unaltered `© 1982 Sinclair Research Ltd` line. Debian ships it in non-free because the terms restrict sale and no source exists — not because redistribution is barred. Still never committed: the repo records the URL and the hashes only. |
| `cpm.system.6228151676.d64` (Commodore **CP/M 3.0 / CP/M Plus** system disk for the C128 — the Z80 side of the machine) | `.gz` `6ed0da2d8a6fa74ae7b6e6cb67d78e1806a2a625ca839b4d93558c5ce7f44cb9`; decompressed `.d64` `69159226bf1996d8fc8c8921f094cd03955c7a8b9ecf800069d1c369dc6e5a1d` *(both locally measured 2026-08-09; the `.d64` re-verified 2026-08-10 on the host copy AND inside the live overlay — identical)* | 76 230 (`.gz`) / 174 848 (`.d64`) | `c128.sh` | [`zimmers.net/anonftp/pub/cbm/demodisks/c128/cpm.system.6228151676.d64.gz`](https://www.zimmers.net/anonftp/pub/cbm/demodisks/c128/cpm.system.6228151676.d64.gz) — a **single mirror**. Two copies exist on the box: the builder's host cache `/data/vms/streamhost/tiles/c128/media/{cpm.d64,cpm.d64.gz}` (the offline recovery path, now a `check-assets.sh` row) and the in-guest copy `/opt/bridge/media/c128/cpm.d64` inside the tile overlay, attached by VICE `-8` (a VICE argument, not a QEMU device, so the golden device set is unaffected). **Pending population into the shared media cache.** | **The one external file in the Commodore wave** — VICE bundles the C128 ROMs, including the CP/M Z80 BIOS, but not the CP/M system DISK. Commodore/DRI-era copyright, terms unclear. Private preservation exhibit only; never committed, never served, no download affordance in the tile. |
| `ql-mame0224-merged.zip` (MAME `ql.zip` — the Sinclair QL romset; the tile uses only four of its 27 members) | `c4c39530c7abe6518f90b0df9d4eec9201434a905c77f05f490137007e420b03` *(locally measured 2026-08-09)* | 499 412 | `sinclairql.sh` | [`archive.org/download/MAME_0.224_ROMs_merged/ql.zip`](https://archive.org/download/MAME_0.224_ROMs_merged/ql.zip); staged `/data/assets-staging/sinclairql/ql-mame0224-merged.zip` with adjacent `MANIFEST.sha256` — **PRESENT + verified**. The builder re-assembles a four-member `ql.zip` **by SHA1** inside the guest — `ql.js 0000.ic33` `59fd4372771a630967ee102760f4652904d7d5fa`, `ql.js 8000.ic34` `b8c9203026a7de6a44bd0942ec9343e8b222cb41`, `ipc8049.ic24` `fcb1c97ee7c66e5b6d8fbb57c06fd2f6509f2e1b`, `bql010-sqpp` `ba94bdad2303a263008b6ea744669a19938d9998` — and verifies them against the shipped MAME's own `-listxml ql`. The QL's `hal16l8.ic38` PLD is `nodump` in every MAME set that has ever existed. | **Amstrad's Sinclair permission does NOT cover this.** That grant is read as covering the ZX Spectrum line and the machines Amstrad itself built; Amstrad acquired the QL rights and sold them on, and no published emulator permission for the QL ROM was found. Treat as preservation-source with unclear terms: private exhibit only, never committed, never served, no download affordance. |
| `d32.rom` (Dragon 32 monitor + Microsoft 16K Extended Color BASIC 1.0, the machine's whole 16 KB ROM) | `fc0e900bfec6b52f0f80ba1e65a4712808d2a411b5b00496639ef1a2152351f1` *(locally measured 2026-08-09; SHA1 `f2dab125673e653995a83bf6b793e3390ec7f65a` matches MAME's own pin for the `dragon32` driver, read back from `-listxml` on the shipped 0.289 binary)* | 16 384 | `dragon32.sh` | [`archive.org/download/MAME_0.224_ROMs_merged/dragon32.zip/d32.rom`](https://archive.org/download/MAME_0.224_ROMs_merged/dragon32.zip/d32.rom) — the single-member extraction form, 1.4 s instead of a merged set. Staged `/data/assets-staging/dragon32/d32.rom` with adjacent `MANIFEST.sha256`; the builder re-fetches and re-hashes if it is absent. **The rest of `dragon32.zip` is not needed and is not staged** — the tile runs with the `ext` slot emptied, so `ddos10.rom` (which `-verifyroms` demands) would only produce the wrong screen. | ROM copyright status is unclear: Dragon Data Ltd has been gone since 1984 and the BASIC lineage is Microsoft's. Preservation source. Private exhibit only; never committed, never served, no download affordance. |
| `basic11b.rom` (Oric Atmos **Extended BASIC V1.1**, the machine's whole ROM) | sha256 `ed28568574716eef5d7c0fde2568d7a47a6e4b1fbca81daff3be05e45723466d` *(locally measured 2026-08-09)*; SHA1 `9451a1a09d8f75944dbd6f91193fc360f1de80ac`, CRC32 `c3a92bef` *(MAME `orica` bios `ver11` pin, asserted at build time against the SHIPPED binary's own `-listxml`)* | 16 384 | `oricatmos.sh` | Extracted from `oric1.zip` (sha256 `9a9b227ea8f234ba99a9309fbddbf5506ae6333fbc357a5a3e8ab20f7f22b093`, 406 610 B), member `orica/basic11b.rom`, of the Internet Archive item [`MAME_0.224_ROMs_merged`](https://archive.org/details/MAME_0.224_ROMs_merged) — the item stores per-game zips at its root, so the builder fetches only that one 406 KB zip. **`orica` is a CLONE of `oric1`, so in a merged set its BIOS variants live in the PARENT's zip** under an `orica/` prefix. Staged `/data/assets-staging/oricatmos/basic11b.rom` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | Tangerine Computer Systems / Oric Products International are both long defunct and no rights-holder can be identified; copyright status unclear. Private preservation exhibit only — the ROM is never committed and never served, only executed. |
| `kc85_2.zip` (merged MAME romset for the KC 85 family from VEB Mikroelektronik Mühlhausen — 18 members covering `kc85_2`/`kc85_3`/`kc85_4`/`kc85_5`; `kc854.sh` extracts three of them **by SHA1**: `caos__c0.854` `774fc2496a59b77c7c392eb5aa46420e7722797e`, `caos__e0.854` `4300f7ff813c1fb2d5c928dbbf1c9e1fe52a9577` and the dump MAME calls `basic_c0.854` `c2e3af55c79e049e811607364f88c703b0285e2e`, which in this archive is stored under the name `kc85_3/basic_c0.853` — no member called `basic_c0.854` exists) | `ed5b8a567232beb89a5f78fea4066160aec2ba0f2a67555439c20785d6a096ab` *(locally measured 2026-08-09)* | 119 343 | `kc854.sh` | Internet Archive item [`MAME_0.224_ROMs_merged`](https://archive.org/details/MAME_0.224_ROMs_merged), file `kc85_2.zip` (merged set: the whole family lives in the parent's zip, so `kc85_4.zip` 404s). Staged `/data/assets-staging/kc854/kc85_2.zip` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | CAOS and HC-BASIC were published by VEB Mikroelektronik "Wilhelm Pieck" Mühlhausen, a state combine that was wound up with the GDR in 1990; there is no successor who could grant or withhold a licence, and the images circulate freely in preservation archives and ship in MAME's own hash files. Copyright status is therefore unclear rather than permissive. Private preservation exhibit only; never commit or publicly serve the ROMs. |

### MAME romset reservoir — archive.org bulk MAME dumps

Individual MAME romsets are not staged one at a time by hand. The practical
source is a bulk archive.org dump of an older MAME, fetched **per parent zip**
(no need to mirror the whole thing) and re-assembled for the MAME the tile will
actually ship:

| item | contents | note |
|---|---|---|
| [`MAME_0.224_ROMs_merged`](https://archive.org/details/MAME_0.224_ROMs_merged) | 13 245 zips, 72.6 GB, **merged** (clones live inside the parent's zip) | the best-coverage item found so far; other MAME versions exist on archive.org and are worth trying when a member is missing |

**Merged means clones are folded in**, so a machine having no zip of its own is
usually not a gap: `specpls2`/`specpls3` are inside `spec128.zip`, `dragon64`
inside `dragon32.zip`, `kc85_3`/`kc85_5` inside `kc85_2.zip`, `aa305`/`aa440`
inside `aa310.zip`, `sx64` and `c64_se` inside `c64.zip`.

**YOU CANNOT FEED THESE ZIPS STRAIGHT TO A NEWER MAME.** Use
[`scripts/dev/mame-romset.py`](../../scripts/dev/mame-romset.py), which asks the
MAME you will ship what it wants, indexes every member of every candidate zip by
**SHA1 rather than filename**, and writes a set under the names that MAME
expects. Three failure modes it exists to defeat, each observed here:

- **Members get renamed between versions.** kim1's `6530-002.bin` became
  `6530-002.u2`; the bytes are identical and a filename-based copy fails.
  Demonstrated end to end: the 0.224 zip yields a 0.276-correct set that
  `-verifyroms` calls good.
- **Parent/clone splits move.** `kc85_4` was a `kc85_2` clone in 0.251 and is
  its own parent in 0.276, needing `basic_c0.854` — a member that only ever
  lived in the parent's zip. `--also <other-parent>` covers this.
- **`-verifyroms` is not a usable gate** for computer drivers: it reports "bad"
  purely because *alternative BIOS* entries are absent (spectrum carries ~30
  third-party ROMs), and on `dragon32` it actively points the wrong way — it
  demands the FDC ROM that makes the machine boot DRAGONDOS instead of
  Microsoft BASIC. Gate on the framebuffer and on pinned SHA1s.

`-listxml <driver>` also emits every machine reachable through the driver's
**slots**, and those are not required: a bare `kim1` pulls in an Apple II
Mockingboard, a Scorpion and four Sun keyboards. The tool treats the driver's
own set as required and device sets as optional, so a set is not reported
broken because an unrelated slot device is absent.

Licence class for everything sourced this way: **preservation-source, no
authorised URL** — a bulk romset dump is not an authorised distribution by
anyone. Fine to RUN on this private passkey-gated exhibit; record the URL, the
measured sha256 and the class, and **never commit the bits** — the repo is
public.

### `indyr4400` — an asset DERIVED from another tile's golden, not downloaded

| Asset | sha256 | Bytes | Consumed by | Provenance | Class / terms |
|---|---|---|---|---|---|
| `irix65-r4400-disk.ext4` — a read-only ext4 image whose only content is `disk.raw`, the raw SGI disk carrying this lab's IRIX 6.5.22 install. Staged `/data/gallery-guests/IrisIndy/irix65-r4400-disk.ext4` (444 + immutable), 6500 MiB apparent / ~500 MiB allocated (sparse). The **container's** own hash is not reproducible (mkfs stamps a random UUID), so the hash recorded here is the INNER `disk.raw`. | inner `disk.raw`: `b8214c34a2983ce9f2b0781ef56a7a71971da2e3dbcb87cc7f1f990f822b1c61` *(locally measured 2026-08-10, verified equal on both sides of the wrap)* | inner `disk.raw`: 6 291 456 000 | `scripts/build-guests/tiles/indyr4400.sh`, staged + verified by `streamhost/tiles/indyr4400/fetch-assets.sh` | **No external download.** Extracted with `chdman extracthd` from a **copy** of this lab's own `irix65-apps.chd` — the `irix` tile's golden, already recorded in this section. Iris's CHD backend rejects that uncompressed CHD (`InvalidFile`), which is why the raw form exists; the ext4 wrapper exists because Iris sizes a disk with `File::metadata().len()`, which is 0 for a block device, so the read-only asset drive has to present a regular FILE. | **preservation-source**, inheriting the `irix65-apps.chd` terms exactly — same bits, different container. **PUBLISH BLOCKER**: never committed and never publicly served. |

**Not an asset:** the `iris` emulator binary itself. It is built from source
(`github.com/techomancer/iris`, BSD-3, `main` @ `1e05210`, features
`lightning,rex-jit,chd`) in a throwaway bookworm chroot by the builder and
installed to `/data/gallery-guests/IrisIndy/iris-bookworm`. Nothing about it
is licence-encumbered; it is listed here only so the path is discoverable.


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
| NeXTSTEP 3.3 for m68k, pre-installed disk `NS33_2GB.dd` | sha256 `6381423b066c33c24c9c9ec519086708b9cf3b2f11882fed5319cfb6a3422f1b` *(measured)*; enclosing `.7z` sha256 `6940df2a00cc9cc1f8849667deeb7d30c6fb4aced2e31d44d719df32db059b47`, 60 508 875 B | 2 012 774 400 (sparse, ~232 MB on disk) | `nextstep.sh` | nextstep kiosk guest `/opt/bridge/media/nextstep/NS33_2GB.dd` — **PRESENT in-guest** (inside the tile overlay + its golden; re-fetched by the builder) | archive.org item `nextstep-3.3-hd-image-with-previous.-7z`; NeXT/Apple-copyrighted, preservation class, RUN privately here, never re-distributed |
| NeXT ROM Rev 2.5 v66 `Rev_2.5_v66.BIN` | sha256 `1b753890b67095b73e104c939ddf62eca9e7d0aedde5108e3893b0ed9d8000a4` *(measured)* | 131 072 | `nextstep.sh` | nextstep kiosk guest `/opt/bridge/media/nextstep/Rev_2.5_v66.BIN` — **PRESENT in-guest**; taken from the Previous source tree (`src/Rev_2.5_v66.BIN`, SVN r1847), byte-identical to the archive.org copy | SourceForge `previous` SVN; NeXT/Apple-copyrighted, RUN privately here, never re-distributed |
| NeXTSTEP 3.3 **Intel** User ISO | none | ~356 MB | *(historical)* | **not staged** — the Intel route is a documented dead end (QEMU-10 SCSI/IDE I/O wall); the live tile is the m68k route above | archive.org item `NeXTSTEP33CISC` |
| Amiga Kickstart 1.3 ROM `kick13.rom` | md5 `82a21c1890cae844b3df741f2762d48d` *(pin, measured-match in-kiosk)* | 262 144 | `amiga.sh` (+ URL also in `bridge-base.sh`) | amiga kiosk guest `/opt/bridge/media/amiga/kick13.rom` — **PRESENT in-guest** (baked into the bridge overlay golden; re-fetched by the builder) | archive.org item `commodore-amiga-firmware`; Amiga ROMs are Cloanto/Amiga-copyrighted |
| Workbench 1.3 boot ADF `workbench13.adf` | md5 `d10f4907697c4eafcf976b4ef6ea829b` *(pin, measured-match in-kiosk)* | 901 120 | `amiga.sh` | kiosk `/opt/bridge/media/amiga/workbench13.adf` — **PRESENT in-guest** | amigamuseum.emu-france.info mirror |
| Dwarf/Draco Mesa emulator `dist.zip` | sha256 `67f84b77cbed6cba9d7d2485e84b8142e4fd2403243f8abd8f6e5a81ff6fcf75` *(pin, measured-match in-kiosk)* | 509 198 | `daybreak.sh` | daybreak kiosk guest `/opt/bridge/media/daybreak/dist.zip` — **PRESENT in-guest** (unpacked into the tile overlay + its golden; re-fetched by the builder) | `github.com/devhawala/dwarf` — **URL pinned to commit `c264af5e37f89d7aa0eec968aa23818bf5a89837`, not to `master`** (changed 2026-08-10; both blobs re-fetched from that commit and re-hashed — byte-identical to the pins, so nothing has moved yet). A moving ref against a fixed hash is a *timer*, not a risk: the first upstream push makes the fetch succeed and the hash check fail, and the build then reports an integrity violation for what is really "upstream moved". **BSD-3-Clause, redistributable** — but the licence covers the emulator ONLY, not the Xerox disk below |
| Xerox ViewPoint 2.0.5 Pilot disk `vp2.0.5.zdisk` | sha256 `02bdb53ba7f7896a914fe43b7ca19a620907d0fdbf0f55317b7d1f39aab3f872` *(pin, measured-match in-kiosk)* | 4 657 062 | `daybreak.sh` | daybreak kiosk guest `/opt/bridge/media/daybreak/vp2.0.5.zdisk` — **PRESENT in-guest** | `github.com/devhawala/dwarf` `disks-6085/vp2.0.5.zdisk`, at the same pinned commit `c264af5e37f89d7aa0eec968aa23818bf5a89837` (see the row above for why `master` was wrong); **preservation-source** — Xerox-copyright ViewPoint/Pilot software rebuilt from the Bitsavers XDE 5.0 6085 disk plus the VP 2.0.5 floppy set. RUN privately here, streamed as pixels, never re-distributed and never given a download affordance. Its Software Options are unlocked but **bound to processor id `10-00-FE-31-AB-21`** — changing the emulated MAC re-locks every application |
| Xerox 8010 "Dandelion" rigid-disk pack `8010_hd_images.zip` | sha256 `d9fb11362229ba7b9dbb7500f2240f9c1e9cdaa9f37bb4431221174483ca438e` *(pin, measured-match in-kiosk)* | 14 020 559 | `star.sh` | star kiosk guest `/opt/star/8010_hd_images.zip` — **PRESENT in-guest** (unpacked into the tile overlay + its golden; re-fetched by the builder) | [`bitsavers.org/bits/Xerox/8010/8010_hd_images.zip`](https://bitsavers.org/bits/Xerox/8010/8010_hd_images.zip) — live. **preservation-source**: three Dandelion rigid-disk images (ViewPoint 2.0, XDE 5.0, Interlisp-D Harmony). Xerox never released ViewPoint or Pilot and there is no licence grant. RUN privately here, streamed as pixels, never re-distributed and never given a download affordance |
| Xerox ViewPoint 2.0 Pilot volume `ViewPoint-2.0-11-9-1990-18-38.img` | sha256 `a7ead97a18d748debd769e5d2358f05ece24f10a5421e9fbc73b598e4a7f7020` *(measured)* | 65 433 601 | `star.sh` | star kiosk guest `/opt/star/run/vp20.img` — **PRESENT in-guest**, extracted from the pack above and re-verified on every build | Same pack, same posture. Time-locked: the emulated TOD clock must read December 1997 (Xerox "Product Factoring"), option key `8 7T78 M8YL LFEQ` |
| Darkstar (Xerox 8010 emulator), commit `7ab55ff3d5c1802e7e69561a04b3e845ef92b53e` | *(git commit pin — no tarball)* | ~2 MB source | `star.sh` | BUILT from source in the star tile overlay (`mono-complete` + `nuget restore` + `xbuild`); no binary is fetched | [`github.com/livingcomputermuseum/Darkstar`](https://github.com/livingcomputermuseum/Darkstar); **BSD-2-Clause, redistributable** — but the licence covers Josh Dersch's emulator ONLY. The same repo also carries Xerox-copyright Dandelion IOP PROM dumps (`537P030xx.bin`) and CP microcode, which are **preservation-source** on the same footing as the disk above |
| GEOS 2.0 for C64 `.d64` | md5 `709bec31c3502cbcf5d4761c38dcfa9e` *(pin)* | ~170 KB | `bridge-base.sh` / `c64.sh` | c64 kiosk media dir (in-guest) | archive.org item `geos64_J1AD`; Berkeley Softworks. VICE itself bundles the C64 kernal/basic ROMs (fetched as VICE 3.x source from SourceForge) |
| Apple GEOS deskTop for the Apple //e — `GEOS-mouse supported by APPLEWIN.hdv.zip` and the `geos.hdv` ProDOS image it unpacks to (volume `/BIGWON`, file dated 2009-12-05) | `.zip` sha256 `64b7bef2440e2f0424586a893c641b566901403ad3ce6b3b5adaab573ae23e35`; `geos.hdv` sha256 `5aba89dda3450abf17b8cc05d9de98149abe0bb072e5b01cc29b7fff995fc681` *(both **locally measured 2026-08-10** on the live apple2 overlay — this row previously read "none")* | 599 723 (`.zip`) / 1 327 616 (`.hdv`) | `apple2.sh` | [`mirrors.apple2.org.za/…/other_os/gui/geos/`](https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/masters/other_os/gui/geos/) (Asimov mirror) — a **SINGLE mirror, and the only source this tile has**. The bits live only inside the tile overlay at `/opt/bridge/media/{geos.hdv,geos-mouse.hdv.zip}`; there is no host-side copy. **Pending population into the shared media cache.** linapple bundles the Apple //e ROM, so no ROM is fetched | **abandonware-URL.** Breadbox released Apple GEOS as freeware in 2003; this is the AppleWin-tailored (== LinApple) mouse build. Both sha256s are now **fatal gates** in `apple2.sh` — before 2026-08-10 the only validation was `file geos.hdv \| grep ProDOS`, which any ProDOS image passes, including a truncated or substituted one. The `file` assertion is kept as a *secondary* check: the hash says it is the right file, `file` says it is a sane one, and the two failures read differently. apple2 must be rebuilt for the trixie/`sdl12-compat` move, so an unpinned single mirror was the fleet's weakest link |
| RISC OS 5.30 IOMD ROM + HardDisc4 | none | ~4 MB + ~50 MB | `riscos.sh` | showcase-only tile (neko backend retired) — no live staging | riscosopen.org zipfiles; RISC OS Open licence (free download) |

**Atari ST needs NO TOS ROM** — `atarist.sh` boots EmuTOS (GPL,
`emutos-1024k-1.3` pinned via `bridge-base.sh`).

#### `atarist` — the five curated GEM application archives

All five are **sha256-gated fatally** in `atarist.sh` (a mismatch aborts the
build), and all five were **re-measured on the box 2026-08-10** — every hash
matches its builder pin exactly. What was missing until then was the *declaration*:
they appeared in no manifest and had no `check-assets.sh` row, while living in
exactly one place — `/data/vms/streamhost/tiles/atarist/assets/atarist-apps/`,
a **tile directory nobody treats as an asset location**. They now have rows in
both. **Pending population into the shared media cache**; do not clean that dir.

The exposure is the *sources*, not the hashes: three small sites, one of which
(`exxosforum.co.uk`) requires a two-step PHP cookie handshake — `DL_CAP2.php`
then `dl.php` — and another of which addresses its file by an opaque numeric id.

| file | sha256 *(all locally measured 2026-08-10)* | size | source | class / terms |
|---|---|---|---|---|
| `ART-3488.zip` (AIM 3.1 image manager / paint package) | `a5b245ae886aaeedc7d98a0d7ae774c75c214faa567f5b3f88321c89a210e147` | 338 767 | `exxosforum.co.uk/atari/PDL/FLOPPYSHOP/` (Floppyshop PD library), two-step PHP cookie handshake | **abandonware-URL** — public-domain package in the Floppyshop PD library; no rights holder identifiable. Private exhibit, never committed |
| `UTL-3762.zip` (GEMBench 4.03 benchmark) | `74bce9ec2c7ec4d0da144887e0a5848bde3feff165e4cdabde52c3a395824567` | 506 587 | same Floppyshop route | **abandonware-URL** — unregistered redistributable shareware. Private exhibit, never committed |
| `baller.zip` (Ballerburg) | `8bcb4214cc6a30c02413f73923cabcf65437b9294f6148f3018f01bac9115d45` | 35 465 | [`eckhardkruse.net/atari_st/download/baller.zip`](https://www.eckhardkruse.net/atari_st/download/baller.zip) — the author's own site | **freely-fetchable-pinned** — released to the public domain by its author, Eckhard Kruse. The cleanest licence in this group |
| `baller_sources.zip` (Ballerburg sources) | `63fb6c5aa14f4f912e4d5cff61f42fa35951932d0635b185e14da434212ed593` | 66 041 | same author site | **freely-fetchable-pinned** — same PD grant; shipped in the guest's `ORIGINAL/` folder alongside the binary |
| `pacman_for_gem_0_25.zip` (Pacman for GEM 0.2.5) | `6f33a9e7371f9fb6bd635dd6d67250e1c5adc6c0b44b609e726e0fed84f5fe3e` | 177 423 | `atarimania.com/pgedump.awp?id=31902` — an opaque numeric id, not a filename | **abandonware-URL** — freeware; the original archive's own terms permit redistribution. Private exhibit, never committed |

### `base-media` — the four blobs baked into the frozen bridge base

These are on **no host path**. They live inside
`/data/vms/bridge/bridge-base.qcow2` at `/opt/bridge/media/`, and every bridge
tile inherits them through its thin overlay — so a `check-assets.sh` row for them
reads "will fetch", exactly like the nextstep/daybreak/star in-overlay rows. The
rows exist for the **hash record**. Verify for real by reading the base
**read-only and never writable** (`qemu-nbd --read-only`, ~5 s); the hashes below
were taken the cheaper equivalent way, through four independent live overlays
(pet2001, c64, atarist, apple2), which all report the same bytes.

The base also carries `/opt/bridge/media/LICENSES`, a 725-byte text note rather
than media — so "five things in `/opt/bridge/media`" is four blobs plus a README.

| file | sha256 *(locally measured 2026-08-10)* | size | consumed by | source / class |
|---|---|---|---|---|
| `GEOS.D64` (GEOS 2.0 for the C64) | `2aabeb34bd3bb21866f5c50db172a4aeb11163ed1dc178eb82342f7ce3405a59` (md5 `709bec31c3502cbcf5d4761c38dcfa9e`, matching the `bridge-base.sh` pin) | 174 848 | `c64.sh` | archive.org `geos64_J1AD`; Berkeley Softworks. **abandonware-URL**, private exhibit only |
| `etos1024k.img` (EmuTOS 1.3, 1024 KB ROM image) | `e2692d0277d473128ac0557fd30a8995a8223a114e91b0e66e8af4ec35b59728` | 1 048 576 | `atarist.sh` | built/pinned by `bridge-base.sh`; **GPLv2** — the one freely redistributable blob of the four |
| `amiga/kick13.rom` (Amiga Kickstart 1.3 r34.005, A500) | `ee05862d8102a08436ac4056da7d549db31625c7d47b24dfb7b3c9a5c113ca53` (md5 `82a21c1890cae844b3df741f2762d48d`, matching the pin) | 262 144 | `amiga.sh` | archive.org `commodore-amiga-firmware`; Cloanto/Amiga-copyright. **abandonware-URL**, private exhibit only |
| `amiga/workbench13.adf` (Workbench 1.3 / 34.20 boot disk) | `3610df193fdbbfbd88da695732a5c3ed63e77ed3de20e187201289e3915bb2c2` (md5 `d10f4907697c4eafcf976b4ef6ea829b`, matching the pin) | 901 120 | `amiga.sh` | amigamuseum.emu-france.info mirror; Commodore-copyright. **abandonware-URL**, private exhibit only |

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
| ContrAlto 2 source tree (Xerox Alto II emulator, **and the Alto media**) | git commit `e3681fbc30d129172b4c306aaee8c4e71ae1a458` of `https://github.com/jdersch/Contralto2.git`, BSD-3-Clause | `alto.sh` | cloned to `/data/gallery-guests/Alto/src`, published self-contained to `/data/gallery-guests/Alto/app`; nothing staged under `/data/assets-staging` |
| `nonprog.dsk` — Xerox Alto **Non-Programmer's Disk** (Bravo 7.5, Draw 5.2, Empress, Laurel, the Helvetica family) | sha256 `2696bc0da29400430b1c829d8a0f6c3a67c1764380cdca5431a29fc0f97da289` *(locally measured 2026-08-10)*, 2 601 648 | `alto.sh` | **ships inside the ContrAlto tree above**, at `Contralto/Disks/nonprog.dsk`; copied into the tile overlay at `/opt/bridge/alto/disk/`. Never fetched separately, never staged, never committed |
| Alto I + Alto II microcode PROM dumps | `ROM/AltoI`, `ROM/AltoII` in the same pinned tree | `alto.sh` | as above — no separate ROM hunt, and no `chdman` conversion (that is a MAME-only tax; MAME's `alto2` does not boot here) |

**Read the Alto rows' licence split carefully.** The BSD-3 licence covers Josh Dersch's code and nothing else: the microcode PROMs and the Diablo packs in that tree are **Xerox-copyright preservation material**, and the Computer History Museum's grant covers providing the Alto file archive to private individuals and non-profits for non-commercial use — it is not a public redistribution licence. The posture is the same as every other preservation row here and is comfortable: a private, passkey-gated exhibit that streams pixels. **Never commit the packs, never serve them, and give the tile no download affordance.**

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
- Sailfish SDK emulator VDI.

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
