#!/usr/bin/env bash
# Submit a probe job: a copy of expt_b0/run.sh whose benchmark step is replaced
# by tools/probe/probe.sh. Usage: tools/probe/submit_probe.sh explain|equiv SCALE [sbatch args...]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
mode="$1" scale="$2"; shift 2
work="$root/probe-runs"; mkdir -p "$work"
script="$work/probe-run.sh"
sed "s|^run_benchmark &>\"\${BENCHMARK_LOG_FILE}\"$|source \"$root/tools/probe/probe.sh\"|" "$root/expt_b0/run.sh" >"$script"
grep -q "tools/probe/probe.sh" "$script" || { echo "failed to patch run.sh" >&2; exit 1; }
cd "$work"
sbatch --parsable --mail-type=NONE --job-name="probe-$mode" --output="probe-$mode-%j.out" --error="probe-$mode-%j.err" \
	--export="ALL,PROBE_MODE=$mode,SCALE=$scale,PROFILE_FILES=${PROFILE_FILES:-},SCRIPT_DIR=$root/expt_b0,RESULT_ROOT=$work/results" "$@" "$script"
