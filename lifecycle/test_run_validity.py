"""Tests for the benchmark run-validity gate (lifecycle/run_validity.sh).

Abort text below is copied from the preserved baseline job 853208
(result-c4.txt, result-c8.txt, warmup-c16.txt).
"""
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent

ABORTED_RUN = """\
progress: 10.0 s, 3.2 tps, lat 1210.5 ms stddev 900.1, 0 failed, 0 retried, 0 retries
pgbench: error: client 0 script 6 aborted in command 39 query 0: ERROR:  could not commit transaction for shard 102090 on at least one active node
pgbench: error: client 1 script 6 aborted in command 39 query 0: ERROR:  could not commit transaction for shard 102089 on at least one active node
transaction type: multiple scripts
number of transactions actually processed: 1938
number of failed transactions: 8 (0.411%)
number of serialization failures: 8 (0.411%)
pgbench: error: Run was aborted; the above results are incomplete.
pgbench_exit_code=2
tee_exit_code=0
"""

# Serialization failures that exhausted --max-tries: counted as failed, no abort.
FAILED_BUT_COMPLETE_RUN = """\
transaction type: multiple scripts
number of transactions actually processed: 2077
number of failed transactions: 84 (3.887%)
number of serialization failures: 84 (3.887%)
pgbench_exit_code=0
tee_exit_code=0
"""

CLEAN_RUN = """\
transaction type: multiple scripts
number of transactions actually processed: 500
number of failed transactions: 0 (0.000%)
pgbench_exit_code=0
tee_exit_code=0
"""


def bash(body, timeout=30):
    return subprocess.run(
        ["bash", "-s"], input=body, capture_output=True, text=True, timeout=timeout,
    )


UNEXPECTED_ABORT_RUN = """\
pgbench: error: client 3 script 0 aborted in command 12 query 0: FATAL:  terminating connection due to administrator command
server closed the connection unexpectedly
transaction type: multiple scripts
pgbench: error: Run was aborted; the above results are incomplete.
pgbench_exit_code=2
"""

MIXED_ABORT_RUN = """\
pgbench: error: client 0 script 6 aborted in command 39 query 0: ERROR:  could not commit transaction for shard 102090 on at least one active node
pgbench: error: client 5 script 2 aborted in command 3 query 0: ERROR:  canceling statement due to statement timeout
pgbench: error: Run was aborted; the above results are incomplete.
pgbench_exit_code=2
"""

INCOMPLETE_WITHOUT_ABORT_RECORD = """\
transaction type: multiple scripts
pgbench: error: Run was aborted; the above results are incomplete.
pgbench_exit_code=2
"""


class ClassifyRunTests(unittest.TestCase):
    def classify(self, warmup_rc, warmup_text, measured_rc, measured_text):
        with tempfile.TemporaryDirectory() as d:
            warmup = Path(d) / "warmup.txt"
            measured = Path(d) / "result.txt"
            measured.write_text(measured_text)
            if warmup_text is None:
                warmup_arg = "-"
            else:
                warmup.write_text(warmup_text)
                warmup_arg = shlex.quote(str(warmup))
            result = bash(
                f"set -euo pipefail\nsource {shlex.quote(str(ROOT / 'run_validity.sh'))}\n"
                f"classify_run {warmup_rc} {warmup_arg} {measured_rc} {shlex.quote(str(measured))}"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

    def test_clean_run_is_valid(self):
        self.assertEqual(self.classify(0, CLEAN_RUN, 0, CLEAN_RUN), "1,0,0,ok")

    def test_serialization_failures_without_aborts_are_valid(self):
        self.assertEqual(self.classify(0, CLEAN_RUN, 0, FAILED_BUT_COMPLETE_RUN), "1,0,0,ok")

    def test_known_commit_aborts_are_accepted_and_counted(self):
        self.assertEqual(self.classify(0, CLEAN_RUN, 2, ABORTED_RUN),
                         "1,0,2,measured_known_commit_aborts_2")

    def test_known_warmup_aborts_are_accepted_and_counted(self):
        self.assertEqual(self.classify(2, ABORTED_RUN, 0, CLEAN_RUN),
                         "1,2,0,warmup_known_commit_aborts_2")

    def test_unexpected_abort_is_invalid(self):
        self.assertEqual(self.classify(0, CLEAN_RUN, 2, UNEXPECTED_ABORT_RUN),
                         "0,0,1,measured_unexpected_aborts_1")

    def test_unexpected_warmup_abort_invalidates_measurement(self):
        self.assertEqual(self.classify(2, UNEXPECTED_ABORT_RUN, 0, CLEAN_RUN),
                         "0,1,0,warmup_unexpected_aborts_1")

    def test_mixed_aborts_are_invalid_and_list_both(self):
        self.assertEqual(self.classify(0, CLEAN_RUN, 2, MIXED_ABORT_RUN),
                         "0,0,2,measured_unexpected_aborts_1;measured_known_commit_aborts_1")

    def test_nonzero_exit_without_abort_text_is_invalid(self):
        self.assertEqual(self.classify(0, CLEAN_RUN, 1, CLEAN_RUN), "0,0,0,measured_exit_1")

    def test_incomplete_run_without_abort_record_is_invalid(self):
        self.assertEqual(self.classify(0, CLEAN_RUN, 2, INCOMPLETE_WITHOUT_ABORT_RECORD),
                         "0,0,0,measured_exit_2;measured_incomplete")

    def test_no_warmup_is_supported(self):
        self.assertEqual(self.classify("-", None, 0, CLEAN_RUN), "1,0,0,ok")


FAKE_PGBENCH = r"""#!/usr/bin/env bash
# Fake pgbench: aborts clients ($ABORT_KIND=known|unexpected) when -c is listed in $ABORT_MEASURED/$ABORT_WARMUP.
clients=0 prefix="" logging=0
for arg in "$@"; do
	case "$prev" in -c) clients="$arg" ;; esac
	case "$arg" in --log-prefix=*) prefix="${arg#--log-prefix=}"; logging=1 ;; esac
	prev="$arg"
done
if ((logging)); then
	printf '0 1 5000 0 0 0\n1 1 7000 1 0 0\n' >"${prefix}.100"
	list="$ABORT_MEASURED"
else
	list="$ABORT_WARMUP"
fi
echo "transaction type: multiple scripts"
if [[ " $list " == *" $clients "* ]]; then
	if [[ "$ABORT_KIND" == unexpected ]]; then
		echo "pgbench: error: client 0 script 0 aborted in command 12 query 0: FATAL:  terminating connection due to administrator command"
	else
		echo "pgbench: error: client 0 script 6 aborted in command 39 query 0: ERROR:  could not commit transaction for shard 102090 on at least one active node"
		echo "pgbench: error: client 1 script 6 aborted in command 39 query 0: ERROR:  could not commit transaction for shard 102089 on at least one active node"
	fi
	echo "pgbench: error: Run was aborted; the above results are incomplete."
	exit 2
fi
echo "number of transactions actually processed: 2"
exit 0
"""

FAKE_PSQL = r"""#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == *"MAX(merchant_id)"* ]] && { echo "10|100|100|100"; exit 0; }; done
cat >/dev/null
"""


class BenchmarkGateIntegrationTests(unittest.TestCase):
    """Run the real run_benchmark loop and final gate from each runner."""

    def run_runner(self, experiment, abort_measured="", abort_warmup="", fail_on_invalid=None, kind="known"):
        """fail_on_invalid=None uses the runner's own FAIL_ON_INVALID_RUN default line."""
        runner = (ROOT.parent / experiment / "run.sh").read_text()
        default_line = next(l for l in runner.splitlines() if l.startswith("FAIL_ON_INVALID_RUN="))
        fail_setting = default_line if fail_on_invalid is None else f"FAIL_ON_INVALID_RUN={fail_on_invalid}"
        tail = "############### Functions: analyze benchmark results" + runner.split(
            "############### Functions: analyze benchmark results", 1)[1]
        d = tempfile.mkdtemp()
        tx = Path(d) / "transactions"
        tx.mkdir()
        for name in ("T1_place_order", "T2_update_inventory", "T3_order_history", "T4_product_lookup",
                     "T5_update_order_status", "T6_global_sales", "T7_inventory_transfer",
                     "T8_update_customer", "T9_update_product"):
            (tx / f"{name}.sql").write_text("SELECT 1;\n")
        for name, body in (("pgbench", FAKE_PGBENCH), ("psql", FAKE_PSQL)):
            path = Path(d) / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC)
        run_dir = Path(d) / "job" / "benchmark-results"
        run_dir.mkdir(parents=True)
        q = lambda p: shlex.quote(str(p))
        prelude = f"""
set -euo pipefail
info() {{ echo "[info] $*"; }}
fail() {{ echo "ERROR: $*" >&2; exit 1; }}
check_server_steps() {{ :; }}
restart_postgres_servers() {{ :; }}
source {q(ROOT / 'run_validity.sh')}
INVALID_RUN_COUNT=0
export ABORT_MEASURED={shlex.quote(abort_measured)} ABORT_WARMUP={shlex.quote(abort_warmup)} ABORT_KIND={kind}
PGBENCH={q(Path(d) / 'pgbench')}; PSQL={q(Path(d) / 'psql')}
PGHOST=h; PGPORT=1; PGUSER=u; PGDATABASE=db; COORDINATOR=h; WORKERS=(w1 w2)
JOB_RESULT_DIR={q(run_dir.parent)}; RUN_DIR={q(run_dir)}; LOG_DIR={q(run_dir / 'logs')}
TX_DIR={q(tx)}; BENCHMARK_LOG_FILE={q(run_dir.parent / 'benchmark.log')}
SUMMARY_FILE={q(run_dir / 'summary.csv')}; TX_METRICS_FILE={q(run_dir / 'tx.csv')}
BENCHMARK_CONFIG_FILE={q(run_dir / 'config.txt')}; README_METRICS_FILE={q(run_dir / 'README.txt')}
CLIENT_COUNTS="1 4 8"; DURATION=10; WARMUP_DURATION=5; THREADS=4; PROGRESS_INTERVAL=10
LOG_SAMPLE_RATE=1.0; PGBENCH_SEED=42; PGBENCH_MAX_TRIES=3; PGBENCH_FAILURES_DETAILED=1
PGBENCH_QUERY_MODE=simple
{fail_setting}
RESET_BETWEEN_CLIENT_COUNTS=0; RESET_AFTER_WARMUP=0; RESTART_SERVERS_BETWEEN_CLIENT_COUNTS=0
T1_WEIGHT=10; T2_WEIGHT=10; T3_WEIGHT=5; T4_WEIGHT=5; T5_WEIGHT=10; T6_WEIGHT=10; T7_WEIGHT=30
T8_WEIGHT=10; T9_WEIGHT=10; MIN_ITEMS_PER_ORDER=1; MAX_ITEMS_PER_ORDER=5; HOT_MERCHANT_PERCENT=10
HOT_ORDER_PERCENT=50; MIN_ORDER_QTY=1; MAX_ORDER_QTY=5; INVENTORY_CHANGE_MIN=-5; INVENTORY_CHANGE_MAX=20
REPORT_DAYS=30; T7_MIN_TRANSFER_QTY=1; T7_MAX_TRANSFER_QTY=5; SCALE=1; DATA_SEED=42
PG_SHARED_BUFFERS=x; PG_WORK_MEM=x; PG_MAINTENANCE_WORK_MEM=x; PG_MAX_CONNECTIONS=x; PG_ISOLATION_LEVEL=serializable
PG_MAX_WAL_SIZE=x; PG_MIN_WAL_SIZE=x; PG_CHECKPOINT_TIMEOUT=x; PG_CHECKPOINT_COMPLETION_TARGET=x
CITUS_ENABLE_REPARTITION_JOINS=x; CITUS_MAX_SHARED_POOL_SIZE=x; CITUS_MAX_ADAPTIVE_EXECUTOR_POOL_SIZE=x
CITUS_LOCAL_SHARED_POOL_SIZE=x; SERVER_RESTART_TIMEOUT=60
"""
        try:
            result = bash(prelude + tail, timeout=60)
            summary_file = run_dir / "summary.csv"
            summary = summary_file.read_text().splitlines() if summary_file.exists() else []
            log_file = run_dir.parent / "benchmark.log"
            log = log_file.read_text() if log_file.exists() else ""
        finally:
            shutil.rmtree(d, ignore_errors=True)
        # Surface the runner's own log in assertion messages.
        result.stderr += "\n--- benchmark.log tail ---\n" + log[-1500:]
        return result, summary

    def rows(self, summary):
        header = summary[0].split(",")
        return {r.split(",")[0]: dict(zip(header, r.split(","))) for r in summary[1:]}

    def test_all_clean_runs_pass(self):
        for experiment in ("expt_a0", "expt_b0"):
            with self.subTest(experiment=experiment):
                result, summary = self.run_runner(experiment)
                self.assertEqual(result.returncode, 0, result.stderr)
                rows = self.rows(summary)
                self.assertEqual(sorted(rows), ["1", "4", "8"])
                self.assertTrue(all(r["valid"] == "1" and r["validity_notes"] == "ok" for r in rows.values()))

    def test_known_aborts_keep_rows_valid_and_record_counts(self):
        for experiment in ("expt_a0", "expt_b0"):
            with self.subTest(experiment=experiment):
                result, summary = self.run_runner(experiment, abort_measured="4", abort_warmup="8")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("INVALID", result.stderr.split("--- benchmark.log tail ---")[0])
                rows = self.rows(summary)
                self.assertEqual([rows[c]["valid"] for c in ("1", "4", "8")], ["1", "1", "1"])
                self.assertEqual((rows["4"]["measured_aborted_clients"], rows["4"]["pgbench_exit_code"]), ("2", "2"))
                self.assertEqual(rows["4"]["validity_notes"], "measured_known_commit_aborts_2")
                self.assertEqual(rows["8"]["warmup_aborted_clients"], "2")
                self.assertEqual(rows["8"]["validity_notes"], "warmup_known_commit_aborts_2")

    def test_known_aborts_do_not_fail_job_even_when_failing_is_enabled(self):
        result, summary = self.run_runner("expt_b0", abort_measured="1 4 8", fail_on_invalid=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(r["valid"] == "1" for r in self.rows(summary).values()))

    def test_default_marks_unexpected_abort_invalid_but_job_succeeds(self):
        for experiment in ("expt_a0", "expt_b0"):
            with self.subTest(experiment=experiment):
                result, summary = self.run_runner(experiment, abort_measured="4", kind="unexpected")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("WARNING: 1 client-count run(s) INVALID", result.stderr)
                self.assertNotIn("ERROR:", result.stderr.split("--- benchmark.log tail ---")[0])
                rows = self.rows(summary)
                self.assertEqual(sorted(rows), ["1", "4", "8"], "later client counts still run")
                self.assertEqual([rows[c]["valid"] for c in ("1", "4", "8")], ["1", "0", "1"])
                self.assertEqual(rows["4"]["validity_notes"], "measured_unexpected_aborts_1")

    def test_unexpected_abort_fails_job_when_enabled(self):
        for experiment in ("expt_a0", "expt_b0"):
            with self.subTest(experiment=experiment):
                result, _ = self.run_runner(experiment, abort_measured="4", kind="unexpected", fail_on_invalid=1)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR: Benchmark produced invalid runs", result.stderr)

    def test_unexpected_warmup_abort_invalidates_measurement(self):
        result, summary = self.run_runner("expt_b0", abort_warmup="8", kind="unexpected")
        self.assertEqual(result.returncode, 0, result.stderr)
        row = self.rows(summary)["8"]
        self.assertEqual((row["valid"], row["warmup_aborted_clients"], row["pgbench_exit_code"]), ("0", "1", "0"))
        self.assertEqual(row["validity_notes"], "warmup_unexpected_aborts_1")


if __name__ == "__main__":
    unittest.main()
