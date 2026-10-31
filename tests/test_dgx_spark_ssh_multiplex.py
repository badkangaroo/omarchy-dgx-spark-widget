"""SSH multiplex session tests (no network)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "dgx-spark-status"


def load_module():
    from importlib.machinery import SourceFileLoader

    name = "dgx_spark_status_test"
    mod = SourceFileLoader(name, str(SCRIPT)).load_module()
    sys.modules[name] = mod
    return mod


class SshMultiplexTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def setUp(self):
        self.cfg = dict(self.mod.DEFAULTS) | {
            "sshTarget": "alex@spark-test",
            "sshUser": "alex",
            "host": "192.0.2.1",
            "connectTimeoutSec": 2.0,
            "sshControlPersist": "10m",
        }

    def test_ssh_base_cmd_includes_multiplex_options(self):
        cmd = self.mod.ssh_base_cmd(self.cfg, "alex@spark-test", 2.0)
        flat = " ".join(cmd)
        self.assertIn("ControlMaster=auto", flat)
        self.assertIn("ControlPersist=10m", flat)
        self.assertIn("ControlPath=", flat)
        self.assertIn("cm-%C", flat)
        self.assertEqual(cmd[-1], "alex@spark-test")

    def test_password_ssh_cmd_has_no_multiplex(self):
        cmd = self.mod.ssh_password_cmd(self.cfg, "alex@spark-test")
        flat = " ".join(cmd)
        self.assertNotIn("ControlMaster", flat)
        self.assertNotIn("ControlPath", flat)

    def test_status_tick_one_ssh_data_call_when_master_alive(self):
        metrics_stdout = "OK\nspark\nalex\nMETRICS_JSON:{\"cpuPct\":1.0,\"memPct\":2.0,\"gpus\":[]}\n"
        calls: list[list[str]] = []

        def fake_run(cmd, *args, **kwargs):
            calls.append(list(cmd))
            if "-O" in cmd and "check" in cmd:
                return mock.Mock(returncode=0, stdout="", stderr="")
            return mock.Mock(returncode=0, stdout=metrics_stdout, stderr="")

        with mock.patch.object(self.mod.subprocess, "run", side_effect=fake_run):
            auth, device = self.mod.collect_auth_and_device_metrics(self.cfg, "192.0.2.1")

        data_calls = [c for c in calls if c and c[0] == "ssh" and "-O" not in c]
        self.assertEqual(len(data_calls), 1)
        self.assertTrue(auth.get("ok"))
        self.assertTrue(device and device.get("ok"))

    def test_status_tick_combined_auth_header_when_no_master(self):
        metrics_stdout = "OK\nspark\nalex\nMETRICS_JSON:{\"cpuPct\":3.0,\"gpus\":[]}\n"
        calls: list[list[str]] = []

        def fake_run(cmd, *args, **kwargs):
            calls.append(list(cmd))
            if "-O" in cmd and "check" in cmd:
                return mock.Mock(returncode=1, stdout="", stderr="")
            return mock.Mock(returncode=0, stdout=metrics_stdout, stderr="")

        with mock.patch.object(self.mod.subprocess, "run", side_effect=fake_run):
            self.mod.collect_auth_and_device_metrics(self.cfg, "192.0.2.1")

        data_calls = [c for c in calls if c and c[0] == "ssh" and "-O" not in c]
        self.assertEqual(len(data_calls), 1)
        remote = data_calls[0][-1]
        self.assertTrue(remote.startswith("echo OK; hostname; whoami"))

    def test_exit_255_triggers_exit_and_single_retry(self):
        calls: list[list[str]] = []
        data_attempts = {"n": 0}

        def fake_run(cmd, *args, **kwargs):
            calls.append(list(cmd))
            if "-O" in cmd:
                return mock.Mock(returncode=0, stdout="", stderr="")
            if "-G" in cmd:
                return mock.Mock(returncode=0, stdout="controlpath /tmp/x\n", stderr="")
            data_attempts["n"] += 1
            if data_attempts["n"] == 1:
                return mock.Mock(returncode=255, stdout="", stderr="Permission denied (publickey).")
            return mock.Mock(returncode=0, stdout="OK\n", stderr="")

        with mock.patch.object(self.mod.subprocess, "run", side_effect=fake_run):
            result = self.mod.ssh_run(self.cfg, "alex@spark-test", "echo OK", 2.0)

        exit_calls = [c for c in calls if c and "-O" in c and "exit" in c]
        self.assertEqual(data_attempts["n"], 2)
        self.assertEqual(len(exit_calls), 1)
        self.assertTrue(result.get("ok"))

    def test_second_failure_after_255_does_not_loop(self):
        calls: list[list[str]] = []

        def fake_run(cmd, *args, **kwargs):
            calls.append(list(cmd))
            if "-O" in cmd:
                return mock.Mock(returncode=0, stdout="", stderr="")
            if "-G" in cmd:
                return mock.Mock(returncode=0, stdout="controlpath /tmp/x\n", stderr="")
            return mock.Mock(returncode=255, stdout="", stderr="Permission denied (publickey).")

        with mock.patch.object(self.mod.subprocess, "run", side_effect=fake_run):
            result = self.mod.ssh_run(self.cfg, "alex@spark-test", "echo OK", 2.0)

        data_calls = [c for c in calls if c and c[0] == "ssh" and "-O" not in c and "-G" not in c]
        self.assertEqual(len(data_calls), 2)
        self.assertFalse(result.get("ok"))

    def test_debug_log_never_contains_password_marker(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "dbg.log"
            self.mod.configure_debug_log(path)
            self.mod.reset_tick_debug()
            self.mod.note_tick_reauth("exit 255")
            self.mod.note_tick_session(reused=False)
            self.mod.flush_tick_debug_log()
            text = path.read_text(encoding="utf-8")
        self.assertIn("NEW_LOGIN", text)
        self.assertNotIn("password", text.lower())
        self.assertNotIn("askpass", text.lower())

    def test_askpass_env_does_not_put_password_on_argv(self):
        env, pass_file, ask_file = self.mod.askpass_env("hunter2")
        try:
            self.assertNotIn("hunter2", str(ask_file))
            self.assertNotIn("hunter2", ask_file.read_text(encoding="utf-8"))
        finally:
            self.mod.cleanup_askpass(pass_file, ask_file)

    def test_close_session_invokes_ssh_exit(self):
        calls: list[list[str]] = []

        def fake_run(cmd, *args, **kwargs):
            calls.append(list(cmd))
            return mock.Mock(returncode=0, stdout="controlpath /tmp/fake\n", stderr="")

        with mock.patch.object(self.mod.subprocess, "run", side_effect=fake_run):
            self.mod.ssh_master_exit(self.cfg, "alex@spark-test", 2.0)

        exit_cmds = [c for c in calls if "-O" in c and "exit" in c]
        self.assertEqual(len(exit_cmds), 1)
        self.assertIn("ControlMaster=auto", " ".join(exit_cmds[0]))


if __name__ == "__main__":
    unittest.main()
