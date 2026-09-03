#!/usr/bin/env bash
# =============================================================================
# box-sync-pairs.sh — the ONE declaration of every repo/box mirror pair.
#
# This was the pair table inside verify-box-sync.sh. It is a library now for a
# concrete reason: on 2026-08-10 the orchestrator hand-scp'd drifting files to
# labhost FOUR times in one day, because the detector could say DIFFERS and
# nothing could say "push it". Splitting the DECLARATION from the DETECTOR lets
# the reconcile half (scripts/dev/box-sync-push.sh) read exactly the same rows,
# the same secret guard and the same scrub map that the gate reads — so a pair
# can never be verified one way and pushed another.
#
# Every row carries FOUR facts, not two:
#
#   mode       exact | scrub    — is the labhost copy deployed VERBATIM, or with the
#                                 operator's real host/gallery names substituted
#                                 in for this repo's scrubbed placeholders?
#   authority  repo | box       — which side is the source of truth. scripts/
#                                 README.md has always SAID "the repo is
#                                 authoritative for source, the box for
#                                 generated/live artifacts"; it was prose, and a
#                                 tool cannot read prose. Pushing a generated
#                                 artifact back at labhost overwrites the thing
#                                 that generated it, so this is not a hint.
#   post       none | daemon-reload
#                                 what labhost needs told after the bytes land.
#                                 Deliberately NOT "restart the service": that
#                                 is a human decision about a live exhibit, and
#                                 a sync tool that restarts things is a sync
#                                 tool nobody dares run.
#
# The scrub map is built from gitignored registry/local.env and is exported in
# THREE forms, all sed programs, none of which may ever be printed, written to a
# local file, or passed in argv — they carry the operator's real LAN IP and
# public hostnames (AGENTS.md "Placeholder values"):
#
#   BOX_SYNC_CANON_PROG    `${KEY:-placeholder}` -> placeholder   (placeholders only)
#   BOX_SYNC_REVERSE_PROG  real -> placeholder, then canon        (labhost copy -> repo form)
#   BOX_SYNC_FORWARD_PROG  canon, then placeholder -> real        (repo copy -> labhost form)
#
# CANON FIRST in the forward program is load-bearing: substitute the bare
# placeholder first and `${SH_HOST_IP:-192.0.2.10}` becomes
# `${SH_HOST_IP:-<real>}`, which the canon rule no longer matches, and the
# deployed file ends up with a shell fallback wrapped around a real address
# instead of the flat value labhost expects. Reverse then canon is the mirror
# of that and is what the gate has always done.
#
# With no registry/local.env, BOX_SYNC_SCRUB_READY stays 0. The gate reports
# those rows UNCHECKED; the push path must REFUSE them. "Unchecked" is never
# "fine" in the write direction — that is how a placeholder gets written over a
# live deployment.
#
# Sourceable only; it is not a CLI.
# =============================================================================

# Populated by box_sync_load_pairs; parallel arrays, one entry per pair.
declare -a BOX_SYNC_LABELS=() BOX_SYNC_REPO_FILES=() BOX_SYNC_BOX_FILES=()
declare -a BOX_SYNC_MODES=() BOX_SYNC_AUTHORITY=() BOX_SYNC_POST=()

BOX_SYNC_CANON_PROG=""
BOX_SYNC_REVERSE_PROG=""
BOX_SYNC_FORWARD_PROG=""
BOX_SYNC_SCRUB_READY=0
# The placeholders the operator actually overrides — placeholders only, so this
# one IS safe to print. It is what lets the push path say "this row is deployed
# with substitution" without ever naming the substituted value.
declare -a BOX_SYNC_LIVE_PLACEHOLDERS=()

# --- scrub map -------------------------------------------------------------
# Only keys whose value actually DIFFERS from the repo placeholder contribute a
# substitution rule; a local.env that still holds the placeholders is the same
# as having none, and must not flip SCRUB_READY.
box_sync_scrub_init() {
  local repo_root="$1" key real placeholder escaped_real escaped_ph fwd_prog=""
  # shellcheck disable=SC1091
  . "$repo_root/scripts/lib/local-env.sh"

  _box_sync_rule() {
    key="$1" real="$2" placeholder="$3"
    escaped_ph="$(printf '%s' "$placeholder" | sed -e 's/[][\.*^$/&]/\\&/g')"
    BOX_SYNC_CANON_PROG+="s/\\\${$key:-$escaped_ph}/$placeholder/g;"
    [ -n "$real" ] || return 0
    [ "$real" != "$placeholder" ] || return 0
    escaped_real="$(printf '%s' "$real" | sed -e 's/[][\.*^$/&]/\\&/g')"
    BOX_SYNC_REVERSE_PROG+="s/$escaped_real/$placeholder/g;"
    fwd_prog+="s/$escaped_ph/$(printf '%s' "$real" | sed -e 's/[\/&\\]/\\&/g')/g;"
    BOX_SYNC_LIVE_PLACEHOLDERS+=("$placeholder")
    BOX_SYNC_SCRUB_READY=1
  }
  _box_sync_rule SH_HOST_IP "${SH_HOST_IP:-}" 192.0.2.10
  _box_sync_rule SH_TUNNEL_HOST "${SH_TUNNEL_HOST:-}" tunnel.example.com
  _box_sync_rule SH_GALLERY_HOST "${SH_GALLERY_HOST:-}" gallery.example.com
  unset -f _box_sync_rule

  BOX_SYNC_REVERSE_PROG+="$BOX_SYNC_CANON_PROG"
  BOX_SYNC_FORWARD_PROG="$BOX_SYNC_CANON_PROG$fwd_prog"
}

# --- where the box is -------------------------------------------------------
# LAB=local means "this shell IS labhost" (scripts/host/box-install.sh running
# from /data/kernel-hive): the same discovery commands run in-process instead
# of over ssh, so the install path reads exactly the rows the gate reads.
box_sync_remote() { # <lab> <script>   (stdin passes through)
  if [ "$1" = local ]; then
    bash -c "$2"
  else
    ssh -o ConnectTimeout=15 "$1" "$2"
  fi
}

# --- pair table ------------------------------------------------------------
# box_sync_add_pair <label> <repo-relative> <box-absolute> <mode> <authority> [post]
box_sync_add_pair() {
  case "$1$2$3" in
    *uptoken* | *unifitoken* | *credentials.* | */pki/* | *.key*)
      printf 'box-sync-pairs: refusing secret-like path\n' >&2
      exit 2
      ;;
  esac
  case "$4" in exact | scrub) ;; *)
    printf 'box-sync-pairs: %s: bad mode %s\n' "$1" "$4" >&2
    exit 2
    ;;
  esac
  case "$5" in repo | box) ;; *)
    printf 'box-sync-pairs: %s: bad authority %s\n' "$1" "$5" >&2
    exit 2
    ;;
  esac
  BOX_SYNC_LABELS+=("$1") BOX_SYNC_REPO_FILES+=("$2") BOX_SYNC_BOX_FILES+=("$3")
  BOX_SYNC_MODES+=("$4") BOX_SYNC_AUTHORITY+=("$5") BOX_SYNC_POST+=("${6:-none}")
}

# box_sync_load_pairs <repo> <box-root> <lab> <tmpdir>
# Three of the trees are unions discovered on labhost, so this makes exactly two
# read-only ssh round trips (find, find). Everything else is declared here.
box_sync_load_pairs() {
  local REPO="$1" BOX_ROOT="$2" LAB="$3" tmpdir="$4" name rel path

  # scripts/README.md "Box-sync pairs" (expanded to one byte pair per row).
  box_sync_add_pair labctl scripts/labctl /usr/local/bin/labctl exact repo
  # labctl's pure-function modules (size-exclusions.json split, 2026-08-17):
  # scripts/labctl.d/*.py -> /usr/local/lib/labctl/*.py, one row per file, as
  # a TREE rather than a name list for the same reason the auth-plane loop
  # below is one — a file added to labctl.d/ and forgotten here would be
  # DEPLOYED-INVISIBLE, exactly the auth-plane gap this pattern already closed.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    box_sync_add_pair "labctl.d/${rel#scripts/labctl.d/}" "$rel" \
      "/usr/local/lib/labctl/${rel#scripts/labctl.d/}" exact repo
  done < <(git -C "$REPO" ls-files 'scripts/labctl.d/*.py' | sort)
  # guest_wake.py is shared (labctl AND scripts/dev/qmp-type.py AND any driver
  # of your own), so it lives in scripts/lib/ rather than labctl.d/ — which puts
  # it outside the tree loop above. It installs FLAT beside common.py, and
  # common.py searches its own directory for exactly this reason. Without this
  # row an installed labctl cannot import it and every verb dies on startup.
  box_sync_add_pair guest_wake scripts/lib/guest_wake.py \
    /usr/local/lib/labctl/guest_wake.py exact repo
  box_sync_add_pair clone-guard scripts/lib/clone-guard.sh /usr/local/bin/clone-guard exact repo
  box_sync_add_pair kh-claim scripts/lib/kh-claim.sh /usr/local/bin/kh-claim exact repo
  box_sync_add_pair kh-session scripts/lib/kh-session.sh /usr/local/lib/kh-session.sh exact repo
  box_sync_add_pair xvfb-alloc scripts/lib/xvfb-alloc.sh /usr/local/bin/xvfb-alloc exact repo
  box_sync_add_pair chroot-guard scripts/lib/chroot-guard.sh /usr/local/bin/chroot-guard exact repo
  box_sync_add_pair checkpoint-guard scripts/lib/checkpoint-guard.sh \
    /usr/local/bin/checkpoint-guard exact repo
  # The guard SOURCES its framebuffer-proof half; deploy them together or the
  # guard refuses to run at all (it will not delete a checkpoint it cannot prove).
  box_sync_add_pair checkpoint-guard-proof scripts/lib/checkpoint-guard-proof.sh \
    /usr/local/lib/checkpoint-guard-proof.sh exact repo
  # checkpoint-guard drives QMP through labqmp, so labqmp has to reach the box too:
  # the guard runs on labhost (the station qmp.sock files are root-only there).
  box_sync_add_pair labqmp scripts/lib/labqmp.py /usr/local/lib/labqmp.py exact repo
  # The healer behind chroot-guard: restores host API mounts a rogue teardown
  # stripped (2026-08-10 /dev/pts, 2026-08-17 securityfs). Script + timer-driven
  # oneshot unit, installed live on labhost.
  box_sync_add_pair mount-sentinel scripts/host/mount-sentinel.sh /usr/local/bin/mount-sentinel exact repo
  box_sync_add_pair mount-sentinel-unit scripts/host/mount-sentinel.service /etc/systemd/system/mount-sentinel.service exact repo daemon-reload
  box_sync_add_pair mount-sentinel-timer scripts/host/mount-sentinel.timer /etc/systemd/system/mount-sentinel.timer exact repo daemon-reload
  box_sync_add_pair gen-tiles-json scripts/gen_tiles_json.py /root/gen_tiles_json.py exact repo
  # gen-local-ca.sh deploys with the operator's real hostname substituted in
  # (discovered 2026-08-11 when the writer's reverse-scrub check refused the
  # row): scrub, not exact, or a push writes a placeholder over it.
  # deploy_hint.py added 2026-08-31 AND THE OMISSION WAS CAUGHT ONE COMMAND
  # BEFORE IT SHIPPED: this list is static, and osgallery-https-server.py IMPORTS
  # deploy_hint at module scope. Deploying the importer without the imported file
  # does not drift — it stops the serving plane from starting at all, which is a
  # worse failure than the one the tree loop below was introduced to prevent.
  # Every new top-level serve module must be added here, and the fact that it
  # must be is the weakness: see the tree loop for auth/authui/walkin and the
  # reason it exists.
  for name in clientcmd.sh osgallery-https-server.py reset-tile.sh install-https-service.sh \
    config.py static_files.py webrtc.py clientlog.py clientcmd.py restore.py signal_route.py \
    usage.py walkin_plane.py deploy_hint.py analytics.py probes.py linecov.py telemetry_routes.py telemetry_stores.py eum_proxy.py traces.py traces_schema.py traces_policy.py traces_otlp.py otlp_resource.py otlp_semconv.py telemetry_paths.py tracecontext.py \
    tracing.py tracing_http.py \
    logs.py logs_schema.py logs_otlp.py logs_read.py logsink.py \
    vitals.py vitals_schema.py vitals_otlp.py vitals_read.py; do
    box_sync_add_pair "serve/$name" "scripts/serve/$name" "$BOX_ROOT/serve/$name" exact repo
  done
  box_sync_add_pair serve/gen-local-ca.sh scripts/serve/gen-local-ca.sh "$BOX_ROOT/serve/gen-local-ca.sh" scrub repo
  # The rest of the deployed serving plane. These were live on labhost with NO
  # pair for months, so a drifted copy was invisible: check-stream-tickets.py and
  # pen-trace.py are both named in AGENTS.md's debugging table as the thing you
  # run when a station will not connect or a pen feels wrong, reset-auth.sh is the
  # guarded path for the account database that must never be rm'd, and the
  # requirements pair is what decides whether the labhost venv matches the repo.
  for name in check-stream-tickets.py pen-trace.py key-trace.py reset-auth.sh \
    sync-venv.sh test-clientlog.sh requirements.in requirements.txt; do
    box_sync_add_pair "serve/$name" "scripts/serve/$name" "$BOX_ROOT/serve/$name" exact repo
  done
  # The auth plane (session gate, passkeys, tickets, and its UI), as a TREE
  # rather than a name list: this is the security-relevant half of the public
  # gallery, and a static list is exactly how a newly added file escapes the
  # gate. Anything git tracks here is mirrored and therefore checked.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    box_sync_add_pair "serve/${rel#scripts/serve/}" "$rel" "$BOX_ROOT/serve/${rel#scripts/serve/}" exact repo
  done < <(git -C "$REPO" ls-files 'scripts/serve/auth/*' 'scripts/serve/authui/*' 'scripts/serve/walkin/*' | sort)
  # The manifest the UI fetches at runtime to build the grid. It had no pair,
  # which meant a deployed manifest could differ from the generated one and
  # nothing would say so — and on 2026-08-10 exactly that was done on purpose,
  # to hide one station from the grid during a measurement campaign. A
  # deliberate override is fine; an INVISIBLE one is not, so it is a pair and
  # shows as DIFFERS until the override is reverted.
  #
  # The repo side of all four runtime documents is RENDERED, not committed
  # (stations-registry.py rendered()), so render them here: each pair then compares
  # the deployed bytes against what the registry says right now, which is the
  # only comparison worth making.
  python3 "$REPO/scripts/stations-registry.py" render --out "$REPO/build/registry" >/dev/null ||
    {
      echo "box-sync: render failed (registry does not validate)" >&2
      return 1
    }
  box_sync_add_pair serve/webroot/gallery-manifest.json \
    build/registry/gallery-manifest.json \
    "$BOX_ROOT/serve/webroot/gallery-manifest.json" exact repo
  box_sync_add_pair serve/webroot/poster-docs.json \
    build/registry/poster-docs.json \
    "$BOX_ROOT/serve/webroot/poster-docs.json" exact repo
  # The live signaling registry and golden manifest are rendered from the
  # registry too. They stay box-AUTHORITATIVE so the push path keeps refusing
  # them: a live SIGNAL_CONFIG and the reset allow-list are replaced by
  # `serve-https-spa.sh manifests`, deliberately and atomically, never as a
  # side effect of a file sync.
  box_sync_add_pair serve/tiles.json build/registry/tiles.json "$BOX_ROOT/serve/tiles.json" exact box
  box_sync_add_pair serve/golden-manifest.json build/registry/golden-manifest.json "$BOX_ROOT/serve/golden-manifest.json" exact box
  # The serving plane is deployed WITH the operator's real host/gallery names
  # substituted in (scripts/serve/restart-https.sh's SIGNAL_HOST default and the
  # unit's SIGNAL_HOST/PUBLIC_HOST Environment= lines), so these three compare
  # against the reverse-scrubbed box copy — and are written through the forward
  # substitution, never verbatim.
  box_sync_add_pair serve/restart-https.sh scripts/serve/restart-https.sh "$BOX_ROOT/serve/restart-https.sh" scrub repo
  box_sync_add_pair serve/osgallery-https.service scripts/serve/osgallery-https.service "$BOX_ROOT/serve/osgallery-https.service" scrub repo
  # The HTTPS server's systemd supervisor: repo source must also match the INSTALLED
  # unit (what actually runs + auto-starts on boot), like the streamhost/amiga units.
  box_sync_add_pair osgallery-https-unit scripts/serve/osgallery-https.service /etc/systemd/system/osgallery-https.service scrub repo daemon-reload
  box_sync_add_pair vm-idle-watch scripts/vm-idle-watch.sh "$BOX_ROOT/serve/vm-idle-watch.sh" exact repo
  # The observability carriers, on timers since 2026-09-01. Both were hand-run
  # for their whole lives, so every Instana view they feed was stale by default.
  # Only the UNITS are paired: both scripts import from the checkout
  # (scripts/serve/traces.py, registry/local.env), so the units run them out of
  # /data/kernel-hive rather than from a copy that could not resolve its own
  # imports. Landing these installs the units; ENABLING them is the operator's
  # decision — docs/lab/INSTANA-VIEW-INVENTORY.md §2.
  box_sync_add_pair kh-instana-forward-unit scripts/observability/kh-instana-forward.service /etc/systemd/system/kh-instana-forward.service exact repo daemon-reload
  box_sync_add_pair kh-instana-forward-timer scripts/observability/kh-instana-forward.timer /etc/systemd/system/kh-instana-forward.timer exact repo daemon-reload
  # The VITALS leg is a THIRD carrier and a third pair, not a flag on the first,
  # because its cadence is different by two orders of magnitude: Instana stamps
  # metric points at INGEST, so the tick period IS the resolution in the tenant
  # and a five-minute batch of five-second samples would land as one instant.
  # 10 s; the whole argument is in scripts/observability/instana_vitals.py.
  box_sync_add_pair kh-instana-vitals-unit scripts/observability/kh-instana-vitals.service /etc/systemd/system/kh-instana-vitals.service exact repo daemon-reload
  box_sync_add_pair kh-instana-vitals-timer scripts/observability/kh-instana-vitals.timer /etc/systemd/system/kh-instana-vitals.timer exact repo daemon-reload
  box_sync_add_pair kh-trace-ship-unit scripts/observability/kh-trace-ship.service /etc/systemd/system/kh-trace-ship.service exact repo daemon-reload
  box_sync_add_pair kh-trace-ship-timer scripts/observability/kh-trace-ship.timer /etc/systemd/system/kh-trace-ship.timer exact repo daemon-reload
  box_sync_add_pair solaris-cdrv streamhost/guest-agents/solaris/cdrv.py /root/cdrv.py exact repo
  box_sync_add_pair solaris-gexec streamhost/guest-agents/solaris/gexec.py /root/gexec.py exact repo
  box_sync_add_pair irix-irixexec streamhost/guest-agents/irix/irixexec.py /root/irixexec.py exact repo
  box_sync_add_pair irix-mctl streamhost/guest-agents/irix/mctl.py /root/mctl.py exact repo
  box_sync_add_pair sunos414-sunexec streamhost/guest-agents/sunos414/sunexec.py /root/sunexec.py exact repo
  box_sync_add_pair newsos-exec streamhost/guest-agents/newsos/newsosexec.py /root/newsosexec.py exact repo
  box_sync_add_pair qmp-hmp scripts/qmp_hmp.py /root/qmp_hmp.py exact repo
  box_sync_add_pair shmshot scripts/shmshot.py /root/shmshot.py exact repo
  # Deployed with a real address baked in (same 2026-08-11 discovery as
  # serve/gen-local-ca.sh): scrub keeps the live value on push.
  box_sync_add_pair mobile-netem scripts/dev/mobile-netem.sh /usr/local/bin/mobile-netem scrub repo
  box_sync_add_pair amiga-coldboot-watch scripts/coldboot/amiga-coldboot-watch.sh /usr/local/bin/amiga-coldboot-watch.sh exact repo
  box_sync_add_pair streamhost-unit streamhost/deploy/streamhost@.service /etc/systemd/system/streamhost@.service exact repo daemon-reload
  box_sync_add_pair amiga-coldboot-unit streamhost/deploy/amiga-coldboot-watch.service /etc/systemd/system/amiga-coldboot-watch.service exact repo daemon-reload
  # openvms is the one station whose ExecStartPre boots a second VM (its Debian
  # Xorg bridge) before the guest, so it needs a longer start backstop than the
  # shared template gives every other station. Per-instance drop-in rather than
  # a template edit; the reasoning is in the .conf itself.
  box_sync_add_pair openvms-start-timeout streamhost/deploy/streamhost@openvms.service.d/start-timeout.conf /etc/systemd/system/streamhost@openvms.service.d/start-timeout.conf exact repo daemon-reload
  box_sync_add_pair sailfish-seriald-unit streamhost/deploy/seriald-sailfishos.service /etc/systemd/system/seriald-sailfishos.service exact repo daemon-reload
  box_sync_add_pair sailfish-seriald streamhost/stations/sailfishos/seriald.py "$BOX_ROOT/stations/sailfishos/seriald.py" exact repo
  # Per-station network-link helper pairs live in their own file — this one hit
  # the 600-line hard cap. See box-sync-pairs-retronet.sh.
  # shellcheck source=scripts/lib/box-sync-pairs-retronet.sh
  . "$(dirname "${BASH_SOURCE[0]}")/box-sync-pairs-retronet.sh"
  box_sync_add_retronet_pairs
  # nextstep's retronet VETH lifecycle helper. Box-authored mirror pair like the
  # rn-tapnet helpers above. Unlike every other one it creates a private netns as
  # well as the link, because this station is host-native Previous and has to stay
  # CRIU-checkpointable — criu can dump a veth it is told about and cannot dump a
  # foreign tap fd at all. It is also where the pcap checksum-offload fix lives,
  # without which the guest silently drops every TCP segment labhost sends it. See
  # docs/lab/retronet/WEB-STATION-nextstep.md.
  box_sync_add_pair nextstep-rn-tapnet streamhost/stations/nextstep/rn-tapnet.sh "$BOX_ROOT/stations/nextstep/rn-tapnet.sh" exact repo
  # …and the station's own launcher and control-socket client. The launcher rides
  # the emit as --x11-runtime-file and ctl.py as an --aux-file, but an aux file
  # only lands on a RE-EMIT, and both of these are on the reset path: a fix to
  # either has to reach the box on a plain box-deploy, the way tru64's and
  # w2kalpha's do.
  box_sync_add_pair nextstep-x11-runtime streamhost/stations/nextstep/x11-runtime.sh "$BOX_ROOT/stations/nextstep/x11-runtime.sh" exact repo
  box_sync_add_pair nextstep-ctl streamhost/stations/nextstep/ctl.py "$BOX_ROOT/stations/nextstep/ctl.py" exact repo
  # tru64's CDE Xsession.d ICQ fixture. This box copy is the REFERENCE copy; the
  # live one is baked onto the guest's own disk at
  # /etc/dt/config/Xsession.d/9999.icq-fixture and only runs on a cold boot.
  # Tracking it here keeps the reference from claiming the station still runs
  # climm after the Gaim swap.
  box_sync_add_pair tru64-icq-fixture streamhost/stations/tru64/9999.icq-fixture "$BOX_ROOT/stations/tru64/9999.icq-fixture" exact repo
  # beos retronet: its bridge-tap lifecycle helper, plus the two files that live
  # INSIDE the guest and whose box copies are the REFERENCE copies (the live ones
  # are baked onto the guest's own BFS disk, so they only change on a golden
  # re-bake). beos's rn-tapnet.sh was never in this list, so its box copy could
  # drift silently the way tru64's did. UserBootscript is the ready scene;
  # icbm-watchdog.sh is what keeps ICBM signed on to the gateway -- ICBM .71 has
  # no auto-reconnect of its own. See docs/lab/retronet/STATION-beos.md.
  box_sync_add_pair beos-rn-tapnet streamhost/stations/beos/rn-tapnet.sh "$BOX_ROOT/stations/beos/rn-tapnet.sh" exact repo
  box_sync_add_pair beos-bootscript streamhost/stations/beos/UserBootscript "$BOX_ROOT/stations/beos/UserBootscript" exact repo
  box_sync_add_pair beos-icbm-watchdog streamhost/stations/beos/icbm-watchdog.sh "$BOX_ROOT/stations/beos/icbm-watchdog.sh" exact repo
  # win98se ICQ presence healer (labhost): a timer nudges the persona's golden
  # BOS socket so ICQ reconnects after every reset/wake (ICQ 2000b will not on
  # its own). See docs/lab/retronet/ICQ-STATION.md §reconnect.
  box_sync_add_pair win98se-icq-nudge scripts/retronet/win98se-icq-nudge.py /usr/local/sbin/win98se-icq-nudge.py exact repo
  box_sync_add_pair win98se-icq-nudge-unit scripts/retronet/win98se-icq-nudge.service /etc/systemd/system/win98se-icq-nudge.service exact repo daemon-reload
  box_sync_add_pair win98se-icq-nudge-timer scripts/retronet/win98se-icq-nudge.timer /etc/systemd/system/win98se-icq-nudge.timer exact repo daemon-reload
  # nt4 retronet: its bridge-tap lifecycle helper and its own ICQ presence healer
  # (guest 10.99.0.12, persona 40000). See docs/lab/retronet/ICQ-STATION-NT4.md.
  box_sync_add_pair nt4-rn-tapnet streamhost/stations/nt4/rn-tapnet.sh "$BOX_ROOT/stations/nt4/rn-tapnet.sh" exact repo
  box_sync_add_pair nt4-icq-nudge scripts/retronet/nt4-icq-nudge.py /usr/local/sbin/nt4-icq-nudge.py exact repo
  box_sync_add_pair nt4-icq-nudge-unit scripts/retronet/nt4-icq-nudge.service /etc/systemd/system/nt4-icq-nudge.service exact repo daemon-reload
  box_sync_add_pair nt4-icq-nudge-timer scripts/retronet/nt4-icq-nudge.timer /etc/systemd/system/nt4-icq-nudge.timer exact repo daemon-reload
  # win2000 retronet: same shape as win98se — its bridge-tap lifecycle helper and
  # its own ICQ presence healer (the timer/nudge is per-station, targeting the
  # win2000 guest IP + its golden ICQ port). See docs/lab/retronet/ICQ-STATION-win2000.md.
  box_sync_add_pair win2000-rn-tapnet streamhost/stations/win2000/rn-tapnet.sh "$BOX_ROOT/stations/win2000/rn-tapnet.sh" exact repo
  box_sync_add_pair win2000-icq-nudge scripts/retronet/win2000-icq-nudge.py /usr/local/sbin/win2000-icq-nudge.py exact repo
  box_sync_add_pair win2000-icq-nudge-unit scripts/retronet/win2000-icq-nudge.service /etc/systemd/system/win2000-icq-nudge.service exact repo daemon-reload
  box_sync_add_pair win2000-icq-nudge-timer scripts/retronet/win2000-icq-nudge.timer /etc/systemd/system/win2000-icq-nudge.timer exact repo daemon-reload
  # hpuxvue retronet web plane: bridge-tap lifecycle helper only (no ICQ persona,
  # no exec channel on this station). Same mirror pair as the helpers above.
  # See docs/lab/retronet/WEB-STATION-hpuxvue.md.
  box_sync_add_pair hpuxvue-rn-tapnet streamhost/stations/hpuxvue/rn-tapnet.sh "$BOX_ROOT/stations/hpuxvue/rn-tapnet.sh" exact repo

  # os2warp retronet WEB plane: its bridge-tap lifecycle helper, same mirror-pair
  # shape as win98se's above. No ICQ nudge — os2warp is a web-only retronet
  # station (no chat client). See docs/lab/retronet/WEB-STATION-os2warp.md.
  box_sync_add_pair os2warp-rn-tapnet streamhost/stations/os2warp/rn-tapnet.sh "$BOX_ROOT/stations/os2warp/rn-tapnet.sh" exact repo

  # pcbsd retronet WEB + ICQ planes: same mirror-pair shape. PC-BSD 1.5.1 browses
  # the corpus with Konqueror 3.5.8 and signs into the OSCAR gateway with Kopete
  # 0.12.7 (UIN 17900) over tap pcbsdrn0. Without this pair the launcher dies at
  # `bash "$B/rn-tapnet.sh" up`. See docs/lab/retronet/STATION-pcbsd.md.
  box_sync_add_pair pcbsd-rn-tapnet streamhost/stations/pcbsd/rn-tapnet.sh "$BOX_ROOT/stations/pcbsd/rn-tapnet.sh" exact repo

  # rhapsody retronet WEB plane: same mirror-pair shape again. The generic
  # launcher sweep carries qemu-streamhost.sh, but NOT the helper it calls, so
  # without this pair the box checkout has rn-tapnet.sh and the station dir does
  # not — and the launcher dies at `bash "$B/rn-tapnet.sh" up` with "No such file
  # or directory", i.e. the station cannot start at all. Web-only (no ICQ
  # persona: DR2 has no OSCAR client). See docs/lab/retronet/WEB-STATION-rhapsody.md.
  box_sync_add_pair rhapsody-rn-tapnet streamhost/stations/rhapsody/rn-tapnet.sh "$BOX_ROOT/stations/rhapsody/rn-tapnet.sh" exact repo

  # macos753 retronet WEB plane: the same mirror pair, for the same reason as the
  # three above — the launcher's FIRST action is `bash "$D/rn-tapnet.sh" up`, so
  # without this pair the station cannot start at all. This guest is Mac OS 7.5.3
  # on the q800's built-in dp83932 SONIC, statically addressed via MacTCP (which
  # has no DHCP client) on 10.99.0.23. Web-only: ICQ is out of scope for this
  # station. See docs/lab/retronet/WEB-STATION-macos753.md.
  box_sync_add_pair macos753-rn-tapnet streamhost/stations/macos753/rn-tapnet.sh "$BOX_ROOT/stations/macos753/rn-tapnet.sh" exact repo

  # irix retronet WEB plane, and the first rn-tapnet on an x11-RUNTIME station.
  # irix is not QEMU: its helpers normally travel as emit `--aux-file`s from the
  # registry (tapnet.sh does, and has no pair here), so this pair is not the
  # launcher-cannot-start guarantee it is for the seven above — the emit already
  # places the file. It is here because it is the LEDGER's requirement
  # (stations_registry/validate_retronet.py fails any station shipping an
  # rn-tapnet.sh without one) and because pinning the box copy `exact repo`
  # catches a hand-edit on the box that the emit would otherwise quietly
  # reinstate only on the next re-emit. Both paths write the same repo bytes.
  # This guest is IRIX 6.5 in MAME on the Indy's SEEQ 80C03, statically
  # addressed in-guest on 10.99.0.24. Web-only: no OSCAR client is built for
  # IRIX yet. See docs/lab/retronet/WEB-STATION-irix.md.
  box_sync_add_pair irix-rn-tapnet streamhost/stations/irix/rn-tapnet.sh "$BOX_ROOT/stations/irix/rn-tapnet.sh" exact repo

  # The live labctl matrix is harvested into the committed reference sample:
  # `labctl gen` writes the labhost copy, so labhost is the source of truth.
  box_sync_add_pair tiles-json scripts/tiles.json.sample "$BOX_ROOT/tiles.json" exact box

  # build-deploy.sh's workspace/source mirror, expanded file-by-file. AGENTS.md
  # "Building": edit locally -> rsync to box -> cargo build there. Repo source.
  box_sync_add_pair streamhost/Cargo.toml streamhost/Cargo.toml "$BOX_ROOT/build/Cargo.toml" exact repo
  box_sync_add_pair streamhost/Cargo.lock streamhost/Cargo.lock "$BOX_ROOT/build/Cargo.lock" exact repo
  box_sync_add_pair streamhost/member-Cargo.toml streamhost/streamhost/Cargo.toml "$BOX_ROOT/build/streamhost/Cargo.toml" exact repo
  git -C "$REPO" ls-files 'streamhost/streamhost/src/**' |
    sed 's#^streamhost/streamhost/src/##' | sort >"$tmpdir/src-repo"
  box_sync_remote "$LAB" \
    "find '$BOX_ROOT/build/streamhost/src' -type f -name '*.rs' -printf '%P\\n' | sort" \
    >"$tmpdir/src-box"
  sort -u "$tmpdir/src-repo" "$tmpdir/src-box" >"$tmpdir/src-union"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    box_sync_add_pair "src/$rel" "streamhost/streamhost/src/$rel" "$BOX_ROOT/build/streamhost/src/$rel" exact repo
  done <"$tmpdir/src-union"

  # Only verbatim, tracked launchers of LIVE stations are box-authored mirror pairs.
  # Generic launchers are checked by verify-emit.sh; the tracked soltest-*
  # launchers are clone/experiment scaffolds that run out of /data/vms/sandbox/,
  # never out of $BOX_ROOT/stations, so they have no box counterpart by design.
  while IFS= read -r path; do
    rel="${path#streamhost/stations/}"
    case "$rel" in soltest-*) continue ;; esac
    box_sync_add_pair "launcher/$rel" "$path" "$BOX_ROOT/stations/$rel" exact repo
  done < <(git -C "$REPO" ls-files 'streamhost/stations/*/qemu-streamhost.sh' | sort)

  # Registry tree union: box-only and repo-only allowed files must be visible as
  # MISSING rather than silently omitted. "Allowed source files" is the same
  # filter on BOTH sides (README.md, *.json, *.in, minus registry/posters/) — the
  # poster prose and its image-candidate research feed the UI build only, and the
  # gitignored local.env is operator-local; neither is part of the labhost mirror.
  git -C "$REPO" ls-files 'registry/**' | sed 's#^registry/##' |
    grep -E '(^|/)README\.md$|\.json$|\.in$' | grep -v '^posters/' | sort >"$tmpdir/registry-repo"
  box_sync_remote "$LAB" \
    "find '$BOX_ROOT/build/registry' -path '$BOX_ROOT/build/registry/posters' -prune -o -type f \\( -name README.md -o -name '*.json' -o -name '*.in' \\) -printf '%P\\n' | sort" \
    >"$tmpdir/registry-box"
  sort -u "$tmpdir/registry-repo" "$tmpdir/registry-box" >"$tmpdir/registry-union"
  # bring-up-all.sh.in renders the ordered boot script, which carries the
  # operator's real address — so its DEPLOYED copy holds a real value and the
  # row is scrub, not exact (discovered 2026-08-12 when the writer's
  # reverse-scrub check refused it). Everything else in the tree is verbatim.
  local mode
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      templates/bring-up-all.sh.in) mode=scrub ;;
      *) mode=exact ;;
    esac
    box_sync_add_pair "registry/$rel" "registry/$rel" "$BOX_ROOT/build/registry/$rel" "$mode" repo
  done <"$tmpdir/registry-union"
}

# --- darklaunch overlays ----------------------------------------------------
# A darklaunch is a DECLARED, additive, box-side deployment divergence: a rig
# (typically working out of a git worktree) exposes extra rows in a deployed,
# mirrored JSON document without committing them, and declares exactly what it
# added in $BOX_ROOT/serve/darklaunch.d/<name>.json:
#
#   { "darklaunch": "<name>", "owner": "<the tool that wrote it>",
#     "files": { "<box-absolute path>":
#                  { "kind": "json-object-keys" | "json-entries",
#                    "ids": ["row-id", ...] } } }
#
# The gate compares the labhost copy WITH THE DECLARED IDS REMOVED against the repo
# copy, both reduced to one canonical JSON form: the declared rows become
# invisible, and any OTHER divergence in the same file still fails. The
# declaration is the claim and the filtered hash is the proof — a declaration
# whose ids the file does not carry is STALE and fails the gate, exactly like a
# stale size-exclusion (a one-way ledger rots).
#
# Kinds: json-object-keys removes top-level object keys (serve/tiles.json);
# json-entries removes doc["entries"] rows by their "id" (gallery-manifest).
# Declarations on scrub-mode pairs are unsupported and ignored; a declared path
# that is not a mirror pair has no effect (it hides nothing — the path was
# never gated). File CONTENTS never travel in this pass — only paths,
# declaration names, hashes and a found-ids count.
declare -A BOX_SYNC_DL_NAMES=() BOX_SYNC_DL_MD5=() BOX_SYNC_DL_FOUND=()

# The remote half: line 1 of stdin is the darklaunch.d directory; each output
# row is `path<TAB>names<TAB>filtered-canonical-md5<TAB>ids-found`, with the
# md5 column carrying ERROR:<why> when the declaration cannot be proven. The
# canonical form MUST stay byte-identical to box_sync_canon_json_md5 below —
# the two halves only ever meet as hashes.
# shellcheck disable=SC2016  # REMOTE script; $vars must reach labhost unexpanded
BOX_SYNC_REMOTE_DARKLAUNCH='
IFS= read -r DLDIR
export DLDIR
python3 - <<"PYEOF"
import glob, hashlib, json, os

merged = {}
for decl_path in sorted(glob.glob(os.path.join(os.environ["DLDIR"], "*.json"))):
    try:
        with open(decl_path) as fh:
            decl = json.load(fh)
        name, files = decl["darklaunch"], decl["files"]
    except (OSError, ValueError, KeyError) as exc:
        print(f"{decl_path}\t?\tERROR:unreadable declaration ({exc})\t0")
        continue
    for path, spec in files.items():
        e = merged.setdefault(path, {"names": set(), "kinds": set(), "ids": set()})
        e["names"].add(str(name))
        e["kinds"].add(spec.get("kind", "?"))
        e["ids"].update(spec.get("ids", []))
for path, e in sorted(merged.items()):
    names = ",".join(sorted(e["names"]))
    if len(e["kinds"]) != 1 or e["kinds"] - {"json-object-keys", "json-entries"}:
        print(f"{path}\t{names}\tERROR:unknown or conflicting kind\t0")
        continue
    kind = e["kinds"].pop()
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except OSError:
        print(f"{path}\t{names}\tERROR:file absent on box\t0")
        continue
    except ValueError as exc:
        print(f"{path}\t{names}\tERROR:unparseable JSON ({exc})\t0")
        continue
    ids = e["ids"]
    if kind == "json-object-keys":
        if not isinstance(doc, dict):
            print(f"{path}\t{names}\tERROR:not a JSON object\t0")
            continue
        nfound = sum(1 for i in ids if i in doc)
        for i in ids:
            doc.pop(i, None)
    else:
        ents = doc.get("entries") if isinstance(doc, dict) else None
        if not isinstance(ents, list):
            print(f"{path}\t{names}\tERROR:no entries list\t0")
            continue
        nfound = sum(1 for x in ents if isinstance(x, dict) and x.get("id") in ids)
        doc["entries"] = [x for x in ents if not (isinstance(x, dict) and x.get("id") in ids)]
    blob = json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    print(f"{path}\t{names}\t{hashlib.md5(blob).hexdigest()}\t{nfound}")
PYEOF
'

# The local half of the proof: canonical-JSON md5 of a repo file. The dumps()
# arguments MUST stay identical to the remote pass above. Failure modes return
# sentinels that can never equal a real hash, so they fail closed as DIFFERS.
box_sync_canon_json_md5() { # <file> -> md5, or a sentinel matching nothing
  [ -f "$1" ] || {
    printf 'MISSING\n'
    return 0
  }
  command -v python3 >/dev/null 2>&1 || {
    printf 'NO-PYTHON3\n'
    return 0
  }
  python3 - "$1" <<'PYEOF' 2>/dev/null || printf 'UNPARSEABLE\n'
import hashlib, json, sys
with open(sys.argv[1]) as fh:
    doc = json.load(fh)
blob = json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.md5(blob).hexdigest())
PYEOF
}

# box_sync_darklaunch_load <lab> <box-root>
# One short ssh; fills the three maps, keyed by box-absolute path. An absent or
# empty darklaunch.d yields empty maps. On ssh failure the maps stay empty and
# every declared row degrades to DIFFERS — fail closed, never fail invisible.
box_sync_darklaunch_load() {
  local lab="$1" box_root="$2" path names md5 nfound
  BOX_SYNC_DL_NAMES=() BOX_SYNC_DL_MD5=() BOX_SYNC_DL_FOUND=()
  while IFS=$'\t' read -r path names md5 nfound; do
    [ -n "$path" ] || continue
    BOX_SYNC_DL_NAMES["$path"]="$names"
    BOX_SYNC_DL_MD5["$path"]="$md5"
    BOX_SYNC_DL_FOUND["$path"]="${nfound:-0}"
  done < <(printf '%s\n' "$box_root/serve/darklaunch.d" |
    box_sync_remote "$lab" "$BOX_SYNC_REMOTE_DARKLAUNCH")
}

# --- the one batched remote hash pass --------------------------------------
# stdin: line 1 = the reverse-scrub sed program (possibly empty), then one
# `mode<TAB>path` line per pair. Paths are fixed by the table above or by the
# restricted find output; file contents are never printed. The program travels
# on stdin so the operator's real values stay out of argv, out of local files,
# and out of the output.
# shellcheck disable=SC2016  # this is the REMOTE script; $vars must reach the box unexpanded
BOX_SYNC_REMOTE_HASH='
IFS= read -r SEDPROG
while IFS="	" read -r mode path; do
  if [ ! -f "$path" ]; then printf "MISSING\n"; continue; fi
  if [ "$mode" = scrub ] && [ -n "$SEDPROG" ]; then
    sed -e "$SEDPROG" -- "$path" | md5sum | awk "{print \$1}"
  else
    md5sum -- "$path" | awk "{print \$1}"
  fi
done
'
