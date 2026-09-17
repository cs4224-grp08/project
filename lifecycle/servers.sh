declare -a PORT_GUARD_PIDS=()

acquire_port_guards() {
	local node ready attempt guard_pid
	for node in "${NODES[@]}"; do
		ready="$JOB_RESULT_DIR/$node-port.ready"
		rm -f -- "$ready"
		srun --overlap --exact --nodes=1 --ntasks=1 --cpus-per-task=1 --nodelist="$node" \
			python3 "$LIFECYCLE_DIR/port_guard.py" \
			"/tmp/$PGUSER/citus-port-$PGPORT.lock" "$PGPORT" "$ready" \
			>"$JOB_RESULT_DIR/$node-port-guard.log" 2>&1 &
		guard_pid=$!
		PORT_GUARD_PIDS+=("$guard_pid")
		for attempt in $(seq 1 30); do
			kill -0 "$guard_pid" 2>/dev/null || break
			[[ -f "$ready" ]] && break
			sleep 1
		done
		if ! kill -0 "$guard_pid" 2>/dev/null || [[ ! -f "$ready" ]]; then
			echo "ERROR: Cannot reserve $node:$PGPORT; see $JOB_RESULT_DIR/$node-port-guard.log" >&2
			return 1
		fi
	done
}

release_port_guards() {
	local guard_pid node
	for guard_pid in "${PORT_GUARD_PIDS[@]}"; do
		kill "$guard_pid" 2>/dev/null || true
	done
	for guard_pid in "${PORT_GUARD_PIDS[@]}"; do
		wait "$guard_pid" 2>/dev/null || true
	done
	PORT_GUARD_PIDS=()
	for node in "${NODES[@]}"; do
		rm -f -- "$JOB_RESULT_DIR/$node-port.ready"
	done
}

verify_server_identity() {
	local node="$1" actual
	actual=$(PGCONNECT_TIMEOUT=5 "$PSQL" -X -A -t -v ON_ERROR_STOP=1 \
		-h "$node" -p "$PGPORT" -U "$PGUSER" -d postgres \
		-c 'SHOW data_directory;') || return 1
	if [[ "$actual" != "$PGDATA" ]]; then
		echo "ERROR: $node:$PGPORT uses $actual, expected $PGDATA; refusing to use this server" >&2
		return 1
	fi
}

stop_node_verified() {
	local node="$1"
	srun --overlap --exact --nodes=1 --ntasks=1 --cpus-per-task=1 --nodelist="$node" \
		bash "$LIFECYCLE_DIR/servers.sh" stop "$PG_BIN_DIR/pg_ctl" "$PGDATA" "${SERVER_RESTART_TIMEOUT:-60}"
}

check_data_stopped() {
	local control="$1" directory="$2" result
	if [[ ! -d "$directory" ]]; then
		return 0
	fi
	if "$control" -D "$directory" status; then
		echo "ERROR: Server still running in $directory" >&2
		return 1
	else
		result=$?
		if [[ "$result" != "3" ]]; then
			echo "ERROR: Cannot establish stopped state for $directory (pg_ctl exit $result)" >&2
			return 1
		fi
	fi
}

stop_local_verified() {
	local control="$1" directory="$2" timeout="$3" result
	if [[ ! -d "$directory" ]]; then
		return 0
	fi
	if "$control" -D "$directory" status; then
		"$control" -D "$directory" stop -m fast -w -t "$timeout" || return 1
	else
		result=$?
		[[ "$result" == "3" ]] || return 1
	fi
	check_data_stopped "$control" "$directory" || return 1
	printf 'Verified stopped: %s\n' "$directory"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -euo pipefail
	case "${1:-}" in
		stop) stop_local_verified "$2" "$3" "$4" ;;
		check-stopped) check_data_stopped "$2" "$3" ;;
		*) echo 'Expected stop or check-stopped' >&2; exit 2 ;;
	esac
fi
