#!/usr/bin/env bash
# Builds citus_project_team_08/ for the submission: each experiment's run.sh and
# transactions/ from this repo, plus every reported job in README.md that
# completed all six client counts, copied in full from the cluster.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SUBMISSION_DIR=${SUBMISSION_DIR:-$ROOT/citus_project_team_08}
LOGIN_NODE=${CLUSTER_HOST:-cs5424}
EXPECTED_CLIENT_COUNTS=${EXPECTED_CLIENT_COUNTS:-6}
SSH_COMMAND="ssh -o BatchMode=yes -o ControlPath=${CLUSTER_CONTROL_PATH:-$HOME/.ssh/cm-%C}"

reported_jobs() {
	grep -E '^\| `expt_[ab][0-9]+`' "$ROOT/README.md" | while IFS='|' read -r _ folder_cell _ _ _ reported_job_cell _; do
		local experiment
		experiment=$(tr -d ' `' <<<"$folder_cell")
		grep -oE '[0-9]{6,}' <<<"$reported_job_cell" | sed "s/^/$experiment /" || echo "$experiment"
	done
}

describe_remote_job() {
	local experiment=$1 job=$2
	$SSH_COMMAND "$LOGIN_NODE" bash -s -- "$experiment" "$job" <<'EOF'
job_directory=$(ls -d ~/citus_project*/"$1"/slurm-results/job-"$2" ~/citus_project_worktrees/*/"$1"/slurm-results/job-"$2" ~/runs/*/*/"$1"/slurm-results/job-"$2" 2>/dev/null | head -1)
[[ -n "$job_directory" ]] || { echo "missing"; exit; }
job_state=$(sacct -j "$2" -X -n -o State%20 2>/dev/null | tr -d ' ')
client_count=$(($( (wc -l <"$job_directory/benchmark-results/summary.csv") 2>/dev/null || echo 1) - 1))
echo "$job_directory ${job_state:-unknown} $client_count"
EOF
}

mkdir -p "$SUBMISSION_DIR"
cp "$ROOT/README.md" "$ROOT/install_citus_slurm.sh" "$SUBMISSION_DIR/"

copied_jobs=()
skipped_jobs=()
experiments_without_results=()
while read -r experiment job; do
	if [[ -z "${job:-}" ]]; then
		experiments_without_results+=("$experiment")
		continue
	fi
	read -r job_directory job_state client_count < <(describe_remote_job "$experiment" "$job")
	# Slurm's accounting forgets old jobs, so "unknown" counts as finished when every client count has results
	if [[ "$job_directory" == missing || ! "$job_state" =~ ^(COMPLETED|unknown)$ || "$client_count" -ne "$EXPECTED_CLIENT_COUNTS" ]]; then
		skipped_jobs+=("$experiment:$job (${job_state:-missing}, ${client_count:-0} client counts)")
		continue
	fi
	experiment_directory="$SUBMISSION_DIR/$experiment"
	rsync -a --exclude slurm-results --exclude 'citus-*' "$ROOT/$experiment/" "$experiment_directory/"
	mkdir -p "$experiment_directory/slurm-results"
	rsync -az -e "$SSH_COMMAND" "$LOGIN_NODE:$job_directory/" "$experiment_directory/slurm-results/job-$job/"
	rsync -az -e "$SSH_COMMAND" "$LOGIN_NODE:$(dirname "$(dirname "$job_directory")")/citus-$job."{out,err} "$experiment_directory/"
	copied_jobs+=("$experiment:$job")
	echo "copied $experiment job $job"
done < <(reported_jobs)

for experiment_directory in "$SUBMISSION_DIR"/expt_*/; do
	[[ -d "$experiment_directory/slurm-results" ]] || experiments_without_results+=("$(basename "$experiment_directory")")
done

echo
echo "Copied ${#copied_jobs[@]} jobs into $SUBMISSION_DIR"
if ((${#skipped_jobs[@]})); then
	echo "Skipped (not a complete run):"
	printf '  %s\n' "${skipped_jobs[@]}"
fi
if ((${#experiments_without_results[@]})); then
	echo "No complete job, so not in the submission:"
	printf '  %s\n' "${experiments_without_results[@]}"
fi
