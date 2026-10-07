#!/usr/bin/env bash
set -euo pipefail

(($# == 1)) || {
	echo "usage: scripts/smoke-test-experiment.sh <expt>" >&2
	exit 2
}

export LOCAL_CLUSTER="citus-smoke-$$"
source "$(dirname "$0")/cluster/local.sh"

EXPT=$(basename "$1")
check_folder "$EXPT"
SMALL_RUN_SETTINGS=(SCALE=0.05 "CLIENT_COUNTS=1 16" WARMUP_DURATION=5 DURATION=30)
STEP_LOG=$(mktemp)

step() {
	echo "==> $*"
	: >"$STEP_LOG"
}

finish() {
	local rc=$?
	set +e
	if ((rc != 0)); then
		echo "--- last output ---"
		tail -n 80 "$STEP_LOG"
		echo "FAIL $EXPT"
	fi
	cmd_down >/dev/null 2>&1
	rm -f "$STEP_LOG"
	exit "$rc"
}
trap finish EXIT

requested_nodes() {
	local directive
	directive=$(grep -m 1 '^#SBATCH --nodes=' "$ROOT/$EXPT/run.sh") || die "$EXPT/run.sh has no '#SBATCH --nodes=N' line"
	echo "${directive#*=}"
}

nodes=$(requested_nodes)

step "Starting a Local Cluster with $nodes nodes"
(cmd_up "$nodes") >"$STEP_LOG" 2>&1

step "Pushing $EXPT"
(cmd_push "$EXPT") >"$STEP_LOG" 2>&1

step "Running $EXPT"
rc=0
job=$(sbatch_run_sh "$EXPT" --wait "${SMALL_RUN_SETTINGS[@]}" 2>"$STEP_LOG") || rc=$?
job=${job%%;*}
if ((rc != 0)); then
	[[ -z "$job" ]] || (cmd_tail "$EXPT" "$job") >>"$STEP_LOG" 2>&1
	echo "Job ${job:-(not submitted)} failed with exit code $rc" >>"$STEP_LOG"
	exit 1
fi

step "Checking job $job"
results="$PROJECT_DIR/$EXPT/slurm-results/job-$job/benchmark-results"
on_login_node 'cat "$1/summary.csv"' "$results" 2>"$STEP_LOG" | sed 's/^/    /'

unexpected_aborts=$(on_login_node 'cat "$1"/warmup-c*.txt "$1"/result-c*.txt' "$results" 2>"$STEP_LOG" |
	grep '^pgbench: error: client .* aborted' | grep -v "$CITUS_COMMIT_CONFLICT" || true)
if [[ -n "$unexpected_aborts" ]]; then
	echo "Clients aborted on errors other than Citus commit conflicts:" >"$STEP_LOG"
	echo "$unexpected_aborts" >>"$STEP_LOG"
	exit 1
fi

never_succeeded=$(on_login_node 'cat "$1/transaction_metrics.csv"' "$results" 2>"$STEP_LOG" | awk -F, '
	NR == 1 { for (i = 1; i <= NF; i++) column_index[$i] = i; next }
	$column_index["name"] != "\"disabled\"" { ok[$column_index["transaction"]] += $column_index["successful_transactions"] }
	END { for (t in ok) if (ok[t] == 0) print t }
' | sort)
if [[ -n "$never_succeeded" ]]; then
	echo "Transactions that never succeeded: ${never_succeeded//$'\n'/ }" >"$STEP_LOG"
	exit 1
fi

echo "PASS $EXPT"
