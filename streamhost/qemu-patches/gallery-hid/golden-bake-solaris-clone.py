#!/usr/bin/env python3
"""Validate and save an empty-ring gallery-hid golden on a Solaris clone."""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time


GHID_STATUS_CONNECTED = 1 << 0
GHID_STATUS_DRIVER_READY = 1 << 1
GHID_STATUS_RESET_REQ = 1 << 2
GHID_IRQ_ALL = 0x7


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(120)
        self.sock.connect(path)
        self.file = self.sock.makefile("rwb", buffering=0)
        greeting = json.loads(self.file.readline())
        if "QMP" not in greeting:
            raise RuntimeError("invalid QMP greeting")
        self.command("qmp_capabilities")

    def command(self, execute, arguments=None):
        request = {"execute": execute}
        if arguments is not None:
            request["arguments"] = arguments
        self.file.write((json.dumps(request) + "\n").encode())
        while True:
            response = json.loads(self.file.readline())
            if "event" in response:
                continue
            if "error" in response:
                raise RuntimeError("QMP %s failed: %s" %
                                   (execute, response["error"]))
            if "return" in response:
                return response["return"]

    def hmp(self, command):
        return self.command("human-monitor-command",
                            {"command-line": command})

    def close(self):
        self.file.close()
        self.sock.close()


def fail(message):
    raise RuntimeError(message)


def read_pid(path):
    with open(path, encoding="ascii") as source:
        value = source.read().strip()
    if not value.isdigit():
        fail("invalid pidfile: %s" % path)
    pid = int(value)
    os.kill(pid, 0)
    return pid


def qemu_uses_clone_disk(pid, clone_dir):
    with open("/proc/%d/cmdline" % pid, "rb") as source:
        argv = [item.decode(errors="replace")
                for item in source.read().split(b"\0") if item]
    clone_prefix = clone_dir + os.sep
    return argv, any(clone_prefix in item and "file=" in item for item in argv)


def backend_connected(socket_path):
    output = subprocess.check_output(
        ["ss", "-xnp"], text=True, stderr=subprocess.STDOUT)
    return any(socket_path in line and "ESTAB" in line
               for line in output.splitlines())


def pci_bars(qmp):
    for bus in qmp.command("query-pci"):
        for device in bus["devices"]:
            if device.get("qdev_id") != "ghid0":
                continue
            bars = {region["bar"]: region["address"]
                    for region in device.get("regions", [])}
            if bars.get(0, -1) < 0 or bars.get(2, -1) < 0:
                fail("ghid0 BAR0/BAR2 is not programmed")
            return bars[0], bars[2]
    fail("QMP query-pci did not find qdev ghid0")


def read_phys32(qmp, address):
    result = qmp.hmp("xp /1wx 0x%x" % address)
    values = re.findall(r"0x([0-9a-fA-F]{1,8})", result)
    if len(values) != 1:
        fail("could not parse physical read at 0x%x: %r" %
             (address, result))
    return int(values[0], 16)


def snapshot_exists(info, name):
    return any(re.match(r"\s*\S+\s+%s(?:\s|$)" % re.escape(name), line)
               for line in info.splitlines())


def main():
    parser = argparse.ArgumentParser(
        description="validate gallery-hid state and save a clone-only golden")
    parser.add_argument("clone_dir")
    parser.add_argument("--snapshot", default="golden")
    parser.add_argument("--replace", action="store_true",
                        help="delete an existing snapshot of the same name")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate without changing snapshots")
    args = parser.parse_args()

    clone_dir = os.path.realpath(args.clone_dir)
    allowed_root = "/data/vms/soltest/"
    if not clone_dir.startswith(allowed_root):
        fail("refusing non-clone path outside %s: %s" %
             (allowed_root, clone_dir))
    if "/streamhost/tiles/" in clone_dir or clone_dir.endswith("/solaris"):
        fail("refusing a live tile path: %s" % clone_dir)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.snapshot):
        fail("snapshot name contains unsupported characters")

    pidfile = os.path.join(clone_dir, "qemu.pid")
    qmp_path = os.path.join(clone_dir, "qmp.sock")
    ghid_path = os.path.join(clone_dir, "gallery-hid.sock")
    pid = read_pid(pidfile)
    argv, uses_clone = qemu_uses_clone_disk(pid, clone_dir)
    if not uses_clone:
        fail("pid %d does not use a disk below the clone directory" % pid)
    if not argv or "qemu-system" not in os.path.basename(argv[0]):
        fail("pidfile does not identify qemu-system: %r" % argv[:1])
    if backend_connected(ghid_path):
        fail("gallery backend is still connected; release input and close it")

    qmp = QMP(qmp_path)
    try:
        status = qmp.command("query-status")
        if status.get("status") != "running":
            fail("VM is not running: %r" % status)
        bar0, bar2 = pci_bars(qmp)
        device_status = read_phys32(qmp, bar0 + 0x00C)
        irq_status = read_phys32(qmp, bar0 + 0x010)
        irq_mask = read_phys32(qmp, bar0 + 0x014)
        epoch = read_phys32(qmp, bar2 + 0x014)
        producer = read_phys32(qmp, bar2 + 0x040)
        consumer = read_phys32(qmp, bar2 + 0x080)
        last_epoch = read_phys32(qmp, bar2 + 0x084)

        if producer != consumer:
            fail("ring is not empty: producer=%u consumer=%u" %
                 (producer, consumer))
        if epoch == 0 or last_epoch != epoch:
            fail("driver generation is not armed: epoch=%u last_epoch=%u" %
                 (epoch, last_epoch))
        if not device_status & GHID_STATUS_DRIVER_READY:
            fail("driver-ready is clear: status=0x%x" % device_status)
        if device_status & (GHID_STATUS_CONNECTED | GHID_STATUS_RESET_REQ):
            fail("backend/reset state is not quiesced: status=0x%x" %
                 device_status)
        if irq_status != 0 or irq_mask != GHID_IRQ_ALL:
            fail("IRQ state is not settled: status=0x%x mask=0x%x" %
                 (irq_status, irq_mask))

        print("validated clone=%s pid=%d epoch=%u producer=consumer=%u "
              "status=0x%x irq_mask=0x%x" %
              (clone_dir, pid, epoch, producer, device_status, irq_mask))
        if args.dry_run:
            print("dry-run: snapshot unchanged")
            return

        before = qmp.hmp("info snapshots")
        exists = snapshot_exists(before, args.snapshot)
        if exists and not args.replace:
            fail("snapshot %r already exists; pass --replace" % args.snapshot)
        if exists:
            qmp.hmp("delvm %s" % args.snapshot)
        started = time.monotonic()
        qmp.hmp("savevm %s" % args.snapshot)
        elapsed = time.monotonic() - started
        after = qmp.hmp("info snapshots")
        if not snapshot_exists(after, args.snapshot):
            fail("snapshot was not listed after savevm")
        print("saved snapshot=%s seconds=%.3f" %
              (args.snapshot, elapsed))
    finally:
        qmp.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError,
            json.JSONDecodeError) as error:
        print("golden-bake: %s" % error, file=sys.stderr)
        sys.exit(1)
