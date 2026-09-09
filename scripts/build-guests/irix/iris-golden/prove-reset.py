#!/usr/bin/env python3
"""prove-reset.py — prove a host-native Iris station's reset on the framebuffer.

Stream D of the `indyr4400` de-bridging. Runs ON LABHOST, against a rig under
`/data/vms/sandbox/<name>/`, never against the live station (AGENTS.md rule 4).

What "proven" means here is exactly what the bridge checkpoint had to show
(`docs/guests/indyr4400.md` §Checkpoint), taken off the guest's VRAM instead of
QEMU's `screendump`:

  1. two restores of the same checkpoint are BYTE-IDENTICAL, and a frame
     dirtied between them DIFFERS — so the restore restores, and the digest is
     sensitive enough to notice if it did not;
  2. input is live IMMEDIATELY after the restore — a click on the Toolchest
     highlights it, on the framebuffer, not in a log;
  3. the restore is fast enough to be a reset button — measured, against the
     ~7-minute cold boot it replaces;
  4. a checkpoint survives an UNCLEAN exit. The station's COW overlay flushes
     its `.dirty` sidecar only on a clean exit, so a killed emulator loses the
     live overlay — but `save_snapshot` captures the overlay's dirty sectors
     INTO the snapshot, so the checkpoint does not depend on that flush. This
     is the phase that proves it: SIGKILL, then a cold start that restores;
  5. the provenance triple is enforced — a checkpoint captured by a different
     binary is REFUSED, loudly, rather than restored into a mismatched machine
     (rule 6: checkpoint + binary + device set are ONE combination).

Phases are separate so each runs under a bounded timeout and the expensive one
(a ~7-minute cold boot) is paid once:

    prove-reset.py --rig DIR --bin PATH boot     # cold boot to the desktop
    prove-reset.py --rig DIR --bin PATH bake     # SAVEST golden
    prove-reset.py --rig DIR --bin PATH prove    # 1,2,3
    prove-reset.py --rig DIR --bin PATH cold     # 4
    prove-reset.py --rig DIR --bin PATH prov     # 5

Every phase appends a JSON line to `<rig>/proof.jsonl` and prints the PNGs and
digests it produced, so the report is assembled from measurements rather than
from memory.
"""

import argparse
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import contextlib

from irisrig import Ci, Framebuffer, Mctl, Monitor, Rig  # noqa: E402


def record(rig, phase, **fields):
    line = dict(phase=phase, at=time.strftime("%FT%TZ", time.gmtime()), **fields)
    with open(os.path.join(rig.dir, "proof.jsonl"), "a") as f:
        f.write(json.dumps(line) + "\n")
    print(json.dumps(line, indent=2))
    return line


def keep(rig, src, name):
    """Park a proof PNG under <rig>/proof/ so a later phase cannot overwrite it."""
    d = os.path.join(rig.dir, "proof")
    os.makedirs(d, exist_ok=True)
    dst = os.path.join(d, name)
    shutil.copy2(src, dst)
    return dst


def slam_and_click(mon, x, y, settle=0.15):
    """Put the pointer at roughly (x, y) and click.

    Iris takes RELATIVE PS/2 deltas and IRIX applies its own acceleration
    (~3.5x, history-dependent) to large moves, but is 1:1 near zero — the same
    fact the `irix` station's closed-loop MOVEA engine relies on. So: slam to
    the top-left corner with deltas far larger than the screen (the guest
    clamps at 0,0 — no acceleration can overshoot a clamp), then walk to the
    target in single-pixel steps, which acceleration leaves alone.

    This is a PROOF lever, not the station's pointer: absolute positioning on
    this station is stream C's closed VC2 loop.
    """
    for _ in range(8):
        mon.cmd("ps2 mouse -200 -200 0", idle=0.15, deadline=10.0)
    time.sleep(settle)
    step = 4
    for _ in range(max(0, x) // step):
        mon.cmd(f"ps2 mouse {step} 0 0", idle=0.05, deadline=5.0)
    for _ in range(max(0, y) // step):
        mon.cmd(f"ps2 mouse 0 -{step} 0", idle=0.05, deadline=5.0)
    time.sleep(settle)
    # PS/2 mouse dy is positive UP; the walk above already accounts for it.
    mon.cmd("ps2 mouse 0 0 1", idle=0.1, deadline=5.0)  # button 1 down
    time.sleep(settle)
    mon.cmd("ps2 mouse 0 0 0", idle=0.1, deadline=5.0)  # up


# ---------------------------------------------------------------------------


def phase_boot(rig, args):
    """Cold-boot the rig to a settled desktop. ~7 minutes on this station."""
    rig.state = None  # IRIS_STATE empty = the deliberate cold-boot lever
    t0 = time.monotonic()
    pid = rig.start()
    ok, waited = rig.wait_sockets(deadline=90.0)
    if not ok:
        return record(rig, "boot", ok=False, why="sockets never appeared", waited_s=round(waited, 1), log=rig.log)
    # --ci does not autostart the CPU: the harness owns the first instruction.
    ci = Ci(rig.ci_sock)
    ci.cmd("start")
    mon = Monitor(rig.monitor_addr)
    fb = Framebuffer(mon, os.path.join(rig.dir, "fb"))
    settled, digest, waited = fb.settle(seconds=args.settle, deadline=args.boot_deadline)
    shot = fb.dump("boot")
    ps2 = mon.cmd("ps2 status")
    return record(
        rig,
        "boot",
        ok=settled,
        pid=pid,
        boot_s=round(time.monotonic() - t0, 1),
        settle_wait_s=round(waited, 1),
        md5=shot["md5"],
        png=keep(rig, shot["png"], "01-cold-boot.png"),
        ps2_status=ps2.strip().splitlines()[-1] if ps2.strip() else "",
    )


def phase_bake(rig, args):
    """SAVEST the settled desktop as the checkpoint."""
    ctl = Mctl(rig.ctl_sock)
    mon = Monitor(rig.monitor_addr)
    fb = Framebuffer(mon, os.path.join(rig.dir, "fb"))
    before = fb.dump("prebake")
    ok, text, ms = ctl.verb(f"SAVEST {args.name}", timeout=600.0)
    after = fb.dump("postbake")
    prov = os.path.join(rig.dir, "saves", args.name, "kh-provenance.toml")
    return record(
        rig,
        "bake",
        ok=ok,
        verb_text=text,
        savest_ms=round(ms),
        md5_before=before["md5"],
        md5_after=after["md5"],
        png=keep(rig, after["png"], "02-baked.png"),
        provenance=prov,
        provenance_written=os.path.exists(prov),
        size_mb=round(dirsize(os.path.join(rig.dir, "saves")) / 1e6, 1),
    )


def dirsize(p):
    t = 0
    for root, _, files in os.walk(p):
        for f in files:
            with contextlib.suppress(OSError):
                t += os.path.getsize(os.path.join(root, f))
    return t


def phase_prove(rig, args):
    """Restore-identity, dirtied-frame difference, input-after-restore, timing."""
    ctl = Mctl(rig.ctl_sock)
    mon = Monitor(rig.monitor_addr)
    fb = Framebuffer(mon, os.path.join(rig.dir, "fb"))
    out = {}

    # A — restore, capture.
    ok1, t1, ms1 = ctl.verb(f"LOADST {args.name}", timeout=600.0)
    a = fb.dump("restoreA")
    out.update(restore1_ok=ok1, restore1_text=t1, restore1_ms=round(ms1), md5_restore1=a["md5"])

    # B — dirty the screen: click the Toolchest open.
    slam_and_click(mon, args.toolchest_x, args.toolchest_y)
    changed, dirty_digest, waited = fb.change(a["md5"], deadline=args.input_deadline)
    d = fb.dump("dirty")
    out.update(
        dirtied=changed,
        dirty_wait_s=round(waited, 1),
        md5_dirty=d["md5"],
        png_dirty=keep(rig, d["png"], "03-dirtied.png"),
    )

    # C — restore again, capture at the same instant in the machine's life.
    ok2, t2, ms2 = ctl.verb(f"LOADST {args.name}", timeout=600.0)
    b = fb.dump("restoreB")
    out.update(
        restore2_ok=ok2,
        restore2_text=t2,
        restore2_ms=round(ms2),
        md5_restore2=b["md5"],
        png_restore=keep(rig, b["png"], "04-restored.png"),
    )

    # D — input live IMMEDIATELY after the restore. No settle, no warmup: the
    # click goes in as soon as the verb acks. An ack from the emulation thread
    # plus a framebuffer change is the proof; either alone is not.
    slam_and_click(mon, args.toolchest_x, args.toolchest_y)
    live, live_digest, live_wait = fb.change(b["md5"], deadline=args.input_deadline)
    live_shot = fb.dump("liveafter")
    out.update(
        input_live_after_restore=live,
        input_wait_s=round(live_wait, 1),
        png_input=keep(rig, live_shot["png"], "05-click-after-restore.png"),
    )

    # E — RESET (the in-memory rollback the station's reset button reaches).
    ok3, t3, ms3 = ctl.verb("RESET", timeout=600.0)
    c = fb.dump("afterreset")
    out.update(reset_ok=ok3, reset_text=t3, reset_ms=round(ms3), md5_reset=c["md5"])

    out["identical_restores"] = a["md5"] == b["md5"]
    out["dirty_differs"] = d["md5"] != a["md5"]
    out["reset_matches_restore"] = c["md5"] == a["md5"]
    out["ok"] = all([ok1, ok2, ok3, out["identical_restores"], out["dirty_differs"], out["input_live_after_restore"]])
    return record(rig, "prove", **out)


def phase_cold(rig, args):
    """The checkpoint must not depend on a clean exit: SIGKILL, then restore."""
    mon = Monitor(rig.monitor_addr)
    fb = Framebuffer(mon, os.path.join(rig.dir, "fb"))
    ctl = Mctl(rig.ctl_sock)
    ok0, _, _ = ctl.verb(f"LOADST {args.name}", timeout=600.0)
    base = fb.dump("prekill")
    ctl.close()
    mon.close()

    killed = rig.stop(hard=True)
    dirty_sidecar = os.path.join(rig.dir, "scsi1.overlay.dirty")
    sidecar_present = os.path.exists(dirty_sidecar)

    rig.state = args.name  # IRIS_STATE: restore at startup instead of booting
    t0 = time.monotonic()
    pid = rig.start()
    ok, waited = rig.wait_sockets(deadline=120.0)
    if not ok:
        return record(rig, "cold", ok=False, why="sockets never appeared after kill", killed=killed, log=rig.log)
    mon = Monitor(rig.monitor_addr)
    fb = Framebuffer(mon, os.path.join(rig.dir, "fb"))
    settled, digest, swait = fb.settle(seconds=args.settle, deadline=180.0)
    shot = fb.dump("coldrestored")
    return record(
        rig,
        "cold",
        ok=(shot["md5"] == base["md5"]),
        killed=killed,
        prekill_restore_ok=ok0,
        startup_restore_s=round(time.monotonic() - t0, 1),
        socket_wait_s=round(waited, 1),
        settle_wait_s=round(swait, 1),
        md5_before_kill=base["md5"],
        md5_after_cold_start=shot["md5"],
        overlay_dirty_sidecar_present_after_sigkill=sidecar_present,
        png=keep(rig, shot["png"], "06-cold-start-restored.png"),
        pid=pid,
    )


def phase_prov(rig, args):
    """A checkpoint from a different binary must be REFUSED (rule 6)."""
    ctl = Mctl(rig.ctl_sock)
    ok_before, text_before, _ = ctl.verb(f"CKPT {args.name}")
    prov = os.path.join(rig.dir, "saves", args.name, "kh-provenance.toml")
    with open(prov) as f:
        original = f.read()
    try:
        # Rewrite only the binary hash: same features, same disks, same CPU —
        # so Iris's own manifest checks all pass and the ONLY thing that can
        # refuse this restore is the binary leg of the triple.
        forged = []
        for line in original.splitlines():
            if line.startswith("binary_blake3"):
                line = f'binary_blake3 = "{"0" * 64}"'
            forged.append(line)
        with open(prov, "w") as f:
            f.write("\n".join(forged) + "\n")
        refused, text, _ = ctl.verb(f"LOADST {args.name}", timeout=600.0)
        ok_ckpt, ckpt_text, _ = ctl.verb(f"CKPT {args.name}")
    finally:
        with open(prov, "w") as f:
            f.write(original)
    restored_ok, restore_text, _ = ctl.verb(f"LOADST {args.name}", timeout=600.0)
    return record(
        rig,
        "prov",
        ok=(not refused) and restored_ok,
        ckpt_before=text_before,
        refused_as_expected=(not refused),
        refusal_text=text,
        ckpt_while_forged=ckpt_text,
        restore_after_repair_ok=restored_ok,
        restore_text=restore_text,
    )


PHASES = {"boot": phase_boot, "bake": phase_bake, "prove": phase_prove, "cold": phase_cold, "prov": phase_prov}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rig", required=True)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--monitor-port", type=int, default=18888)
    ap.add_argument("--name", default="golden")
    ap.add_argument("--settle", type=float, default=6.0)
    ap.add_argument("--boot-deadline", type=float, default=900.0)
    ap.add_argument("--input-deadline", type=float, default=45.0)
    ap.add_argument("--toolchest-x", type=int, default=40)
    ap.add_argument("--toolchest-y", type=int, default=1010)
    ap.add_argument("phase", choices=sorted(PHASES))
    a = ap.parse_args()
    rig = Rig(a.rig, a.bin, a.monitor_port)
    r = PHASES[a.phase](rig, a)
    return 0 if r.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
