#!/bin/bash
# The IRIX / SGI Indy MAME patch stack -- ONE authoritative ordered list.
#
# Source this, do not copy the list. Two build scripts consume it
# (build-mame-irix.sh for the lab box, build-mame-macos.sh for a dev Mac) and
# the whole point is that they cannot drift apart. A stale second copy of this
# list is exactly what left `mame-taptun-ifname-env.patch` documented as
# adopted while the shipped binary did not carry it, and the failure mode there
# was silent: MAME ignores MAME_TAP_IFNAME, opens upstream's global tap, finds
# nothing, and runs on with no networking.
#
# ORDER IS LOAD-BEARING and the dependencies are real, not cosmetic:
#   - mame-newport-shm-framebuffer.patch does NOT apply to a pristine tree. Its
#     hunks quote `m_cache_bitmap` / `m_cache_valid`, which only exist after
#     mame-newport-dirty-frame-cache.patch. Apply the cache first.
#   - mame-indy-256mb-ram.patch and mame-mc-dma-ptbase-mask.patch are a required
#     pair: 256 MB without the DMA page-table-base mask fix panics
#     ("PANIC: bad istack") roughly 9 boots in 12.
#   - mame-pit8253-idle-strobe-rearm.patch and mame-indy-scheduling-quantum.patch
#     are a required pair in the other direction: the PIT fix deletes the timer
#     storm that was the ONLY thing interleaving the CPU with its own keyboard
#     controller, so alone it boots IRIX to a desktop with no keyboard and no
#     mouse. Both go last because both touch files earlier patches also touch.
#
# Each entry is  <patch-file>|<dir to run `patch -p1` in>|<applies-when>
#   applies-when: "all", "x86_64" (host arch gate), or "linux" (host OS gate).
# The ds1386 patch's diff paths are relative to src/devices/machine, which is
# why the strip-dir column exists at all.
#
# DELIBERATELY NOT IN THE STACK:
#   mame-indy-mips3-fastram.patch        BLOCKED. Under the station's real command
#     line (`-ioc2:rs232a pty`) IRIX stops at "Memory diagnostic *FAILED* /
#     Check or replace: SIMM S7" and never reaches the login chooser. The
#     registration defect is diagnosed in docs/guests/irix.md; do not add this
#     back without re-running the bisect table there.
#   mame-newport-vc2-restale-timing.patch  a real MAME inaccuracy, but it was
#     disproven as the cause of the black-screen boot hang and buys nothing.
#   mame-drawshm.patch                   the DRIVER-AGNOSTIC `-video shm` OSD
#     render module. Deliberately out of THIS stack and belongs in every OTHER
#     MAME station's build instead: irix already has the better producer for its
#     own machine (mame-newport-shm-framebuffer.patch publishes from the Newport
#     device, where the whole-frame render cache hands it a damage flag for
#     free, which a render-layer module cannot get). Adding it here would buy
#     the exhibit nothing and cost it a binary rebake. It is freestanding --
#     modules.lua + osdobj_common.cpp + its own new file, none of which any
#     patch above touches -- so it applies to a pristine tree on its own.

IRIX_MAME_BASE="8f21e978d0bd54971145e08ab5fab6c3c3d4ba81"

IRIX_MAME_STACK=(
  "mame-irix-skip-warnings.patch|.|all"
  "mame-indy-256mb-ram.patch|.|all"
  "mame-mc-dma-ptbase-mask.patch|.|all"
  "mame-indy-drc-cache-256mb.patch|.|x86_64"
  # VC2 cursor-swap accounting (issue #45): records the compensating cursor
  # register write X makes when it swaps the cursor GLYPH, which is the only
  # exact expression of a cursor hotspot anywhere in the machine -- the
  # hotspot itself is X server software state and appears in no register.
  # Against a PRISTINE newport.cpp, so it goes before the other newport
  # patches. Adds three save items => CHANGES THE SAVESTATE SIGNATURE and
  # orphans the golden: rebake after adopting it.
  "mame-vc2-cursor-swap.patch|.|all"
  "mame-newport-dirty-frame-cache.patch|.|all"
  "mame-newport-shm-framebuffer.patch|.|all"
  "mame-ds1386-date-from-day.patch|src/devices/machine|all"
  "mame-hle-ps2-mouse-carry.patch|.|all"
  "mame-taptun-ifname-env.patch|.|linux"
  "mame-osd-cache-line-size-memo.patch|.|all"
  "mame-pit8253-idle-strobe-rearm.patch|.|all"
  "mame-indy-scheduling-quantum.patch|.|all"
  "mame-indy-savestate.patch|.|all"
  # mamectl (issue #45): the compiled-in guest-control module (unix socket,
  # mamectl/1). FREESTANDING by design — it touches only files no other patch
  # in this stack touches (modules.lua, osdobj_common.cpp, save.cpp, plus its
  # own new src/osd/modules/ctlsock/), so it dry-run-applies on a pristine
  # tree and any future MAME station inherits it by adding this one line. Goes
  # LAST so the 13 station-specific patches above never have to rebase over it.
  # NOTE: the module allocates one persistent timer UNCONDITIONALLY (9 save
  # entries) — adding or dropping this patch changes the savestate signature
  # and orphans the golden: rebake via scripts/coldboot/irix-record-boot.sh.
  "mame-ctlsock.patch|.|all"
)

# irix_mame_apply <tree-dir> <patch-dir>
#
# Dry-runs each patch IMMEDIATELY BEFORE applying it, never all-then-all: the
# stack is dependent, so a dry-run of the whole list against the unpatched tree
# reports failures that are not real (and, worse, would pass patches that only
# apply because an earlier one has not landed yet).
irix_mame_apply() {
  local tree="$1" patches="$2" entry file dir when
  local arch os
  arch="$(uname -m)"
  os="$(uname -s)"
  for entry in "${IRIX_MAME_STACK[@]}"; do
    file="${entry%%|*}"
    dir="${entry#*|}"
    dir="${dir%%|*}"
    when="${entry##*|}"
    if [ "$when" = "x86_64" ] && [ "$arch" != "x86_64" ]; then
      # AArch64's B reaches only +/-128 MB, so a 256 MB DRC code cache can put
      # two blocks further apart than a branch can encode and MAME dies with
      # "asmjit error 48: InvalidDisplacement" seconds into the IRIX boot.
      echo "  skipped $file (host is $arch, not x86_64)"
      continue
    fi
    if [ "$when" = "linux" ] && [ "$os" != "Linux" ]; then
      echo "  skipped $file (host is $os; the tap provider is Linux-only)"
      continue
    fi
    [ -f "$patches/$file" ] || {
      echo "missing patch: $patches/$file" >&2
      return 1
    }
    if ! patch -p1 -d "$tree/$dir" --dry-run -f <"$patches/$file" >/dev/null 2>&1; then
      echo "  FAILED to apply $file -- aborting rather than leaving a half-patched tree" >&2
      return 1
    fi
    patch -p1 -d "$tree/$dir" -f <"$patches/$file" >/dev/null
    echo "  applied $file${dir:+  (in $dir)}"
  done
}
