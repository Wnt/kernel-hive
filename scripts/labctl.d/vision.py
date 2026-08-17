"""labctl.d/vision.py — the install-vision OCR/template/settle plumbing
behind `labctl assert`. Moved verbatim out of scripts/labctl
(size-exclusions.json split, step 3b). Imports from labctl.d/common and
labctl.d/capture only — never from labctl.
"""

import os, subprocess, sys, tempfile, time

from common import die, tile_conf
from capture import capture_png_any

VISION_DIR = os.environ.get("LABCTL_VISION_DIR", "/data/vms/streamhost/build/scripts/install-vision")


def vision_python():
    override = os.environ.get("LABCTL_VISION_PYTHON")
    candidates = [override] if override else []
    candidates += [os.path.join(VISION_DIR, ".venv", "bin", "python"), sys.executable]
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    die("no Python interpreter for install-vision; run scripts/install-vision/install.sh")


def run_vision(script, args):
    path = os.path.join(VISION_DIR, script)
    if not os.path.isfile(path):
        die("install-vision primitive missing: %s" % path)
    try:
        return subprocess.run([vision_python(), path, *args], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        die("install-vision %s timed out" % script)


def cmd_assert(argv):
    if len(argv) < 2:
        die("usage: labctl assert <tile> --text <s> | --template <png> | --settle")
    name = argv[0]
    c = tile_conf(name)
    mode = argv[1]
    if mode in ("--text", "--template"):
        if len(argv) != 3 or not argv[2]:
            die("usage: labctl assert <tile> %s <value>" % mode)
        value = argv[2]
    elif mode == "--settle":
        if len(argv) != 2:
            die("usage: labctl assert <tile> --settle")
        value = None
    else:
        die("usage: labctl assert <tile> --text <s> | --template <png> | --settle")

    # HARD READ-ONLY invariant: unlike shot/type/exec, assert must not call
    # ensure_running. A QMP screendump of a paused guest reads its current VGA
    # surface without cont, reset, or input injection.
    with tempfile.TemporaryDirectory(prefix="labctl-assert-%s-" % name) as work:
        first = os.path.join(work, "frame-a.png")
        try:
            capture_png_any(name, c, first, resume=False)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            die(str(exc))
        if mode == "--text":
            result = run_vision("find_text.py", [first, value])
        elif mode == "--template":
            if not os.path.isfile(value):
                die("template not found: %s" % value)
            result = run_vision("find_template.py", [first, value])
        else:
            result = None
            for attempt in range(1, 6):
                time.sleep(1)
                second = os.path.join(work, "frame-b.png")
                try:
                    capture_png_any(name, c, second, resume=False)
                except (RuntimeError, subprocess.TimeoutExpired) as exc:
                    die(str(exc))
                result = run_vision("settle.py", [first, second])
                if result.returncode == 0:
                    break
                os.replace(second, first)
            assert result is not None
        if result.stdout:
            sys.stdout.write(result.stdout)
        if result.returncode != 0:
            detail = result.stderr.strip()
            if detail:
                sys.stderr.write(detail + "\n")
            sys.exit(result.returncode)
