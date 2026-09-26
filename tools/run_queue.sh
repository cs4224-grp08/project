#!/usr/bin/env bash
# Submit experiments one after another, at most MAX_JOBS at a time, keeping
# every job on its own nodes (all jobs use the same team port, 5440).
# A job is submitted only when none of ours is pending, excluding the nodes of
# our running jobs, and the next one waits until it has started.
# Usage: nohup tools/run_queue.sh expt_a1 expt_b1 ... >queue.log 2>&1 &
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
max="${MAX_JOBS:-4}"
base_exclude="xcng0,xcng1,xgpj0,xcnh[0-3],xcnc13"
for expt in "$@"; do
	while :; do
		mine=$(squeue -h -u "$USER" -o "%T %N")
		pending=$(grep -c '^PENDING' <<<"$mine")
		running=$(grep -c '^RUNNING' <<<"$mine")
		((pending == 0 && running < max)) && break
		sleep 60
	done
	nodes=$(awk '$1 == "RUNNING" {print $2}' <<<"$mine" | paste -sd, -)
	id=$(cd "$root/$expt" && sbatch --parsable --constraint=xcnc --mail-type=FAIL \
		--exclude="$base_exclude${nodes:+,$nodes}" run.sh) || { echo "$(date '+%F %T') submit $expt FAILED"; continue; }
	echo "$(date '+%F %T') submitted $expt as job $id (excluding our nodes: ${nodes:-none})"
	while [[ $(squeue -h -j "$id" -o "%T" 2>/dev/null) == PENDING ]]; do sleep 30; done
	echo "$(date '+%F %T') $expt job $id: $(squeue -h -j "$id" -o '%T %N' 2>/dev/null || echo finished)"
done
echo "$(date '+%F %T') all submitted"
