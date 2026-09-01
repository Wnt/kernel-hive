"""WHO produced a span: the service table, and where each service's build id
comes from.

SPLIT OUT OF `traces_otlp.py` because it is the part that has to be RIGHT
rather than merely well-shaped, and because two of the three answers involve
reading the box. The exporter's job is spelling; this file's job is identity.

THE TABLE IS EXPLICIT, NOT A GUESS ON A NAME. Until 2026-09-01 the language a
span's producer was reported in was computed as

    "python" if svc.endswith("-serve") else "webjs"

which is a two-way guess dressed as a mapping: the Rust daemon does not end in
`-serve`, so every `input.dispatch`, `guest.frame.next` and `streamhost.session`
span left the box labelled `telemetry.sdk.language: webjs`. The comment directly
above that line already argued why a wrong language is harmful — it merges two
services into one node on a service map and tells a consumer the wrong language
for half the spans — so the code was contradicting its own docstring. Three
services, three rows, and a service NOT in the table reports no language at all
rather than being guessed into one: an absent attribute is a question a consumer
can still ask, a wrong one is an answer it cannot doubt.

THE THREE BUILD IDS COME FROM THREE DIFFERENT PLACES, because the three planes
ship on three different cadences and there is no single "the version of Kernel
Hive" to report:

    kernel-hive-spa     the batch's own `build` field — the bundle id the TAB
                        was running, uploaded with its spans. Already handled by
                        the caller; nothing here reads it.
    kernel-hive-serve   `/data/vms/streamhost/.deployed-rev`, the sha
                        `box-install.sh` last actually wrote. Not the checkout's
                        HEAD, and not `origin/main`: the same distinction
                        docs/lab/AGENT-CI-EXIT-RULE.md draws for the box-state
                        gate. A push is not a deploy.
    kernel-hive-daemon  PER STATION, and it has to be: `build-deploy.sh
                        --canary` exists precisely so one station can run a
                        different binary from the other sixty. The artifact
                        `stations/<id>/current` points at names the build itself,
                        `streamhost-<gitsha>`.

WHY THE DAEMON VERSION IS TIME-GATED. The symlink says what the station runs
NOW; a span was produced at some point in the past, and the forwarder reads the
tree minutes to hours later. Claiming the current artifact for a span that
predates a canary swap would be a fabricated fact of exactly the kind
`service.version` exists to prevent. So the link's own mtime is compared against
the span's start: a link installed AFTER the span cannot be what produced it,
and the version is omitted instead. Wrong in the safe direction — a rollout
window loses the attribute rather than mislabelling it.

NOTHING HERE INVENTS A PLACEHOLDER. Every accessor returns `None` when the
answer is not on this machine: off the box (CT950, a laptop, CI) neither path
exists, `.deployed-rev` is root-readable only, and a station may have no
versioned install at all. `None` means the exporter omits the attribute, which
is the rule the SPA's build id already follows — a consumer grouping by version
must never be handed a string it cannot distinguish from a real one.
"""

from __future__ import annotations

from pathlib import Path

#: The producers, by the `kh.service` attribute each one stamps on its spans
#: (`scripts/serve/tracing.py`, `streamhost/src/trace/mod.rs`; the browser
#: stamps none and takes the export's default). `language` is OTel's
#: `telemetry.sdk.language`; `instance` names WHICH resource-identity key
#: distinguishes two producers of the same service, and is what the exporter
#: turns into `service.instance.id`:
#:
#:   session  one browser tab                (the SPA: a Resource is one tab)
#:   host     the one serving-plane process  (there is exactly one per box)
#:   station  one streamhost daemon of 61    (a service map with 61 daemons
#:            merged into a single node cannot say which machine was asleep)
SERVICES: dict[str, dict[str, str]] = {
    "kernel-hive-spa": {"language": "webjs", "instance": "session"},
    "kernel-hive-serve": {"language": "python", "instance": "host"},
    "kernel-hive-daemon": {"language": "rust", "instance": "station"},
}

#: Where the serving plane's deployed sha is recorded, by `box-install.sh`.
DEPLOYED_REV = Path("/data/vms/streamhost/.deployed-rev")
#: `build-deploy.sh`'s INSTALL_ROOT/stations. Deliberately NOT under /data: the
#: daemon binaries are an OS install, so this path is only readable ON the box.
DAEMON_STATIONS = Path("/usr/local/lib/streamhost/stations")
#: Artifact names are `streamhost-<gitsha>`, or `streamhost-<label>-<hash>` for
#: a hand-built one. The version is everything after this prefix — a real build
#: identity in both cases, which is why neither is rewritten into "unknown".
ARTIFACT_PREFIX = "streamhost-"


def language_of(service: str) -> str | None:
    """`telemetry.sdk.language` for a known producer, else None (never a guess)."""
    row = SERVICES.get(service)
    return row["language"] if row else None


def instance_kind_of(service: str) -> str | None:
    """Which identity distinguishes two instances of this service, else None."""
    row = SERVICES.get(service)
    return row["instance"] if row else None


class BuildIds:
    """Build ids for the two planes that do not carry their own, cached per run.

    Cached because a forward walks hundreds of traces across a handful of
    stations and the answer cannot change inside one process's lifetime in any
    way worth chasing — and because the alternative is a `readlink` per span.
    """

    def __init__(self, deployed_rev: Path | None = None, daemon_stations: Path | None = None):
        self.deployed_rev = Path(deployed_rev) if deployed_rev is not None else DEPLOYED_REV
        self.daemon_stations = Path(daemon_stations) if daemon_stations is not None else DAEMON_STATIONS
        self._serve: str | None | object = _UNSET
        self._daemon: dict[str, tuple[str, float] | None] = {}

    def serve(self) -> str | None:
        """The sha `box-install.sh` last wrote, or None if it cannot be read."""
        if self._serve is _UNSET:
            self._serve = _parse_deployed_rev(self.deployed_rev)
        return self._serve  # type: ignore[return-value]

    def daemon(self, station: str | None, at_ms: int | None = None) -> str | None:
        """The binary station `station` was running at `at_ms`, or None.

        None whenever the answer would be a guess: no station on the span, no
        versioned install, an unreadable tree, or — the case this argument is
        really about — an artifact link installed AFTER the span it would be
        claimed for.
        """
        if not station:
            return None
        if station not in self._daemon:
            self._daemon[station] = _read_artifact(self.daemon_stations / station / "current")
        found = self._daemon[station]
        if not found:
            return None
        version, installed_ms = found
        if at_ms is not None and installed_ms > at_ms:
            return None
        return version


class _Unset:
    pass


_UNSET = _Unset()


def _parse_deployed_rev(path: Path) -> str | None:
    """`sha=<40 hex>` out of the marker file, validated rather than trusted.

    A marker half-written by an interrupted install, or a file that is not this
    marker at all, must produce None and not a plausible-looking string: the
    whole point of this attribute is that a consumer can believe it.
    """
    try:
        text = path.read_text()
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("sha="):
            sha = line[4:].strip()
            if len(sha) == 40 and all(c in "0123456789abcdef" for c in sha):
                return sha
            return None
    return None


def _read_artifact(link: Path) -> tuple[str, float] | None:
    """(version, install time in ms) for one station's `current` link."""
    try:
        name = Path(link.readlink()).name
        installed_ms = link.lstat().st_mtime * 1000.0
    except (OSError, ValueError):
        return None
    if not name.startswith(ARTIFACT_PREFIX):
        return None
    version = name[len(ARTIFACT_PREFIX) :]
    return (version, installed_ms) if version else None
