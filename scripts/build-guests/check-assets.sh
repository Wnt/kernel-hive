#!/usr/bin/env bash
# check-assets.sh — preflight for the build-guests external inputs.
# Verifies presence (+ sha256/md5 where pinned) of every REQUIRED staged asset
# and required env var, and reports the fetched-at-build inputs informationally.
# Companion of docs/lab/ASSETS-MANIFEST.md (keep the two in sync).
#
#   check-assets.sh                 # check everything (full-fleet rebuild view)
#   check-assets.sh --only winxp --only solaris-cde
#   check-assets.sh --root /data/assets-staging --class licensed --class abandonware-URL
#   check-assets.sh --quiet        # only failures + summary
#   build-all.sh --check-assets    # same, wired as a preflight
#
# Exit: 0 = all REQUIRED assets present/verified; 1 = something missing/mismatched.
set -u

GALLERY_ROOT="${GALLERY_ROOT:-/data/gallery-guests}"
ASSET_STAGING="${ASSET_STAGING:-/data/assets-staging}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ASSETS="$SCRIPT_DIR/assets"

QUIET=0
ONLY=()
CLASSES=()
while [ $# -gt 0 ]; do case "$1" in
  --root)
    [ $# -ge 2 ] || {
      echo "--root requires a directory" >&2
      exit 2
    }
    GALLERY_ROOT="$2"
    shift 2
    ;;
  --root=*)
    GALLERY_ROOT="${1#*=}"
    shift
    ;;
  --class)
    [ $# -ge 2 ] || {
      echo "--class requires a name" >&2
      exit 2
    }
    CLASSES+=("$2")
    shift 2
    ;;
  --class=*)
    CLASSES+=("${1#*=}")
    shift
    ;;
  --only)
    [ $# -ge 2 ] || {
      echo "--only requires a builder" >&2
      exit 2
    }
    ONLY+=("$2")
    shift 2
    ;;
  --only=*)
    ONLY+=("${1#*=}")
    shift
    ;;
  --quiet | -q)
    QUIET=1
    shift
    ;;
  -h | --help)
    sed -n '2,13p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 2
    ;;
esac done

# ---- table ------------------------------------------------------------------
# TYPE|BUILDER|LABEL|PATH-or-ENVNAME|ALGO:HASH (optional)|CLASS
#   req-file : REQUIRED staged file (missing/mismatch => failure)
#   req-env  : REQUIRED env var (unset/empty => failure)
#   repo     : repo-tracked asset (missing/mismatch => failure — repo corruption)
#   opt-file : fetched-at-build cache; verified IF present, else "will fetch"
ROWS=(
  # -- licensed: user-supplied media -------------------------------------------
  "req-file|solaris-cde|Solaris 10 U11 x86 DVD ISO|$GALLERY_ROOT/SolarisCDE/sol10.iso|sha256:e8b86de15de374f93d356a6cc4c73952a365294fe82aa0f278cd028054ad57ea|licensed"
  "req-file|winxp|Windows XP SP3 ISO (GRTMPVOL_EN repack; or set XP_ISO_LOCAL)|${XP_ISO_LOCAL:-$GALLERY_ROOT/WinXPpro/winxp-sp3.iso}||licensed"
  "req-env|winxp|XP volume-license key|WINXP_PRODUCT_KEY||licensed"
  "req-file|msdos-win1|Genuine Windows 1.01 SETUP result (Win 2.03 MOUSE.DRV + SETVER)|$GALLERY_ROOT/MSDOSWin1/.build-work/dl/disk_install2.qcow2|sha256:cf7a75f0d61223ad594e33b6c55b7f457a1880f67f2c5699634440aa2a18071e|licensed"
  "req-file|sailfishos|Sailfish SDK emulator VDI (set SFOS_VDI)|${SFOS_VDI:-$GALLERY_ROOT/SailfishOS/emulator.vdi}||licensed"
  # -- VSI Community: account/application-gated private lab media -------------
  "req-file|openvms|OpenVMS x86-64 2026 Community Package|$GALLERY_ROOT/OpenVMS/community_2026.zip|sha256:ceae51ded68e96861e7211b30ef837e8d101eb5d3a3ddb78c13d5d7619ddfb83|VSI Community"
  # -- preservation-source media (private lab intake; never committed) --------
  "req-file|redstar3|Red Star OS 3.0 Desktop install ISO|$ASSET_STAGING/redstar3/redstar_desktop3.0_sign.iso|sha256:895ad0e01ae0d35a65e9ac42dd34d0a1d685d6dfa331ce5b4f24bbc753439be3|preservation-source"
  "req-file|redstar2|Red Star OS 2.0 desktop install ISO|$ASSET_STAGING/redstar2/redstar.iso|sha256:69a45d07c302782cb777d03abd39c5b45b4099e5c994a74a77bb71ab5d229997|preservation-source"
  # chokanji: the whole 超漢字/B-right/V media set (archive.org 'chokanji'); the builder
  # pulls it via media_cache_require and repacks qemuckj/mc.img -> chokanji.qcow2.
  # Stored content-addressed in the media archive; opt-file => fetched at build if absent.
  "opt-file|chokanji|超漢字/Chokanji-V + B-right/V + QEMU-CKJ media set (archive.org 'chokanji'; qemuckj/mc.img = pre-installed B-right/V)|${MEDIA_ARCHIVE_ROOT:-/data/media-archive}/blobs/b8/b8fd99a928d5564e53b58d2b8853b05f799a3fc32ba09cee0714a66c675039df|sha256:b8fd99a928d5564e53b58d2b8853b05f799a3fc32ba09cee0714a66c675039df|preservation-source"
  "req-file|mpf2|Multitech MPF-II Monitor + BASIC ROM|$ASSET_STAGING/mpf2/mpf_ii.rom|sha1:92378b0db561632b58a9b36a85f8fb00796198bb|preservation-source"
  # -- freely fetchable, pinned (the builder fetches + verifies if absent) -------
  # Debian non-free spectrum-roms; its usr/share/doc/spectrum-roms/copyright carries
  # Amstrad's 1999 emulator permission. zxspectrum.sh extracts 48.rom from it.
  "opt-file|zxspectrum|Sinclair ZX Spectrum 48K ROM, in Debian's spectrum-roms package (fetched by zxspectrum.sh from deb.debian.org if absent)|$ASSET_STAGING/zxspectrum/spectrum-roms_20081224-5_all.deb|sha256:8d25dd300a0c86b4459e152de3bc657dca894b167e6a6419eb195d9669bfe950|freely-fetchable-pinned"
  "opt-file|ubuntu|Ubuntu 4.10 Warty Warthog live CD ISO (fetched by ubuntu.sh from old-releases.ubuntu.com if absent)|$ASSET_STAGING/ubuntu/warty-release-live-i386.iso|sha256:189746859b539c37d978b107589610aa49a7415f7c089d22667867a918591013|freely-fetchable-pinned"
  # -- repo-tracked assets ------------------------------------------------------
  # NOTE: cosmo.zip/jill.zip/Winamp tarball are no longer shipped in the repo
  # (removed pre-publication, see docs/guests/freedos.md + docs/guests/winxp.md).
  # cosmo/jill are fetched from archive.org by freedos.sh if no local copy is
  # staged at this path; Winamp has no fetch source and must be staged by hand.
  "opt-file|freedos|Cosmo zip (fetched from archive.org; contains REGISTERED eps 2-3, ep.1 only is staged into the guest)|$ASSETS/freedos/cosmo.zip|sha256:d7197b6b86170c808714e591faa29b028b7ad13bf45c34d66425934c0c5245f8|not-redistributed"
  "opt-file|freedos|Jill of the Jungle zip (fetched from archive.org)|$ASSETS/freedos/jill.zip|sha256:ab09c4674f7c43e3ea80b9e22b250da442f471c3877e5d5410c9ba6c1366f837|not-redistributed"
  "opt-file|winxp|Winamp 2.95 installed tree (OPTIONAL, operator-supplied only — no fetch source, build skips the shortcut if absent, see docs/guests/winxp.md)|$ASSETS/winxp/Winamp-2.95-installed.tar.gz|sha256:cd0bbbc4ceebfc2fd8c9b22d63a03fdb3c7a182be680af6dcea032f33c2a8dd9|not-redistributed"
  "repo|win311|GALLERY.GRP|$ASSETS/win311/GALLERY.GRP||repo"
  "repo|apple2|linapple kiosk patch|$ASSETS/apple2/linapple-kiosk.patch||repo"
  "repo|amigaos|AROS icons/backdrop|$ASSETS/amigaos/icons/Games.info||repo"
  "repo|toaruos|Desktop launchers|$ASSETS/toaruos/Desktop/4_mines.launcher||repo"
  # -- abandonware-URL: verified if the cache survives, refetched otherwise ----
  "opt-file|msdos-win1|MS-DOS 6.22 Disk1|$GALLERY_ROOT/MSDOSWin1/.build-work/dl/Disk1.img|sha256:b88030401122d234ea6aafba3cfed7de2b7b1782700a67be5498edca6f9fec5d|abandonware-URL"
  "opt-file|msdos-win1|MS-DOS 6.22 Disk2|$GALLERY_ROOT/MSDOSWin1/.build-work/dl/Disk2.img|sha256:e1d48a415495a17d65316d5328a91d7df0910fb1e42b0b07e7dbf8a4b4df305a|abandonware-URL"
  "opt-file|msdos-win1|MS-DOS 6.22 Disk3|$GALLERY_ROOT/MSDOSWin1/.build-work/dl/Disk3.img|sha256:52a3b4e7f5973c38f2517dbb20426bf5c8bd62f202e84a85d3d7283401d5e63c|abandonware-URL"
  "opt-file|msdos-win1|Windows 1.01 floppy|$GALLERY_ROOT/MSDOSWin1/.build-work/dl/win101.img|sha256:621e0e4e284359864a4a6d7eb702b4bc37b258c8ce82744f8ac29e89fec57397|abandonware-URL"
  "opt-file|qnx|QNX 6.5.0 live ISO|$GALLERY_ROOT/QNX/QNX650Live.iso|sha256:e22a2a75b2f4ec4be4a933590fd2bf9c9d8b6466b7c0b3553521d6ef005e4077|abandonware-URL"
  "opt-file|win311|Windows 3.11 prebuilt base image|$GALLERY_ROOT/Win311/hda.img|sha256:0aa6e4a593e4cc762306a9dfcfe262001672185bc66ba17ae69b593925e62340|abandonware-URL"
  "opt-file|os2warp|OS/2 Warp 4 evolved golden lineage|$GALLERY_ROOT/OS2Warp/os2.qcow2|sha256:2b166b8d75912feb189945ee77480b2889f3c2554ca16fdf39e432e6656653bc|abandonware-URL"
  "opt-file|win95|Win95 UTM zip (md5 pin verified by win95.sh at fetch)|$GALLERY_ROOT/Win95/.dl/win95-utm.zip||abandonware-URL"
  "opt-file|win311|DOOM 1.9 shareware|$GALLERY_ROOT/Win311/dl/doom19.zip|sha256:63ad7609f2e951fb2198f682e1226f003946c75c00b9785fa967ffb12c6745f7|abandonware-URL"
  "opt-file|win311|Duke3D shareware|$GALLERY_ROOT/Win311/dl/duke3d.zip|sha256:c7e380b2a2e3faed8b7008e3e1306b360405138ac7407cef2d3bb00b5663b65a|abandonware-URL"
  "opt-file|win311|Quake shareware|$GALLERY_ROOT/Win311/dl/quakesw.zip|sha256:b8e3e9c9f875dc6dda5ebdb9c2434bdfb3ece86c516089ebfe5c12106fffe7c1|abandonware-URL"
  "opt-file|win2000|Duke3D shareware cache|$GALLERY_ROOT/Win2000/.cache/duke3d_sw.zip|sha256:c7e380b2a2e3faed8b7008e3e1306b360405138ac7407cef2d3bb00b5663b65a|abandonware-URL"
  "opt-file|win2000|Quake shareware cache|$GALLERY_ROOT/Win2000/.cache/quake_msdos.zip|sha256:920f4609801d0bdbea5b6738cec49da846df4ff8ce0d46c901ea080dd4437833|abandonware-URL"
  "opt-file|win2000|Wolfenstein 3D shareware cache|$GALLERY_ROOT/Win2000/.cache/wolf3dsw.zip|sha256:76ee5e73e7d6341aefff620989bb5f828e9d295982afd5415b62dee7fe54eb64|abandonware-URL"
  # -- freely-fetchable-pinned: presence informational -------------------------
  "opt-file|haiku|Haiku R1/beta5 ISO|$GALLERY_ROOT/Haiku/haiku.iso|sha256:22ae312a38e98083718b6984186e753d15806bd6ea44542144fdcef42c4dcb69|freely-fetchable-pinned"
  "opt-file|android-x86|Android-x86 9.0-r2 ISO|$GALLERY_ROOT/Android/android-x86-9.0-r2.iso|sha256:91cedb534ba095a0c9b3eceede4147967fd27beea9bba640776f787dc3555021|freely-fetchable-pinned"
  "opt-file|templeos|TempleOS ISO|$GALLERY_ROOT/TempleOS/TempleOS.ISO|sha256:5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26|freely-fetchable-pinned"
  # bootOS (Oscar Toledo G., BSD-2): bootos.sh re-fetches both from raw.githubusercontent.com
  # at a pinned commit if absent. osall.img also carries five third-party boot-sector
  # programs under their own licences -- staged locally, never committed.
  "opt-file|bootos|bootOS 512-byte boot sector (os.img, nanochess/bootOS @329b75e6)|$ASSET_STAGING/bootos/os.img|sha256:35e1231cf29f8750566a97dfb628b2bbe2c24a2f7d7518d7a94103f9976d3df8|freely-fetchable-pinned"
  "opt-file|bootos|bootOS 360K floppy with 19 boot-sector programs (osall.img, nanochess/bootOS @329b75e6)|$ASSET_STAGING/bootos/osall.img|sha256:20927188a96cca1cc41bd43a24186cd6fb3e68a4f82fdaf7c2e59c9bfd874653|freely-fetchable-pinned"
  "opt-file|helenos|HelenOS 0.14.1 ISO|$GALLERY_ROOT/HelenOS/HelenOS-0.14.1-ia32.iso|sha256:1b15da0459cbfe28a6d3058675c2c20a4b03584cfb4d034c0ccb17b521791ccb|freely-fetchable-pinned"
  # PC/GEOS Ensemble (GeoWorks Ensemble lineage, bluewaysw open-source build,
  # Apache-2.0): pcgeos.sh re-fetches from the CI-latest release tag if absent
  # (a moving tag; this hash is the pin). Composed onto the fleet FreeDOS 1.3 disk.
  "opt-file|pcgeos|PC/GEOS Ensemble build (pcgeos-ensemble_nc.zip, bluewaysw/pcgeos CI-latest)|$ASSET_STAGING/pcgeos/pcgeos-ensemble_nc.zip|sha256:77587fb5b61783f65031296ddfa147273f4d398e00c40f5e5e9bfeaf37dc2bb2|freely-fetchable-pinned"
  "opt-file|reactos|ReactOS 0.4.14 live ISO|$GALLERY_ROOT/ReactOS/ReactOS.iso|sha256:9b39db9d930c919060379c8b3f1406d5cc8821e019fc3ccecf6e2dce9d1d0c7e|freely-fetchable-pinned"
  # ravynOS 0.6.1 is the LAST FreeBSD-based build; upstream deleted every FreeBSD-era
  # release (v0.4.x-v0.6.1) from GitHub and SourceForge when it restarted on Darwin/XNU,
  # so the only supply is volunteer mirrors (nomadlogic / NTNU / Clarkson). This hash was
  # measured locally AND matches the checksum from the now-deleted release page.
  "opt-file|ravynos|ravynOS 0.6.1 amd64 live ISO (BSD; UEFI-only)|$ASSET_STAGING/ravynos/ravynOS_0.6.1_amd64.iso|sha256:e7a2b90e8d87c073857bce6f65ec5023542ec76d4f694b55f49af981c4ff9516|freely-fetchable-pinned"
  # ZX81 ROM, second revision. NOT covered by the 1986 Amstrad permission --
  # Amstrad bought the Spectrum and QL rights only; Nine Stations Networks Ltd wrote
  # and still holds the ZX80/ZX81 ROM copyright. Preservation source, private.
  "req-file|zx81|Sinclair ZX81 ROM (2nd revision, zx81a.rom)|$ASSET_STAGING/zx81/zx81a.rom|sha256:14ad84f4243efcd41587ff46ab932d11087043e8d455a1ed2a227b9657828dfa|preservation-source"
  # dragon32.sh re-fetches and re-hashes this itself if it is missing, so the
  # check is here to fail a long build early rather than to gate the fetch.
  "req-file|dragon32|Dragon 32 monitor + Microsoft Extended Color BASIC ROM|$ASSET_STAGING/dragon32/d32.rom|sha1:f2dab125673e653995a83bf6b793e3390ec7f65a|preservation-source"
  # oricatmos.sh fetches this itself from the pinned archive.org item when it is
  # absent, so it is opt-file rather than req-file; the row exists so a staged
  # copy is hash-checked before a build spends time on it.
  "opt-file|oricatmos|Oric Atmos Extended BASIC V1.1 ROM (MAME orica bios ver11)|$ASSET_STAGING/oricatmos/basic11b.rom|sha256:ed28568574716eef5d7c0fde2568d7a47a6e4b1fbca81daff3be05e45723466d|preservation-source"
  "req-file|kc854|KC 85 family merged MAME romset (CAOS 4.2 + HC-BASIC extracted by sha1)|$ASSET_STAGING/kc854/kc85_2.zip|sha256:ed5b8a567232beb89a5f78fea4066160aec2ba0f2a67555439c20785d6a096ab|preservation-source"
  "req-file|sinclairql|Sinclair QL MAME romset (merged ql.zip; builder extracts 4 members by sha1)|$ASSET_STAGING/sinclairql/ql-mame0224-merged.zip|sha256:c4c39530c7abe6518f90b0df9d4eec9201434a905c77f05f490137007e420b03|preservation-source"
  # -- atarist-mame (de-bridging spike, build-mame-atarist.sh). The ST on MAME
  # needs TWO roms and only the first is clean. EmuTOS is GPLv2, but this is the
  # 192 KB image and NOT the etos1024k.img the bridge base bakes for hatari:
  # MAME's ST maps a 0x30000 TOS region, so the 1 MB image cannot be loaded at
  # all. The IKBD firmware is Atari's, has no free reimplementation as a 6301
  # image, and MAME 0.289's ST driver has no HLE keyboard path -- so unlike the
  # hatari exhibit (which HLEs the IKBD in C and needs no ROM), the MAME ST
  # exhibit is NOT licence-clean. Same category as the Amiga Kickstart the
  # bridge base fetches: copyrighted, freely fetchable at a pinned URL,
  # hash-gated, never committed. The builder fetches both if absent.
  "opt-file|atarist-mame|EmuTOS 1.4 192k ROM image etos192us.img (GPLv2)|$ASSET_STAGING/atarist-mame/etos192us.img|sha256:8fbbf8b44fc3e34281eaf8cda5265510e9af9ccda0e3e409111648060d244cfc|freely-fetchable-pinned"
  "opt-file|atarist-mame|Atari ST IKBD HD6301 firmware keyboard.u1 (Atari copyright; without it the ST's mouse and keyboard are dead)|$ASSET_STAGING/atarist-mame/keyboard.u1|sha256:b2c5c61bac3dbd563206ddf4a4bca14db6d95575fe6892e59fff621e5205311f|freely-fetchable-pinned"
  # -- in-overlay media (nextstep): these two live INSIDE the station's own qcow2
  # overlay at /opt/bridge/media/nextstep/, not on the host filesystem, so the
  # host paths below never exist and these rows read "will fetch". They are
  # here for the hash record; nextstep.sh re-verifies both sha256s in-guest on
  # every run and refuses to continue on a mismatch. Never committed.
  "opt-file|nextstep|NeXTSTEP 3.3 m68k pre-installed disk (fetched + verified in-guest)|$ASSET_STAGING/nextstep/NS33_2GB.dd|sha256:6381423b066c33c24c9c9ec519086708b9cf3b2f11882fed5319cfb6a3422f1b|preservation-source"
  "opt-file|nextstep|NeXT ROM Rev 2.5 v66 (ships inside the Previous source tree)|$ASSET_STAGING/nextstep/Rev_2.5_v66.BIN|sha256:1b753890b67095b73e104c939ddf62eca9e7d0aedde5108e3893b0ed9d8000a4|preservation-source"
  # -- in-overlay media (daybreak): same shape as nextstep above. Both live
  # INSIDE the station's own qcow2 overlay at /opt/bridge/media/daybreak/, so the
  # host paths never exist and these rows read "will fetch". They are here for
  # the hash record; daybreak.sh re-verifies both sha256s in-guest on every run
  # and refuses to continue on a mismatch. Never committed. Note the split
  # licence: the emulator is BSD-3, the Xerox disk it boots is NOT.
  "opt-file|daybreak|Dwarf/Draco Mesa emulator dist.zip (fetched + verified in-guest)|$ASSET_STAGING/daybreak/dist.zip|sha256:67f84b77cbed6cba9d7d2485e84b8142e4fd2403243f8abd8f6e5a81ff6fcf75|freely-fetchable-pinned"
  "opt-file|daybreak|Xerox ViewPoint 2.0.5 Pilot disk for the 6085 (fetched + verified in-guest)|$ASSET_STAGING/daybreak/vp2.0.5.zdisk|sha256:02bdb53ba7f7896a914fe43b7ca19a620907d0fdbf0f55317b7d1f39aab3f872|preservation-source"
  # -- in-overlay media (star): same shape again — the bitsavers pack lives
  # INSIDE the station overlay at /opt/star/, so the host path never exists and
  # this row reads "will fetch". star.sh re-verifies the pack AND the extracted
  # ViewPoint image in-guest on every run and refuses to continue on a
  # mismatch. Never committed. The emulator (Darkstar, BSD-2) is built from
  # source in the overlay rather than fetched as a binary, so it has no row
  # here; its pinned commit is in star.sh and ASSETS-MANIFEST.md.
  "opt-file|star|Xerox 8010 Dandelion rigid-disk pack, incl. ViewPoint 2.0 (fetched + verified in-guest)|$ASSET_STAGING/star/8010_hd_images.zip|sha256:d9fb11362229ba7b9dbb7500f2240f9c1e9cdaa9f37bb4431221174483ca438e|preservation-source"
  # BBC Micro: five blobs, no authorised fetch URL anywhere (see ASSETS-MANIFEST).
  # bbcmicro.sh never downloads; the operator stages these and the builder gates
  # each on SHA-1, then assembles the three MAME zips itself.
  "req-file|bbcmicro|Acorn MOS 1.20 (BBC Micro Model B)|$ASSET_STAGING/bbcmicro/os12.rom|sha1:0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d|preservation-source"
  "req-file|bbcmicro|BBC BASIC II|$ASSET_STAGING/bbcmicro/basic2.rom|sha1:4a7393f3a45ea309f744441c16723e2ef447a281|preservation-source"
  "req-file|bbcmicro|TMS5220 speech PHROM (BBC Micro)|$ASSET_STAGING/bbcmicro/phroma.bin|sha1:b369809275cb67dfd8a749265e91adb2d2558ae6|preservation-source"
  "req-file|bbcmicro|SAA5050 teletext character generator (no glyphs in MODE 7 without it)|$ASSET_STAGING/bbcmicro/saa5050|sha1:6c8daba70374e5aa3a6402f24cdc5f8677d58a0f|preservation-source"
  "req-file|bbcmicro|Acorn DNFS 1.20 (the driver's default fdc slot needs it)|$ASSET_STAGING/bbcmicro/dnfs120.rom|sha1:7e3c536baeae84d6498a14e8405319e01ee78232|preservation-source"
  # ARM Evaluation System: the bbcmicro blobs again in this station's own staging
  # dir, plus four of its own. armeval.sh never downloads either; note there is
  # NO dnfs120 here — `-fdc acorn1770` replaces the 8271, because the ARM
  # Evaluation System discs are ADFS double density and the 8271 cannot read them.
  "req-file|armeval|Acorn MOS 1.20 (BBC Micro Model B host)|$ASSET_STAGING/armeval/os12.rom|sha1:0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d|preservation-source"
  "req-file|armeval|BBC BASIC II (host language, kept in the banner by -rom3)|$ASSET_STAGING/armeval/basic2.rom|sha1:4a7393f3a45ea309f744441c16723e2ef447a281|preservation-source"
  "req-file|armeval|TMS5220 speech PHROM (zip member cm62024.bin)|$ASSET_STAGING/armeval/phroma.bin|sha1:b369809275cb67dfd8a749265e91adb2d2558ae6|preservation-source"
  "req-file|armeval|SAA5050 teletext character generator (no glyphs in MODE 7 without it)|$ASSET_STAGING/armeval/saa5050|sha1:6c8daba70374e5aa3a6402f24cdc5f8677d58a0f|preservation-source"
  "req-file|armeval|ARM Tube bootstrap, Executive v1.00 14 Aug 1986 (bbc_tube_arm BIOS 101)|$ASSET_STAGING/armeval/armeval_101.rom|sha1:f86bbc4894e62725b8ef22d44e7f44d37c98ac14|preservation-source"
  "req-file|armeval|Acorn DFS 2.23 (bbc_acorn1770 BIOS dfs223)|$ASSET_STAGING/armeval/dfs v2.23,acorn.rom|sha1:0d7ed0b0b3852cb61970ada1993244f2896896aa|preservation-source"
  "req-file|armeval|Acorn ADFS 1.30 (sideways socket 3 by path; socket 1 kills the Tube)|$ASSET_STAGING/armeval/Acorn-ADFS-1.30.rom|sha1:301fd05c475a629c4bec70510d4507256a5b00d8|preservation-source"
  "req-file|armeval|ARM Evaluation System Disc 3 'Utilities 2 / BASIC' (carries $.AB, ARM BBC Basic V 1.00)|$ASSET_STAGING/armeval/armevaluationsystem-disc3.adl|sha1:f5114ff744f6f742da3959a91a1b98af0bd1db5d|preservation-source"
  # -- DEC media (decos, pdp11): staged by hand, and NO builder may fetch them.
  # Every trailing-edge.com host is offline, so these came through the Wayback
  # raw form and bitsavers; a lost copy is a one-shot re-hunt, not a re-download.
  # See ASSETS-MANIFEST §0 for the Mentec hobbyist grant these run under.
  "req-file|decos|RT-11 V5.3 distribution kit (RL02 pack + the Mentec licence text)|$ASSET_STAGING/decos/rtv53swre.tar.Z|sha256:9fdad10969f1f391b13d9d97aa8fc1aa8fcb44472dac363d23eb2d31500207bc|preservation-source"
  "req-file|decos|RSX-11M V4.2 BL38 TK50 kit|$ASSET_STAGING/decos/rsx11m42.zip|sha256:c8766a53ae5b32c060560d5cea6302715c046322c80dbc234cc7e63ab2391ba1|preservation-source"
  "req-file|decos|RSTS/E V9.6 installation tape (TPC)|$ASSET_STAGING/decos/rsts_v9_6_install.zip|sha256:aaf4aa978e13318fe304dfbf75e20090206e17caa5b76bab69bec2704d9c694f|preservation-source"
  "req-file|pdp11|2.11BSD prebuilt MSCP pack (Don North), pristine zip|/data/vms/streamhost/stations/pdp11/media/2.11BSD_rq.dsk.zip|sha256:94abeca02f001619e7aa2252cb2336ffe79af0cb3fb35cbd8c14240af3125a6b|preservation-source"
  # -- atarist app archives: sha256-gated in the builder, but the SOURCES are
  # three small sites (one behind a two-step PHP cookie handshake, one an opaque
  # atarimania numeric id). The builder re-fetches when they are absent, so this
  # is not a gate on the fetch — it is here so a lost cache fails the preflight
  # instead of failing three fragile HTTP requests deep into a build. Same
  # reasoning as the dragon32 row above. Pending population into the media cache.
  "req-file|atarist|AIM 3.1 image manager (Floppyshop ART-3488)|/data/vms/streamhost/stations/atarist/assets/atarist-apps/ART-3488.zip|sha256:a5b245ae886aaeedc7d98a0d7ae774c75c214faa567f5b3f88321c89a210e147|abandonware-URL"
  "req-file|atarist|GEMBench 4.03 (Floppyshop UTL-3762)|/data/vms/streamhost/stations/atarist/assets/atarist-apps/UTL-3762.zip|sha256:74bce9ec2c7ec4d0da144887e0a5848bde3feff165e4cdabde52c3a395824567|abandonware-URL"
  "req-file|atarist|Ballerburg (Eckhard Kruse, PD)|/data/vms/streamhost/stations/atarist/assets/atarist-apps/baller.zip|sha256:8bcb4214cc6a30c02413f73923cabcf65437b9294f6148f3018f01bac9115d45|freely-fetchable-pinned"
  "req-file|atarist|Ballerburg sources (Eckhard Kruse, PD)|/data/vms/streamhost/stations/atarist/assets/atarist-apps/baller_sources.zip|sha256:63fb6c5aa14f4f912e4d5cff61f42fa35951932d0635b185e14da434212ed593|freely-fetchable-pinned"
  "req-file|atarist|Pacman for GEM 0.2.5 (atarimania pgedump id=31902)|/data/vms/streamhost/stations/atarist/assets/atarist-apps/pacman_for_gem_0_25.zip|sha256:6f33a9e7371f9fb6bd635dd6d67250e1c5adc6c0b44b609e726e0fed84f5fe3e|abandonware-URL"
  # -- c128: one file, one mirror (zimmers.net). c128.sh re-fetches when the host
  # copy is absent; the row exists so a dead mirror is discovered at preflight.
  "req-file|c128|Commodore CP/M 3.0 system disk for the C128 (Z80 side)|/data/vms/streamhost/stations/c128/media/cpm.d64|sha256:69159226bf1996d8fc8c8921f094cd03955c7a8b9ecf800069d1c369dc6e5a1d|preservation-source"
  # -- apple2: the GEOS media lives INSIDE the station overlay at /opt/bridge/media/,
  # not on the host, so these read "will fetch" exactly like the nextstep and
  # daybreak rows above. apple2.sh gates BOTH sha256s in-guest on every run.
  # mirrors.apple2.org.za is the only source, so the pin is the whole defence.
  "opt-file|apple2|Apple GEOS deskTop mouse HDV, zipped (fetched + verified in-guest)|$ASSET_STAGING/apple2/geos-mouse.hdv.zip|sha256:64b7bef2440e2f0424586a893c641b566901403ad3ce6b3b5adaab573ae23e35|abandonware-URL"
  "opt-file|apple2|Apple GEOS deskTop ProDOS image geos.hdv, unzipped (fetched + verified in-guest)|$ASSET_STAGING/apple2/geos.hdv|sha256:5aba89dda3450abf17b8cc05d9de98149abe0bb072e5b01cc29b7fff995fc681|abandonware-URL"
  # -- indyr4400: DERIVED from labhost's own irix checkpoint, not downloaded. The
  # ext4 container's hash is not reproducible (mkfs stamps a random UUID), so
  # this row is presence-only; the inner disk.raw hash is in ASSETS-MANIFEST §0.
  "req-file|indyr4400|IRIX 6.5.22 r4400 read-only asset drive (derived from irix65-apps.chd)|$GALLERY_ROOT/IrisIndy/irix65-r4400-disk.ext4||preservation-source"
  # -- base-media: the four media blobs CAPTURED INTO the frozen bridge base at
  # /opt/bridge/media/ inside /data/vms/bridge/bridge-base.qcow2. Every bridge
  # station inherits them through its overlay; c64 boots GEOS.D64, atarist boots
  # etos1024k.img, amiga boots the Kickstart + Workbench pair. They are on no
  # host path, so these rows read "will fetch" and exist for the HASH RECORD —
  # the same honest-hollow shape the nextstep/daybreak/star rows use.
  # To verify them for real, read the base READ-ONLY and never writable:
  #   modprobe nbd && qemu-nbd --read-only -c /dev/nbd0 /data/vms/bridge/bridge-base.qcow2
  #   mount -o ro /dev/nbd0p1 /mnt/x && sha256sum /mnt/x/opt/bridge/media/...
  # (hashes below measured 2026-08-10 through live station overlays, which is the
  # cheaper equivalent: pet2001/c64/atarist/apple2 all report the same bytes.)
  # The base also carries /opt/bridge/media/LICENSES, a text note, not media.
  "opt-file|bridge-base|C64 GEOS 2.0 disk GEOS.D64 (baked into the bridge base)|$ASSET_STAGING/bridge-base/GEOS.D64|sha256:2aabeb34bd3bb21866f5c50db172a4aeb11163ed1dc178eb82342f7ce3405a59|base-media"
  "opt-file|bridge-base|EmuTOS 1.3 1024k ROM image etos1024k.img (GPLv2; baked into the bridge base)|$ASSET_STAGING/bridge-base/etos1024k.img|sha256:e2692d0277d473128ac0557fd30a8995a8223a114e91b0e66e8af4ec35b59728|base-media"
  "opt-file|bridge-base|Amiga Kickstart 1.3 kick13.rom (baked into the bridge base)|$ASSET_STAGING/bridge-base/kick13.rom|sha256:ee05862d8102a08436ac4056da7d549db31625c7d47b24dfb7b3c9a5c113ca53|base-media"
  "opt-file|bridge-base|Amiga Workbench 1.3 boot ADF workbench13.adf (baked into the bridge base)|$ASSET_STAGING/bridge-base/workbench13.adf|sha256:3610df193fdbbfbd88da695732a5c3ed63e77ed3de20e187201289e3915bb2c2|base-media"
  # -- DELIBERATELY NOT LISTED, so a green run is not read as more than it is:
  #   * The six VICE stations (c64, vic20, plus4, pet2001, cbm8032, cbm2) and gt40
  #     have NO external media at all — VICE bundles every ROM they need, and
  #     gt40's lunar.lda ships inside the MIT-licensed Open SIMH tree it builds.
  #     A row for them would be hollow, and a hollow row is worse than none.
  #   * alto: the Alto disk packs and microcode PROMs ship inside the pinned
  #     ContrAlto2 git tree the builder clones. Nothing is staged separately.
  #   * amiga/c64: their media IS the base-media rows above, not a second copy.
  #   * The host-built MAME binaries under /data/vms/streamhost/assets/<tile>/mame/
  #     (the six build-mame-*.sh products bbcb/dragon/kc85/mpf2/oricatmos/zx81,
  #     plus irix's separately-built sgi; 68-122 MB each) are BUILD ARTIFACTS, not
  #     media: losing one costs a chroot rebuild, not the station. No rows.
)

# ---- impl ---------------------------------------------------------------------
c_r=$'\e[31m'
c_g=$'\e[32m'
c_y=$'\e[33m'
c_0=$'\e[0m'
want() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local k
  for k in "${ONLY[@]}"; do [ "$k" = "$1" ] && return 0; done
  return 1
}
want_class() {
  [ ${#CLASSES[@]} -eq 0 ] && return 0
  local k
  for k in "${CLASSES[@]}"; do [ "$k" = "$1" ] && return 0; done
  return 1
}
hash_ok() { # hash_ok <file> <algo:hex>  (empty pin => ok)
  [ -n "$2" ] || return 0
  local algo="${2%%:*}" want="${2#*:}" got
  case "$algo" in
    sha256) got="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" ;;
    sha1) got="$(sha1sum "$1" 2>/dev/null | awk '{print $1}')" ;;
    md5) got="$(md5sum "$1" 2>/dev/null | awk '{print $1}')" ;;
    *) return 1 ;;
  esac
  [ "$got" = "$want" ]
}

missing=()
mismatched=()
fetchlist=()
okn=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r type builder label path pin class <<<"$row"
  want "$builder" || continue
  want_class "$class" || continue
  case "$type" in
    req-env)
      if [ -n "${!path:-}" ]; then
        okn=$((okn + 1))
        [ $QUIET = 1 ] || echo "${c_g}ok${c_0}      env  $path  ($builder)"
      else missing+=("env  $path — $label  [$builder, $class]"); fi
      ;;
    req-file | repo)
      if [ ! -s "$path" ]; then
        missing+=("file $path — $label  [$builder, $class]")
      elif ! hash_ok "$path" "$pin"; then
        mismatched+=("file $path — $label  [$builder] sha256 MISMATCH (want ${pin#*:})")
      else
        okn=$((okn + 1))
        [ $QUIET = 1 ] || echo "${c_g}ok${c_0}      file $path"
      fi
      ;;
    opt-file)
      if [ ! -s "$path" ]; then
        fetchlist+=("$label  [$builder, $class] -> will be fetched at build")
      elif ! hash_ok "$path" "$pin"; then
        mismatched+=("file $path — $label  [$builder] sha256 MISMATCH (stale cache? delete to refetch)")
      else
        okn=$((okn + 1))
        [ $QUIET = 1 ] || echo "${c_g}ok${c_0}      cache $path"
      fi
      ;;
  esac
done

echo
[ ${#fetchlist[@]} -gt 0 ] && [ $QUIET = 0 ] && {
  echo "${c_y}fetched at build (not staged — informational):${c_0}"
  printf '  - %s\n' "${fetchlist[@]}"
  echo
}
if [ ${#missing[@]} -eq 0 ] && [ ${#mismatched[@]} -eq 0 ]; then
  echo "${c_g}check-assets: OK${c_0} — $okn verified, ${#fetchlist[@]} to fetch at build."
  exit 0
fi
[ ${#missing[@]} -gt 0 ] && {
  echo "${c_r}MISSING (stage these first — see docs/lab/ASSETS-MANIFEST.md):${c_0}"
  printf '  - %s\n' "${missing[@]}"
}
[ ${#mismatched[@]} -gt 0 ] && {
  echo "${c_r}HASH MISMATCH:${c_0}"
  printf '  - %s\n' "${mismatched[@]}"
}
exit 1
