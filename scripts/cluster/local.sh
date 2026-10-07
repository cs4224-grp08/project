#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/commands.sh"

LOCAL_CLUSTER=${LOCAL_CLUSTER:-cs5424-local}
LOGIN_NODE="$LOCAL_CLUSTER-xlogin"
POLL_SECONDS=${POLL_SECONDS:-5}
PROJECT_DIR=${PROJECT_DIR:-citus_project}
IMAGE=citus-slurm-cluster
ACCOUNT=cs08
ACCOUNT_HOME=/home/stuproj/$ACCOUNT
RSYNC_TRANSPORT="docker exec -i -u $ACCOUNT"

usage() {
	cat <<'EOF'
Usage: scripts/cluster/local.sh <command> [args]

Commands:
  up [nodes]                     start the Local Cluster (default 5 nodes); the first time also builds it
  down                           stop the Local Cluster and delete everything on it
  build                          rebuild the Local Cluster's image
EOF
	shared_commands_usage
	cat <<'EOF'

Environment:
  LOCAL_CLUSTER                  name of the Local Cluster (cs5424-local)
  POLL_SECONDS                   wait's interval in seconds (5)
  PROJECT_DIR                    project folder (citus_project)
EOF
	shared_environment_usage
	exit 2
}

on_login_node() {
	local script=$1
	shift
	docker exec -i -u "$ACCOUNT" "$LOGIN_NODE" bash -s -- "$@" <<<"$script"
}

sbatch_options() {
	echo "--nodes=$(on_login_node 'sinfo -h -o %D') --exclude="
}

is_running() {
	docker container inspect "$LOGIN_NODE" >/dev/null 2>&1
}

image_exists() {
	docker image inspect "$IMAGE" >/dev/null 2>&1
}

start_container() {
	local hostname=$1 daemon=$2 nodes=$3
	docker run -d --init --name "$LOCAL_CLUSTER-$hostname" --hostname "$hostname" \
		--network "$LOCAL_CLUSTER" --network-alias "$hostname" -e "NODES=$nodes" \
		-v "$LOCAL_CLUSTER:$ACCOUNT_HOME/$PROJECT_DIR" "$IMAGE" "$daemon" >/dev/null
}

wait_until_idle() {
	local nodes=$1
	for _ in $(seq 1 120); do
		if [[ "$(docker exec "$LOGIN_NODE" sinfo -h -o '%T %D' 2>/dev/null)" == "idle $nodes" ]]; then
			return
		fi
		sleep 1
	done
	docker exec "$LOGIN_NODE" sinfo -N >&2 || true
	die "$LOCAL_CLUSTER's nodes didn't start"
}

cmd_build() {
	echo "Building $IMAGE"
	docker build -q -t "$IMAGE" -f "$ROOT/scripts/cluster/image/Dockerfile" "$ROOT" >/dev/null
}

cmd_up() {
	local nodes=${1:-5} i
	[[ "$nodes" =~ ^[0-9]+$ ]] && ((nodes >= 2)) || die "expected at least 2 nodes, got '$nodes'"
	! is_running || die "$LOCAL_CLUSTER is already running"
	image_exists || cmd_build
	echo "Starting $LOCAL_CLUSTER with $nodes nodes"
	docker network create "$LOCAL_CLUSTER" >/dev/null
	docker volume create "$LOCAL_CLUSTER" >/dev/null
	start_container xlogin slurmctld "$nodes"
	for ((i = 0; i < nodes; i++)); do
		start_container "xcnc$i" slurmd "$nodes"
	done
	docker exec "$LOGIN_NODE" chown "$ACCOUNT": "$ACCOUNT_HOME/$PROJECT_DIR"
	wait_until_idle "$nodes"
	echo "Started $LOCAL_CLUSTER"
}

cmd_down() {
	docker ps -aq --filter "name=^$LOCAL_CLUSTER-" | while read -r container; do
		docker rm -f "$container" >/dev/null
	done
	docker volume rm "$LOCAL_CLUSTER" >/dev/null 2>&1 || true
	docker network rm "$LOCAL_CLUSTER" >/dev/null 2>&1 || true
	echo "Stopped $LOCAL_CLUSTER"
}

cmd_shell() {
	docker exec -it -u "$ACCOUNT" -w "$ACCOUNT_HOME/$PROJECT_DIR" "$LOGIN_NODE" bash -l
}

main() {
	(($#)) || usage
	local command=$1
	shift
	is_command "$command" || usage
	case "$command" in
	up | down | build) ;;
	*) is_running || die "$LOCAL_CLUSTER isn't running" ;;
	esac
	"cmd_$command" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
