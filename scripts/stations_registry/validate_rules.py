"""Business-rule validators layered on top of the JSON-Schema-lite check, plus validate()."""

from __future__ import annotations

import json
import re
from typing import Any

from .constants import REGISTRY, REPO, TILES
from .loading import RegistryError, fixture_path, is_x11_runtime, load
from .pointer_rules import (
    LEGACY_POINTER_BACKEND,
    POINTER_LEDGER_EXCEPTION,
    POINTER_METHODS,
    POINTER_MODE_BY_BACKEND,
)
from .validate_acceptance import validate_acceptance, validate_rollout
from .validate_emulator import validate_emulator, validate_ui
from .validate_facts import validate_facts
from .validate_retronet import validate_retronet
from .validate_schema import fail, validate_json_schema, validate_schema_shape


def is_hidden(row: dict[str, Any]) -> bool:
    """Soft-hidden: a full lineup entry that the gallery does not announce."""
    return row.get("listing", {}).get("state") == "hidden"


def validate_listing(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """Enforce the soft-hide block the shipped JSON-Schema evaluator cannot.

    validate_json_schema() honours neither additionalProperties nor a
    conditional, so the "reason/since iff hidden" rule and the typo guard are
    business rules here. The load-bearing one is the last: a hide only means
    anything for a row that WOULD otherwise be listed, and a hide on a row that
    is already out of gallery-manifest.json is a lie a future session would
    believe.
    """
    allowed = {"state", "reason", "since"}
    for row in rows:
        listing = row.get("listing")
        if listing is None:
            continue
        if not isinstance(listing, dict):
            fail(errors, row, "listing must be an object")
            continue
        unknown = sorted(set(listing) - allowed)
        if unknown:
            fail(errors, row, f"listing has unknown key(s) {unknown}; allowed: {sorted(allowed)}")
        state = listing.get("state")
        if state not in {"listed", "hidden"}:
            fail(errors, row, f"listing.state must be 'listed' or 'hidden', got {state!r}")
            continue
        if state == "listed":
            extra = sorted(k for k in ("reason", "since") if k in listing)
            if extra:
                fail(errors, row, f"listing.state 'listed' must not carry {extra} — a listed exhibit explains nothing")
            continue
        if not str(listing.get("reason", "")).strip():
            fail(errors, row, "listing.state 'hidden' requires a non-blank reason (why it is off the floor)")
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", str(listing.get("since", ""))):
            fail(errors, row, "listing.state 'hidden' requires since as YYYY-MM-DD")
        if not row.get("enabled") or "bindingOrder" not in row.get("render", {}):
            fail(
                errors,
                row,
                "listing.state 'hidden' on an entry that is not in the public lineup anyway "
                "(needs enabled + render.bindingOrder). enabled:false is RETIREMENT, not a hide — "
                "pick one, and do not declare a hide that does nothing.",
            )


# spa/src/ui/grid/StreamView/typeDemoProgram.ts DEMO_PER_CHAR_MS -- what the UI
# typist assumes when the entry declares no perCharMs of its own.
SPA_DEFAULT_PER_CHAR_MS = 70


def validate_demo_pacing(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """The typist's per-character budget must not undercut the daemon's pacing.

    streamhost drains typed keys at SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS per
    character. The SPA waits line.length * perCharMs before submitting the next
    line, so a perCharMs below that rate builds a backlog across the listing: the
    ENTER arrives late and the next line's first characters land while BASIC is
    still tokenising, which the visitor sees as randomly missing characters. The
    two numbers live in different files, so pin them together here rather than
    rediscovering the drift on the exhibit floor.
    """
    for row in rows:
        demo = row.get("demoProgram")
        if not demo:
            continue
        env = (row.get("runtime") or {}).get("stationEnv", {})

        def ms(key: str, env: dict[str, Any] = env) -> int:
            try:
                return int(env.get(key, 0))
            except (TypeError, ValueError):
                return 0

        drain = ms("SH_KEY_MIN_HOLD_MS") + ms("SH_KEY_MIN_GAP_MS")
        if drain == 0:
            continue
        budget = demo.get("perCharMs", SPA_DEFAULT_PER_CHAR_MS)
        if budget < drain:
            fail(
                errors,
                row,
                f"demoProgram.perCharMs={budget} is below the tile's typed drain rate "
                f"({drain} ms/char = SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS); the typist "
                f"would out-run the guest and lose characters",
            )


def device_ledger(row: dict[str, Any]) -> str:
    """Every place this tile's emulated input devices are written down.

    The in-repo launcher is the authoritative device ledger for a verbatim tile,
    but only its COMMAND lines are: three launchers carry a `do NOT add
    usb-tablet` comment, which a naive substring search reads as a tablet.
    """
    runtime = row.get("runtime", {})
    qemu = runtime.get("qemu", {})
    parts = list(qemu.get("deviceSetSummary", [])) + [str(a) for a in qemu.get("emitArgs", [])]
    launcher = qemu.get("launcher") or runtime.get("x11", {}).get("launcher")
    if launcher and (REPO / launcher).exists():
        text = (REPO / launcher).read_text()
        parts += [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    return "\n".join(parts)


def validate_pointer_method(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """Pin the declared pointer METHOD to the runtime that actually delivers it.

    `stream.pointer.method` / `absolute` / `present` are the human-facing answer
    to "can a visitor point at this exhibit, and what makes that work". Nothing
    at runtime reads them, so left alone they would rot the first time a tile
    changed backend -- and a stale `absolute: true` is exactly the claim nobody
    re-checks. So derive them here from the four places that DO decide, and fail
    on any disagreement: the tile's SH_INPUT_BACKEND (or the legacy SH_POINTER it
    is derived from), its emulated device ledger, and labctl's pointer_mode.
    """
    for row in rows:
        ptr = row.get("stream", {}).get("pointer")
        if not isinstance(ptr, dict):
            fail(errors, row, "stream.pointer missing: every entry must declare its pointer, posters included")
            continue
        method = ptr.get("method")
        if method not in POINTER_METHODS:
            fail(errors, row, f"invalid stream.pointer.method {method!r}")
            continue
        backends, needs, forbids = POINTER_METHODS[method]
        if row.get("stream", {}).get("transport") != "streamhost":
            # No daemon, no devices: a poster or an unpromoted candidate.
            if method != "none" or ptr.get("absolute") or ptr.get("present"):
                fail(
                    errors,
                    row,
                    "non-streamhost entry must declare pointer method none with "
                    f"absolute false and present false, not {method!r}",
                )
            continue
        env = row.get("runtime", {}).get("stationEnv", {})
        backend = ptr.get("backend") or env.get("SH_INPUT_BACKEND") or LEGACY_POINTER_BACKEND.get(ptr.get("transport"))
        if backend not in POINTER_MODE_BY_BACKEND:
            fail(errors, row, f"cannot resolve an input backend for stream.pointer {ptr.get('transport')!r}")
            continue
        if backend not in backends:
            fail(
                errors,
                row,
                f"stream.pointer.method {method!r} is delivered by backend "
                f"{'/'.join(sorted(backends))}, but this tile runs {backend!r} "
                f"(stream.pointer.backend / runtime.stationEnv SH_INPUT_BACKEND / "
                f"legacy SH_POINTER={ptr.get('transport')!r}). Correct the method or "
                f"the backend -- the LIVE station.env on the box is the truth about "
                f"which one is wrong.",
            )
        # method "none" means no pointer regardless of backend: a keys-only
        # mamesock station carries an input backend but nothing to point with.
        present = backend != "disabled" and method != "none"
        absolute = present and backend != "dbus-rel"
        if ptr.get("present") is not present or ptr.get("absolute") is not absolute:
            fail(
                errors,
                row,
                f"stream.pointer absolute={ptr.get('absolute')!r}/present={ptr.get('present')!r} "
                f"contradicts backend {backend!r}, which InputBackend::pointer_mode() "
                f"(streamhost/streamhost/src/config/backends.rs) makes "
                f"absolute={absolute}/present={present}",
            )
        pointer_mode = row.get("operator", {}).get("labctl", {}).get("pointer_mode")
        expected_mode = "none" if method == "none" else POINTER_MODE_BY_BACKEND[backend]
        if pointer_mode is not None and pointer_mode != expected_mode:
            fail(
                errors,
                row,
                f"operator.labctl.pointer_mode {pointer_mode!r} contradicts backend "
                f"{backend!r} (expected {expected_mode!r}); labctl and the SPA both "
                f"choose their pointer transport from it",
            )
        ledger = device_ledger(row)
        exempt = POINTER_LEDGER_EXCEPTION in row.get("migrationExceptions", [])
        if needs and not exempt and not any(token in ledger for token in needs):
            fail(
                errors,
                row,
                f"stream.pointer.method {method!r} needs one of "
                f"{'/'.join(needs)} in the device ledger (runtime.qemu.launcher, "
                f"deviceSetSummary, emitArgs), which names none of them",
            )
        hits = [token for token in forbids if token in ledger]
        if hits:
            fail(
                errors,
                row,
                f"stream.pointer.method {method!r} is contradicted by {'/'.join(hits)} "
                f"in the device ledger (runtime.qemu.launcher, deviceSetSummary, "
                f"emitArgs): an absolute device is wired up that this method says "
                f"is not the one in use",
            )


def keymap_escape(ch: str) -> str:
    """Percent-encode the three characters SH_KEY_MAP's wire format cannot carry.

    The value is `guest:host` pairs joined by commas, so a guest or host
    character that IS a colon or a comma has no literal spelling: the Dragon 32
    puts ':' on the host key a PC labels '-', which would render as `::-`, and
    labctl's split(':', 1) then yields an empty guest and DROPS the mapping
    silently -- one missing character, not an error. Only '%', ',' and ':' are
    touched, so every map written before this existed renders unchanged;
    labctl's keymap_unescape() is the other half.
    """
    return ch.replace("%", "%25").replace(",", "%2C").replace(":", "%3A")


def validate_keyboard_env(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """`keyboard.charMap` is the single source; SH_KEY_MAP is how labctl consumes it.

    labctl drives QMP directly and cannot read the registry, so the map reaches it
    through the tile's env. Two copies can drift, and a drifted keyboard map fails
    as mangled characters that read like a timing bug -- so pin them together here.
    """
    for row in rows:
        charmap = (row.get("keyboard") or {}).get("charMap")
        env = (row.get("runtime") or {}).get("stationEnv", {}).get("SH_KEY_MAP")
        if not charmap and not env:
            continue
        if charmap and not env:
            fail(
                errors,
                row,
                "keyboard.charMap declared but SH_KEY_MAP missing from runtime.stationEnv (labctl reads it from there)",
            )
            continue
        if env and not charmap:
            fail(errors, row, "SH_KEY_MAP set in runtime.stationEnv with no keyboard.charMap to derive it from")
            continue
        expected = ",".join(f"{keymap_escape(g)}:{keymap_escape(h)}" for g, h in charmap.items())
        if env != expected:
            fail(errors, row, f"SH_KEY_MAP does not match keyboard.charMap (expected {expected!r}, found {env!r})")


def validate_fleet_encoder(globals_doc: dict[str, Any], errors: list[str]) -> None:
    """Pin the emitter's fleet default to the value the registry declares.

    SH_BUFSIZE_RATIO=0.5 was applied by hand across the fleet on 2026-07-17 and
    never recorded in the registry, so a re-emit would have silently restored 1.0
    on 30 tiles. The emitter writes the value; the registry now declares it; this
    stops the two from disagreeing again. (It changes no behaviour today: tier 0
    is CQP with no VBV and the daemon already caps ABR tiers at min(ratio, 0.5) --
    but a silent divergence between what the registry says and what the fleet runs
    is the thing worth preventing.)
    """
    declared = (globals_doc.get("fleetEncoder") or {}).get("bufsizeRatio")
    if declared is None:
        return
    emitter = REPO / "streamhost/scripts/streamhost-station.sh"
    text = emitter.read_text()
    found = re.search(r'^BUFSIZE_RATIO="([0-9.]+)"', text, re.M)
    if not found:
        errors.append(f"{emitter.relative_to(REPO)}: cannot find the BUFSIZE_RATIO default")
    elif float(found.group(1)) != float(declared):
        errors.append(
            f"{emitter.relative_to(REPO)}: BUFSIZE_RATIO default {found.group(1)} != "
            f"registry-v1.json fleetEncoder.bufsizeRatio {declared}"
        )


def validate_exhibit_assets(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """A production tile is not an exhibit until it has a placard and a hero image.

    Both were missing when mpf2 first went to `lifecycle: production`, and nothing
    caught it -- the SPA simply rendered a tile with no exhibit notes. These live
    outside the registry (prose in registry/posters/, the image in the SPA's public
    tree), so only a filesystem check can see them.
    """
    for row in rows:
        if row.get("lifecycle") != "production" or not row.get("enabled"):
            continue
        if row.get("stream", {}).get("transport") != "streamhost":
            continue
        os_id = row["id"]
        if not (REGISTRY / "posters" / f"{os_id}.md").is_file():
            fail(errors, row, f"production tile has no poster prose: registry/posters/{os_id}.md")
        hero = REPO / "spa/public/posters" / os_id / "desktop.webp"
        if not hero.is_file():
            fail(errors, row, f"production tile has no hero image: {hero.relative_to(REPO)}")


def validate() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    globals_doc, rows = load()
    errors: list[str] = []
    try:
        schema = json.loads((REGISTRY / "schema/tile-v1.schema.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot load tile JSON Schema: {exc}") from exc
    for row in rows:
        validate_json_schema(
            {k: v for k, v in row.items() if not str(k).startswith("_")},
            schema,
            str(row["_path"].relative_to(REPO)),
            errors,
        )
    validate_schema_shape(rows, errors)
    validate_listing(rows, errors)
    validate_exhibit_assets(rows, errors)
    validate_keyboard_env(rows, errors)
    validate_pointer_method(rows, errors)
    validate_emulator(rows, errors)
    validate_ui(rows, errors)
    validate_demo_pacing(rows, errors)
    validate_fleet_encoder(globals_doc, errors)
    validate_retronet(rows, errors)
    validate_acceptance(rows, errors)
    validate_rollout(rows, errors)
    validate_facts(rows, errors)
    ids: dict[str, str] = {}
    unique: dict[str, dict[Any, str]] = {
        k: {} for k in ("stationDir", "udpPort", "slot", "experimentSlot", "bringUpOrder", "bindingOrder")
    }
    by_id = {row["id"]: row for row in rows}
    for row in rows:
        os_id = row["id"]
        expected_name = f"{os_id}.json"
        if row["_path"].name != expected_name:
            fail(errors, row, f"filename must be {expected_name}")
        if os_id in ids:
            fail(errors, row, f"duplicate id also in {ids[os_id]}")
        ids[os_id] = str(row["_path"])
        if row.get("museum", {}).get("id") != os_id:
            fail(errors, row, "museum.id differs from id")
        stream = row.get("stream", {})
        runtime = row.get("runtime", {})
        render = row.get("render", {})
        binding_order = render.get("bindingOrder")
        if row.get("enabled") and (
            not isinstance(binding_order, int) or isinstance(binding_order, bool) or binding_order < 0
        ):
            fail(errors, row, "enabled entry render.bindingOrder must be a non-negative integer")
        # Disabled candidate scaffolds reserve their identity, slot, and port even
        # though they intentionally use showcase transport until promotion.
        for key, value in (
            ("stationDir", row.get("stationDir")),
            ("udpPort", stream.get("udpPort")),
            ("slot", stream.get("slot")),
            ("experimentSlot", stream.get("experimentSlot")),
            ("bringUpOrder", runtime.get("bringUpOrder")),
            ("bindingOrder", binding_order),
        ):
            if value is None:
                continue
            if value in unique[key]:
                fail(errors, row, f"duplicate {key}={value!r} also used by {unique[key][value]}")
            unique[key][value] = os_id
        if stream.get("transport") != "streamhost":
            if row.get("lifecycle") not in {"showcase", "candidate"}:
                fail(errors, row, "non-streamhost entry must be showcase/candidate")
            continue
        if row.get("lifecycle") == "production":
            if stream.get("legacyPortException"):
                if stream.get("udpPort") == globals_doc["ports"]["productionBase"] + stream.get("slot", -1):
                    fail(errors, row, "legacyPortException set but port follows slot policy")
            elif stream.get("udpPort") != globals_doc["ports"]["productionBase"] + stream.get("slot", -99999):
                fail(errors, row, "production UDP port violates base+slot policy without legacyPortException")
            for key in ("stationsManifestOrder", "bringUpGroup", "goldenOrder"):
                if key not in row.get("render", {}):
                    fail(errors, row, f"production entry missing render.{key}")
            if runtime.get("bringUpOrder") is None:
                fail(errors, row, "production entry missing bringUpOrder")
            if "reset" not in row:
                fail(errors, row, "production entry missing reset policy")
            # A station outside the edge's DNAT range is unreachable from the public
            # gallery while looking entirely healthy on labhost -- service active,
            # ticket accepted, signalling fine, and the daemon simply never sees a
            # session. Four stations shipped that way on 2026-08-09.
            low = globals_doc["ports"]["publicRelayLow"]
            high = globals_doc["ports"]["publicRelayHigh"]
            # legacyPortException stations are deliberately off the base+slot policy
            # (reactos sits on 4433) and the edge carries its own rule for them, so
            # the range check does not apply.
            in_range = low <= stream.get("udpPort", -1) <= high
            if stream.get("transport") == "streamhost" and not stream.get("legacyPortException") and not in_range:
                fail(
                    errors,
                    row,
                    f"udpPort {stream.get('udpPort')} is outside the public relay range "
                    f"{low}-{high}: the tile would stream on the LAN but be unreachable "
                    f"through the edge. Widen the range (nftables on vm-control, the "
                    f"comment in /etc/wireguard/wg0.conf and docs/PUBLIC-GALLERY.md) or "
                    f"pick a slot inside it.",
                )
        elif row.get("lifecycle") == "experiment":
            expected = globals_doc["ports"]["experimentBase"] + stream.get("experimentSlot", -99999)
            if stream.get("udpPort") != expected:
                fail(errors, row, "experiment UDP port violates base+experimentSlot policy")
        tile_dir = row["stationDir"]
        # ONE station, ONE name. The id is the user-facing half (/os/<id>, the poster
        # path, docs/guests/<id>.md, the UI binding); stationDir is the daemon half
        # (SH_STATION, the runtime dir, streamhost@<dir>). They used to be allowed to
        # differ behind an explicit alias block, and the two that did — aros/amigaos
        # and solaris/solariscde — cost a special case in every tool that spanned
        # them, plus a four-hour outage on 2026-08-05 when the gateway signed a
        # ticket with the wrong half. Both were renamed on 2026-08-10; this keeps
        # the seam from being reintroduced.
        if os_id != tile_dir:
            fail(errors, row, f"id '{os_id}' and stationDir '{tile_dir}' must match — one tile, one name")
        ptr = stream["pointer"]
        if (
            ptr["transport"] == "rel"
            and not row.get("spa", {}).get("pointerRel")
            and "spa-pointer-rel" not in row.get("migrationExceptions", [])
        ):
            fail(errors, row, "relative pointer lacks SPA pointerRel or spa-pointer-rel migration exception")
        if ptr["transport"] == "warpd" and "agentAddress" not in ptr:
            fail(errors, row, "warpd pointer missing agentAddress")
        x11 = is_x11_runtime(row)
        qemu = runtime.get("qemu", {})
        machine = qemu.get("machine")
        if (
            not x11
            and (
                machine is None or machine in {"pc", "q35"} or (isinstance(machine, str) and machine.startswith("pc,"))
            )
            and "legacy-machine-alias" not in row.get("migrationExceptions", [])
        ):
            fail(errors, row, "unversioned/implicit production machine lacks legacy-machine-alias exception")
        if qemu.get("patchedDevice") == "gallery-hid-pci":
            binary = qemu.get("binary", "")
            stable_binary = "/data/vms/streamhost/qemu-gallery-hid/qemu-system-x86_64"
            if not (binary.startswith("/data/vms/sandbox/") or binary == stable_binary):
                fail(errors, row, "gallery-hid must use the standalone patched QEMU")
            companions = {item.get("name") for item in runtime.get("companions", [])}
            native_sink = runtime.get("stationEnv", {}).get("SH_INPUT_BACKEND") == "gallery-hid"
            if not native_sink and "warpd-to-ghid" not in companions:
                fail(errors, row, "gallery-hid missing warpd-to-ghid companion")
            if native_sink and "warpd-to-ghid" in companions:
                fail(errors, row, "native gallery-hid sink must not declare the Python bridge companion")
        reset = row.get("reset")
        if reset:
            if reset.get("resetMode") == "loadvm" and not reset.get("snapshot"):
                fail(errors, row, "loadvm reset missing snapshot")
            if reset.get("resetMode") == "restart" and reset.get("snapshot") is not None:
                fail(errors, row, "restart reset must have null snapshot")
            if reset.get("resetMode") == "pve-rollback":
                if qemu.get("mode") != "pve":
                    fail(errors, row, "pve-rollback reset requires runtime.qemu.mode pve")
                if reset.get("snapshot") != "golden":
                    fail(errors, row, "pve-rollback reset snapshot must be golden")
            # relaunch (x11 RAM-overlay pristine reboot) has no snapshot; criu
            # restores a checkpointed container/desktop tagged 'golden'.
            if reset.get("resetMode") == "relaunch" and reset.get("snapshot") is not None:
                fail(errors, row, "relaunch reset must have null snapshot")
            if reset.get("resetMode") == "criu" and reset.get("snapshot") != "golden":
                fail(errors, row, "criu reset snapshot must be golden")
            if x11 and reset.get("resetMode") not in {"relaunch", "criu"}:
                fail(errors, row, "x11 tile reset must be relaunch or criu")
        env = runtime.get("stationEnv", {})
        expected_env = {
            "SH_STATION": tile_dir,
            "SH_PORT": str(stream["udpPort"]),
            "SH_FPS": str(stream["fps"]),
            "SH_AUDIO": "on" if stream["audio"] else "off",
        }
        if "backend" in ptr:
            expected_env["SH_INPUT_BACKEND"] = ptr["backend"]
            if "SH_POINTER" in env:
                fail(errors, row, "unified pointer backend must not also emit legacy SH_POINTER")
        else:
            expected_env["SH_POINTER"] = ptr["transport"]
        if qemu.get("mode") == "pve":
            vmid = runtime.get("pve", {}).get("vmid")
            if isinstance(vmid, int) and not isinstance(vmid, bool) and vmid >= 1:
                expected_env.update(
                    {
                        "SH_QEMU_MODE": "pve",
                        "SH_PVE_VMID": str(vmid),
                        "SH_QEMU_PIDFILE": f"/var/run/qemu-server/{vmid}.pid",
                    }
                )
                emit_args = qemu.get("emitArgs", [])
                if "--pve-vmid" not in emit_args or str(vmid) not in emit_args:
                    fail(errors, row, "pve runtime.qemu.emitArgs must include --pve-vmid and runtime.pve.vmid")
        if x11:
            x11cfg = runtime.get("x11", {})
            # The frame SOURCE is independent of the runtime kind: `x11` grabs
            # an Xvfb root, `shm` maps a framebuffer the emulator publishes
            # itself (no window, no X server). Default x11, so a station that does
            # not declare one is unchanged.
            capture = x11cfg.get("capture", "x11")
            expected_env.update(
                {
                    "SH_CAPTURE": capture,
                    "SH_X11_DISPLAY": x11cfg.get("display"),
                    "SH_STATION_RUNTIME": "x11",
                    "SH_X11_CMD_FILE": f"/data/vms/streamhost/stations/{tile_dir}/{tile_dir}_cmd",
                }
            )
            if capture == "shm":
                expected_env["SH_SHM_PATH"] = f"/data/vms/streamhost/stations/{tile_dir}/fb.shm"
            if "SH_QMP" in env:
                fail(errors, row, "x11 tile must not emit SH_QMP (no QEMU/QMP)")
        for key, value in expected_env.items():
            if env.get(key) != value:
                fail(errors, row, f"stationEnv {key}={env.get(key)!r}, expected {value!r}")
        for ref in (row.get("guestDoc"), qemu.get("launcher"), qemu.get("envFixture")):
            if ref and not (REPO / ref).exists():
                fail(errors, row, f"referenced path does not exist: {ref}")
        for ref in list(qemu.get("auxFiles", [])) + list(runtime.get("x11", {}).get("auxFiles", [])):
            if not (REPO / ref).exists():
                fail(errors, row, f"referenced aux path does not exist: {ref}")
        x11_launcher = runtime.get("x11", {}).get("launcher")
        if x11_launcher and not (REPO / x11_launcher).exists():
            fail(errors, row, f"referenced path does not exist: {x11_launcher}")
        if not re.fullmatch(r"guest/[a-z0-9-]+", row.get("credentialsRef", "")):
            fail(errors, row, "credentialsRef must be an opaque guest/<id> reference")
        declared_fixture = qemu.get("envFixture")
        resolved_fixture = fixture_path(row)
        if declared_fixture and (resolved_fixture is None or (REPO / declared_fixture) != resolved_fixture):
            fail(errors, row, "runtime.qemu.envFixture disagrees with the emitArgs --env-append-file path")
        overlap = sorted(set(row.get("_recordedTileEnv", {})) & set(row.get("_fixtureEnv", {})))
        if overlap:
            fail(
                errors,
                row,
                f"runtime.stationEnv duplicates fixture-owned key(s) {overlap}: the tile's "
                f"station.env.fixture is the single source for the keys it defines — "
                f"delete them from the registry entry",
            )
    if set(by_id) != {p.stem for p in TILES.glob("*.json")}:
        errors.append("registry filename/id set mismatch")
    if errors:
        raise RegistryError("validation failed:\n  - " + "\n  - ".join(errors))
    return globals_doc, rows
