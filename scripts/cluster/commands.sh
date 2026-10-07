ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NOT_CODE=(--exclude slurm-results --exclude 'citus-*' --exclude .DS_Store)
CITUS_COMMIT_CONFLICT='could not commit transaction for shard [0-9]* on at least one active node'

shared_commands_usage() {
	cat <<'EOF'
  push <expt>...                 copy experiments' code to the cluster
  submit <expt> [VAR=value ...]  push, then submit run.sh with VAR=value overrides
  status                         list your jobs
  wait <job>                     wait for a job to finish
  pull <expt> [--light]          copy an experiment's results back; --light skips raw logs
  run <expt> [VAR=value ...]     push, submit, wait, pull and show logs
  tail <expt> [job]              show the end of a job's logs
  cancel <job>                   cancel a job
  shell                          open a shell in the project folder
EOF
}

shared_environment_usage() {
	cat <<'EOF'
  FORCE=1                        let push replace code that has results
EOF
}

is_command() {
	declare -F "cmd_$1" >/dev/null
}

die() {
	echo "error: $*" >&2
	exit 1
}

sbatch_options() { :; }
warn_before_submitting() { :; }

check_name() {
	[[ "$1" =~ ^expt_[ab][0-9]+$ ]] || die "expected expt_aN or expt_bN, got '$1'"
}

check_folder() {
	check_name "$1"
	[[ -f "$ROOT/$1/run.sh" && -d "$ROOT/$1/transactions" ]] || die "$1 has no run.sh or transactions/"
}

check_job() {
	[[ "$1" =~ ^[0-9]+$ ]] || die "expected a job id, got '$1'"
}

copy_code() {
	local e=$1
	shift
	rsync -az -e "$RSYNC_TRANSPORT" "$@" "${NOT_CODE[@]}" --exclude transactions "$ROOT/$e/" "$LOGIN_NODE:$PROJECT_DIR/$e/"
	rsync -az -e "$RSYNC_TRANSPORT" "$@" --delete --exclude .DS_Store "$ROOT/$e/transactions" "$LOGIN_NODE:$PROJECT_DIR/$e/"
}

files_to_replace() {
	copy_code "$1" --dry-run --itemize-changes --checksum |
		awk '/^[<>]f/ && !/^[<>]f\+\+\+/ { print "    " $2 } /^\*deleting/ { print "    " $2 " (deleted)" }'
}

has_results() {
	on_login_node 'ls -d "$1"/slurm-results/job-* >/dev/null 2>&1' "$PROJECT_DIR/$1"
}

cmd_push() {
	(($#)) || die "usage: push <expt>..."
	local e replaced
	for e in "$@"; do
		check_folder "$e"
		echo "Pushing $e to $LOGIN_NODE:$PROJECT_DIR/$e"
		on_login_node 'mkdir -p "$1"' "$PROJECT_DIR/$e"
		replaced=$(files_to_replace "$e")
		if [[ -n "$replaced" ]]; then
			echo "Replacing:"
			echo "$replaced"
			if [[ "${FORCE:-0}" != 1 ]] && has_results "$e"; then
				die "$e already has results; use a new experiment or FORCE=1"
			fi
		fi
		copy_code "$e"
	done
}

git_revision_of() {
	local e=$1 changes
	if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "not in a git repository"
		return
	fi
	echo "commit $(git -C "$ROOT" rev-parse --verify -q HEAD || echo none)"
	echo "branch $(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)"
	local code=(-- "$e" ":(exclude)$e/slurm-results" ":(exclude)$e/citus-*")
	changes=$(git -C "$ROOT" status --porcelain "${code[@]}")
	if [[ -z "$changes" ]]; then
		echo "uncommitted changes: none"
	else
		echo "uncommitted changes:"
		echo "$changes"
		echo
		git -C "$ROOT" diff HEAD "${code[@]}"
	fi
}

record_git_revision() {
	local e=$1 job=$2 revision
	revision=$(mktemp)
	git_revision_of "$e" >"$revision"
	on_login_node 'mkdir -p "$1"' "$PROJECT_DIR/$e/slurm-results/job-$job"
	rsync -az -e "$RSYNC_TRANSPORT" "$revision" "$LOGIN_NODE:$PROJECT_DIR/$e/slurm-results/job-$job/git-revision.txt"
	rm -f "$revision"
}

sbatch_run_sh() {
	local e=$1 extra_options=$2
	shift 2
	on_login_node 'cd "$1" && options=$2 && shift 2 && exec env "$@" sbatch --parsable $options run.sh' \
		"$PROJECT_DIR/$e" "$(sbatch_options) $extra_options" "$@"
}

JOB=""
cmd_submit() {
	(($#)) || die "usage: submit <expt> [VAR=value ...]"
	local e=$1 setting others sbatch_output
	shift
	for setting in "$@"; do
		[[ "$setting" =~ ^[A-Z_][A-Z0-9_]*= ]] || die "expected VAR=value, got '$setting'"
	done
	cmd_push "$e"
	warn_before_submitting "$e"
	others=$(on_login_node 'squeue -h --me -o %i | wc -l')
	if ((others > 0)); then
		echo "note: $others of your jobs are queued or running; jobs on one node share PGPORT" >&2
	fi
	sbatch_output=$(sbatch_run_sh "$e" "" "$@")
	JOB=${sbatch_output%%;*}
	check_job "$JOB"
	record_git_revision "$e" "$JOB"
	echo "Submitted $e as job $JOB"
}

cmd_status() {
	on_login_node 'squeue --me -o "%.10i %.14j %.9T %.10M %.10l %.5D %R"'
}

job_state() {
	on_login_node 'squeue -h -j "$1" -o %T 2>/dev/null || true' "$1"
}

cmd_wait() {
	(($# == 1)) || die "usage: wait <job>"
	local job=$1 state last=""
	check_job "$job"
	while :; do
		if state=$(job_state "$job"); then
			[[ -z "$state" ]] && break
			if [[ "$state" != "$last" ]]; then
				echo "$(date '+%H:%M') job $job: $state"
				last=$state
			fi
		else
			echo "$(date '+%H:%M') can't reach $LOGIN_NODE; retrying" >&2
		fi
		sleep "$POLL_SECONDS"
	done
	on_login_node 'sacct -j "$1" -X -n -o JobID,State,ExitCode,Elapsed 2>/dev/null || true' "$job"
	echo "Job $job is no longer queued"
}

cmd_pull() {
	(($# >= 1)) || die "usage: pull <expt> [--light]"
	local e=$1 skip_raw_logs=()
	check_name "$e"
	if [[ "${2:-}" == --light ]]; then
		skip_raw_logs=(--exclude logs/ --exclude 'metrics-c*/')
	fi
	mkdir -p "$ROOT/$e"
	echo "Pulling $e results from $LOGIN_NODE:$PROJECT_DIR/$e"
	rsync -az -e "$RSYNC_TRANSPORT" --ignore-existing "${NOT_CODE[@]}" "$LOGIN_NODE:$PROJECT_DIR/$e/" "$ROOT/$e/"
	rsync -az -e "$RSYNC_TRANSPORT" ${skip_raw_logs[@]+"${skip_raw_logs[@]}"} \
		"$LOGIN_NODE:$PROJECT_DIR/$e/slurm-results" "$ROOT/$e/"
	rsync -az -e "$RSYNC_TRANSPORT" --include 'citus-*.out' --include 'citus-*.err' --exclude '*' \
		"$LOGIN_NODE:$PROJECT_DIR/$e/" "$ROOT/$e/"
}

cmd_run() {
	(($#)) || die "usage: run <expt> [VAR=value ...]"
	cmd_submit "$@"
	cmd_wait "$JOB"
	cmd_pull "$1"
	cmd_tail "$1" "$JOB"
}

cmd_tail() {
	(($# >= 1)) || die "usage: tail <expt> [job]"
	local e=$1 job=${2:-}
	check_name "$e"
	[[ -z "$job" ]] || check_job "$job"
	on_login_node '
cd "$1" || exit 1
job=$2
if [[ -z "$job" ]]; then
	latest=$(ls -td slurm-results/job-* 2>/dev/null | head -n 1)
	[[ -n "$latest" ]] || { echo "No jobs yet"; exit 0; }
	job=${latest##*job-}
fi
for f in "citus-$job.out" "citus-$job.err" "slurm-results/job-$job/benchmark.log"; do
	[[ -s "$f" ]] || continue
	echo "==> $f <=="
	tail -n 20 "$f"
done' "$PROJECT_DIR/$e" "$job"
}

cmd_cancel() {
	(($# == 1)) || die "usage: cancel <job>"
	check_job "$1"
	on_login_node 'scancel "$1"' "$1"
}
