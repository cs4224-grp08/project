import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import unittest

from port_guard import reserve


ROOT = Path(__file__).resolve().parent


class LifecycleTests(unittest.TestCase):
    def shell(self, body):
        return subprocess.run(
            ["bash", "-s"], input=f"source {shlex.quote(str(ROOT / 'servers.sh'))}\n{body}",
            capture_output=True, text=True, timeout=10,
        )

    def test_lock_rejects_second_holder_and_can_be_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "port.lock"
            descriptor = reserve(lock, 0)
            try:
                with self.assertRaises(BlockingIOError):
                    reserve(lock, 0)
            finally:
                os.close(descriptor)
            os.close(reserve(lock, 0))

    def test_listener_rejects_reservation(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket() as listener:
            listener.bind(("0.0.0.0", 0))
            listener.listen()
            with self.assertRaises(OSError):
                reserve(Path(directory) / "port.lock", listener.getsockname()[1])

    def test_wrong_server_is_rejected(self):
        result = self.shell("fake_psql() { echo /wrong/data; }; PSQL=fake_psql; PGPORT=5440; PGUSER=test; PGDATA=/expected/data; verify_server_identity node")
        self.assertNotEqual(result.returncode, 0)

    def test_guard_release_removes_ready_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / "node-port.ready"
            ready.write_text("123\n")
            result = self.shell(f"NODES=(node); JOB_RESULT_DIR={shlex.quote(directory)}; release_port_guards")
            self.assertEqual((result.returncode, ready.exists()), (0, False))

    def test_expected_server_is_accepted(self):
        result = self.shell("fake_psql() { echo /expected/data; }; PSQL=fake_psql; PGPORT=5440; PGUSER=test; PGDATA=/expected/data; verify_server_identity node")
        self.assertEqual(result.returncode, 0)

    def test_stop_failure_is_reported(self):
        result = self.shell("control() { if [[ $3 == status ]]; then return 0; else return 1; fi; }; stop_local_verified control /tmp 1")
        self.assertNotEqual(result.returncode, 0)

    def test_unknown_status_is_not_treated_as_stopped(self):
        result = self.shell("control() { return 4; }; stop_local_verified control /tmp 1")
        self.assertNotEqual(result.returncode, 0)

    def test_live_data_directory_cannot_be_reinitialized(self):
        result = self.shell("control() { return 0; }; check_data_stopped control /tmp")
        self.assertNotEqual(result.returncode, 0)

    def test_stopped_server_is_accepted(self):
        result = self.shell("control() { return 3; }; stop_local_verified control /tmp 1")
        self.assertEqual(result.returncode, 0)

    def test_shutdown_is_verified_after_successful_stop(self):
        result = self.shell("running=1; control() { if [[ $3 == stop ]]; then running=0; return 0; fi; if ((running)); then return 0; else return 3; fi; }; stop_local_verified control /tmp 1")
        self.assertEqual(result.returncode, 0)

    def test_cleanup_failure_changes_job_exit_status(self):
        for experiment in ("expt_a0", "expt_b0"):
            with self.subTest(experiment=experiment), tempfile.TemporaryDirectory() as directory:
                runner = (ROOT.parent / experiment / "run.sh").read_text()
                cleanup = "cleanup() {" + runner.split("cleanup() {", 1)[1].split("### reap srun processes", 1)[0]
                result = self.shell(
                    f"{cleanup}\nCLEANUP_STARTED=0; SERVERS_LAUNCHED=1; NODES=(node); "
                    f"JOB_RESULT_DIR={shlex.quote(directory)}; "
                    "stop_node_verified() { return 1; }; bounded_wait_server_pids() { :; }; "
                    "release_port_guards() { :; }; trap cleanup EXIT; exit 0"
                )
                self.assertNotEqual(result.returncode, 0)

    def test_cleanup_preserves_original_failure(self):
        runner = (ROOT.parent / "expt_b0" / "run.sh").read_text()
        cleanup = "cleanup() {" + runner.split("cleanup() {", 1)[1].split("### reap srun processes", 1)[0]
        result = self.shell(f"{cleanup}\nCLEANUP_STARTED=0; SERVERS_LAUNCHED=0; release_port_guards() {{ :; }}; trap cleanup EXIT; exit 7")
        self.assertEqual(result.returncode, 7)


if __name__ == "__main__":
    unittest.main()
