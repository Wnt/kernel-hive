"""The station-facts checks that need the live box, probe-gated so CI stays green.

`validate_facts` compares two things that are both in the repo, so it runs
everywhere. The claims here are about the BOX -- whether the interface a
`retronet` block names is really up, on the bridge it names, behind the guard
chain it names -- and those cannot be answered from a checkout.

So this is a SEPARATE command, never part of `make station-registry-check`:
a public clone, an offline laptop and GitHub Actions have no `ssh lab`, and a
check that fails there teaches the next agent to bypass the gate. Exactly
like the pre-push gate's box-state stage, an unreachable box SKIPs loudly and
exits 0; only a reachable box that DISAGREES is a failure.

    python3 scripts/stations-registry.py facts-live

Two facts are read in ONE ssh round trip (`ip -o link show` + `iptables -S`)
and compared locally, so adding stations does not add ssh calls.
"""

from __future__ import annotations

import os
import re
import subprocess
from typing import Any

from .loading import load
from .validate_facts import _declared_links

LAB_PROBE = ("ssh", "-n", "-o", "ConnectTimeout=4", "-o", "BatchMode=yes")
BOX_FACTS = "ip -o link show; echo ---IPTABLES---; iptables -S"


def _lab_host() -> str:
    return os.environ.get("LAB", "lab")


def box_reachable(host: str) -> bool:
    try:
        return subprocess.run([*LAB_PROBE, host, "true"], capture_output=True, timeout=15).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def read_box_facts(host: str) -> tuple[dict[str, str | None], set[str]]:
    """(interface -> its bridge master or None, set of iptables chain names)."""
    out = subprocess.run(
        ["ssh", "-n", "-o", "ConnectTimeout=15", host, BOX_FACTS],
        capture_output=True,
        text=True,
        timeout=90,
        check=True,
    ).stdout
    links_text, _, rules_text = out.partition("---IPTABLES---")
    links: dict[str, str | None] = {}
    for line in links_text.splitlines():
        match = re.match(r"^\d+:\s+([A-Za-z0-9_.-]+)(?:@[A-Za-z0-9_.-]+)?:", line)
        if match:
            master = re.search(r"\bmaster\s+([A-Za-z0-9_.-]+)", line)
            links[match.group(1)] = master.group(1) if master else None
    chains = set(re.findall(r"^-N\s+(\S+)", rules_text, re.M))
    return links, chains


def check_station(row: dict[str, Any], links: dict[str, str | None], chains: set[str]) -> list[str]:
    block = row.get("retronet") or {}
    os_id, problems = row["id"], []
    link_text = block.get("link", "")
    declared = _declared_links(link_text)
    bridge_match = re.search(r"\bon\s+([A-Za-z0-9_.-]+)\s*$", link_text.strip())
    bridge = bridge_match.group(1) if bridge_match else None
    missing = [name for name in declared if name not in links]
    if missing:
        problems.append(
            f"{os_id}: retronet.link names {missing} but the box has no such interface — the ledger "
            f"points at an interface that does not exist. `ssh {_lab_host()} 'ip -o link show'` lists "
            f"what is really there; the station's own streamhost/stations/{os_id}/rn-tapnet.sh creates it."
        )
    elif bridge and not any(links[name] == bridge for name in declared):
        actual = {name: links[name] for name in declared}
        problems.append(
            f"{os_id}: retronet.link says the link is on {bridge!r} but no declared interface is "
            f"enslaved to it on the box (master: {actual}) — the guest is NOT on the bridge the "
            "registry promises, so its containment story is not the one being enforced."
        )
    guard = block.get("guard")
    if guard and guard not in chains:
        problems.append(
            f"{os_id}: retronet.guard names the chain {guard!r} but the box's iptables has no such "
            f"chain — the fail-closed containment the registry claims is NOT installed. "
            f"`ssh {_lab_host()} 'iptables -S'`, then "
            f"`ssh {_lab_host()} 'streamhost/stations/{os_id}/rn-tapnet.sh up'` reinstalls it."
        )
    return problems


def cmd_facts_live() -> int:
    """Compare each `retronet` block against the live box. Unreachable box = SKIP."""
    host = _lab_host()
    print("== station facts (live box) ==")
    if not box_reachable(host):
        print(f"  SKIPPED: ssh {host} unreachable (public clone, offline, or CI)")
        return 0
    try:
        links, chains = read_box_facts(host)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"  SKIPPED: could not read box facts over ssh {host}: {exc}")
        return 0
    _, rows = load()
    stations = [row for row in rows if row.get("retronet")]
    problems: list[str] = []
    for row in stations:
        problems.extend(check_station(row, links, chains))
    if problems:
        print(f"  FAIL — {len(problems)} live disagreement(s) across {len(stations)} retronet station(s):")
        for problem in problems:
            print(f"    - {problem}")
        return 1
    print(f"  ok — {len(stations)} retronet station(s): every declared link, bridge and guard chain is live")
    return 0


def main() -> int:
    return cmd_facts_live()


if __name__ == "__main__":
    raise SystemExit(main())
