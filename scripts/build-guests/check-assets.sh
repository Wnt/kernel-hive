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
  "req-file|mpf2|Multitech MPF-II Monitor + BASIC ROM|$ASSET_STAGING/mpf2/mpf_ii.rom|sha1:92378b0db561632b58a9b36a85f8fb00796198bb|preservation-source"
  # -- freely fetchable, pinned (the builder fetches + verifies if absent) -------
  # Debian non-free spectrum-roms; its usr/share/doc/spectrum-roms/copyright carries
  # Amstrad's 1999 emulator permission. zxspectrum.sh extracts 48.rom from it.
  "opt-file|zxspectrum|Sinclair ZX Spectrum 48K ROM, in Debian's spectrum-roms package (fetched by zxspectrum.sh from deb.debian.org if absent)|$ASSET_STAGING/zxspectrum/spectrum-roms_20081224-5_all.deb|sha256:8d25dd300a0c86b4459e152de3bc657dca894b167e6a6419eb195d9669bfe950|freely-fetchable-pinned"
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
  "opt-file|helenos|HelenOS 0.14.1 ISO|$GALLERY_ROOT/HelenOS/HelenOS-0.14.1-ia32.iso|sha256:1b15da0459cbfe28a6d3058675c2c20a4b03584cfb4d034c0ccb17b521791ccb|freely-fetchable-pinned"
  "opt-file|reactos|ReactOS 0.4.14 live ISO|$GALLERY_ROOT/ReactOS/ReactOS.iso|sha256:9b39db9d930c919060379c8b3f1406d5cc8821e019fc3ccecf6e2dce9d1d0c7e|freely-fetchable-pinned"
  # ZX81 ROM, second revision. NOT covered by the 1986 Amstrad permission --
  # Amstrad bought the Spectrum and QL rights only; Nine Tiles Networks Ltd wrote
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
  # -- in-overlay media (nextstep): these two live INSIDE the tile's own qcow2
  # overlay at /opt/bridge/media/nextstep/, not on the host filesystem, so the
  # host paths below never exist and these rows read "will fetch". They are
  # here for the hash record; nextstep.sh re-verifies both sha256s in-guest on
  # every run and refuses to continue on a mismatch. Never committed.
  "opt-file|nextstep|NeXTSTEP 3.3 m68k pre-installed disk (fetched + verified in-guest)|$ASSET_STAGING/nextstep/NS33_2GB.dd|sha256:6381423b066c33c24c9c9ec519086708b9cf3b2f11882fed5319cfb6a3422f1b|preservation-source"
  "opt-file|nextstep|NeXT ROM Rev 2.5 v66 (ships inside the Previous source tree)|$ASSET_STAGING/nextstep/Rev_2.5_v66.BIN|sha256:1b753890b67095b73e104c939ddf62eca9e7d0aedde5108e3893b0ed9d8000a4|preservation-source"
  # -- in-overlay media (daybreak): same shape as nextstep above. Both live
  # INSIDE the tile's own qcow2 overlay at /opt/bridge/media/daybreak/, so the
  # host paths never exist and these rows read "will fetch". They are here for
  # the hash record; daybreak.sh re-verifies both sha256s in-guest on every run
  # and refuses to continue on a mismatch. Never committed. Note the split
  # licence: the emulator is BSD-3, the Xerox disk it boots is NOT.
  "opt-file|daybreak|Dwarf/Draco Mesa emulator dist.zip (fetched + verified in-guest)|$ASSET_STAGING/daybreak/dist.zip|sha256:67f84b77cbed6cba9d7d2485e84b8142e4fd2403243f8abd8f6e5a81ff6fcf75|freely-fetchable-pinned"
  "opt-file|daybreak|Xerox ViewPoint 2.0.5 Pilot disk for the 6085 (fetched + verified in-guest)|$ASSET_STAGING/daybreak/vp2.0.5.zdisk|sha256:02bdb53ba7f7896a914fe43b7ca19a620907d0fdbf0f55317b7d1f39aab3f872|preservation-source"
  # -- in-overlay media (star): same shape again — the bitsavers pack lives
  # INSIDE the tile overlay at /opt/star/, so the host path never exists and
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
  # ARM Evaluation System: the bbcmicro blobs again in this tile's own staging
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
