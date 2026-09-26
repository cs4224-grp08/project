#!/usr/bin/env bash
# Build the optimization experiment folders from the baselines.
#
# Each expt_wN is a copy of expt_w0 (run.sh unchanged) with the rewritten
# transactions of its optimizations overlaid in order, following the brief's
# progressive approach: V_N = V_{N-1} + O_N. Rewrites live in tools/rewrites/<O>/.
#
#   O1  T3: fetch the 20 most recent orders first, then their items
#   O2  T4: look up inventory by its distribution key
#   O3  T7: one UPDATE for the whole transfer (inventory_id = product_id)
#   O3a T7: one lookup for both products instead of four (side experiment)
#   O4  T1: check, reserve and insert all items with one statement each
#   O5  single-statement transactions in autocommit (T2-T6, T8, T9)
#
# Usage: tools/build_experiments.sh   (run from the repository root)
set -euo pipefail
cd "$(dirname "$0")/.."

declare -A PLAN=(
	[a1]="O1"
	[a2]="O1 O2"
	[a3]="O1 O2 O4"
	[a4]="O1 O2 O4 O5"
	[a5]="O1 O2 O4 O5 O3"
	[b1]="O1"
	[b2]="O1 O3"
	[b3]="O1 O3 O2"
	[b4]="O1 O3 O2 O5"
	[b5]="O1 O3 O2 O5 O4"
	[b6]="O1 O3a"
)

for expt in "${!PLAN[@]}"; do
	base="expt_${expt:0:1}0"
	dir="expt_${expt}"
	mkdir -p "$dir/transactions"
	cp "$base/run.sh" "$dir/run.sh"
	cp "$base"/transactions/*.sql "$dir/transactions/"
	for opt in ${PLAN[$expt]}; do
		cp tools/rewrites/"$opt"/*.sql "$dir/transactions/"
	done
	echo "$dir: ${PLAN[$expt]}"
done | sort
