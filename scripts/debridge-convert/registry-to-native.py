#!/usr/bin/env python3
"""Rewrite one station's registry entry from the QEMU bridge shape to the
host-native (mame-native x11-runtime) shape — the de-bridging conversion
campaign's registry step, applied identically to all nine MAME kiosks.

What it changes (and nothing else):
  * runtime.qemu           -> removed
  * runtime.x11            -> the irix/w2kalpha shape: shared launcher
                              stations/mame-native/x11-runtime.sh, capture=shm,
                              resetMode=relaunch, emitArgs for the --x11 emit
  * runtime.stationEnv     -> the x11-emit key set (irix's shape), keeping the
                              station's port/fps
  * operator.labctl        -> no QMP, no guest exec (there is no guest OS any
                              more); console stays "x11" (the x11-runtime
                              convention labctl already understands)
  * reset                  -> resetMode=relaunch, snapshot=null

usage: registry-to-native.py <tile> <display :NN> [geometry WxHxD]

Idempotent: running it again rewrites the same shape. Review with git diff;
`make tile-registry-generate` afterwards.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    tile, display = sys.argv[1], sys.argv[2]
    geometry = sys.argv[3] if len(sys.argv) > 3 else "1024x768x32"
    path = Path("registry/stations") / f"{tile}.json"
    doc = json.loads(path.read_text())

    base = f"/data/vms/streamhost/stations/{tile}"
    udp = doc["stream"]["udpPort"]
    fps = doc["stream"]["fps"]
    audio = "on" if doc["stream"].get("audio") else "off"

    # Keys-only pointer model: no pointer, but the KEYS ride mamesock.
    doc["stream"]["pointer"].update({"backend": "mamesock", "device": "ioport-keyboard"})

    runtime = doc["runtime"]
    runtime.pop("qemu", None)
    runtime["stationEnv"] = {
        "SH_STATION": tile,
        "SH_STATION_RUNTIME": "x11",
        "SH_INPUT_BACKEND": "mamesock",
        "SH_AUDIO": audio,
        "SH_CAPTURE": "shm",
        "SH_X11_DISPLAY": display,
        "SH_X11_CMD_FILE": f"{base}/{tile}_cmd",
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
        "launcher": "streamhost/stations/mame-native/x11-runtime.sh",
        "resetMode": "relaunch",
        "emitArgs": [
            "--tile",
            tile,
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
            "mamesock",
            "--audio",
            audio,
            "--fps",
            str(fps),
            "--x11-runtime-file",
            "$T/mame-native/x11-runtime.sh",
            "--aux-file",
            f"$T/{tile}/{tile}.keymap",
            "--env-append-file",
            f"$T/{tile}/station.env.fixture",
        ],
        "auxFiles": [
            f"streamhost/stations/{tile}/{tile}.keymap",
            f"streamhost/stations/{tile}/station.env.fixture",
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
            "notes": f"HOST-NATIVE (de-bridged 2026-08-12): MAME runs on the host, "
            f"no QEMU/QMP, no guest OS, no exec channel. Frames drawshm->shm, "
            f"keys ctlsock keymap, audio FIFO. Launcher "
            f"stations/mame-native/x11-runtime.sh; reset=relaunch restores the "
            f"golden savestate in {base}/sta.",
        }
    )

    reset = doc["reset"]
    reset["resetMode"] = "relaunch"
    reset["snapshot"] = None

    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    print(f"{path}: runtime.qemu -> runtime.x11 (display {display}, udp {udp}, fps {fps}, audio {audio})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
