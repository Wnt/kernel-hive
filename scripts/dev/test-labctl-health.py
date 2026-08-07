#!/usr/bin/env python3
"""Focused regression tests for the read-only labctl health/assert helpers."""

import contextlib
import importlib.machinery
import io
import json
import os
import pathlib
import tempfile
import types
import unittest
from unittest import mock

LABCTL = importlib.machinery.SourceFileLoader(
    "labctl_under_test",
    str(pathlib.Path(__file__).resolve().parents[1] / "labctl"),
).load_module()


def journal_line(message, stamp):
    return json.dumps({"MESSAGE": message, "__REALTIME_TIMESTAMP": str(stamp)})


class LabctlHealthTest(unittest.TestCase):
    def test_journal_health_uses_only_current_daemon_invocation(self):
        lines = [
            journal_line("[streamhost] tile=helenos qmp=old", 1),
            journal_line("[streamhost] encoder up", 2),
            journal_line("[transport] SESSION_ACCEPTED addr=old", 3),
            journal_line("[streamhost] tile=helenos qmp=current", 10),
            journal_line("[capture] rss-guard ON: qemu pid=7 anon=26 MB, trip at +2048 MB", 11),
            journal_line("[streamhost] encoder up", 12),
            journal_line("[transport] SESSION_ACCEPTED addr=a", 13),
            journal_line("[transport] SESSION_ACCEPTED addr=b", 14),
            journal_line("[transport] SESSION_ENDED", 15),
            journal_line("[encode] enc latency (snap->AU) us: p50=1", 16),
        ]
        result = types.SimpleNamespace(returncode=0, stdout="\n".join(lines), stderr="")
        with mock.patch.object(LABCTL.subprocess, "run", return_value=result):
            health = LABCTL.journal_health("helenos")
        self.assertTrue(health["encoder_up"])
        self.assertEqual(health["sessions"], 1)
        self.assertEqual(health["guard_base_mb"], 26)
        self.assertEqual(health["guard_mb"], 2048)
        self.assertEqual(health["last_damage_us"], 16)

    def test_env_reader_never_sources_shell(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as env:
            env.write("SH_QEMU_RSS_GUARD_MB=512\n")
            env.write("BAD=$(touch /tmp/must-not-run)\n")
            path = env.name
        values = LABCTL.read_env(path)
        pathlib.Path(path).unlink()
        self.assertEqual(values["SH_QEMU_RSS_GUARD_MB"], "512")
        self.assertEqual(values["BAD"], "$(touch /tmp/must-not-run)")

    def test_age_format(self):
        self.assertEqual(LABCTL.age_text(None), "?")
        self.assertEqual(LABCTL.age_text(8.8), "8s")
        self.assertEqual(LABCTL.age_text(125), "2m05s")
        self.assertEqual(LABCTL.age_text(7380), "2h03m")

    def test_assert_capture_does_not_resume_guest(self):
        ok = types.SimpleNamespace(returncode=0, stdout='{"found":true}\n', stderr="")

        def fake_capture(_name, _conf, out, resume):
            self.assertFalse(resume)
            pathlib.Path(out).write_bytes(b"png")

        with (
            mock.patch.object(LABCTL, "tile_conf", return_value={"qmp": "/fake"}),
            mock.patch.object(LABCTL, "capture_png", side_effect=fake_capture),
            mock.patch.object(LABCTL, "run_vision", return_value=ok),
            mock.patch.object(LABCTL, "ensure_running") as ensure,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            LABCTL.cmd_assert(["helenos", "--text", "HelenOS"])
        ensure.assert_not_called()


class LabctlPauseTest(unittest.TestCase):
    """The non-QEMU arm of idle auto-pause: an x11/shm tile is SIGSTOPped by
    pidfile, so labctl must thaw it with SIGCONT rather than HMP 'cont'."""

    def pidfile(self, body):
        with tempfile.NamedTemporaryFile("w", delete=False) as fh:
            fh.write(body)
            return fh.name

    def test_proc_stopped_reads_kernel_state(self):
        # This process is running, so it must not read as stopped — and comm is
        # parsed after the ')' so spaces/parens in it cannot shift the columns.
        path = self.pidfile(f"{os.getpid()}\n")
        pid, stopped = LABCTL.proc_stopped(path)
        pathlib.Path(path).unlink()
        self.assertIsNotNone(pid)
        self.assertFalse(stopped)

    def test_proc_stopped_tolerates_unusable_pidfiles(self):
        for body in ("", "not-a-pid\n", "999999999\n"):
            path = self.pidfile(body)
            self.assertEqual(LABCTL.proc_stopped(path), (None, False), body)
            pathlib.Path(path).unlink()

    def test_ensure_running_sigconts_a_stopped_emulator(self):
        conf = {"qmp": None, "dir": "/nonexistent"}
        with (
            mock.patch.object(LABCTL, "pause_pidfile", return_value="/fake.pid"),
            mock.patch.object(LABCTL, "proc_stopped", return_value=(4242, True)),
            mock.patch.object(LABCTL.os, "kill") as kill,
            mock.patch.object(LABCTL, "hmp") as hmp,
        ):
            LABCTL.ensure_running(conf, "irix")
        kill.assert_called_once_with(4242, LABCTL.signal.SIGCONT)
        hmp.assert_not_called()

    def test_ensure_running_leaves_a_running_emulator_alone(self):
        conf = {"qmp": None, "dir": "/nonexistent"}
        with (
            mock.patch.object(LABCTL, "pause_pidfile", return_value="/fake.pid"),
            mock.patch.object(LABCTL, "proc_stopped", return_value=(4242, False)),
            mock.patch.object(LABCTL.os, "kill") as kill,
        ):
            LABCTL.ensure_running(conf, "irix")
        kill.assert_not_called()

    def test_ensure_running_still_uses_qmp_on_qemu_tiles(self):
        with (
            mock.patch.object(LABCTL, "hmp") as hmp,
            mock.patch.object(LABCTL.os, "kill") as kill,
        ):
            LABCTL.ensure_running({"qmp": "/fake.sock"}, "helenos")
        hmp.assert_called_once()
        self.assertEqual(hmp.call_args[0][1], "cont")
        kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
