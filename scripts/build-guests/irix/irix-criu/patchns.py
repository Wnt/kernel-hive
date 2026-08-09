#!/usr/bin/env python3
"""Apply the four CRIU deltas to a COPY of the production IRIX tile launcher.

    patchns.py <copy-of-x11-runtime.sh>

The live tile's `streamhost/tiles/irix/x11-runtime.sh` is NOT checkpointable as
shipped, for four independent reasons. Each hunk below fixes exactly one, and
each asserts its anchor is present exactly once, so a launcher that has moved on
fails loudly here instead of producing a subtly different runtime.

Never run this against the tile's own launcher — copy it first.

Hunks 1-3 are inert unless IRIX_NETNS is set, so a patched copy still behaves
exactly like production when run without it.
"""

import sys

HUNKS = [
    (
        # 1. The netns owner (nsnet.sh) created the tap; tapnet.sh must not also
        #    try to, and must not install a second, conflicting rule set.
        '  IRIX_NET_EGRESS="$NET_EGRESS" bash "$TAPNET" up "$TAP_IF" "$TAP_HOST_CIDR" "$TAP_GUEST_IP" || return 1',
        '  if [ -n "${IRIX_NETNS:-}" ]; then\n'
        '    ip -n "$IRIX_NETNS" link show "$TAP_IF" >/dev/null 2>&1 || {\n'
        '      echo "FATAL: IRIX_NETNS=$IRIX_NETNS has no $TAP_IF" >&2\n'
        "      return 1\n"
        "    }\n"
        "  else\n"
        '    IRIX_NET_EGRESS="$NET_EGRESS" bash "$TAPNET" up "$TAP_IF" '
        '"$TAP_HOST_CIDR" "$TAP_GUEST_IP" || return 1\n'
        "  fi",
    ),
    (
        # 2. Run MAME inside the netns. `nsenter --net=` ONLY: `ip netns exec`
        #    also unshares the mount namespace and dies on this host's /etc/pve.
        '  [ -n "${IRIX_CPUS:-}" ] && pin=(taskset -c "$IRIX_CPUS")',
        '  [ -n "${IRIX_CPUS:-}" ] && pin=(taskset -c "$IRIX_CPUS")\n'
        '  [ -n "${IRIX_NETNS:-}" ] && pin=(nsenter --net=/run/netns/"$IRIX_NETNS" "${pin[@]}")',
    ),
    (
        # 3. The carrier observation has to look inside the netns, or the
        #    launcher warns that MAME did not attach while it is attached.
        '    if [ "$(cat "/sys/class/net/$TAP_IF/carrier" 2>/dev/null || echo 0)" = 1 ]; then',
        '    if [ "$(ip ${IRIX_NETNS:+-n "$IRIX_NETNS"} -o link show "$TAP_IF" '
        '2>/dev/null | grep -c LOWER_UP)" != 0 ]; then',
    ),
    (
        # 4. MAME opens /dev/snd/seq through its MIDI provider EVEN WITH
        #    `-sound none`, and criu cannot dump that fd. `--external dev[116/1]`
        #    does NOT rescue an already-open fd — the provider must never open
        #    it. This hunk is the one that is NOT conditional: it changes the
        #    shipped command line, which is why the CRIU launcher is a copy.
        '    -skip_gameinfo "${vid[@]}" -sound none \\',
        '    -skip_gameinfo "${vid[@]}" -sound none -midiprovider none \\',
    ),
]


def main() -> int:
    path = sys.argv[1]
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for i, (old, new) in enumerate(HUNKS, 1):
        count = text.count(old)
        if count != 1:
            print(f"hunk {i}: anchor found {count} times, expected 1", file=sys.stderr)
            return 1
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"patched {len(HUNKS)} hunks in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
