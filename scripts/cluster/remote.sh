#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/commands.sh"

LOGIN_NODE=${CLUSTER_HOST:-cs5424}
POLL_SECONDS=${POLL_SECONDS:-300}
PROJECT_DIR=${PROJECT_DIR:-runs/$(git -C "$ROOT" symbolic-ref --short -q HEAD || git -C "$ROOT" rev-parse --short HEAD)}
SSH_OPTIONS=(-o ControlMaster=auto -o "ControlPath=${CLUSTER_CONTROL_PATH:-$HOME/.ssh/cm-%C}" -o ControlPersist=15m -o ServerAliveInterval=30)
RSYNC_TRANSPORT="ssh ${SSH_OPTIONS[*]}"

usage() {
	cat <<'EOF'
Usage: scripts/cluster/remote.sh <command> [args]

Run it yourself, never from CI, cron or other automation: the SoC cluster's usage
policy forbids that.

Commands:
EOF
	shared_commands_usage
	cat <<'EOF'

Environment:
  CLUSTER_HOST                   SSH host of the Remote Cluster (cs5424)
  POLL_SECONDS                   wait's interval in seconds (300)
  PROJECT_DIR                    project folder (runs/<git branch>)
EOF
	shared_environment_usage
	exit 2
}

on_login_node() {
	local script=$1
	shift
	ssh "${SSH_OPTIONS[@]}" "$LOGIN_NODE" "bash -s --$(printf ' %q' "$@")" <<<"$script"
}

sbatch_options() {
	echo "--constraint=${CONSTRAINT:-xcnc} ${EXCLUSIVE:+--exclusive} ${CPUS:+--cpus-per-task=$CPUS} ${MEM:+--mem=$MEM} ${AFTER:+--dependency=afterany:$AFTER} ${NODELIST:+--nodelist=$NODELIST}"
}

cmd_shell() {
	ssh -t "${SSH_OPTIONS[@]}" "$LOGIN_NODE" "mkdir -p $(printf %q "$PROJECT_DIR") && cd $(printf %q "$PROJECT_DIR") && exec \"\$SHELL\" -l"
}

main() {
	(($#)) || usage
	local command=$1
	shift
	is_command "$command" || usage
	"cmd_$command" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
