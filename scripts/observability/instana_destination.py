"""Which of the two Instana doors `instana-forward.py` talks to, and why.

Split out of instana-forward.py so the destination-selection logic (loopback
detection, the narrow http exception, agent-vs-SaaS preference) is unit
testable without a trace store, a socket, or a real Instana tenant — see
scripts/test_instana_destination.py.
"""

from __future__ import annotations

import socket
from dataclasses import dataclass
from typing import Callable
from urllib.parse import urlsplit

#: The local Instana host agent's OTLP/HTTP receiver. Not a secret and not
#: per-tenant — it is IBM's fixed install-time port on 127.0.0.1 — so unlike
#: INSTANA_ENDPOINT this has a real default and does not require local.env at
#: all to be usable, only reachability.
DEFAULT_AGENT_ENDPOINT = "http://127.0.0.1:4318"

#: How long to wait for the agent's port before giving up on auto-detection.
#: It is loopback, so a real agent answers in microseconds; this only needs to
#: be long enough to not be flaky under load, and short enough that a box with
#: no agent installed does not stall `--check`/`--once`.
AGENT_PROBE_TIMEOUT = 0.5

#: Hostnames `post()` accepts over plain http. The one legitimate case: this
#: process and the Instana agent are on the same machine, so http to loopback
#: never crosses a wire — seeing the URL is exactly as available to an
#: eavesdropper as running `ps` on the box already is. Anything else must be
#: https.
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})


@dataclass(frozen=True)
class Destination:
    """Where a batch is about to go, and what that implies for the request.

    `name` is never inferred from the URL by a caller — it is carried
    explicitly end to end (into --check/--dry-run/--once output and the state
    file) so a reader is never left guessing whether bytes went to IBM's SaaS
    or stayed on the box talking to the local agent.
    """

    name: str  # "agent" or "saas"
    endpoint: str  # scheme://host[:port], no trailing slash
    send_key: bool  # x-instana-key / Authorization — SaaS ingest credential
    stamp_host_id: bool  # do WE attach host.id / x-instana-host, or does the agent?


def scheme_problem(url: str, label: str) -> str | None:
    """None if `url` is an acceptable scheme for OTLP egress, else why not.

    https is always fine. Plain http is fine ONLY to a loopback host — the one
    case where "leaves the box in cleartext" is false by construction, because
    it never reaches a wire. This is a narrow, explicit exception keyed on the
    URL's hostname, not a general relaxation of the check: a non-loopback http
    endpoint — a typo, or an agent endpoint pointed at a real remote host — is
    refused exactly as before.
    """
    parts = urlsplit(url)
    if parts.scheme == "https":
        return None
    if parts.scheme == "http" and parts.hostname in LOOPBACK_HOSTS:
        return None
    return f"{label} must be https:// (got {parts.scheme or '?'}://) — plaintext is only allowed to loopback"


def agent_reachable(agent_endpoint: str, timeout: float = AGENT_PROBE_TIMEOUT) -> bool:
    """A plain TCP connect to the agent's OTLP port — nothing OTLP-shaped, just
    "is anything listening". Cheap and safe to call on every auto-detect: it
    is loopback-only by construction (`agent_endpoint` failed `scheme_problem`
    otherwise) and this process is not sandboxed away from its own host.
    """
    parts = urlsplit(agent_endpoint)
    port = parts.port or (443 if parts.scheme == "https" else 80)
    try:
        with socket.create_connection((parts.hostname, port), timeout=timeout):
            return True
    except OSError:
        return False


def choose_destination(
    agent_endpoint: str,
    saas_endpoint: str,
    via_agent: bool,
    via_saas: bool,
    reachable: Callable[[str], bool] = agent_reachable,
) -> tuple[Destination, list[str]]:
    """Pick ONE destination and say why, rather than leaving it implicit.

    --via-agent / --via-saas force a leg outright — useful for a deliberate
    comparison, or to prove one leg is broken without the other masking it.
    With neither given, this auto-detects: the agent wins when its port
    answers (preferred because it adds host correlation for free and keeps
    egress on the box), SaaS is the fallback for a box with no agent.

    ALWAYS returns a concrete Destination, even an unreachable/unconfigured
    one — `--dry-run` has to print something, and the caller decides whether
    the accompanying problems block a real send.
    """
    agent_dest = Destination("agent", agent_endpoint, send_key=False, stamp_host_id=False)
    saas_dest = Destination("saas", saas_endpoint, send_key=True, stamp_host_id=True)

    if via_agent and via_saas:
        return agent_dest, ["--via-agent and --via-saas are mutually exclusive"]
    if via_agent:
        return agent_dest, []
    if via_saas:
        problems = [] if saas_endpoint else ["--via-saas given but INSTANA_ENDPOINT is not set in registry/local.env"]
        return saas_dest, problems
    if reachable(agent_endpoint):
        return agent_dest, []
    if saas_endpoint:
        return saas_dest, []
    return agent_dest, [
        f"neither the local Instana agent ({agent_endpoint}) nor INSTANA_ENDPOINT is available — "
        "install/start the agent, or set INSTANA_ENDPOINT in registry/local.env"
    ]
