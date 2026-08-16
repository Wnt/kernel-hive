#!/usr/bin/env python3
"""Rewrite one station's registry entry from the QEMU bridge shape to the
host-native (x11-runtime) shape — the de-bridging conversion campaign's
registry step, applied identically to all nine MAME kiosks and, since
2026-08-16, to the VICE wave.

What it changes (and nothing else):
  * runtime.qemu           -> removed
  * runtime.x11            -> the irix/w2kalpha shape: the ENGINE's shared
                              launcher, capture=shm, resetMode=relaunch,
                              emitArgs for the --x11 emit
  * runtime.stationEnv     -> the x11-emit key set (irix's shape), keeping the
                              station's port/fps
  * operator.labctl        -> no QMP, no guest exec (there is no guest OS any
                              more); console stays "x11" (the x11-runtime
                              convention labctl already understands)
  * reset                  -> resetMode=relaunch, snapshot=null

The engine decides three things and nothing else: which shared launcher the
station runs, which input sink the daemon builds, and which aux file rides
along. MAME stations carry a per-station GENERATED matrix keymap; VICE stations
carry the ONE shared host-layout keysym table, because VICE resolves keysym ->
matrix itself through the machine's own .vkm.

usage: registry-to-native.py <station> <display :NN> [geometry WxHxD] [--engine mame|vice]

Idempotent: running it again rewrites the same shape. Review with git diff;
`make station-registry-generate` afterwards.
"""

import json
import sys
from pathlib import Path

ENGINES = {
    "mame": {
        "backend": "mamesock",
        "launcher": "streamhost/stations/mame-native/x11-runtime.sh",
        "runtime_dir": "mame-native",
        # per station: the matrix keymap scripts/dev/mame-keymap.py generates
        "aux": "$T/{station}/{station}.keymap",
        "aux_repo": "streamhost/stations/{station}/{station}.keymap",
        "notes": (
            "HOST-NATIVE (de-bridged): MAME runs on the host, no QEMU/QMP, no guest OS, "
            "no exec channel. Frames drawshm->shm, keys ctlsock keymap, audio FIFO. "
            "Launcher stations/mame-native/x11-runtime.sh; reset=relaunch restores the "
            "golden savestate in {base}/sta."
        ),
    },
    "vice": {
        "backend": "vicesock",
        "launcher": "streamhost/stations/vice-native/x11-runtime.sh",
        "runtime_dir": "vice-native",
        # shared by all seven: VICE maps keysym -> matrix through its own .vkm
        "aux": "$T/vice-native/us-layout.keysyms",
        "aux_repo": "streamhost/stations/vice-native/us-layout.keysyms",
        "notes": (
            "HOST-NATIVE (de-bridged): VICE runs on the host, headless, no QEMU/QMP, "
            "no guest OS, no X, no exec channel. Frames VICE_SHM_PATH->shm (the same "
            "IFB1 wire format drawshm uses), keys vicectl + the shared us-layout "
            "keysym table, audio -sounddev wav -> FIFO. Launcher "
            "stations/vice-native/x11-runtime.sh; reset=relaunch restores the "
            "checkpoint in {base}/sta/golden.vsf."
        ),
    },
}


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    engine = "mame"
    for f in flags:
        if f.startswith("--engine="):
            engine = f.split("=", 1)[1]
        else:
            sys.exit(f"unknown flag {f}\n{__doc__}")
    if len(args) < 2 or engine not in ENGINES:
        sys.exit(__doc__)
    eng = ENGINES[engine]
    station, display = args[0], args[1]
    geometry = args[2] if len(args) > 2 else "1024x768x32"
    path = Path("registry/stations") / f"{station}.json"
    doc = json.loads(path.read_text())

    base = f"/data/vms/streamhost/stations/{station}"
    udp = doc["stream"]["udpPort"]
    fps = doc["stream"]["fps"]
    audio = "on" if doc["stream"].get("audio") else "off"
    aux = eng["aux"].format(station=station)
    aux_repo = eng["aux_repo"].format(station=station)

    # Keys-only pointer model: no pointer, but the KEYS ride the engine's sink.
    doc["stream"]["pointer"].update({"backend": eng["backend"], "device": "ioport-keyboard"})

    runtime = doc["runtime"]
    runtime.pop("qemu", None)
    runtime["stationEnv"] = {
        "SH_STATION": station,
        "SH_STATION_RUNTIME": "x11",
        "SH_INPUT_BACKEND": eng["backend"],
        "SH_AUDIO": audio,
        "SH_CAPTURE": "shm",
        "SH_X11_DISPLAY": display,
        "SH_X11_CMD_FILE": f"{base}/{station}_cmd",
        "SH_SHM_PATH": f"{base}/fb.shm",
        "SH_PORT": str(udp),
        "SH_FPS": str(fps),
        "SH_HOST_IP": "192.0.2.10",
        "SH_ADVERTISE_HOST": "192.0.2.10",
        "SH_AUDIO_BITRATE": "96000",
        "SH_HASH_FILE": f"{base}/cert_hash_b64.txt",
        "SH_SIGNALING_JSON": f"{base}/signaling.json",
        "SH_CERT_ROTATE_DAYS": "10",
    }
    runtime["x11"] = {
        "display": display,
        "geometry": geometry,
        "capture": "shm",
        "launcher": eng["launcher"],
        "resetMode": "relaunch",
        "emitArgs": [
            "--tile",
            station,
            "--udp",
            str(udp),
            "--x11",
            "--x11-display",
            display,
            "--capture",
            "shm",
            "--pointer",
            "none",
            "--input-backend",
            eng["backend"],
            "--audio",
            audio,
            "--fps",
            str(fps),
            "--x11-runtime-file",
            f"$T/{eng['runtime_dir']}/x11-runtime.sh",
            "--aux-file",
            aux,
            "--env-append-file",
            f"$T/{station}/station.env.fixture",
        ],
        "auxFiles": [
            aux_repo,
            f"streamhost/stations/{station}/station.env.fixture",
        ],
    }

    labctl = doc["operator"]["labctl"]
    labctl.update(
        {
            "qmp": None,
            "ssh_port": None,
            "exec_port": None,
            "exec_kind": None,
            "exec_user": None,
            "exec_key": None,
            "console": "x11",
            "notes": eng["notes"].format(base=base),
        }
    )

    reset = doc["reset"]
    reset["resetMode"] = "relaunch"
    reset["snapshot"] = None

    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    print(
        f"{path}: runtime.qemu -> runtime.x11 [{engine}] "
        f"(display {display}, udp {udp}, fps {fps}, audio {audio}, backend {eng['backend']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
