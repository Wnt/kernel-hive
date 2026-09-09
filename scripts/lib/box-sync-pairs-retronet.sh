#!/bin/bash
# box-sync-pairs-retronet.sh — the per-station network-link helper pairs.
#
# Split out of box-sync-pairs.sh, which had grown to exactly the 600-line hard
# cap: the next station to need a pair could not be added without breaching it.
# These rows are one coherent class — a helper the station's LAUNCHER calls
# (rn-tapnet.sh, wi-tapnet.sh, rn-netns.sh, x11-runtime.sh), which is NOT an
# emit aux file and so ships nowhere unless it is named here.
#
# Sourced by box-sync-pairs.sh; runs inside box_sync_load_pairs, so it uses
# that function's $BOX_ROOT and the shared box_sync_add_pair helper.
box_sync_add_retronet_pairs() {
  # Every station that ships a launcher-side retronet link helper
  # (streamhost/stations/<id>/rn-tapnet.sh) gets the same box-authored mirror
  # pair, discovered from the repo tree. One row per station was the shape until
  # 2026-09-03, when nine waves each appended one and box-sync-pairs.sh hit the
  # 600-line hard cap mid-landing; the helper is not an emit aux file, so it
  # ships nowhere unless it is named here, and the glob names it for every
  # station, present and future. Per-station facts (address, plane, quirks) live
  # in docs/lab/retronet/*STATION-<id>.md, not in a comment beside a row.
  local rn_helper rn_sid
  for rn_helper in "$REPO"/streamhost/stations/*/rn-tapnet.sh; do
    [ -f "$rn_helper" ] || continue
    rn_sid=${rn_helper%/rn-tapnet.sh}
    rn_sid=${rn_sid##*/}
    box_sync_add_pair "$rn_sid-rn-tapnet" "streamhost/stations/$rn_sid/rn-tapnet.sh" "$BOX_ROOT/stations/$rn_sid/rn-tapnet.sh" exact repo
  done
  # win98se's retronet bridge-tap lifecycle helper, called `up` from its launcher.
  # A station helper like sailfish-seriald: box-authored mirror pair so box-deploy
  # installs it alongside the launcher (not an emit aux file, which deploys on a
  # win95 retronet web plane: its bridge-tap lifecycle helper (guest 10.99.0.13 by
  # DHCP reservation). The warpnet pointer agent (:7777) and a second warpnet
  # winxp's retronet bridge-tap lifecycle helper (web plane: IE6 on the corpus,
  # guest 10.99.0.18). Same box-authored mirror pair as win98se's above.
  # chokanji's retronet bridge-tap lifecycle helper (web plane: the B-right/V
  # 基本ブラウザ on the corpus, guest 10.99.0.21 — statically addressed in-guest,
  # since BTRON3 has no DHCP client). Same box-authored mirror pair as win98se's
  # solaris' retronet bridge-tap lifecycle helper (Tier C, climm/OSCAR), the same
  # box-authored mirror pair as win98se's above. See ICQ-STATION-solaris.md.
  # win311's retronet bridge-tap lifecycle helper (web plane: Netscape 4.08
  # 16-bit on the corpus, guest 10.99.0.27 by DHCP reservation — MS TCP/IP-32
  # over the RTL8029 NDIS3 driver). Same box-authored mirror pair as win98se's
  # The walk-in taps. A NEW file in an existing station dir ships nowhere until
  # named here — how the plane reached production without them, gallery and all.
  for _wi in os2warp rhapsody win311; do
    box_sync_add_pair "$_wi-wi-tapnet" "streamhost/stations/$_wi/wi-tapnet.sh" "$BOX_ROOT/stations/$_wi/wi-tapnet.sh" exact repo
  done
  # tru64's retronet veth lifecycle helper + its es40 launcher. Same box-authored
  # mirror pair as win98se/solaris above; tru64 has no qemu-streamhost.sh, so the
  # generic launcher sweep below does not pick its runtime up. Without these the
  # box copies silently drift from the repo. See ICQ-STATION-tru64.md.
  # aix432's retronet bridge-tap lifecycle helper (web plane: Netscape 4.08 on
  # the corpus, guest 10.99.0.28 statically addressed in-guest). Same
  # box-authored mirror pair as win98se's above. Its skipfix helper rides along:
  # the launcher arms it against -gdb to step over the IBM firmware's POST
  # settimeofday, which otherwise halts the machine at 888-102-700-0A5 — needed
  # on a COLD boot only, since `loadvm golden` never re-runs POST.
  box_sync_add_pair aix432-skipfix streamhost/stations/aix432/skipfix.py "$BOX_ROOT/stations/aix432/skipfix.py" exact repo
  # amigaos35's retronet link is a NETNS cage (FS-UAE bsdsocket has no tap
  # backend) — same launcher-called-helper class as the rn-tapnet.sh files.
  box_sync_add_pair amigaos35-rn-netns streamhost/stations/amigaos35/rn-netns.sh "$BOX_ROOT/stations/amigaos35/rn-netns.sh" exact repo
  box_sync_add_pair tru64-x11-runtime streamhost/stations/tru64/x11-runtime.sh "$BOX_ROOT/stations/tru64/x11-runtime.sh" exact repo
  # w2kalpha's retronet veth lifecycle helper + its es40 launcher. Box-authored
  # mirror pairs like the rn-tapnet helpers above: the generic launcher sweep
  # below globs only qemu-streamhost.sh, so an es40 x11-runtime.sh is never picked
  # up, and rn-tapnet.sh is a launcher-called helper, not an emit aux file — so
  # without these two the box copies silently drift from the repo. rn-tapnet.sh
  # re-homes the guest's dec21143 pcap veth onto vmbr-rn (guest 10.99.0.17). See
  box_sync_add_pair w2kalpha-x11-runtime streamhost/stations/w2kalpha/x11-runtime.sh "$BOX_ROOT/stations/w2kalpha/x11-runtime.sh" exact repo
}
