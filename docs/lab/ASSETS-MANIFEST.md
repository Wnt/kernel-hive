# Licensed / external assets manifest (build-guests inputs)

Every **external input** the `scripts/build-guests/` builders consume, cross-
referenced against what is actually staged on labhost (verified + hashed
2026-07-14). The repo itself carries everything needed to rebuild the lab
**except** the media below (staged externally) and the gitignored secrets.

Preflight checker: **`scripts/build-guests/check-assets.sh`** verifies
presence + sha256 of the required staged set and prints a missing-list;
`build-all.sh --check-assets` runs it first.

**The bits now have a permanent home.** `/data/media-archive` (ZFS dataset
`data/media-archive`, 150 G quota) is a content-addressed, **never-evicting**
archive of every external build input we could reach — created 2026-08-10 with
131 blobs / 15.8 G, including the media baked inside both bridge seeds. This
manifest remains the **index of record** (licence class, provenance, the
reasoning about redistribution); the archive holds bytes and cross-references
back here by sha256. Being archived is **not** permission to redistribute:
the classes below still govern.

- `scripts/build-guests/lib/media-cache.sh` — `media_cache_require` is the
  resolver builders should use: cache hit → use it; miss → fetch, verify the
  pin, archive it; fetch fails **and** cache misses → **FAIL LOUDLY**. It
  replaces the `curl … || true` pattern, which let a media-less build report
  success.
- `scripts/build-guests/check-media-archive.sh` — verifies every blob against
  its own hash, **and the media inside the two frozen bridge seeds** (which
  nothing checked before), read-only. `--manifest` cross-references this file.
- `/data/media-archive/NOT-POPULATED.md` — what could *not* be archived. That
  list is the set of things this lab would lose today.

**What a green preflight does and does not prove (2026-08-10).** The checker was
extended on this date to cover the bridge fleet's external inputs — the DEC media
(decos, pdp11), the five atarist app archives, the c128 CP/M disk, the apple2 GEOS
media, the derived indyr4400 asset drive, and a new **`base-media`** class for the
four blobs captured into the frozen bridge seed. Some stations still have **no row on
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
  stay private on labhost because redistribution terms are unclear.
- **base-media** — media that is not staged anywhere, because it is BAKED INTO
  the frozen bridge seed qcow2 and inherited by every kiosk's overlay. The
  hash record is the whole point; there is no path to stat. Its underlying terms
  are per-file (see the `base-media` table in §2).
- **VSI Community** — account/application-gated OpenVMS Community media. It is
  usable for this private community-system exhibit but is not redistributable;
  the archive and derived disks are publish blockers and remain off-repo.

Sizes/hashes marked *(measured)* were computed on labhost copies; *(pin)* are
the pins baked into the builder.

## Staging bundle

The migration bundle is at `/data/assets-staging/` on labhost, created
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
Those hosts also carry AAAA records labhost cannot reach, so any `curl` at them
needs `-4` or it hangs ~40 s before failing. **Treat all DEC media as one-shot
fetches: stage the bits on labhost; no builder may fetch them at build time.**

| file | sha256 | size | builder | source / staging path | copyright note |
|------|--------|------|---------|-----------------------|----------------|
| `redstar.iso` (volume label `REDSTAR DESKTOP 2.0`, bootable i386 desktop installer) | `69a45d07c302782cb777d03abd39c5b45b4099e5c994a74a77bb71ab5d229997` *(locally measured 2026-07-16)* | 1 416 017 920 | `redstar2.sh` | Internet Archive item [`redstar_20181224`](https://archive.org/details/redstar_20181224), original file `redstar.iso`; `/data/assets-staging/redstar2/redstar.iso` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | DPRK-origin proprietary distribution; copyright and redistribution terms unclear. Private preservation exhibit only; ISO is not committed or publicly served. |
| `redstar_desktop3.0_sign.iso` (volume label `RedStar Desktop 3.0`, i386; contains `redstar-release-3.0-1.rs3.0.i386.rpm`) | `895ad0e01ae0d35a65e9ac42dd34d0a1d685d6dfa331ce5b4f24bbc753439be3` *(locally measured 2026-07-16; archive original MD5 `acf53d2b50ecb1391044b343502becf5` also matches)* | 2 614 644 736 | `redstar3.sh` | Internet Archive item `https://archive.org/details/redstar_desktop3.0_sign`; `/data/assets-staging/redstar3/redstar_desktop3.0_sign.iso` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | DPRK-origin proprietary distribution; redistribution terms unclear. Private preservation exhibit only; ISO is not committed or publicly served. |
| `fsn.tar.Z` (SGI **File System Navigator 1.2** — the 3D file browser from *Jurassic Park*; ELF o32 MIPS-I binary dated 1996-12-13, plus the `Fsn` app-defaults, `Fsn.icon` and the `fsn(1)` man page) | `53ad2649c78798acd52f16fca2fde769d5df1f50645b496d8818f0ba76ab07ef` *(locally measured 2026-08-03; archive-recorded MD5 `7437bf5ba70ac4eb4f748d8f1be8ef13` matches)* | 215 881 | baked into `irix65-apps-v8.chd` (see `docs/guests/irix.md`) | Internet Archive item [`fsn.tar_202201`](https://archive.org/details/fsn.tar_202201), file `fsn.tar.Z` — a copy of SGI's own `ftp.sgi.com:/sgi/fsn/fsn.tar.Z`; staged `/data/vms/streamhost/assets/irix/fsn/fsn.tar.Z` (444) with adjacent `SHA256SUMS` — **PRESENT + verified** | **PUBLISH BLOCKER.** SGI-copyright freeware, binary-only: the program's own banner reads *"(c) Copyright 1992, 1993, 1996, Silicon Graphics, Inc. All rights reserved … provided for demonstration purposes only … Sorry, source code is not available."* SGI published it for free download but granted no redistribution licence, and SGI is defunct, so no one can grant one now. Private preservation exhibit only — neither the tarball nor `irix65-apps-v8.chd` may be committed or publicly served. |
| `mpf_ii.rom` (Multitech Microprofessor II monitor + Applesoft-clone BASIC) | SHA1 `92378b0db561632b58a9b36a85f8fb00796198bb`, CRC32 `8780189f` *(MAME driver pin; record SHA-256 after local intake)* | 16 384 | `mpf2.sh` | MAME `mpf2` clone ROM: in merged sets extract it from `tk2000.zip`; in split sets use `mpf2.zip`. Stage only the verified blob at `/data/assets-staging/mpf2/mpf_ii.rom`. Candidate sources: [MAME 0.224 merged](https://archive.org/details/MAME_0.224_ROMs_merged), [MAME 0.239 merged](https://archive.org/details/mame-0.239-roms-merged). | ROM copyright status is unclear. Private preservation exhibit only; never commit or publicly serve the ROM. |
| `zx81a.rom` (Sinclair ZX81 **second-revision** 8 KB ROM — Sinclair BASIC with floating point, the SLOW/FAST display driver and the character set; MAME `zx81` `-bios 2nd`) | `14ad84f4243efcd41587ff46ab932d11087043e8d455a1ed2a227b9657828dfa` *(locally measured 2026-08-09)*; SHA1 `7b143ee964e9ada89d1f9e88f0bd48d919184cfc`, CRC32 `4b1dd6eb` *(MAME 0.289 driver pin — matched against the shipped binary's own `-listxml`, not a filename)* | 8 192 | `zx81.sh` | Internet Archive item [`MAME_0.224_ROMs_merged`](https://archive.org/details/MAME_0.224_ROMs_merged), single-member extraction `https://archive.org/download/MAME_0.224_ROMs_merged/zx81.zip/zx81a.rom`; staged `/data/assets-staging/zx81/zx81a.rom` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | **Preservation source, and NOT covered by the Amstrad permission.** Amstrad's 1986 purchase of Sinclair's computer business took the Spectrum and QL rights; the ZX80/ZX81 ROM was written by and remains the copyright of **Nine Tiles Networks Ltd**, who have never issued the blanket emulation permission Amstrad gave for the Spectrum ROMs. Private preservation exhibit only: streamed as pixels, never committed, never served, no download affordance in the tile. `-bios 3rd` (`zx81b.rom`) could not be sourced and is not pursued. |
| `2.11BSD_rq.dsk.zip` (2.11BSD, UC Berkeley 1991 — Don North's prebuilt MSCP pack; unzipped `2.11BSD_rq.dsk` is 1 000 047 616 B, sha256 `2f100ee585f229fd55923e1d1c44108e72df96f649f28a31df35985e6a481805` **pristine**, before the tile's four in-guest site-config edits) | `94abeca02f001619e7aa2252cb2336ffe79af0cb3fb35cbd8c14240af3125a6b` *(locally measured 2026-08-09)* | 49 850 663 | `pdp11.sh` | [`ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip`](https://ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip); staged `/data/vms/streamhost/stations/pdp11/media/` | Predates the Net/2 split, so **NOT** covered by the Caldera 2002 Ancient-Unix letter, and the prebuilt image carries no licence statement. Preservation-source: stream-only pixels, never committed, never served, no download affordance. |
| `rtv53swre.tar.Z` (RT-11 V5.3 kit: `Disks/rtv53_rl.dsk` RL02 distribution pack + `Licenses/pdp11_license.txt`) | `9fdad10969f1f391b13d9d97aa8fc1aa8fcb44472dac363d23eb2d31500207bc` *(locally measured 2026-08-09)* | 1 373 083 | `decos.sh` | `http://simh.trailing-edge.com/kits/rtv53swre.tar.Z` — **origin host offline** (Cloudflare 520); retrieved through the Wayback raw form, snapshot `20020108101052`. Staged `/data/assets-staging/decos/` with adjacent `SHA256SUMS` | **Mentec hobbyist grant (1997-07-31): "use and copy … solely for personal, non-commercial uses in conjunction with the EMULATOR" — NOT distribute.** Private exhibit only; never committed, never served, no download affordance. Licence text itself is at `docs/guests/decos-mentec-license.txt` (a licence text is not licensed software). |
| `rsx11m42.zip` (RSX-11M **V4.2 BL38** TK50 kit: `m42kit.tap` + `build.txt`) | `c8766a53ae5b32c060560d5cea6302715c046322c80dbc234cc7e63ab2391ba1` *(locally measured 2026-08-09; re-fetched same day, byte-identical)* | 6 155 772 | `decos.sh` | [`bitsavers.org/bits/DEC/pdp11/rsx11m/rsx11m42.zip`](https://bitsavers.org/bits/DEC/pdp11/rsx11m/rsx11m42.zip) — live | Same Mentec grant. **V4.2, not the V4.3 ceiling** — no reachable copy of V4.3 exists anywhere (see `docs/guests/decos.md`). Do NOT substitute `rsx11m.com`'s `PiDP11_DU0.zip`: that is RSX-11M-**PLUS** V4.6, outside the grant. |
| **BBC Micro Model B ROM set** — five blobs staged at `/data/assets-staging/bbcmicro/`: `os12.rom` (Acorn MOS 1.20, SHA-1 `0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d`, sha256 `2d9fea69017864f6962704481829f95fee08446c8c3a13826d5d4e44000ac9de`, 16 384 B); `basic2.rom` (BBC BASIC II, SHA-1 `4a7393f3a45ea309f744441c16723e2ef447a281`, sha256 `45bd55dc0f6f0f8f1fe9e2481de7def206565eec8f600ba3068b849ca4132079`, 16 384 B); `phroma.bin` (TMS5220 speech PHROM, SHA-1 `b369809275cb67dfd8a749265e91adb2d2558ae6`, sha256 `8c093401661f530032c5aca8fd80d91af58e596d082a51be58ce2ee063a89308`, 16 384 B); `saa5050` (SAA5050 teletext character generator, SHA-1 `6c8daba70374e5aa3a6402f24cdc5f8677d58a0f`, sha256 `9706945b02dd0e30823186ff0d73a49c0d98ed573499a057bab471add7ee28fb`, 960 B); `dnfs120.rom` (Acorn DNFS 1.20, SHA-1 `7e3c536baeae84d6498a14e8405319e01ee78232`, sha256 `e745e34895225a6650b712c1dd0656cb0b0b15f072a8ae6d9ea8d1ac257eb3d6`, 16 384 B) | *(per-file sha256 in the left column — all five measured locally 2026-08-09)* | 66 496 total | `bbcmicro.sh` | **PRESERVATION-SOURCE, NO AUTHORISED URL.** No rights holder publishes these dumps and none authorises a mirror; the only routes that exist are bulk MAME romset dumps nobody was authorised to upload, so this manifest deliberately records **no** fetch URL. The builder does not download: it requires the operator's own staged blobs at `/data/assets-staging/bbcmicro/` and gates each on the SHA-1 above, then assembles `bbcb.zip` / `bbc_acorn8271.zip` / `saa5050.zip` itself. Note `saa5050` is a THIRD zip, in no BIOS set — MODE 7 has no glyphs without it and MAME refuses to start. | Acorn MOS and BBC BASIC are unlicensed for redistribution, and there is documented doubt that Acorn's successors hold clean assignment of the original MOS work — so there is no party who could grant one. Private preservation exhibit only: stream-only pixels, never committed, never served, no download affordance. |
| **ARM Evaluation System media** — four blobs staged at `/data/assets-staging/armeval/` ON TOP OF the bbcmicro set above (`os12.rom`, `basic2.rom`, `phroma.bin`, `saa5050` are the same files and the same hashes, staged again in this tile's own directory): `armeval_101.rom` (ARM Tube co-processor bootstrap, Executive v1.00 14th August 1986 — MAME `bbc_tube_arm` default BIOS `101`, SHA-1 `f86bbc4894e62725b8ef22d44e7f44d37c98ac14`, sha256 `d6ef843f82d7308f0ee68b4b30b4e6c6a561e753991f5634dbe6ae969b4204a7`, 16 384 B); `Acorn-ADFS-1.30.rom` (Acorn Advanced Disc Filing System 1.30, loaded by PATH into sideways socket 3 — `-rom3`; SHA-1 `301fd05c475a629c4bec70510d4507256a5b00d8`, sha256 `4f785bb4572bde31a93f12687dec501c9005b6a0decc6ac943c657447095a563`, 16 384 B); `dfs v2.23,acorn.rom` (Acorn DFS 2.23 — MAME `bbc_acorn1770` default BIOS `dfs223`, SHA-1 `0d7ed0b0b3852cb61970ada1993244f2896896aa`, sha256 `964c9ab33650b9429dd3eb513150b3110c607e0344f90d00ffaa546f982f66db`, 16 384 B); `armevaluationsystem-disc3.adl` (ARM Evaluation System Disc 3, "Utilities 2 / BASIC" — carries `$.AB`, ARM BBC Basic V 1.00; MAME softlist `bbc_flop_arm:armevals` part `flop3`, SHA-1 `f5114ff744f6f742da3959a91a1b98af0bd1db5d`, sha256 `c55f8a1c8abd2d1de4cb6afc4a96cbe72ed1446b39b1a3bbf06ef67698a29375`, 655 360 B) | *(per-file sha256 in the left column — all four measured locally 2026-08-09)* | 704 512 total | `armeval.sh` | **PRESERVATION-SOURCE, NO AUTHORISED URL, AND A DISPUTED CHAIN OF TITLE.** Same position as the BBC Micro set: no rights holder publishes these dumps and none authorises a mirror, so this manifest deliberately records **no** fetch URL. The builder does not download — it requires the operator's own staged blobs and gates each on the SHA-1 above, then assembles `bbcb.zip` / `saa5050.zip` / `bbc_tube_arm.zip` / `bbc_acorn1770.zip` BY SHA-1 against the shipped binary's own `-listxml` (the staged file is `phroma.bin`; the member MAME wants is `cm62024.bin`, and only the hash connects them). Note `bbc_acorn8271`/`dnfs120.rom` is NOT part of this tile: `-fdc acorn1770` replaces it, because the ADFS `.adl` discs are double density and the 8271 cannot read them. All SIX `armevals` discs were obtained and all six SHA-1s match MAME 0.289's `hash/bbc_flop_arm.xml`, so discs 4-6 (Cambridge LISP, PROLOG, FORTRAN 77) exist for a later exhibit; only disc 3 is staged and used here. | Acorn's ARM bootstrap, ADFS, DFS and the evaluation-system discs are all unlicensed for redistribution, and the chain of title through Acorn's successors is genuinely disputed — there is no party who could grant one. Private preservation exhibit only: stream-only pixels, never committed, never served, no download affordance. |
| `rsts_v9_6_install.zip` (RSTS/E V9.6 installation tape, TPC format, 11 850 records / 175 tape marks) | `aaf4aa978e13318fe304dfbf75e20090206e17caa5b76bab69bec2704d9c694f` *(locally measured 2026-08-09)* | 8 071 836 | `decos.sh` | `https://ftp.trailing-edge.com/pub/rsts_dists/rsts_v9_6_install.zip` — **origin host offline**; retrieved through the Wayback raw form. Staged `/data/assets-staging/decos/` | Same Mentec grant (V9.6 is exactly the recital's ceiling). **Do NOT substitute RSTS/E V10.1** — outside the grant. |
| `spectrum-roms_20081224-5_all.deb` (Debian **non-free** `spectrum-roms`; the tile uses only its `usr/share/spectrum-roms/48.rom`, which is byte-identical to MAME's `spectrum.rom`) | `.deb` `8d25dd300a0c86b4459e152de3bc657dca894b167e6a6419eb195d9669bfe950`; extracted `48.rom` sha256 `d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42`, sha1 `5ea7c2b824672e914525d1d5c419d71b84a426a2` *(all locally measured 2026-08-09; the sha1 is also MAME 0.251's and 0.276's pin for `-bios en`)* | 202 748 (`.deb`) / 16 384 (`48.rom`) | `zxspectrum.sh` | [`deb.debian.org/debian/pool/non-free/s/spectrum-roms/spectrum-roms_20081224-5_all.deb`](https://deb.debian.org/debian/pool/non-free/s/spectrum-roms/spectrum-roms_20081224-5_all.deb) — live; the builder fetches and verifies it into `/data/assets-staging/zxspectrum/` if absent | **freely-fetchable-pinned, and the cleanest permission in this table.** `usr/share/doc/spectrum-roms/copyright` inside the package quotes Cliff Lawson of Amstrad plc's 1999 posting verbatim: *"Amstrad are happy for emulator writers to include images of our copyrighted code as long as the (c)opyright messages are not altered"*, conditioned on nobody charging for the ROM code and on emulator (not hardware) use. Both hold here, and the first is honoured on screen: the exhibit's idle scene IS the unaltered `© 1982 Sinclair Research Ltd` line. Debian ships it in non-free because the terms restrict sale and no source exists — not because redistribution is barred. Still never committed: the repo records the URL and the hashes only. |
| `cpm.system.6228151676.d64` (Commodore **CP/M 3.0 / CP/M Plus** system disk for the C128 — the Z80 side of the machine) | `.gz` `6ed0da2d8a6fa74ae7b6e6cb67d78e1806a2a625ca839b4d93558c5ce7f44cb9`; decompressed `.d64` `69159226bf1996d8fc8c8921f094cd03955c7a8b9ecf800069d1c369dc6e5a1d` *(both locally measured 2026-08-09; the `.d64` re-verified 2026-08-10 on the host copy AND inside the live overlay — identical)* | 76 230 (`.gz`) / 174 848 (`.d64`) | `c128.sh` | [`zimmers.net/anonftp/pub/cbm/demodisks/c128/cpm.system.6228151676.d64.gz`](https://www.zimmers.net/anonftp/pub/cbm/demodisks/c128/cpm.system.6228151676.d64.gz) — a **single mirror**. Two copies exist on labhost: the builder's host cache `/data/vms/streamhost/stations/c128/media/{cpm.d64,cpm.d64.gz}` (the offline recovery path, now a `check-assets.sh` row) and the in-guest copy `/opt/bridge/media/c128/cpm.d64` inside the station overlay, attached by VICE `-8` (a VICE argument, not a QEMU device, so the checkpoint device set is unaffected). **Pending population into the shared media cache.** | **The one external file in the Commodore wave** — VICE bundles the C128 ROMs, including the CP/M Z80 BIOS, but not the CP/M system DISK. Commodore/DRI-era copyright, terms unclear. Private preservation exhibit only; never committed, never served, no download affordance in the station. |
| `ql-mame0224-merged.zip` (MAME `ql.zip` — the Sinclair QL romset; the tile uses only four of its 27 members) | `c4c39530c7abe6518f90b0df9d4eec9201434a905c77f05f490137007e420b03` *(locally measured 2026-08-09)* | 499 412 | `sinclairql.sh` | [`archive.org/download/MAME_0.224_ROMs_merged/ql.zip`](https://archive.org/download/MAME_0.224_ROMs_merged/ql.zip); staged `/data/assets-staging/sinclairql/ql-mame0224-merged.zip` with adjacent `MANIFEST.sha256` — **PRESENT + verified**. The builder re-assembles a four-member `ql.zip` **by SHA1** inside the guest — `ql.js 0000.ic33` `59fd4372771a630967ee102760f4652904d7d5fa`, `ql.js 8000.ic34` `b8c9203026a7de6a44bd0942ec9343e8b222cb41`, `ipc8049.ic24` `fcb1c97ee7c66e5b6d8fbb57c06fd2f6509f2e1b`, `bql010-sqpp` `ba94bdad2303a263008b6ea744669a19938d9998` — and verifies them against the shipped MAME's own `-listxml ql`. The QL's `hal16l8.ic38` PLD is `nodump` in every MAME set that has ever existed. | **Amstrad's Sinclair permission does NOT cover this.** That grant is read as covering the ZX Spectrum line and the machines Amstrad itself built; Amstrad acquired the QL rights and sold them on, and no published emulator permission for the QL ROM was found. Treat as preservation-source with unclear terms: private exhibit only, never committed, never served, no download affordance. |
| `d32.rom` (Dragon 32 monitor + Microsoft 16K Extended Color BASIC 1.0, the machine's whole 16 KB ROM) | `fc0e900bfec6b52f0f80ba1e65a4712808d2a411b5b00496639ef1a2152351f1` *(locally measured 2026-08-09; SHA1 `f2dab125673e653995a83bf6b793e3390ec7f65a` matches MAME's own pin for the `dragon32` driver, read back from `-listxml` on the shipped 0.289 binary)* | 16 384 | `dragon32.sh` | [`archive.org/download/MAME_0.224_ROMs_merged/dragon32.zip/d32.rom`](https://archive.org/download/MAME_0.224_ROMs_merged/dragon32.zip/d32.rom) — the single-member extraction form, 1.4 s instead of a merged set. Staged `/data/assets-staging/dragon32/d32.rom` with adjacent `MANIFEST.sha256`; the builder re-fetches and re-hashes if it is absent. **The rest of `dragon32.zip` is not needed and is not staged** — the tile runs with the `ext` slot emptied, so `ddos10.rom` (which `-verifyroms` demands) would only produce the wrong screen. | ROM copyright status is unclear: Dragon Data Ltd has been gone since 1984 and the BASIC lineage is Microsoft's. Preservation source. Private exhibit only; never committed, never served, no download affordance. |
| `DISC1-Install-and-CoreOS.iso` (HP **HP-UX 10.20** Install and Core OS, June 1996 press for Series 700 — the FIRST media tried for `hpuxvue`; its install kernel predates the B/C/J-class PCI SCSI and finds no disk on the emulated B160L, so it is superseded by the July-1997 ACE disc below but kept archived) | `91507d759a25f733ac85d93c3ace9dd87bed712f8b0a3b3054b8e4346bd494d1` *(locally measured 2026-08-18)*; md5 `9ea11531abba61524c8ad65b35aa81c2`, 435 286 016 | `hpuxvue` install (staged by hand under `/data/vms/streamhost/assets/hpuxvue/`, archived with `media_cache_put`) | [`archive.org/details/hpux-1020-iso`](https://archive.org/details/hpux-1020-iso) (mdf→iso conversion of item `hp-ux10.20forhp90007xx`) | **contested-commercial** (HPE still owns HP-UX). Private exhibit only: never committed, never served. |
| `DISC2-Applications.iso` (HP-UX 10.20 Applications, same set) | `f67252fc92e0e55d48c1357bc63c15939ccecb01993b5a2dc28a34c6ee9b9d6a` *(locally measured 2026-08-18)*; md5 `6eed25cf39502d65c854f3f2078d380f`, 647 979 008 | as above | as above | as above |
| `DISC3-Patches-2002.iso` (HP-UX 10.20 patch bundle, 2002, same set) | md5 `0801b7ba96d948c841e3f0f124f9c800` *(sha256 pending archive)*, 328 MB | as above | as above | as above |
| `HP-UX Release 10.20 Additional Core Enhancements July 1997 Series 700 B, C, & J Class B3782-10178.iso` (the bootable Install/Core OS disc for the B/C/J-class workstations — the machine `qemu-system-hppa -M B160L` emulates; carries the 53c8xx PCI SCSI driver the 1996 disc lacks) | md5 `5014f8327e015ca00243e26d49d43712` *(publisher; sha256 measured on archive)*, 453 MB | `hpuxvue` install (`assets/hpuxvue/disc1.iso`) | [`archive.org/details/hp-ux-release-10.20-additional-core-enhancements-july-1997-series-700-b-c-j-class-b-3782-10178`](https://archive.org/details/hp-ux-release-10.20-additional-core-enhancements-july-1997-series-700-b-c-j-class-b-3782-10178) | as above |
| `cd1.iso` from archive.org item `hpux_20200510` (HP-UX 10.20 Install and Core OS, a LATER press — `install/init $Revision: 10.3` — and **the disc that actually installs on `qemu-system-hppa -M B160L`**: its install kernel claims the emulated PCI 53c895a SCSI; the 1996 and July-1997 presses above do not) | md5 `54f0d43ce09d7e6c8450e59b9409c1c1` *(publisher, verified locally 2026-08-18)*, 508 MB | `hpuxvue` install (`assets/hpuxvue/disc1.iso`) | [`archive.org/details/hpux_20200510`](https://archive.org/details/hpux_20200510) — the item's `hpux.img` (a preinstalled disk) is deliberately NOT used | **contested-commercial.** Private exhibit only. |
| `800.ROM` (Macintosh **Quadra 800** ROM, 1 MiB — the whole machine ROM `qemu-system-m68k -M q800` needs as `-bios`) | `05ad753fb594e656cf078023ec189e09e2a7655a780de993b75b8c51ed6b09ca` *(locally measured 2026-08-16)*; md5 `69489153dde910a69d5ae6de5dd65323`, 1 048 576 | `scripts/build-guests/tiles/macos753.sh` (`media_cache_require`) | [`archive.org/download/800_20250604/800.ROM`](https://archive.org/download/800_20250604/800.ROM) — item "Macintosh Quadra 800 ROM". The same 1 MiB image also ships inside `mac_rom_archive_-_as_of_8-19-2011.zip`; the standalone item is used because it needs no 55 MB fetch to extract one member. | **preservation-source.** Apple Macintosh ROM, still Apple's copyright and never released for redistribution. Private exhibit only: never committed, never served, no download affordance. |
| `System753 691-1079-A.iso` (Apple **Mac OS 7.5.3** retail install CD, part number 691-1079-A, bootable 68k+PPC; delivered as `System753 691-1079-A.zip`) | `.zip` `b65d41bd44d9b5543e124f51aa9507749a834d5e06857dd441a203e50a9e19dc` *(locally measured 2026-08-16)*, 174 586 074; inner `.iso` 268 005 376 | `scripts/build-guests/tiles/macos753.sh` (`media_cache_require`) | [`archive.org/download/Macintosh-68K-PPC-System-7.5.3-Bootable-ISO`](https://archive.org/details/Macintosh-68K-PPC-System-7.5.3-Bootable-ISO). The retail `96073-016A` CD (`.toast`, 267 694 080, sha256 `ab3382fe10aa10f8c9068cf80ef86739bd11b7317a50be10c1faa02ce29e3b5d`) was fetched as a fallback and is held staged but unused. | **preservation-source.** Apple distributed System 7.5.3 free of charge and its own legacy-software archive carried it for years, but that was a free DOWNLOAD, not a redistribution grant. Treated like the ROM: private exhibit only, never committed, never served. |
| `basic11b.rom` (Oric Atmos **Extended BASIC V1.1**, the machine's whole ROM) | sha256 `ed28568574716eef5d7c0fde2568d7a47a6e4b1fbca81daff3be05e45723466d` *(locally measured 2026-08-09)*; SHA1 `9451a1a09d8f75944dbd6f91193fc360f1de80ac`, CRC32 `c3a92bef` *(MAME `orica` bios `ver11` pin, asserted at build time against the SHIPPED binary's own `-listxml`)* | 16 384 | `oricatmos.sh` | Extracted from `oric1.zip` (sha256 `9a9b227ea8f234ba99a9309fbddbf5506ae6333fbc357a5a3e8ab20f7f22b093`, 406 610 B), member `orica/basic11b.rom`, of the Internet Archive item [`MAME_0.224_ROMs_merged`](https://archive.org/details/MAME_0.224_ROMs_merged) — the item stores per-game zips at its root, so the builder fetches only that one 406 KB zip. **`orica` is a CLONE of `oric1`, so in a merged set its BIOS variants live in the PARENT's zip** under an `orica/` prefix. Staged `/data/assets-staging/oricatmos/basic11b.rom` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | Tangerine Computer Systems / Oric Products International are both long defunct and no rights-holder can be identified; copyright status unclear. Private preservation exhibit only — the ROM is never committed and never served, only executed. |
| `kc85_2.zip` (merged MAME romset for the KC 85 family from VEB Mikroelektronik Mühlhausen — 18 members covering `kc85_2`/`kc85_3`/`kc85_4`/`kc85_5`; `kc854.sh` extracts three of them **by SHA1**: `caos__c0.854` `774fc2496a59b77c7c392eb5aa46420e7722797e`, `caos__e0.854` `4300f7ff813c1fb2d5c928dbbf1c9e1fe52a9577` and the dump MAME calls `basic_c0.854` `c2e3af55c79e049e811607364f88c703b0285e2e`, which in this archive is stored under the name `kc85_3/basic_c0.853` — no member called `basic_c0.854` exists) | `ed5b8a567232beb89a5f78fea4066160aec2ba0f2a67555439c20785d6a096ab` *(locally measured 2026-08-09)* | 119 343 | `kc854.sh` | Internet Archive item [`MAME_0.224_ROMs_merged`](https://archive.org/details/MAME_0.224_ROMs_merged), file `kc85_2.zip` (merged set: the whole family lives in the parent's zip, so `kc85_4.zip` 404s). Staged `/data/assets-staging/kc854/kc85_2.zip` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | CAOS and HC-BASIC were published by VEB Mikroelektronik "Wilhelm Pieck" Mühlhausen, a state combine that was wound up with the GDR in 1990; there is no successor who could grant or withhold a licence, and the images circulate freely in preservation archives and ship in MAME's own hash files. Copyright status is therefore unclear rather than permissive. Private preservation exhibit only; never commit or publicly serve the ROMs. |
| `rhapsody_5.1_boot.img.gz` (Rhapsody 5.1 DR2 for Intel boot floppy, gzipped 1.44 MB raw image — the `rhapsody` tile) | `ed64360d77a2b7e46c522602d05285f66266391591e63279943083ca7f1ea411` *(locally measured; archive.org md5 `3ecf7b827aeacba44c57ab834d02d942`)* | 1 003 159 | `scripts/build-guests/tiles/rhapsody.sh` (media_cache_require) | Internet Archive item `rhapsody5.1`, `Rhapsody_5.1/`. Staged `/data/vms/sandbox/rhapsody/media/` — **PRESENT + verified** | Preservation-source (commercial Apple, no freeware re-release). Private exhibit only; never committed, never served, only executed. |
| `rhapsody_5.1_drivers.img.gz` (Rhapsody 5.1 DR2 Device Drivers floppy, gzipped) | `eb4c2c5b5b638b41b492b974ad00596f5089e461ab68c37697c144868ed342da` *(locally measured; md5 `001b684b921cd10b39f8463860f77985`)* | 454 392 | same | same item; staged alongside | same posture |
| `rhapsody_5.1_install_cd.img.gz` (Rhapsody 5.1 DR2 install CD, raw 630 116 352-byte image `RhapsodyDR2`, gzipped) | `c297391cbdfa3341e741a92c27fe8dbcb824acb4562dfeca03feb251f29c505b` *(locally measured; md5 `f3d7d0766abe320aa52e100a4cbca803`)* | 261 172 123 | same | same item; staged alongside | same posture |
| `tru64-os-5.1B.iso` (Tru64 UNIX 5.1B Operating System CD, ISO 9660 volume `V5.1Br2650_O1` — the base OS + CDE install media for the `tru64` tile) | `9d1cbf8c50d6d5d94a2790f52334a0967ee60aa939a08a71b723ecdaf780d96c` *(locally measured 2026-08-11)* | 676 808 704 | none yet (assets staged by hand for the dark-launched tile; see `docs/guests/tru64.md`) | Internet Archive item [`tru-64-unix-5.1-b`](https://archive.org/details/tru-64-unix-5.1-b), single-member extraction `Tru64 Unix 5.1B.zip/Tru64 Unix 5.1B/Tru64 UNIX 5.1B - Operating System.iso`; staged `/data/assets-staging/tru64/tru64-os-5.1B.iso` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | Contested-commercial: HPE holds the Tru64 UNIX copyrights and has never granted hobbyist redistribution (same posture class as the irix/solaris media). Private preservation exhibit only; the ISO is never committed and never served, only executed. |
| `beos-5.0.3-professional-gobe.bin` (BeOS R5 Professional 5.0.3 CD image, bin/cue, three MODE1/2352 tracks: track 1 bootable ISO 9660 `BeOS_Tools`, track 2 the raw BFS `BeOS 5 Pro Edition` system volume (325 MB) — the base OS media for the `beos` tile) | `1889fd6cf5af4259b01c9d1925e62f664effdf9dd88f924dc9b4da41ce1f0106` *(locally measured; SHA1 `a4bfd56ca3ada6b33ba74951bd10cce2589afaf3` also recorded)* | 772 302 720 | none yet (assets staged by hand for the dark-launched tile; see `docs/guests/beos.md`) | Internet Archive item `beos-5.0.3-professional-gobe`; the item's download redirector 500s, so fetched from the direct storage node named in the item's own metadata JSON (`server`/`dir` fields → `https://<server>/<dir>/<file>`). Staged `/data/assets-staging/beos/beos-5.0.3-professional-gobe.bin` with adjacent `MANIFEST.sha256` — **PRESENT + verified** | Preservation-source (Pro edition; PE was freeware). Private preservation exhibit only; the disc image is never committed and never served, only executed. |
| `beos-5.0.3-professional-gobe.cue` (cue sheet for the bin above) | `a57d9552cdadbbdbe6f608e8dbe9ac2bec2a010da1ad801fc0176e4d66bb234c` *(locally measured)* | 186 | none yet | Same Internet Archive item as the `.bin` above; staged alongside it | Same posture as the `.bin` above. |
| `sunos_4.1.4_install.iso` (Sun **SunOS 4.1.4** / Solaris 1.1.2 SPARC install CD, sun4/sun4c/sun4m/sun4d/sun4e — the media for the `sunos414` tile; **despite the name it is a raw 2352-byte/sector MODE1 BIN**, 160790 sectors with sync + MSF headers, which is why OpenBIOS finds no boot block on it as-is) | `6088d836cf582128cdd69661c4b62399fbd6f4db9b817188b2d1509cebbb5f48` *(locally measured 2026-08-18)*; md5 `9638a1e88711946f95cb171437ac37a3` | 378 178 080 | none yet (assets staged by hand for the dark-launched tile; see `docs/guests/sunos414.md`) | [`fsck.technology/software/Sun Microsystems/SunOS Install Media/SunOS 4.1.4 SPARC (CD)/`](https://fsck.technology/software/Sun%20Microsystems/SunOS%20Install%20Media/SunOS%204.1.4%20SPARC%20%28CD%29/); staged `/data/vms/sandbox/sunos414/media/` and `/data/vms/streamhost/assets/sunos414/`. The 2048-byte-sector conversion the station actually boots is `sunos414.iso` (329 297 920 B, sha256 recorded in the guest doc); its sector 0 is a valid Sun label ("CD-ROM Disc for SunOS Installation", magic `dabe`). | **contested-commercial** (Oracle holds the SunOS copyrights; no hobbyist redistribution grant). Private preservation exhibit only; the disc image is never committed and never served, only executed. |
| `nwf_672rb_mo.chd` (Sony **NEWS-OS 4.1R** "Version Up Kit" for the NWS-3000 series — the MO installation medium the `newsos` tile was installed from; MAME softlist `sony_news` item `nwf_672rb`, `supported="partial"`) | `cf0310c998e1e3c66a074c4ce026392e30a3e81cae72ce4e9e62f82f3b276853` *(locally measured 2026-08-18)*; md5 `be5b4c8fe82e988ed2ec1ddcd0dc3556` | 130 583 575 | none (installed on camera; see `docs/guests/newsos.md`) | Internet Archive item [`nwf_672rb`](https://archive.org/details/nwf_672rb); staged `/data/vms/sandbox/newsos/media/` | **contested-commercial** (Sony NEWS-OS; no redistribution grant). Private preservation exhibit only; never committed, never served, only executed. |
| `nwf_672rb_installation_program.img` (the kit's boot floppy — `bo fh()copy/i`; softlist floppy `install`, sha1 `ed9499211ccf133570defa136199f331a38368f5` matches MAME's) | `bad9eb0906023efd471212dfecc4597359f1ed04e3d4b2dfc6c4eb0b54f23795` *(locally measured 2026-08-18)* | 1 474 560 | none (as above) | same item, staged alongside | as above. |
| `nws3260.zip` (MAME romset `nws3260`: `mpu-16__ver.2.0a__1990_sony.ic64`, `051_aa.ic109`, `052_aa.ic110`, `idrom.bin` — all four sha1s match MAME 0.289's `-listxml`) | `ca39dadfd6af11230f0269c458074ece10015323a85e4d461c6fe3995d83cc02` *(locally measured 2026-08-18)*; md5 `ec8fe868944b6ec9c5fd4191c95d2383` | 615 741 | `build-mame-native.sh newsos` (`stage-romset.py` from `/data/assets-staging/newsos/`) | Internet Archive item `mame-0.250-roms-split_202212`, path `MAME 0.250 ROMs (split)/nws3260.zip` (identical bytes in `mame-roms-non-merged`) | Sony firmware dump; private exhibit only, never committed. |
| `hd1307.img.gz` (blank, pre-disklabelled 1.3 GB NEWS disk image — the installer's target; NEWS-OS 4.1R's own `format` floppy is unsupported by the driver) | `67e53491e2b519d3eb17d0877d4c2319bf0ebfe9b0b8b58d078cc22e4ca5663d` *(locally measured 2026-08-18)* | 5 207 927 (1 388 496 896 unpacked) | none | `briceonk/news-os` `src/news-inst/blank-images/hd1307.img.gz` (GitHub) | Empty labelled disk — no copyrighted content; kept only for reproducibility. |
| `newsos-disk.chd` (**the installed NEWS-OS 4.1R system disk** the `newsos` station boots — a read-only CHD master, MAME diff overlay per station; produced 2026-08-18 by the on-camera install, packages network/X11/NEWS Desk/sys/man/games/sound/sample/3D, `Xservers -a 1 -t 1`, `/fastboot` re-armed by `rc.local`) | `44446bca0c5106ea34a9e69f0e5cfb757ca11e363c112230dc22c5c4675d286c` *(locally measured 2026-08-18)* | 54 572 432 | produced by hand (see `docs/guests/newsos.md` install recipe) | `/data/vms/streamhost/assets/newsos/newsos-disk.chd` (chmod 444); raw pre-CHD copy `/data/vms/sandbox/newsos/media/newsos-installed-20260818.img` | derived from the contested-commercial media above; private exhibit only, never committed. |

| `AUX_3.0.1_Install.iso` (Apple **A/UX 3.0.1** install CD — Apple Partition Map with an HFS `A/UX CDInstall` volume (A/UX Startup, A/UX HD SC Setup, minimal System) and Unix slices: slice 0 = the live install-time root the CD kernel boots, **slice 6 = the pristine root+usr distribution the install copies**; NOT ROM-bootable as archived: zeroed HFS boot-block header and an empty Driver Descriptor Map) | `4b68cc40a68116949d3c5c6e66b781bc1455ffff6b85aefcb728528ea3f6b6c6` *(locally measured 2026-08-18)*; md5 `dd3edefa2095821878a8b6dee7dc7940` (publisher, matches Macintosh Garden's `AUX_3.0.1_Install.toast_image`), 426 254 336 | `aux` install (`assets/aux/AUX_3.0.1_Install.iso`, presented to the guest as a writable qcow2-overlay `scsi-hd`) | [`archive.org/details/apple-aux-3.0.1`](https://archive.org/details/apple-aux-3.0.1) (same bits as item `aux-3.0.1-install`) | **contested-commercial** (Apple; discontinued 1995, never released). Private exhibit only: never committed, never served. |
| `Bootdisk.img` (A/UX 3.0.1 **Installation Boot Disk**, DiskCopy 4.2 1440K — an "A/UX Installer Startup" System floppy; kept for provenance, unused: QEMU's q800 SWIM does not boot it and the CD's own HFS System serves instead) | `281d11a84575c7d02e9577d5b3d2aec76a22925d53bfb0b2e28fd741d64f30ef` *(locally measured 2026-08-18)*; md5 `34338bb68a25700fbdc21d25a99c6a51`, 1 474 644 | none (archived) | [`archive.org/details/apple-aux-3.0.1`](https://archive.org/details/apple-aux-3.0.1) | as above |
| `AUX_3.1_Update.iso` (Apple **A/UX 3.1 Update** CD, applied on top of 3.0.1 — 3.1.1 itself is archived nowhere reachable) | `fa0f2bb48b1ce603b6b8fb572e70e6f5ae80047fffdf87187d63dd9aba9baeb7` *(locally measured 2026-08-18)*; md5 `f7723b5613a80f3806f500cc23512a0a`, 19 748 864 | `aux` post-install (`assets/aux/AUX_3.1_Update.iso`) | [`archive.org/details/apple-aux-3.1-update`](https://archive.org/details/apple-aux-3.1-update) | as above |

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

### `indyr4400` — an asset DERIVED from another station's checkpoint, not downloaded

| Asset | sha256 | Bytes | Consumed by | Provenance | Class / terms |
|---|---|---|---|---|---|
| `irix65-r4400-disk.ext4` — a read-only ext4 image whose only content is `disk.raw`, the raw SGI disk carrying this lab's IRIX 6.5.22 install. Staged `/data/gallery-guests/IrisIndy/irix65-r4400-disk.ext4` (444 + immutable), 6500 MiB apparent / ~500 MiB allocated (sparse). The **container's** own hash is not reproducible (mkfs stamps a random UUID), so the hash recorded here is the INNER `disk.raw`. | inner `disk.raw`: `b8214c34a2983ce9f2b0781ef56a7a71971da2e3dbcb87cc7f1f990f822b1c61` *(locally measured 2026-08-10, verified equal on both sides of the wrap)* | inner `disk.raw`: 6 291 456 000 | `scripts/build-guests/tiles/indyr4400.sh`, staged + verified by `streamhost/stations/indyr4400/fetch-assets.sh` | **No external download.** Extracted with `chdman extracthd` from a **copy** of this lab's own `irix65-apps.chd` — the `irix` station's checkpoint, already recorded in this section. Iris's CHD backend rejects that uncompressed CHD (`InvalidFile`), which is why the raw form exists; the ext4 wrapper exists because Iris sizes a disk with `File::metadata().len()`, which is 0 for a block device, so the read-only asset drive has to present a regular FILE. | **preservation-source**, inheriting the `irix65-apps.chd` terms exactly — same bits, different container. **PUBLISH BLOCKER**: never committed and never publicly served. |

**Not an asset:** the `iris` emulator binary itself. It is built from source
(`github.com/techomancer/iris`, BSD-3, `main` @ `1e05210`, features
`lightning,rex-jit,chd`) in a throwaway bookworm chroot by the builder and
installed to `/data/gallery-guests/IrisIndy/iris-bookworm`. Nothing about it
is licence-encumbered; it is listed here only so the path is discoverable.


---

## 1. licensed — user-supplied, staged by hand

| file | sha256 | size | builder | expected staging path | env vars (names only) |
|------|--------|------|---------|----------------------|-----------------------|
| Solaris 10 U11 GA x86 DVD ISO (`sol-10-u11-ga-x86-dvd.iso`) | `e8b86de15de374f93d356a6cc4c73952a365294fe82aa0f278cd028054ad57ea` *(measured)* | 2 254 110 720 | `solaris-cde.sh` | `/data/gallery-guests/SolarisCDE/sol10.iso` — **PRESENT on labhost** | `SOL10_ISO`, `SOL10_ISO_URL` (Oracle OTN is SSO-gated; an archive.org mirror URL is the shipped fallback) |
| Windows XP Pro SP3 ISO (integrated-SP3 repack, label `GRTMPVOL_EN`, ≥500 MB) | n/a — **not on labhost any more** (consumed at build 2026-07-04, since deleted; no hash was recorded) | ~624 MB | `winxp.sh` | `/data/gallery-guests/WinXPpro/winxp-sp3.iso` (or `XP_ISO_LOCAL=`) — **MISSING: must be re-staged for any rebuild** | `XP_ISO_LOCAL`, `XP_ISO_URL`, `WINXP_PRODUCT_KEY` (**required**, volume-license key), `XP_ADMIN_PW` |
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
| OS/2 Warp 4 prebuilt `os2.qcow2` | sha256 `2b166b8d75912feb189945ee77480b2889f3c2554ca16fdf39e432e6656653bc` *(measured)* | 501 809 152 | `os2warp.sh` | `/data/gallery-guests/OS2Warp/os2.qcow2` — **PRESENT**, but **evolved in place**: it IS the live checkpoint lineage, not the pristine download | archive.org item `os2warp4_20240227`; IBM-copyrighted, used privately here |
| QNX 6.5.0 live ISO `QNX650Live.iso` | sha256 `e22a2a75b2f4ec4be4a933590fd2bf9c9d8b6466b7c0b3553521d6ef005e4077` *(pin, measured-match)* | 111 167 488 | `qnx.sh` | `/data/gallery-guests/QNX/QNX650Live.iso` — **PRESENT + verified** | archive.org item `qnx-650-live` |
| NeXTSTEP 3.3 for m68k, pre-installed disk `NS33_2GB.dd` | sha256 `6381423b066c33c24c9c9ec519086708b9cf3b2f11882fed5319cfb6a3422f1b` *(measured)*; enclosing `.7z` sha256 `6940df2a00cc9cc1f8849667deeb7d30c6fb4aced2e31d44d719df32db059b47`, 60 508 875 B | 2 012 774 400 (sparse, ~232 MB on disk) | `nextstep.sh` | nextstep kiosk guest `/opt/bridge/media/nextstep/NS33_2GB.dd` — **PRESENT in-guest** (inside the station overlay + its checkpoint; re-fetched by the builder) | archive.org item `nextstep-3.3-hd-image-with-previous.-7z`; NeXT/Apple-copyrighted, preservation class, RUN privately here, never re-distributed |
| NeXT ROM Rev 2.5 v66 `Rev_2.5_v66.BIN` | sha256 `1b753890b67095b73e104c939ddf62eca9e7d0aedde5108e3893b0ed9d8000a4` *(measured)* | 131 072 | `nextstep.sh` | nextstep kiosk guest `/opt/bridge/media/nextstep/Rev_2.5_v66.BIN` — **PRESENT in-guest**; taken from the Previous source tree (`src/Rev_2.5_v66.BIN`, SVN r1847), byte-identical to the archive.org copy | SourceForge `previous` SVN; NeXT/Apple-copyrighted, RUN privately here, never re-distributed |
| NeXTSTEP 3.3 **Intel** User ISO | none | ~356 MB | *(historical)* | **not staged** — the Intel route is a documented dead end (QEMU-10 SCSI/IDE I/O wall); the live tile is the m68k route above | archive.org item `NeXTSTEP33CISC` |
| Amiga Kickstart 1.3 ROM `kick13.rom` | md5 `82a21c1890cae844b3df741f2762d48d` *(pin, measured-match in-kiosk)* | 262 144 | `amiga.sh` (+ URL also in `bridge-base.sh`) | amiga kiosk guest `/opt/bridge/media/amiga/kick13.rom` — **PRESENT in-guest** (captured into the bridge overlay checkpoint; re-fetched by the builder) | archive.org item `commodore-amiga-firmware`; Amiga ROMs are Cloanto/Amiga-copyrighted |
| Workbench 1.3 boot ADF `workbench13.adf` | md5 `d10f4907697c4eafcf976b4ef6ea829b` *(pin, measured-match in-kiosk)* | 901 120 | `amiga.sh` | kiosk `/opt/bridge/media/amiga/workbench13.adf` — **PRESENT in-guest** | amigamuseum.emu-france.info mirror |
| Dwarf/Draco Mesa emulator `dist.zip` | sha256 `67f84b77cbed6cba9d7d2485e84b8142e4fd2403243f8abd8f6e5a81ff6fcf75` *(pin, measured-match in-kiosk)* | 509 198 | `daybreak.sh` | daybreak kiosk guest `/opt/bridge/media/daybreak/dist.zip` — **PRESENT in-guest** (unpacked into the station overlay + its checkpoint; re-fetched by the builder) | `github.com/devhawala/dwarf` — **URL pinned to commit `c264af5e37f89d7aa0eec968aa23818bf5a89837`, not to `master`** (changed 2026-08-10; both blobs re-fetched from that commit and re-hashed — byte-identical to the pins, so nothing has moved yet). A moving ref against a fixed hash is a *timer*, not a risk: the first upstream push makes the fetch succeed and the hash check fail, and the build then reports an integrity violation for what is really "upstream moved". **BSD-3-Clause, redistributable** — but the licence covers the emulator ONLY, not the Xerox disk below |
| Xerox ViewPoint 2.0.5 Pilot disk `vp2.0.5.zdisk` | sha256 `02bdb53ba7f7896a914fe43b7ca19a620907d0fdbf0f55317b7d1f39aab3f872` *(pin, measured-match in-kiosk)* | 4 657 062 | `daybreak.sh` | daybreak kiosk guest `/opt/bridge/media/daybreak/vp2.0.5.zdisk` — **PRESENT in-guest** | `github.com/devhawala/dwarf` `disks-6085/vp2.0.5.zdisk`, at the same pinned commit `c264af5e37f89d7aa0eec968aa23818bf5a89837` (see the row above for why `master` was wrong); **preservation-source** — Xerox-copyright ViewPoint/Pilot software rebuilt from the Bitsavers XDE 5.0 6085 disk plus the VP 2.0.5 floppy set. RUN privately here, streamed as pixels, never re-distributed and never given a download affordance. Its Software Options are unlocked but **bound to processor id `10-00-FE-31-AB-21`** — changing the emulated MAC re-locks every application |
| Xerox 8010 "Dandelion" rigid-disk pack `8010_hd_images.zip` | sha256 `d9fb11362229ba7b9dbb7500f2240f9c1e9cdaa9f37bb4431221174483ca438e` *(pin, measured-match in-kiosk)* | 14 020 559 | `star.sh` | star kiosk guest `/opt/star/8010_hd_images.zip` — **PRESENT in-guest** (unpacked into the station overlay + its checkpoint; re-fetched by the builder) | [`bitsavers.org/bits/Xerox/8010/8010_hd_images.zip`](https://bitsavers.org/bits/Xerox/8010/8010_hd_images.zip) — live. **preservation-source**: three Dandelion rigid-disk images (ViewPoint 2.0, XDE 5.0, Interlisp-D Harmony). Xerox never released ViewPoint or Pilot and there is no licence grant. RUN privately here, streamed as pixels, never re-distributed and never given a download affordance |
| Xerox ViewPoint 2.0 Pilot volume `ViewPoint-2.0-11-9-1990-18-38.img` | sha256 `a7ead97a18d748debd769e5d2358f05ece24f10a5421e9fbc73b598e4a7f7020` *(measured)* | 65 433 601 | `star.sh` | star kiosk guest `/opt/star/run/vp20.img` — **PRESENT in-guest**, extracted from the pack above and re-verified on every build | Same pack, same posture. Time-locked: the emulated TOD clock must read December 1997 (Xerox "Product Factoring"), option key `8 7T78 M8YL LFEQ` |
| Darkstar (Xerox 8010 emulator), commit `7ab55ff3d5c1802e7e69561a04b3e845ef92b53e` | *(git commit pin — no tarball)* | ~2 MB source | `star.sh` | BUILT from source in the star tile overlay (`mono-complete` + `nuget restore` + `xbuild`); no binary is fetched | [`github.com/livingcomputermuseum/Darkstar`](https://github.com/livingcomputermuseum/Darkstar); **BSD-2-Clause, redistributable** — but the licence covers Josh Dersch's emulator ONLY. The same repo also carries Xerox-copyright Dandelion IOP PROM dumps (`537P030xx.bin`) and CP microcode, which are **preservation-source** on the same footing as the disk above |
| GEOS 2.0 for C64 `.d64` | md5 `709bec31c3502cbcf5d4761c38dcfa9e` *(pin)* | ~170 KB | `bridge-base.sh` / `c64.sh` | c64 kiosk media dir (in-guest) | archive.org item `geos64_J1AD`; Berkeley Softworks. VICE itself bundles the C64 kernal/basic ROMs (fetched as VICE 3.x source from SourceForge) |
| Apple GEOS deskTop for the Apple //e — `GEOS-mouse supported by APPLEWIN.hdv.zip` and the `geos.hdv` ProDOS image it unpacks to (volume `/BIGWON`, file dated 2009-12-05) | `.zip` sha256 `64b7bef2440e2f0424586a893c641b566901403ad3ce6b3b5adaab573ae23e35`; `geos.hdv` sha256 `5aba89dda3450abf17b8cc05d9de98149abe0bb072e5b01cc29b7fff995fc681` *(both **locally measured 2026-08-10** on the live apple2 overlay — this row previously read "none")* | 599 723 (`.zip`) / 1 327 616 (`.hdv`) | `apple2.sh` | [`mirrors.apple2.org.za/…/other_os/gui/geos/`](https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/masters/other_os/gui/geos/) (Asimov mirror) — a **SINGLE mirror, and the only source this tile has**. The bits live only inside the tile overlay at `/opt/bridge/media/{geos.hdv,geos-mouse.hdv.zip}`; there is no host-side copy. **Pending population into the shared media cache.** linapple bundles the Apple //e ROM, so no ROM is fetched | **abandonware-URL.** Breadbox released Apple GEOS as freeware in 2003; this is the AppleWin-tailored (== LinApple) mouse build. Both sha256s are now **fatal gates** in `apple2.sh` — before 2026-08-10 the only validation was `file geos.hdv \| grep ProDOS`, which any ProDOS image passes, including a truncated or substituted one. The `file` assertion is kept as a *secondary* check: the hash says it is the right file, `file` says it is a sane one, and the two failures read differently. apple2 must be rebuilt for the trixie/`sdl12-compat` move, so an unpinned single mirror was the fleet's weakest link |
| RISC OS 5.30 IOMD ROM + HardDisc4 | none | ~4 MB + ~50 MB | `riscos.sh` | showcase-only tile (neko backend retired) — no live staging | riscosopen.org zipfiles; RISC OS Open licence (free download) |

**Atari ST needs NO TOS ROM** — `atarist.sh` boots EmuTOS (GPL,
`emutos-1024k-1.3` pinned via `bridge-base.sh`).

#### `atarist` — the five curated GEM application archives

All five are **sha256-gated fatally** in `atarist.sh` (a mismatch aborts the
build), and all five were **re-measured on labhost 2026-08-10** — every hash
matches its builder pin exactly. What was missing until then was the *declaration*:
they appeared in no manifest and had no `check-assets.sh` row, while living in
exactly one place — `/data/vms/streamhost/stations/atarist/assets/atarist-apps/`,
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

### `base-media` — the four blobs captured into the frozen bridge seed

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

### `win98se` — retronet ICQ client (stream D)

Not builder-driven yet — installed over the exec channel in retronet wave 2
(`docs/lab/retronet/POC-PLAN.md`, stream D), not baked by a `build-guests/tiles/`
script. Staged **only** in the content-addressed media archive (no
`/data/assets-staging/` copy):
`/data/media-archive/blobs/9d/9d5574cea30a8a0353d815555c59d589189b0fb98d9de63e74d908c16de3e11f`
(`media_cache_put`, see `scripts/build-guests/lib/media-cache.sh`).

| file | sha256 | size | source | class / terms |
|---|---|---|---|---|
| `icq2000b.exe` (ICQ 2000b, Mirabilis/AOL) | `9d5574cea30a8a0353d815555c59d589189b0fb98d9de63e74d908c16de3e11f` *(locally measured 2026-08-20; matches the file's own archive.org-recorded md5 `ae59de2259f3a109a6d66eb037da2335` and sha1 `4c916525f43d2a789a924cc81bf7b8bee7034645`)* | 5 331 244 | [`archive.org/details/icq2000b_202206`](https://archive.org/details/icq2000b_202206), file `icq2000b.exe` — the exact installer [Retro AIM Server's `CLIENT_ICQ.md`](https://github.com/mk6i/retro-aim-server/blob/main/docs/CLIENT_ICQ.md) links to for its own ICQ-2000b setup guide | **abandonware-URL.** Mirabilis/AOL-copyright, long-discontinued, no redistribution grant; hosted by a preservation archive. Chosen over the older ICQ 98a/99a/99b generation because those speak a *different, non-OSCAR* legacy protocol (UDP v3-v5 on port 4000 — a separate subsystem in Retro AIM Server, `ICQ_LEGACY_ENABLED`); ICQ 2000b is the first ICQ client to speak real OSCAR over TCP 5190 — the same port/protocol family the PoC's AIM support already rides ("one daemon, two nostalgia brands", `docs/lab/RETRONET-BRIEF.md` §5) and the exact port the PoC's network contract fixes (`docs/lab/retronet/POC-PLAN.md`: `10.99.0.2:5190`). iserverd is also an OSCAR-protocol reimplementation, so the same choice holds for the documented fallback. ICQ 2000b also keeps its contact list local to the client (2001+/2002+ store it server-side, and Retro AIM Server's own docs flag them as less reliable to set up). Private preservation exhibit only; never committed, never publicly served — installed into the win98se guest only. |

### `ICQ 2001b` — retronet ICQ SSI client for the Windows fleet (media-only, upgrade path)

Sourced for the Windows leg of `docs/lab/retronet/ICQ-ONBOARDING-PLAN.md`:
every Windows ICQ station (win98se, win2000, nt4, win95) runs ICQ 2000b today,
whose contact list is **client-local** (the row above) — a golden rebuild or
`labctl reset` shows an empty list until the contact seeder re-drives the
client's own Add-Contact UI. ICQ 2001b is the first ICQ generation with a
**server-stored (SSI) contact list**: a client that signs in against the
gateway populates its list from the server on login, no per-station seeding
needed. Not builder-driven and not installed on any station yet — this row is
media-sourcing only, same status as the `macos753` and `climm` rows below; the
actual client swap is separate future work. Staged **only** in the
content-addressed media archive (no `/data/assets-staging/` copy):
`/data/media-archive/blobs/34/3436e607cc2dfde7021f6f50d1f8f20e9da88dcb846d50fa9b88eecb9fa6d511`
(`media_cache_put`, see `scripts/build-guests/lib/media-cache.sh`).

| file | sha256 | size | source | class / terms |
|---|---|---|---|---|
| `ICQ2001b.exe` (ICQ 2001b build 3659, ICQ Ltd./AOL) | `3436e607cc2dfde7021f6f50d1f8f20e9da88dcb846d50fa9b88eecb9fa6d511` *(locally measured 2026-08-21, cross-checked from two independent fetches — CT950 and labhost, byte-identical; matches the file's own archive.org-recorded md5 `0867033819dc7c5293e33344560070d2` and sha1 `01ecd76e1664240b6db8fd662a687fcb82be32f1`)* | 4 312 600 | [`archive.org/details/icq-2001b`](https://archive.org/details/icq-2001b) (identifier `icq-2001b`, uploaded 2022-06-07, curator note "checked for malware"), file `ICQ2001b.exe` | **abandonware-URL.** ICQ Ltd./AOL-copyright, long-discontinued, no redistribution grant; hosted by a preservation archive — same private-collection stance as every row in this section. Private preservation exhibit only; never committed, never publicly served. |

**Why ICQ 2001b, and why over ICQ 2002a and Miranda IM.** The requirement
(`docs/lab/retronet/ICQ-ONBOARDING-PLAN.md`) is a Windows OSCAR client with a
genuinely server-stored contact list, not a client-local one that merely looks
server-driven:

- **First-party confirmation against the exact gateway software this fleet
  runs.** [Open OSCAR Server's own `CLIENT_ICQ.md`](https://github.com/mk6i/open-oscar-server/blob/main/docs/CLIENT_ICQ.md)
  (the renamed `retro-aim-server`, the doc the win98se row above cites for ICQ
  2000b) gives **ICQ 2001 & 2002** a dedicated, tested setup guide and says
  outright: "Unlike ICQ 2000b, these clients store your contact list on the
  server rather than locally on the client." That is the SSI/feedbag
  behaviour confirmed by the server maintainers' own hand, not inferred from
  version-history trivia. The same doc flags ICQ 2001/2002 as unreliable
  under WINE ("do not run reliably under WINE — use native Windows") — a
  non-issue here since every station in this fleet is a real Windows guest
  under QEMU, never WINE; if anything it rules out an approach we were never
  taking.
- **2001b over 2002a: provenance, not protocol.** `CLIENT_ICQ.md` links both
  as equally valid (`oldversion.com` for each), so the choice came down to
  sourcing quality. ICQ 2001b has a clean, single-purpose archive.org item
  (`icq-2001b`, uploaded 2022-06-07 — the same date/batch as this file's
  `icq2000b_202206` neighbour above) with a curator note "checked for
  malware" and md5/sha1 recorded in the item's own metadata, which the
  locally measured hash matches exactly. ICQ 2002a has **no equivalent
  standalone archive.org item** — `archive.org/metadata/icq-2002a` returns
  empty, and an advanced-search title query finds it only bundled inside
  multi-title CD-ROM/magazine cover-disc collections (a Czech PC World disc,
  a PC Brasil freeware disc) — messier provenance to pin and verify than a
  dedicated, curated single-file item. ICQ 2001b is also the version that
  *introduced* SSI (contemporary sources: "from the release of ICQ 2001b, the
  Contact List is saved on the ICQ servers"), making it the earlier-tested,
  more conservative choice, and its November-2001 release sits
  contemporaneously with the win98se/win2000/nt4 fleet's own era rather than
  a year further out.
- **Windows 9x/NT/2000 compatibility confirmed independently of the archive
  listing.** Cross-referenced compatibility listings show ICQ 2001b running
  on Windows 95, 98, ME, NT 4.0, 2000 and XP — one client covers every
  station in this fleet (win95, win98se, nt4, win2000).
- **Genuinely the file, not a mislabeled repack.** The fetched installer's
  own embedded string self-identifies: `ICQ Installation (Ver 2001b Build
  3659)` — extracted with `strings` from the downloaded PE, not taken on the
  archive listing's word alone.
- **Miranda IM — considered, not chosen.** Miranda IM's ICQ protocol plugin
  is genuinely SSI-based, and Miranda shipped both an ANSI build (Win95/98/
  ME) and a Unicode build (NT4/2000/XP/2003) from 0.5 onward, so broad Win9x/
  NT coverage is plausible. Two things tipped the decision to ICQ 2001b
  instead: (1) Open OSCAR Server's own client docs don't mention Miranda at
  all — there is no first-party "this works against our server" the way
  there is for ICQ 2001/2002, only general corroboration that its ICQ plugin
  loads a server-side list; (2) pinning the *specific* early Miranda release
  that both still runs on Win95/98 (pre-Unicode-only NG-fork era) and has a
  working SSI-capable ICQ plugin would need the kind of source-level dig this
  manifest did for climm (`oscar_base.c`, compiled-in `login.icq.com:5190`,
  below) — worthwhile when climm was the *only* Unix OSCAR candidate with no
  ICQ-branded alternative, but out of proportion here when a genuine,
  first-party-documented ICQ client already satisfies the requirement
  cleanly. Kept as a fallback if ICQ 2001b proves unreliable on any of the
  four Windows stations at bring-up time.

Not yet run against the gateway or installed into any station — that is the
station bring-up wave's job, same caveat as the `climm` rows below.

### `macos753` — retronet AIM client media (Tier D, media-only so far)

Not builder-driven yet — **networking itself doesn't exist on this station
today** (`docs/guests/macos753.md`: "Network: none, deliberately"), so client
install is blocked on a device-set change (NIC add → cold rebuild) that is
separate future work (`docs/lab/retronet/ICQ-ONBOARDING-PLAN.md`, macos753 is
Tier D — hardest). This row is media-sourcing only. Staged **only** in the
content-addressed media archive (no `/data/assets-staging/` copy):
`/data/media-archive/blobs/96/965f5c9c4f6d796e1c3f347fc5ec05693b9aa27848679bda98f2cb3fc4f71cec`
(`media_cache_put`, see `scripts/build-guests/lib/media-cache.sh`).

| file | sha256 | size | source | class / terms |
|---|---|---|---|---|
| `AIM_installer_2.01.617.sit` (AOL Instant Messenger 2.01.617, 1999, StuffIt archive of an Installer VISE package) | `965f5c9c4f6d796e1c3f347fc5ec05693b9aa27848679bda98f2cb3fc4f71cec` *(locally measured 2026-08-20; matches the file's own site-published sha1 `15134f371105475fa4f9f8b6c8e0f80fc73cd9a7`)* | 2 538 648 | [`macintoshrepository.org/1213-aol-instant-messenger-2-x-68k-`](https://www.macintoshrepository.org/1213-aol-instant-messenger-2-x-68k-), file `AIM_installer_2.01.617.sit` (download id 10986) — a vintage-Mac preservation mirror (the WinWorld/archive.org equivalent for classic Mac abandonware) | **abandonware-URL.** AOL-copyright, long-discontinued, no redistribution grant. Chosen over any ICQ-branded Mac client: AIM has spoken OSCAR since its May-1997 launch (OSCAR was literally AIM's internal project codename before it became the wire protocol's name), so every AIM generation — including this, its **last 68K-compatible build** — is a genuine period OSCAR client; Mac ICQ, by contrast, topped out at 68K version 1.7.2 (Macintosh Garden's own version table) and every Mac ICQ build after it (2.0b onward) is PowerPC-only, postdating ICQ's own industry-wide OSCAR migration (~1999–2000) — no 68k-and-OSCAR ICQ-for-Mac build was found and one may not exist. **68K-native and System-7.5-aware by the installer's own hand**: `unar`-extracted, the `InstallAIM` binary's data fork contains the literal string *"The Thead [sic] Manager extension is required to run AIM. It is built into all MacOS computers running system 7.5 or later"* — satisfied by this station's System 7.5.3 with no extra extension; internal CPU-family tags confirm `68K Only` / `68020`/`68030`/`68040` (matches the Quadra 800's 68040). Private preservation exhibit only; never committed, never publicly served — install is blocked on the NIC-add device-set change above. |

### `climm` (formerly micq) — retronet ICQ/OSCAR client for Unix (solaris + tru64, stream C)

Not builder-driven — sourced for the two Tier-C Unix stations in
`docs/lab/retronet/ICQ-ONBOARDING-PLAN.md` (solaris x86/CDE, tru64/Alpha).
Staged **only** in the content-addressed media archive (no
`/data/assets-staging/` copy):
`/data/media-archive/blobs/c8/c87f17bf52e1b2b29b840ba7994762609d75acd89857560209915d7584d8587b`
(`media_cache_put`).

| file | sha256 | size | source | class / terms |
|---|---|---|---|---|
| `climm-0.6.4.tgz` (climm, formerly micq/mICQ) | `c87f17bf52e1b2b29b840ba7994762609d75acd89857560209915d7584d8587b` *(locally measured 2026-08-20)* | 1 209 914 | [SourceForge `climm` project](https://sourceforge.net/projects/climm/files/climm/climm-0.6.4/climm-0.6.4.tgz/download), file `climm-0.6.4.tgz` (2009-02-22 release; GitHub mirror `github.com/tadu/climm` cross-checked as the same lineage but ships no pre-generated `configure` — the SourceForge tarball is the one to build from) | **freely-fetchable-pinned.** GPLv2 (BSD-ish for the pre-0.4.9 Matt D. Smith code, all v8/OSCAR code GPLv2, `COPYING` carries an explicit OpenSSL-linking exception since 0.4.12) — genuinely open, unlike this subsection's neighbours above. "No-one from the climm project is in any way affiliated with Mirabilis or AOL" (`COPYING`). |

**Why climm over centericq/licq.** All three are OSCAR-capable per
`ICQ-ONBOARDING-PLAN.md`'s candidate list; climm won on buildability, not
just protocol support:

- **OSCAR confirmed at the source level, not just by reputation** —
  `src/oscar_base.c`, `oscar_bos.c` (the BOS redirect `GATEWAY.md`'s "two
  doors" section describes), `oscar_snac.c`/`oscar_tlv.c`, `oscar_register.c`,
  `oscar_contact.c` are all present, and the compiled-in default is literally
  `login.icq.com:5190` (`src/oscar_base.c`, `src/file_util.c`) — the real
  OSCAR port, matching the gateway's `10.99.0.2:5190` door exactly. README:
  "login with both the old v6 and the new v8 protocol" (v8 = OSCAR).
- **Zero hard dependencies beyond libc sockets.** `configure.ac` has exactly
  two `AC_CHECK_LIB` calls (`nsl`/`inet_ntoa`, `socket`/`getpeername` — the
  standard SysV-vs-BSD sockets split, present on Solaris and gracefully
  skipped where already in libc). No ncurses, no Qt, no OpenSSL requirement:
  SSL, Tcl scripting, OTR and peer-to-peer are all `--disable-*` opt-outs, and
  XMPP/MSN (the only two `.cpp` files in the tree, `jabber_base.cpp`/
  `msn_base.cpp`) are opt-**in** (`--enable-xmpp`/`--enable-msn`, both off by
  default) — a default build never touches a C++ compiler, `AC_PROG_CXX` in
  `configure.ac` notwithstanding (a harmless unconditional probe).
- **Ships a pre-generated `./configure` + `Makefile.in`** (`config.guess`,
  `config.sub`, `install-sh`, `depcomp`, `missing` all present in the
  tarball) — no autoconf/automake bootstrap needed on either target, which
  matters because neither box ships a modern autotools. Contrast the GitHub
  mirror (`tadu/climm`), a raw tree needing `autoconf 2.59+`/`automake 1.9+`
  and a `build-aux/prepare` bootstrap — kept only as a provenance cross-check,
  not the staged artifact.
- **centericq** (last release 4.21.0, 2005, only ever packaged through Debian
  etch) pulls in its own `libicq2000` OSCAR implementation plus ncurses,
  OpenSSL and (for some features) gpgme/jpeg — a heavier C++ build with more
  points of failure on a vendor compiler. **licq** (SourceForge, 1.0.x-1.3.x
  era) is C++ throughout with a `dlopen`-based plugin loader, and its only
  graphical UI is Qt — there never was a native Motif plugin, so "graphical
  licq under CDE" would mean building Qt3/Qt4 from source first, not just
  Licq itself, out of proportion to this errand. Both remain viable fallbacks
  if climm's build stalls on either box, but were not sourced here.

**Solaris 10 x86 build strategy — CONFIRMED buildable, gcc already on the
box.** `labctl exec solaris` (read-only, 2026-08-20): `/usr/sfw/bin/gcc` is
GCC 3.4.3 for `i386-pc-solaris2.10`
(`/usr/sfw/bin/i386-pc-solaris2.10-gcc-3.4.3`), and the full binutils set
(`as`, `ld`, `ar`, `make`, `m4`, `yacc`, `lex`) is present under
`/usr/ccs/bin` — the station's GA DVD install already carries the `SFWgcc`
cluster, so **no Companion CD is needed**. Recipe:
`PATH=/usr/sfw/bin:/usr/ccs/bin:$PATH ./configure --disable-ssl --disable-tcl
--disable-otr --disable-peer2peer && make`. Not yet run on the guest — that
is the station-bring-up wave's first checkpoint, not this errand's.

**Tru64/Alpha build strategy — feasible, not a blocker, on the strength of a
real precedent.** `tru64` has no `gcc`; its native `/usr/bin/cc` is
**Compaq C V6.5-011** (`cc -V`, 2026-08-20). That compiler has *already*
built one substantial autoconf-based C project on this exact guest — Lynx
2.8.9rel.1 (`/usr/local/bin/lynx`, `docs/guests/tru64.md` "The browser"
section), which needed only `CONFIG_SHELL=/bin/ksh` (Tru64's default
`/bin/sh` is the legacy Bourne shell and chokes on modern `configure`
scripts) and ran its ~35 min `configure` + ~45 min `make` on the emulated
Alpha without incident. climm is architecturally simpler than Lynx (no
terminal/curses handling, no HTML parser, no SSL requirement once
`--disable-ssl` is passed) and needs the same one shell workaround.
**Verdict: NOT a hard blocker.** The station already has `cc`, X11 dev
headers (`libX11`/`libXtst`, used to build `xptr`), and a network path out
(the `dec21143` NIC added 2026-08-17). This reverses the onboarding plan's
framing of tru64 as "Alpha client sourcing is the friction": the friction was
never sourcing a *binary* — none exists for Alpha/Tru64 regardless of
client, see below — it is building from source, and this station has already
proven that path works for software of comparable or greater complexity.
Recipe: `CONFIG_SHELL=/bin/ksh /bin/ksh ./configure --disable-ssl
--disable-tcl --disable-otr --disable-peer2peer && make`. Also not yet run —
same caveat as solaris above.

**No prebuilt binary exists for either target.** The SourceForge release
carries `.src.rpm`/`.i486.rpm`/`_i386.deb` (Linux x86) and an
`-AmigaOS.tgz` — nothing for SPARC/x86 Solaris or Alpha/Tru64 was ever built
by anyone. Source-only is not a fallback here, it is the only option, and it
is a good one given the above.

## 3. freely-fetchable-pinned — open upstreams

| file | pin | builder | staging path (labhost state) |
|------|-----|---------|--------------------------|
| FreeDOS 1.3 FullUSB + choice/ctmouse pkgs | official ibiblio URLs (unpinned hashes) | `freedos.sh` | `.build-work/dl` cache |
| 9front `9front-11554.amd64.qcow2.gz` | release 11554 | `9front.sh` | `/data/gallery-guests/9front/` |
| Haiku R1/beta5 anyboot ISO x86_64 | sha256 `22ae312a38e98083718b6984186e753d15806bd6ea44542144fdcef42c4dcb69` *(pin, measured-match)*, 1 477 246 976 | `haiku.sh` | `/data/gallery-guests/Haiku/haiku.iso` — **PRESENT + verified** |
| HelenOS 0.14.1 ia32 ISO | version-pinned; measured `1b15da0459cbfe28a6d3058675c2c20a4b03584cfb4d034c0ccb17b521791ccb`, 25 792 512 | `helenos.sh` | `…/HelenOS/` — PRESENT |
| KolibriOS `latest-iso.7z` | **moving** “latest” URL; measured iso `dc3e3726f2495df7eef93e89bd2362c693afcaa7e466cd837607fbe8a60a18a0`, 99 358 720 | `kolibrios.sh` | `…/KolibriOS/kolibri.iso` — PRESENT |
| ReactOS 0.4.14 live zip | build `0.4.14-release-125-g5b02d38`; measured iso `9b39db9d930c919060379c8b3f1406d5cc8821e019fc3ccecf6e2dce9d1d0c7e`, 263 192 576 | `reactos.sh` | `…/ReactOS/ReactOS.iso` — PRESENT |
| ToaruOS v2.3.2 `image.iso` | sha256 `b1dc51bd48f2b4613237185c9acb1a9beb13ab6acdd2e01d9722f77343e4c9ea` *(pin)*; labhost copy measures `fda58cd13612…` (**modified in place by the games bake** — expected) | `toaruos.sh` | `…/toaruos/image.iso` |
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

## 5. gaps found (could NOT be located on labhost)

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
  showcase-only UI exhibit; VM 900 was deleted 2026-07-08.

## Env vars referenced by builders (names only — values live outside git)

`WINXP_PRODUCT_KEY`, `XP_ISO_LOCAL`, `XP_ISO_URL`, `XP_ADMIN_PW`,
`SOL10_ISO`, `SOL10_ISO_URL`, `SFOS_VDI`, `SFOS_EMULATOR_URL`,
`SFOS_SKIP_DOWNLOAD`, `BASE_SHA256` (win311), `WOLF3D_URL`, `NETSCAPE_URL`,
`VBE_ZIP_URL`, `VBE9X_URL`, `GALLERY_ROOT`/`GUESTS_ROOT`, per-builder
`ISO_URL`/`SRC_URL` overrides.
