# Benchmark run validity checks, sourced by the experiment runners.
#
# pgbench 18 aborts a client on any error it cannot retry (only 40001/40P01 are
# retried); the client then stops for the rest of the run.
#
# Working assumption (2026-09-26): aborts caused by the known Citus commit-error
# quirk are acceptable. Citus reports some worker serialization failures at
# COMMIT as "could not commit transaction for shard N on at least one active
# node" (SQLSTATE XX000), which pgbench cannot retry. Such rows stay valid; their
# abort counts are recorded so throughput can be read against the clients that
# actually remained. Any other abort, an exit code not explained by aborts, or an
# incomplete run without an abort record makes the row invalid.

KNOWN_ABORT_PATTERN='could not commit transaction for shard [0-9]+ on at least one active node'
ABORT_LINE_PATTERN='^pgbench: error: client [0-9]+ .*aborted'

# count_aborted_clients FILE: print the number of client-abort records in FILE.
count_aborted_clients() {
	local file="$1" n=0
	if [[ -f "$file" ]]; then
		n=$(grep -cE "$ABORT_LINE_PATTERN" "$file") || true
	fi
	echo "${n:-0}"
}

# count_known_aborts FILE: print the number of aborts caused by the known quirk.
count_known_aborts() {
	local file="$1" n=0
	if [[ -f "$file" ]]; then
		n=$(grep -E "$ABORT_LINE_PATTERN" "$file" | grep -cE "$KNOWN_ABORT_PATTERN") || true
	fi
	echo "${n:-0}"
}

# run_marked_incomplete FILE: succeed when pgbench reported an aborted run.
run_marked_incomplete() {
	[[ -f "$1" ]] && grep -q '^pgbench: error: Run was aborted' "$1"
}

# _classify_phase PHASE RC FILE: append to the caller's problems/notes arrays
# and set the caller's phase_aborted variable.
_classify_phase() {
	local phase="$1" rc="$2" file="$3"
	local total known unknown
	total=$(count_aborted_clients "$file")
	known=$(count_known_aborts "$file")
	unknown=$((total - known))
	phase_aborted="$total"

	# pgbench exits 2 when any client aborted; that exit is explained by the aborts.
	if ((rc != 0)) && ! ((rc == 2 && total > 0)); then
		problems+=("${phase}_exit_${rc}")
	fi
	((unknown == 0)) || problems+=("${phase}_unexpected_aborts_${unknown}")
	if ((total == 0)) && run_marked_incomplete "$file"; then
		problems+=("${phase}_incomplete")
	fi
	((known == 0)) || notes+=("${phase}_known_commit_aborts_${known}")
}

# classify_run WARMUP_RC WARMUP_FILE MEASURED_RC MEASURED_FILE
# Pass "-" for WARMUP_RC and WARMUP_FILE when no warmup ran.
# Prints: valid,warmup_aborted_clients,measured_aborted_clients,validity_notes
# valid is 1 or 0. validity_notes is "ok", or ';'-separated problems (which make
# the row invalid) followed by informational known-abort notes.
classify_run() {
	local warmup_rc="$1" warmup_file="$2" measured_rc="$3" measured_file="$4"
	local -a problems=() notes=()
	local phase_aborted warmup_aborted=0 measured_aborted valid=1

	if [[ "$warmup_rc" != "-" ]]; then
		_classify_phase warmup "$warmup_rc" "$warmup_file"
		warmup_aborted="$phase_aborted"
	fi
	_classify_phase measured "$measured_rc" "$measured_file"
	measured_aborted="$phase_aborted"

	((${#problems[@]} == 0)) || valid=0
	local -a all=("${problems[@]}" "${notes[@]}")
	if ((${#all[@]} == 0)); then
		echo "1,${warmup_aborted},${measured_aborted},ok"
	else
		local IFS=';'
		echo "${valid},${warmup_aborted},${measured_aborted},${all[*]}"
	fi
}
