# Probe for the query rewrites. Sourced by a generated copy of expt_b0/run.sh
# (see tools/probe/submit_probe.sh) in place of run_benchmark, so the cluster
# and data are already set up and run.sh's functions and variables are in scope.
#
#   PROBE_MODE=explain  invariant checks, EXPLAIN ANALYZE and single-client
#                       latency of baseline vs rewritten transactions (SCALE=1)
#   PROBE_MODE=equiv    result/effect equivalence of every rewrite (small SCALE)

PROBE_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWRITES="$PROBE_TOOLS/../rewrites"
BASE_TX="$SCRIPT_DIR/transactions"
OUT="$JOB_RESULT_DIR/probe"
HELPER=(python3 "$PROBE_TOOLS/probe_helper.py")
mkdir -p "$OUT"
export PSQL PGHOST PGPORT PGUSER PGDATABASE

load_dimensions() {
	IFS='|' read -r NUM_MERCHANTS NUM_CUSTOMERS NUM_PRODUCTS INITIAL_NUM_ORDERS < <(psqlx -A -t -c "
		SELECT (SELECT MAX(merchant_id) FROM merchants), (SELECT MAX(customer_id) FROM customers),
		       (SELECT MAX(product_id) FROM products), (SELECT MAX(order_id) FROM orders);")
	HOT_MERCHANTS=$((NUM_MERCHANTS * HOT_MERCHANT_PERCENT / 100))
	((HOT_MERCHANTS >= 1)) || HOT_MERCHANTS=1
	((HOT_MERCHANTS < NUM_MERCHANTS)) || HOT_MERCHANTS=$((NUM_MERCHANTS - 1))
	defs=(
		-D NUM_MERCHANTS="$NUM_MERCHANTS" -D NUM_CUSTOMERS="$NUM_CUSTOMERS"
		-D NUM_PRODUCTS="$NUM_PRODUCTS" -D INITIAL_NUM_ORDERS="$INITIAL_NUM_ORDERS"
		-D HOT_ORDER_PERCENT="$HOT_ORDER_PERCENT" -D HOT_MERCHANTS="$HOT_MERCHANTS"
		-D MIN_ITEMS_PER_ORDER="$MIN_ITEMS_PER_ORDER" -D MAX_ITEMS_PER_ORDER="$MAX_ITEMS_PER_ORDER"
		-D MIN_ORDER_QTY="$MIN_ORDER_QTY" -D MAX_ORDER_QTY="$MAX_ORDER_QTY"
		-D INVENTORY_CHANGE_MIN="$INVENTORY_CHANGE_MIN" -D INVENTORY_CHANGE_MAX="$INVENTORY_CHANGE_MAX"
		-D REPORT_DAYS="$REPORT_DAYS" -D T7_MIN_TRANSFER_QTY="$T7_MIN_TRANSFER_QTY"
		-D T7_MAX_TRANSFER_QTY="$T7_MAX_TRANSFER_QTY"
	)
	reset_benchmark_sequences >/dev/null # run_benchmark normally does this
	echo "dimensions: merchants=$NUM_MERCHANTS customers=$NUM_CUSTOMERS products=$NUM_PRODUCTS orders=$INITIAL_NUM_ORDERS hot=$HOT_MERCHANTS"
}

bench() { # label file seconds -> one line with pgbench's own latency/tps
	local label="$1" file="$2" secs="$3" log="$OUT/micro-$1.txt" rc=0
	"$PGBENCH" -n -c 1 -j 1 -T "$secs" -M simple --random-seed=42 -D DEBUG_MODE=0 "${defs[@]}" \
		-f "$file" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" >"$log" 2>&1 || rc=$?
	printf '%-14s rc=%s %s | %s | %s\n' "$label" "$rc" \
		"$(grep -m1 'actually processed' "$log")" "$(grep -m1 'latency average' "$log")" \
		"$(grep -m1 -E 'error|ERROR' "$log" || echo 'no errors')"
}

probe_explain() {
	echo "== invariants"
	psqlx -A -c "SELECT count(*) AS rows, count(*) FILTER (WHERE inventory_id <> product_id) AS key_mismatch,
		count(DISTINCT product_id) AS distinct_products FROM inventory;"
	psqlx -A -c "SELECT (SELECT count(*) FROM products) AS products,
		(SELECT count(*) FROM products p JOIN inventory i ON i.inventory_id = p.product_id
		  WHERE i.merchant_id = p.merchant_id AND i.product_id = p.product_id) AS matching_inventory;"
	psqlx -A -c "SELECT (SELECT count(*) FROM orders) AS orders,
		(SELECT count(DISTINCT order_id) FROM order_items) AS orders_with_items;"
	psqlx -A -c "SELECT count(*) AS items_with_other_merchant FROM order_items oi JOIN orders o ON o.order_id = oi.order_id
		WHERE oi.merchant_id <> o.merchant_id;"
	load_dimensions

	echo "== EXPLAIN ANALYZE (see $OUT/explain-*.txt)"
	"${HELPER[@]}" explain "$OUT/explain-baseline.txt" \
		"$BASE_TX"/T{1,3,4,6,7}_*.sql
	"${HELPER[@]}" explain "$OUT/explain-rewrites.txt" \
		"$REWRITES"/O1/T3_*.sql "$REWRITES"/O2/T4_*.sql "$REWRITES"/O3/T7_*.sql \
		"$REWRITES"/O3a/T7_*.sql "$REWRITES"/O4/T1_*.sql
	grep -hE "^=== |Execution Time|Custom Scan|Task Count|ERROR" "$OUT"/explain-*.txt || true

	echo "== single-client latency (pgbench -c 1)"
	local f t
	for f in "$BASE_TX"/T*.sql; do
		t=$(basename "$f" .sql); t=${t%%_*}
		[[ $t == T3 ]] && secs=60 || secs=20
		bench "base-$t" "$f" "$secs"
	done
	for f in "$REWRITES"/O*/T*.sql; do
		t=$(basename "$f" .sql); t=${t%%_*}
		bench "$(basename "$(dirname "$f")")-$t" "$f" 20
	done
}

# run_writes LABEL FILE: reset data, run the fixed invocation list, dump state
run_writes() {
	local label="$1" file="$2" s rc=0 i=0
	reset_benchmark_database "equivalence $label" >>"$OUT/resets.log" 2>&1
	while IFS= read -r extra; do
		i=$((i + 1))
		# shellcheck disable=SC2086
		"$PGBENCH" -n -c 1 -j 1 -t 1 -M simple "${defs[@]}" $extra -f "$file" \
			-h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" >>"$OUT/pgbench-$label.log" 2>&1 || {
			rc=$?; echo "  $label invocation $i ($extra) exited $rc"; }
	done <"$OUT/cases-$CASESET.txt"
	"${HELPER[@]}" dump-state "$OUT/state-$label" "$INITIAL_NUM_ORDERS"
	echo "  $label: $i invocations, $(grep -c 'aborted' "$OUT/pgbench-$label.log" || true) aborts"
}

write_cases() { # set name, then extra pgbench args per line
	local name="$1" n="${EQUIV_SEEDS:-150}" s
	shift
	{
		(($# == 0)) || printf '%s\n' "$@" # edge cases first, on pristine stock
		for s in $(seq 1 "$n"); do echo "-D DEBUG_MODE=0 --random-seed=$s"; done
	} >"$OUT/cases-$name.txt"
}

probe_equiv() {
	load_dimensions
	local nm=$NUM_MERCHANTS np=$NUM_PRODUCTS stock pass=1
	echo "== invariant: item merchant = order merchant (0 expected)"
	psqlx -A -c "SELECT count(*) AS items_with_other_merchant FROM order_items oi JOIN orders o ON o.order_id = oi.order_id
		WHERE oi.merchant_id <> o.merchant_id;"
	echo "== reads"
	"${HELPER[@]}" compare-reads "$OUT/reads-T3-O1.txt" "$NUM_MERCHANTS" "$NUM_CUSTOMERS" "$NUM_PRODUCTS" \
		"$BASE_TX/T3_order_history.sql" "$REWRITES/O1/T3_order_history.sql" t3 || pass=0
	cmp -s <("${HELPER[@]}" statements "$REWRITES/O1/T3_order_history.sql") <("${HELPER[@]}" statements "$REWRITES/O5/T3_order_history.sql") &&
		echo "t3: O5 statement identical to O1 PASS" || { echo "t3: O5 statement differs from O1 FAIL"; pass=0; }
	"${HELPER[@]}" compare-reads "$OUT/reads-T4-O2.txt" "$NUM_MERCHANTS" "$NUM_CUSTOMERS" "$NUM_PRODUCTS" \
		"$BASE_TX/T4_product_lookup.sql" "$REWRITES/O2/T4_product_lookup.sql" t4 || pass=0
	cmp -s <("${HELPER[@]}" statements "$REWRITES/O2/T4_product_lookup.sql") <("${HELPER[@]}" statements "$REWRITES/O5/T4_product_lookup.sql") &&
		echo "t4: O5 statement identical to O2 PASS" || { echo "t4: O5 statement differs from O2 FAIL"; pass=0; }
	cmp -s <("${HELPER[@]}" statements "$BASE_TX/T6_global_sales.sql") \
		<("${HELPER[@]}" statements "$REWRITES/O5/T6_global_sales.sql") &&
		echo "t6: O5 statement identical to baseline PASS" || { echo "t6: statement differs FAIL"; pass=0; }
	grep -h "RESULT" "$OUT"/reads-*.txt | sort | uniq -c

	echo "== writes (reset, same inputs, compare final state)"
	reset_benchmark_database "pristine" >>"$OUT/resets.log" 2>&1
	"${HELPER[@]}" dump-state "$OUT/state-pristine" "$INITIAL_NUM_ORDERS"
	stock=$(psqlx -A -t -c "SELECT quantity FROM inventory WHERE inventory_id = 25;")
	local d="-D DEBUG_MODE=1"
	t1() { echo "$d -D DEBUG_MERCHANT_ID=$1 -D DEBUG_CUSTOMER_ID=$2 -D DEBUG_ITEM_COUNT=$3 -D DEBUG_PRODUCT_ID_1=$4 -D DEBUG_QTY_1=$5 -D DEBUG_PRODUCT_ID_2=${6:-0} -D DEBUG_QTY_2=${7:-0} -D DEBUG_PRODUCT_ID_3=${8:-0} -D DEBUG_QTY_3=${9:-0} -D DEBUG_PRODUCT_ID_4=${10:-0} -D DEBUG_QTY_4=${11:-0} -D DEBUG_PRODUCT_ID_5=${12:-0} -D DEBUG_QTY_5=${13:-0}"; }
	# T1 edge cases: normal, repeated product, insufficient stock, repeated product whose
	# total exceeds stock (each part alone fits), another merchant's product, another
	# merchant's customer, five items, one item
	write_cases t1 \
		"$(t1 2 $((2 + nm)) 3 2 1 $((2 + nm)) 2 $((2 + 2 * nm)) 3)" \
		"$(t1 3 $((3 + nm)) 3 3 2 $((3 + nm)) 1 3 4)" \
		"$(t1 4 $((4 + nm)) 2 4 1 $((4 + nm)) 100000)" \
		"$(t1 5 $((5 + nm)) 2 25 $((stock - 1)) 25 2)" \
		"$(t1 5 $((5 + nm)) 2 25 1 25 1)" \
		"$(t1 6 $((6 + nm)) 2 6 1 7 1)" \
		"$(t1 7 8 1 7 1)" \
		"$(t1 8 $((8 + 2 * nm)) 5 8 1 $((8 + nm)) 2 $((8 + 2 * nm)) 3 $((8 + 3 * nm)) 4 $((8 + 4 * nm)) 5)" \
		"$(t1 9 9 1 $((9 + 5 * nm)) 5)"
	t7() { echo "$d -D DEBUG_T7_SOURCE_PRODUCT_ID=$1 -D DEBUG_T7_DEST_PRODUCT_ID=$2 -D DEBUG_T7_TRANSFER_QTY=$3"; }
	# T7 edge cases: normal, same product, insufficient stock, missing source,
	# missing destination, exact remaining stock, same shard pair
	write_cases t7 "$(t7 1 2 3)" "$(t7 5 5 1)" "$(t7 10 11 100000)" "$(t7 $((np + 1)) 3 1)" \
		"$(t7 4 $((np + 5)) 1)" "$(t7 25 26 "$stock")" "$(t7 25 26 1)" "$(t7 30 31 2)"
	write_cases plain

	CASESET=t1 run_writes T1-base "$BASE_TX/T1_place_order.sql"
	CASESET=t1 run_writes T1-O4 "$REWRITES/O4/T1_place_order.sql"
	CASESET=t7 run_writes T7-base "$BASE_TX/T7_inventory_transfer.sql"
	CASESET=t7 run_writes T7-O3 "$REWRITES/O3/T7_inventory_transfer.sql"
	CASESET=t7 run_writes T7-O3a "$REWRITES/O3a/T7_inventory_transfer.sql"
	local t f
	for t in T2_update_inventory T5_update_order_status T8_update_customer T9_update_product; do
		CASESET=plain run_writes "${t%%_*}-base" "$BASE_TX/$t.sql"
		CASESET=plain run_writes "${t%%_*}-O5" "$REWRITES/O5/$t.sql"
	done
	echo "== invariant after the T1 runs (0 expected)"
	psqlx -A -c "SELECT count(*) AS items_with_other_merchant FROM order_items oi JOIN orders o ON o.order_id = oi.order_id
		WHERE oi.merchant_id <> o.merchant_id;"
	echo "== comparisons"
	for pair in T1-base:T1-O4 T7-base:T7-O3 T7-base:T7-O3a T2-base:T2-O5 T5-base:T5-O5 T8-base:T8-O5 T9-base:T9-O5; do
		PRISTINE="$OUT/state-pristine" "${HELPER[@]}" compare-state "$OUT/state-${pair%%:*}" "$OUT/state-${pair#*:}" || pass=0
	done
	((pass)) && echo "EQUIVALENCE: ALL PASS" || echo "EQUIVALENCE: FAILURES (see above)"
}

probe_profile() { # per-statement latency (pgbench -r) for PROFILE_FILES
	load_dimensions
	local f
	for f in $PROFILE_FILES; do
		echo "== $f"
		"$PGBENCH" -n -r -c 1 -j 1 -T 20 -M simple --random-seed=42 -D DEBUG_MODE=0 "${defs[@]}" -f "$f" \
			-h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" 2>&1 |
			grep -E "latency average|^ +[0-9.]+ +[0-9]+ +[^ ]" || true
	done
}

# Invariants after a concurrent run (see docs on isolation): does the data stay
# consistent at the configured isolation level? Two phases on freshly reset data:
#   conserve  only T1 and T7: total stock must equal initial stock minus the
#             quantity of every new order item (T7 only moves stock)
#   mix       all nine transactions with workload B weights
inv_check() { # name expected actual
	local ok=FAIL
	[[ "$2" == "$3" ]] && ok=PASS
	printf 'CHECK %-34s expected=%-10s actual=%-10s %s\n' "$1" "$2" "$3" "$ok"
	[[ $ok == PASS ]] || INV_FAILS=$((INV_FAILS + 1))
}
q1() { psqlx -A -t -c "$1" | tr -d ' \n'; }

probe_invariants() {
	load_dimensions
	INV_FAILS=0
	local phase init_sum final_sum new_items_qty files
	echo "== isolation in effect: coordinator=$(q1 'SHOW default_transaction_isolation')"
	psqlx -A -t -c "SELECT result FROM run_command_on_workers('SHOW default_transaction_isolation');" | sort | uniq -c
	for phase in conserve mix; do
		echo "== phase $phase (clients=${INV_CLIENTS:-16}, ${INV_SECONDS:-90}s, tries=$PGBENCH_MAX_TRIES)"
		reset_benchmark_database "invariants $phase" >>"$OUT/resets.log" 2>&1
		load_dimensions >/dev/null
		init_sum=$(q1 "SELECT sum(quantity) FROM inventory;")
		if [[ $phase == conserve ]]; then
			files=(-f "$BASE_TX/T1_place_order.sql@1" -f "$BASE_TX/T7_inventory_transfer.sql@1")
		else
			files=(-f "$BASE_TX/T1_place_order.sql@$T1_WEIGHT" -f "$BASE_TX/T2_update_inventory.sql@$T2_WEIGHT"
				-f "$BASE_TX/T3_order_history.sql@$T3_WEIGHT" -f "$BASE_TX/T4_product_lookup.sql@$T4_WEIGHT"
				-f "$BASE_TX/T5_update_order_status.sql@$T5_WEIGHT" -f "$BASE_TX/T6_global_sales.sql@$T6_WEIGHT"
				-f "$BASE_TX/T7_inventory_transfer.sql@$T7_WEIGHT" -f "$BASE_TX/T8_update_customer.sql@$T8_WEIGHT"
				-f "$BASE_TX/T9_update_product.sql@$T9_WEIGHT")
		fi
		"$PGBENCH" -n -c "${INV_CLIENTS:-16}" -j 4 -T "${INV_SECONDS:-90}" -M simple --max-tries="$PGBENCH_MAX_TRIES" \
			--random-seed=7 -D DEBUG_MODE=0 "${defs[@]}" "${files[@]}" \
			-h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" >"$OUT/pgbench-inv-$phase.txt" 2>&1 || true
		echo "  pgbench: $(grep -m1 'actually processed' "$OUT/pgbench-inv-$phase.txt"); $(grep -m1 'failed transactions' "$OUT/pgbench-inv-$phase.txt"); aborted clients: $(grep -c 'aborted in command' "$OUT/pgbench-inv-$phase.txt")"
		echo "  prepared transactions before recovery: $(q1 "SELECT (SELECT count(*) FROM pg_prepared_xacts) + (SELECT coalesce(sum(result::int),0) FROM run_command_on_workers('SELECT count(*) FROM pg_prepared_xacts'));")"
		psqlx -A -t -c "SELECT recover_prepared_transactions();" >/dev/null
		sleep 5
		local init=$INITIAL_NUM_ORDERS
		inv_check "prepared transactions left" 0 "$(q1 "SELECT (SELECT count(*) FROM pg_prepared_xacts) + (SELECT coalesce(sum(result::int),0) FROM run_command_on_workers('SELECT count(*) FROM pg_prepared_xacts'));")"
		inv_check "negative stock rows" 0 "$(q1 "SELECT count(*) FROM inventory WHERE quantity < 0;")"
		inv_check "new orders without items" 0 "$(q1 "SELECT count(*) FROM orders WHERE order_id > $init AND order_id NOT IN (SELECT order_id FROM order_items WHERE order_id > $init);")"
		inv_check "new items without order" 0 "$(q1 "SELECT count(*) FROM order_items WHERE order_id > $init AND order_id NOT IN (SELECT order_id FROM orders WHERE order_id > $init);")"
		inv_check "order total <> sum(qty*price)" 0 "$(q1 "SELECT count(*) FROM (SELECT order_id, total_amount FROM orders WHERE order_id > $init) o JOIN (SELECT order_id, sum(quantity * unit_price) AS s FROM order_items WHERE order_id > $init GROUP BY order_id) i ON i.order_id = o.order_id WHERE o.total_amount <> i.s;")"
		psqlx -A -t -c "SELECT 'sample total vs items:', o.order_id, o.total_amount, i.s, i.n FROM (SELECT order_id, total_amount FROM orders WHERE order_id > $init) o JOIN (SELECT order_id, sum(quantity * unit_price) AS s, count(*) AS n FROM order_items WHERE order_id > $init GROUP BY order_id) i ON i.order_id = o.order_id ORDER BY o.order_id LIMIT 3;"
		inv_check "item merchant <> order merchant" 0 "$(q1 "SELECT count(*) FROM orders o JOIN order_items oi ON oi.order_id = o.order_id WHERE o.order_id > $init AND oi.merchant_id <> o.merchant_id;")"
		if [[ $phase == conserve ]]; then
			new_items_qty=$(q1 "SELECT coalesce(sum(quantity),0) FROM order_items WHERE order_id > $init;")
			final_sum=$(q1 "SELECT sum(quantity) FROM inventory;")
			echo "  initial stock $init_sum, sold via new items $new_items_qty, new orders $(q1 "SELECT count(*) FROM orders WHERE order_id > $init;")"
			inv_check "stock conservation (initial-sold)" "$((init_sum - new_items_qty))" "$final_sum"
		fi
	done
	((INV_FAILS == 0)) && echo "INVARIANTS: ALL PASS" || echo "INVARIANTS: $INV_FAILS FAILED"
}

{
	echo "probe mode=${PROBE_MODE:-explain} scale=$SCALE started $(date '+%F %T')"
	case "${PROBE_MODE:-explain}" in
	explain) probe_explain ;;
	equiv) probe_equiv ;;
	profile) probe_profile ;;
	invariants) probe_invariants ;;
	*) echo "unknown PROBE_MODE" ;;
	esac
	echo "probe finished $(date '+%F %T')"
} 2>&1 | tee "$OUT/probe-summary.txt"
