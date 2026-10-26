#!/usr/bin/env bash
#SBATCH --job-name=citus-project
#SBATCH --nodes=5
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --output=citus-%j.out
#SBATCH --error=citus-%j.err
#SBATCH --partition=normal
#SBATCH --time=03:00:00
#SBATCH --mail-type=BEGIN,END,FAIL
# don't run on nodes with arm processor / ubuntu 26.04
# temporarily exclude xcnc13 as server is problematic
#SBATCH --exclude=xcng0,xcng1,xgpj0,xcnh[0-3],xcnc13
# IMPORTANT - replace this with your email
#SBATCH --mail-user=e1122441@u.nus.edu

set -euo pipefail

# IMPORTANT: replace 99 with your project team number (e.g., 1, 2, ..., 20) to ensure a unique PGPORT number for each team
TEAM_ID=${TEAM_ID:-8}

################# PostgreSQL environment variables
PGPORT=$((10#${TEAM_ID} + 5432))
PGUSER="${SLURM_JOB_USER:-${USER}}"

DATA_ROOT=/tmp/${PGUSER}/citus-${SLURM_JOB_ID}
PGDATA="${DATA_ROOT}/pgdata"

PGDATABASE="project-${SLURM_JOB_ID}"

################# Directories
INSTALL_DIR=$HOME/pgsql
PG_BIN_DIR="${INSTALL_DIR}/bin"

RESULT_ROOT="${RESULT_ROOT:-${SLURM_SUBMIT_DIR}/slurm-results}"
JOB_RESULT_DIR="${RESULT_ROOT}/job-${SLURM_JOB_ID}"
RUN_DIR="${JOB_RESULT_DIR}/benchmark-results"
LOG_DIR="${RUN_DIR}/logs"

SCRIPT_DIR="${SCRIPT_DIR:-${SLURM_SUBMIT_DIR}}"
TX_DIR="${SCRIPT_DIR}/transactions"

################# Files
BENCHMARK_LOG_FILE="${JOB_RESULT_DIR}/benchmark.log"

SUMMARY_FILE="${RUN_DIR}/summary.csv"
TX_METRICS_FILE="${RUN_DIR}/transaction_metrics.csv"
BENCHMARK_CONFIG_FILE="${RUN_DIR}/config.txt"
README_METRICS_FILE="${RUN_DIR}/README-metrics.txt"
WORKLOAD_LOG_FILE="${RUN_DIR}/workload_logs.csv"

PSQL="${PG_BIN_DIR}/psql"
PGBENCH="${PG_BIN_DIR}/pgbench"

################# PostgreSQL configuration
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-1GB}"
PG_WORK_MEM="${PG_WORK_MEM:-32MB}"
PG_MAINTENANCE_WORK_MEM="${PG_MAINTENANCE_WORK_MEM:-256MB}"
PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-1000}"
PG_ISOLATION_LEVEL=${PG_ISOLATION_LEVEL:-read committed}

PG_MAX_WAL_SIZE="${PG_MAX_WAL_SIZE:-16GB}"
PG_MIN_WAL_SIZE="${PG_MIN_WAL_SIZE:-2GB}"
PG_CHECKPOINT_TIMEOUT="${PG_CHECKPOINT_TIMEOUT:-30min}"
PG_CHECKPOINT_COMPLETION_TARGET="${PG_CHECKPOINT_COMPLETION_TARGET:-0.9}"

################# Citus configuration
CITUS_ENABLE_REPARTITION_JOINS="${CITUS_ENABLE_REPARTITION_JOINS:-on}"
CITUS_MAX_SHARED_POOL_SIZE="${CITUS_MAX_SHARED_POOL_SIZE:-300}"
CITUS_MAX_ADAPTIVE_EXECUTOR_POOL_SIZE="${CITUS_MAX_ADAPTIVE_EXECUTOR_POOL_SIZE:-4}"
CITUS_LOCAL_SHARED_POOL_SIZE="${CITUS_LOCAL_SHARED_POOL_SIZE:-150}"

################# Data generation configuration
SCALE="${SCALE:-1}"          # scaling factor
DATA_SEED="${DATA_SEED:-42}" # seed for data generation
HOT_MERCHANT_PERCENT="${HOT_MERCHANT_PERCENT:-10}"
HOT_ORDER_PERCENT="${HOT_ORDER_PERCENT:-50}"

################# Benchmarking configuration
PGBENCH_SEED="${PGBENCH_SEED:-42}"
PGBENCH_MAX_TRIES="${PGBENCH_MAX_TRIES:-3}"
PGBENCH_FAILURES_DETAILED="${PGBENCH_FAILURES_DETAILED:-1}"
PGBENCH_QUERY_MODE="${PGBENCH_QUERY_MODE:-simple}"

CLIENT_COUNTS="${CLIENT_COUNTS:-1 4 8 16 32 64}"
THREADS="${THREADS:-${SLURM_CPUS_PER_TASK:-4}}"

DURATION="${DURATION:-600}"              # 10 minutes (short duration for testing)
WARMUP_DURATION="${WARMUP_DURATION:-60}" # 1 minute
BASELINE_DURATION="${BASELINE_DURATION:-120}"
POST_ADAPT_DURATION="${POST_ADAPT_DURATION:-120}"
HOT_MERCHANT_LIMIT="${HOT_MERCHANT_LIMIT:-4}"
ADAPTATION_TIMEOUT="${ADAPTATION_TIMEOUT:-300}"
# Avoid the logical-replication apply conflicts seen during online shard splits.
# This blocks affected writes during isolation and movement; override with auto
# only when explicitly testing the online transfer path.
SHARD_TRANSFER_MODE="${SHARD_TRANSFER_MODE:-block_writes}"

PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-10}"
LOG_SAMPLE_RATE="${LOG_SAMPLE_RATE:-1.0}" # must not change this value

RESET_AFTER_WARMUP="${RESET_AFTER_WARMUP:-0}"
RESTART_SERVERS_BETWEEN_CLIENT_COUNTS="${RESTART_SERVERS_BETWEEN_CLIENT_COUNTS:-1}"
SERVER_RESTART_TIMEOUT="${SERVER_RESTART_TIMEOUT:-60}"

# Weights for transaction workloads A & B
WORKLOAD="${WORKLOAD:-A}"
if [[ "${WORKLOAD}" == "A" ]]; then
        # Transaction weights for workload A
        T1_WEIGHT="${T1_WEIGHT:-36}"
        T2_WEIGHT="${T2_WEIGHT:-20}"
        T3_WEIGHT="${T3_WEIGHT:-10}"
        T4_WEIGHT="${T4_WEIGHT:-10}"
        T5_WEIGHT="${T5_WEIGHT:-10}"
        T6_WEIGHT="${T6_WEIGHT:-5}"
        T7_WEIGHT="${T7_WEIGHT:-5}"
        T8_WEIGHT="${T8_WEIGHT:-2}"
        T9_WEIGHT="${T9_WEIGHT:-2}"
elif [[ "${WORKLOAD}" == "B" ]]; then
        # Transaction weights for workload B
        T1_WEIGHT="${T1_WEIGHT:-10}"
        T2_WEIGHT="${T2_WEIGHT:-10}"
        T3_WEIGHT="${T3_WEIGHT:-5}"
        T4_WEIGHT="${T4_WEIGHT:-5}"
        T5_WEIGHT="${T5_WEIGHT:-10}"
        T6_WEIGHT="${T6_WEIGHT:-10}"
        T7_WEIGHT="${T7_WEIGHT:-30}"
        T8_WEIGHT="${T8_WEIGHT:-10}"
        T9_WEIGHT="${T9_WEIGHT:-10}"
else
        echo "Invalid workload ${WORKLOAD}" >&2
        exit 1
fi

# Transaction T1
MIN_ITEMS_PER_ORDER="${MIN_ITEMS_PER_ORDER:-1}"
MAX_ITEMS_PER_ORDER="${MAX_ITEMS_PER_ORDER:-5}"
MIN_ORDER_QTY="${MIN_ORDER_QTY:-1}"
MAX_ORDER_QTY="${MAX_ORDER_QTY:-5}"

# Transaction T2
INVENTORY_CHANGE_MIN="${INVENTORY_CHANGE_MIN:--5}"
INVENTORY_CHANGE_MAX="${INVENTORY_CHANGE_MAX:-20}"

# Transaction T6
REPORT_DAYS="${REPORT_DAYS:-30}"

# Transaction T7
T7_MIN_TRANSFER_QTY="${T7_MIN_TRANSFER_QTY:-1}"
T7_MAX_TRANSFER_QTY="${T7_MAX_TRANSFER_QTY:-5}"

################# Script initialization
CLEANUP_STARTED=0  # clean up has not started
SERVERS_LAUNCHED=0 # servers have not been launched
PGBENCH_PID=""
declare -a SERVER_PIDS=()
declare -a NODES=()

############### Functions

info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
now_epoch_ms() { date +%s%3N; }

fail() {
        echo "ERROR: $*" >&2
        exit 1
}

psqlx() { ${PSQL} -X -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$@"; }

### clean up on exit
cleanup() {
        local exit_code=$?

        # Prevent cleanup from running twice, e.g. TERM followed by EXIT.
        if ((CLEANUP_STARTED)); then
                return
        fi
        CLEANUP_STARTED=1

        set +e

        if ((exit_code == 0)); then
                echo "Running cleanup after successful completion..."
        else
                echo "Running cleanup after failure; exit code=$exit_code"
        fi

        if [[ -n "${PGBENCH_PID:-}" ]]; then
                kill "$PGBENCH_PID" 2>/dev/null || true
                wait "$PGBENCH_PID" 2>/dev/null || true
                PGBENCH_PID=""
        fi

        if ((SERVERS_LAUNCHED)); then
                local n
                for n in "${NODES[@]:-}"; do
                        srun \
                                --overlap \
                                --exact \
                                --nodes=1 \
                                --ntasks=1 \
                                --cpus-per-task=1 \
                                --nodelist="$n" \
                                bash -c \
                                "${PG_BIN_DIR}/pg_ctl -D '${PGDATA}' stop -m fast \
                 >/dev/null 2>&1 || true" ||
                                true
                done
                bounded_wait_server_pids || true
        fi
        return "$exit_code"
}

### reap srun processes
bounded_wait_server_pids() {
        local timeout_seconds="${SERVER_WAIT_TIMEOUT:-30}"
        local elapsed=0
        local p
        local any_alive

        while ((elapsed < timeout_seconds)); do
                any_alive=0

                for p in "${SERVER_PIDS[@]:-}"; do
                        if kill -0 "$p" 2>/dev/null; then
                                any_alive=1
                                break
                        fi
                done

                ((any_alive == 0)) && break

                sleep 1
                elapsed=$((elapsed + 1))
        done

        for p in "${SERVER_PIDS[@]:-}"; do
                if kill -0 "$p" 2>/dev/null; then
                        kill "$p" 2>/dev/null || true
                fi
        done

        for p in "${SERVER_PIDS[@]:-}"; do
                wait "$p" 2>/dev/null || true
        done
}

### check for any PostgreSQL server failure
check_server_steps() {
        local p
        local n

        # Check the local Slurm server steps.
        for p in "${SERVER_PIDS[@]:-}"; do
                if ! kill -0 "$p" 2>/dev/null; then
                        echo "ERROR: PostgreSQL server srun step terminated unexpectedly" >&2
                        return 1
                fi
        done

        # Check PostgreSQL connectivity to every allocated node.
        for n in "${NODES[@]:-}"; do
                if ! "${PG_BIN_DIR}/pg_isready" \
                        -h "$n" \
                        -p "$PGPORT" \
                        -U "$PGUSER" \
                        -d postgres \
                        >/dev/null 2>&1; then
                        echo "ERROR: PostgreSQL is unavailable on $n:$PGPORT" >&2
                        return 1
                fi
        done
}

### initialize database cluster at node specified by first parameter value
init_node() {
        local n="$1"
        srun --overlap --exact --nodes=1 --ntasks=1 --cpus-per-task=1 --nodelist="$n" bash -s <<EOF2
set -euo pipefail

if [ -d "${DATA_ROOT}" ]; then rm -rf "$DATA_ROOT"; fi
mkdir -p "$PGDATA" "$DATA_ROOT"

${PG_BIN_DIR}/initdb -D "$PGDATA" --username="$PGUSER" --auth=trust --encoding=UTF8 --locale=C
cat >> "$PGDATA/postgresql.conf" <<CONF
listen_addresses='*'
port=$PGPORT
shared_preload_libraries='citus'
output_plugin_libraries='pgoutput, test_decoding, citus'
max_connections=$PG_MAX_CONNECTIONS
shared_buffers='$PG_SHARED_BUFFERS'
work_mem='$PG_WORK_MEM'
maintenance_work_mem='$PG_MAINTENANCE_WORK_MEM'
default_transaction_isolation='$PG_ISOLATION_LEVEL'
max_wal_size='$PG_MAX_WAL_SIZE'
min_wal_size='$PG_MIN_WAL_SIZE'
checkpoint_timeout='$PG_CHECKPOINT_TIMEOUT'
checkpoint_completion_target=$PG_CHECKPOINT_COMPLETION_TARGET
wal_level=logical
max_wal_senders=32
max_replication_slots=32
citus.enable_repartition_joins=$CITUS_ENABLE_REPARTITION_JOINS
citus.max_shared_pool_size=$CITUS_MAX_SHARED_POOL_SIZE
citus.max_adaptive_executor_pool_size=$CITUS_MAX_ADAPTIVE_EXECUTOR_POOL_SIZE
citus.local_shared_pool_size=$CITUS_LOCAL_SHARED_POOL_SIZE
CONF
cat >> "$PGDATA/pg_hba.conf" <<HBA
host all all 0.0.0.0/0 trust
host all all ::/0 trust
HBA
EOF2
}

### record PostgreSQL/Citus versions
record_server_versions() {
        {
                echo "PostgreSQL:"
                ${PSQL} -X -A -t \
                        -h "$COORDINATOR" \
                        -p "$PGPORT" \
                        -U "$PGUSER" \
                        -d "$PGDATABASE" \
                        -c "SELECT version();" || true

                echo
                echo "Citus:"
                ${PSQL} -X -A -t \
                        -h "$COORDINATOR" \
                        -p "$PGPORT" \
                        -U "$PGUSER" \
                        -d "$PGDATABASE" \
                        -c "SELECT citus_version();" || true
        } >"$JOB_RESULT_DIR/server_versions.log" 2>&1
}

##################################### Start server at each node

trap cleanup EXIT INT TERM

info "Slurm job started"
info "SLURM_JOB_ID=${SLURM_JOB_ID:-UNSET}"
info "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST:-UNSET}"
info "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-UNSET}"
info "SLURM_SUBMIT_DIR=${SLURM_SUBMIT_DIR:-UNSET}"
info "PG_BIN_DIR=$PG_BIN_DIR"

[[ -n "${SLURM_JOB_ID:-}" ]] || fail "Run with sbatch or inside a Slurm allocation"

for b in srun scontrol; do command -v "$b" >/dev/null 2>&1 || fail "$b not found"; done
for b in awk sort; do command -v "$b" >/dev/null 2>&1 || fail "$b not found"; done
for b in postgres initdb pg_ctl pg_isready psql createdb pgbench; do
        [[ -x "${PG_BIN_DIR}/$b" ]] ||
                fail "${PG_BIN_DIR}/$b not found or not executable"
done

info "Startup validation passed"

mkdir -p "${JOB_RESULT_DIR}"

# record coordinator & worker nodes
mapfile -t NODES < <(scontrol show hostnames "$SLURM_JOB_NODELIST")
((${#NODES[@]} >= 2)) || fail "Need at least 2 nodes: coordinator + worker"
COORDINATOR="${NODES[0]}"
WORKERS=("${NODES[@]:1}")
(( ${#WORKERS[@]} >= 2 )) || fail "Dynamic shard relocation requires at least two worker nodes"
{
        echo "coordinator=$COORDINATOR"
        i=1
        for w in "${WORKERS[@]}"; do
                echo "worker_${i}=$w"
                i=$((i + 1))
        done
} >"$JOB_RESULT_DIR/topology.txt"

info "Checking that commands can be launched on every allocated node"
for n in "${NODES[@]}"; do
        info "Checking node $n"

        if ! srun \
                --overlap \
                --exact \
                --nodes=1 \
                --ntasks=1 \
                --cpus-per-task=1 \
                --nodelist="$n" \
                hostname; then
                fail "Unable to launch a Slurm job step on node $n"
        fi
done
info "All allocated nodes passed Slurm launch test"

# initialize database cluster at each server
for n in "${NODES[@]}"; do init_node "$n"; done

# start postgres server at each node
# SERVER_PIDS = srun process ids
for n in "${NODES[@]}"; do
        PG_LOGFILE="${JOB_RESULT_DIR}/$n-postgresql.log"
        srun --overlap --nodes=1 --ntasks=1 --nodelist="$n" bash -c "exec ${PG_BIN_DIR}/postgres -D '${PGDATA}' > '${PG_LOGFILE}' 2>&1" &
        SERVER_PIDS+=("$!")
done
SERVERS_LAUNCHED=1 # servers launched

# create database at each server
for n in "${NODES[@]}"; do
        ready=0
        for _ in $(seq 1 60); do
                if "${PG_BIN_DIR}/pg_isready" -h "$n" -p "$PGPORT" -U "$PGUSER" -d postgres >/dev/null 2>&1; then
                        ready=1
                        break
                fi
                sleep 1
        done
        ((ready == 1)) || fail "PostgreSQL failed on $n"
        ${PG_BIN_DIR}/createdb -h "$n" -p "$PGPORT" -U "$PGUSER" "$PGDATABASE"
        ${PSQL} -X -v ON_ERROR_STOP=1 -h "$n" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "CREATE EXTENSION IF NOT EXISTS citus;"
done

# register each worker node at coordinator
for w in "${WORKERS[@]}"; do
        ${PSQL} -X -v ON_ERROR_STOP=1 -h "$COORDINATOR" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT * FROM citus_add_node('$w',$PGPORT);"
done

record_server_versions || true

############### Functions: create database schema

### create schema
create_schema() {
        DROP_EXISTING=1
        CREATE_CITUS_EXTENSION=0

        [[ "$CREATE_CITUS_EXTENSION" == "1" ]] && psqlx -c "CREATE EXTENSION IF NOT EXISTS citus;"

        if [[ "$DROP_EXISTING" == "1" ]]; then
                psqlx <<'SQL'
DROP TABLE IF EXISTS order_items CASCADE; DROP TABLE IF EXISTS orders CASCADE; DROP TABLE IF EXISTS inventory CASCADE;
DROP TABLE IF EXISTS products CASCADE; DROP TABLE IF EXISTS customers CASCADE; DROP TABLE IF EXISTS merchants CASCADE;
SQL
        fi

        psqlx <<'SQL'
CREATE TABLE IF NOT EXISTS merchants(merchant_id BIGINT PRIMARY KEY, merchant_name TEXT NOT NULL, region TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS customers(customer_id BIGINT, merchant_id BIGINT NOT NULL, customer_name TEXT NOT NULL, email TEXT NOT NULL, created_at TIMESTAMP NOT NULL, PRIMARY KEY(customer_id, merchant_id));
CREATE TABLE IF NOT EXISTS products(product_id BIGINT, merchant_id BIGINT NOT NULL, product_name TEXT NOT NULL, category TEXT, price NUMERIC(12,2) NOT NULL, PRIMARY KEY(product_id, merchant_id));
CREATE TABLE IF NOT EXISTS inventory(inventory_id BIGINT, merchant_id BIGINT NOT NULL, product_id BIGINT NOT NULL, quantity INTEGER NOT NULL CHECK(quantity>=0), updated_at TIMESTAMP NOT NULL, PRIMARY KEY(inventory_id, merchant_id));
CREATE TABLE IF NOT EXISTS orders(order_id BIGINT, merchant_id BIGINT NOT NULL, customer_id BIGINT NOT NULL, order_status TEXT NOT NULL, total_amount NUMERIC(12,2) NOT NULL CHECK(total_amount>=0), created_at TIMESTAMP NOT NULL, PRIMARY KEY(order_id, merchant_id));
CREATE TABLE IF NOT EXISTS order_items(order_item_id BIGINT, merchant_id BIGINT NOT NULL, order_id BIGINT NOT NULL, product_id BIGINT NOT NULL, quantity INTEGER NOT NULL CHECK(quantity>0), unit_price NUMERIC(12,2) NOT NULL CHECK(unit_price>=0), PRIMARY KEY(order_item_id, merchant_id));
CREATE INDEX IF NOT EXISTS idx_customers_merchant_id ON customers(merchant_id);
CREATE INDEX IF NOT EXISTS idx_products_merchant_id ON products(merchant_id);
CREATE INDEX IF NOT EXISTS idx_inventory_merchant_id ON inventory(merchant_id);
CREATE INDEX IF NOT EXISTS idx_orders_merchant_id ON orders(merchant_id);
CREATE INDEX IF NOT EXISTS idx_order_items_merchant_id ON order_items(merchant_id);
SQL

        psqlx <<'SQL'
DO $$ BEGIN
IF EXISTS(SELECT 1 FROM pg_extension WHERE extname='citus') THEN
PERFORM create_reference_table('merchants');
IF NOT EXISTS(SELECT 1 FROM pg_dist_partition WHERE logicalrelid='customers'::regclass) THEN PERFORM create_distributed_table('customers','merchant_id'); END IF;
IF NOT EXISTS(SELECT 1 FROM pg_dist_partition WHERE logicalrelid='products'::regclass) THEN PERFORM create_distributed_table('products','merchant_id', colocate_with=>'customers'); END IF;
IF NOT EXISTS(SELECT 1 FROM pg_dist_partition WHERE logicalrelid='inventory'::regclass) THEN PERFORM create_distributed_table('inventory','merchant_id', colocate_with=>'customers'); END IF;
IF NOT EXISTS(SELECT 1 FROM pg_dist_partition WHERE logicalrelid='orders'::regclass) THEN PERFORM create_distributed_table('orders','merchant_id', colocate_with=>'customers'); END IF;
IF NOT EXISTS(SELECT 1 FROM pg_dist_partition WHERE logicalrelid='order_items'::regclass) THEN PERFORM create_distributed_table('order_items','merchant_id', colocate_with=>'customers'); END IF;
END IF; END $$;
SQL

        psqlx <<'SQL'
DO $$
DECLARE
  distributed_count integer;
  merchant_key_count integer;
  colocation_count integer;
  reference_count integer;
  citus_major integer;
BEGIN
  SELECT (regexp_match(citus_version(), '([0-9]+)'))[1]::integer
    INTO citus_major;
  IF citus_major < 11 THEN
    RAISE EXCEPTION 'Dynamic tenant isolation requires Citus 11 or newer; found %', citus_version();
  END IF;

  SELECT COUNT(*),
         COUNT(*) FILTER (WHERE column_to_column_name(logicalrelid, partkey) = 'merchant_id'),
         COUNT(DISTINCT colocationid)
    INTO distributed_count, merchant_key_count, colocation_count
    FROM pg_dist_partition
   WHERE logicalrelid IN ('customers'::regclass, 'products'::regclass,
                          'inventory'::regclass, 'orders'::regclass,
                          'order_items'::regclass)
     AND partmethod = 'h';

  IF distributed_count <> 5 OR merchant_key_count <> 5 OR colocation_count <> 1 THEN
    RAISE EXCEPTION 'Expected five hash-distributed tables on merchant_id in one colocation group (found %, %, %)',
      distributed_count, merchant_key_count, colocation_count;
  END IF;

  SELECT COUNT(*) INTO reference_count
    FROM pg_dist_partition
   WHERE logicalrelid = 'merchants'::regclass
     AND partmethod = 'n';
  IF reference_count <> 1 THEN
    RAISE EXCEPTION 'merchants must be a Citus reference table';
  END IF;
END $$;
SQL
}

############### create database schema
PGHOST="$COORDINATOR"
create_schema &>"$JOB_RESULT_DIR/schema-create.log"

################## Functions: generate data

### scale data size using scaling factor SCALE
scale_count() { awk -v b="$1" -v s="$SCALE" 'BEGIN{x=int(b*s+0.5);if(x<1)x=1;print x}'; }

### generate synthetic data
generate_data() {
        HOT_MERCHANTS=$((NUM_MERCHANTS * HOT_MERCHANT_PERCENT / 100))
        ((HOT_MERCHANTS >= 1)) || HOT_MERCHANTS=1
        COLD_MERCHANTS=$((NUM_MERCHANTS - HOT_MERCHANTS))
        ((COLD_MERCHANTS >= 1)) || COLD_MERCHANTS=1

        if [[ "$TRUNCATE_FIRST" == "1" ]]; then psqlx -c "TRUNCATE TABLE order_items,orders,inventory,products,customers,merchants CASCADE;"; fi

        psqlx <<SQL
INSERT INTO merchants SELECT i,'Merchant-'||i,(ARRAY['North','South','East','West','Central'])[1+(i%5)] FROM generate_series(1::bigint, $NUM_MERCHANTS::bigint) g(i);

INSERT INTO customers SELECT i,1+((i::bigint - 1)%$NUM_MERCHANTS),'Customer-'||i,'customer-'||i||'@example.test',timestamp '2020-01-01'+(((i::bigint * 17))%2000)*interval '1 day' FROM generate_series(1::bigint, $NUM_CUSTOMERS::bigint) g(i);

INSERT INTO products SELECT i,1+((i::bigint - 1)%$NUM_MERCHANTS),'Product-'||i,'Category-'||(i%10),(1+(((i::bigint * 7919))%100000)/100.0)::numeric(12,2) FROM generate_series(1::bigint, $NUM_PRODUCTS::bigint) g(i);

INSERT INTO inventory SELECT product_id,merchant_id,product_id,10+((hashint8extended(product_id,$DATA_SEED)&9223372036854775807)%991)::int,current_timestamp FROM products;
SQL

        psqlx <<SQL
WITH g AS (
  SELECT i::bigint,(hashint8extended(i,$DATA_SEED)&9223372036854775807) h1,(hashint8extended(i,$((DATA_SEED + 1)))&9223372036854775807) h2 FROM generate_series(1::bigint, $NUM_ORDERS::bigint) g(i)
), m AS (
  SELECT i::bigint,CASE WHEN (h1%10000)<($HOT_ORDER_PERCENT*100) THEN 1+(h2%$HOT_MERCHANTS) ELSE $HOT_MERCHANTS+1+(h2%$COLD_MERCHANTS) END::bigint merchant_id FROM g
)
INSERT INTO orders
SELECT i::bigint,merchant_id,merchant_id+$NUM_MERCHANTS*((hashint8extended(i,$((DATA_SEED + 2)))&9223372036854775807)%((($NUM_CUSTOMERS-merchant_id)/$NUM_MERCHANTS)+1)),
       'COMPLETED',0.00,current_timestamp-(((i::bigint * 31))%365)*interval '1 day' FROM m;
SQL

        psqlx <<SQL
WITH g AS (
 SELECT i order_item_id,1+((i::bigint - 1)%$NUM_ORDERS) order_id,(hashint8extended(i,$((DATA_SEED + 10)))&9223372036854775807) ph,
        1+((hashint8extended(i,$((DATA_SEED + 11)))&9223372036854775807)%5)::int qty FROM generate_series(1::bigint, $NUM_ORDER_ITEMS::bigint) g(i)
), x AS (SELECT g.*,o.merchant_id FROM g JOIN orders o USING(order_id)),
y AS (SELECT *,merchant_id+$NUM_MERCHANTS*(ph%((($NUM_PRODUCTS-merchant_id)/$NUM_MERCHANTS)+1)) product_id FROM x)
INSERT INTO order_items SELECT y.order_item_id,y.merchant_id,y.order_id,y.product_id,y.qty,p.price FROM y JOIN products p USING(product_id);
UPDATE orders o SET total_amount=x.total FROM (SELECT order_id,SUM(quantity*unit_price)::numeric(12,2) total FROM order_items GROUP BY order_id) x WHERE o.order_id=x.order_id;
SQL
        [[ "$RUN_ANALYZE" == "1" ]] && psqlx -c "ANALYZE;"
        echo "Synthetic data generation complete. Default scale creates about $((NUM_ORDER_ITEMS / NUM_ORDERS)) historical items/order."
}

################## generate data
PGHOST="$COORDINATOR"
NUM_MERCHANTS="${NUM_MERCHANTS:-$(scale_count 1000)}"
NUM_CUSTOMERS="${NUM_CUSTOMERS:-$(scale_count 1000000)}"
NUM_PRODUCTS="${NUM_PRODUCTS:-$(scale_count 500000)}"
NUM_ORDERS="${NUM_ORDERS:-$(scale_count 5000000)}"
NUM_ORDER_ITEMS="${NUM_ORDER_ITEMS:-$(scale_count 15000000)}"
TRUNCATE_FIRST="${TRUNCATE_FIRST:-1}"
RUN_ANALYZE="${RUN_ANALYZE:-1}"
generate_data &>"$JOB_RESULT_DIR/data-generation.log"
echo "Checking PostgreSQL servers after data loading..."
check_server_steps || fail "Cluster health check failed after data generation"

############### Functions: analyze benchmark results

###  collect log files
collect_logs() {
        local prefix="$1"
        local output="$2"
        local found=0
        local f
        local nullglob_was_set=0

        shopt -q nullglob && nullglob_was_set=1
        shopt -s nullglob

        : >"$output"

        for f in "${prefix}".*; do
                cat "$f" >>"$output"
                found=1
        done

        ((nullglob_was_set)) || shopt -u nullglob

        if ((found == 0)); then
                echo "ERROR: No pgbench transaction log found for prefix $prefix" >&2
                return 1
        fi
}

### calculate latency metrics
# Input: one latency value in microseconds per line.
# Output: count,average_ms,p50_ms,p95_ms,p99_ms,min_ms,max_ms
calculate_latency_metrics() {
        local input="$1"

        if [[ ! -s "$input" ]]; then
                echo "0,NA,NA,NA,NA,NA,NA"
                return
        fi

        local sorted="${input}.sorted"
        sort -n "$input" >"$sorted"

        awk '
    {
      values[NR] = $1
      sum += $1
    }
    END {
      n = NR
      p50 = int((n - 1) * 0.50) + 1
      p95 = int((n - 1) * 0.95) + 1
      p99 = int((n - 1) * 0.99) + 1
      printf "%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
             n,
             (sum / n) / 1000.0,
             values[p50] / 1000.0,
             values[p95] / 1000.0,
             values[p99] / 1000.0,
             values[1] / 1000.0,
             values[n] / 1000.0
    }
  ' "$sorted"

        rm -f "$sorted"
}

### extract stats for transaction retries
extract_pgbench_retry_stats() {
        local result_file="$1"

        local retried_transactions
        local total_retries
        local serialization_failures
        local deadlock_failures

        retried_transactions="$(
                awk '
      /^number of transactions retried:/ {
        line=$0
        sub(/^.*:[[:space:]]*/, "", line)
        sub(/[[:space:]].*$/, "", line)
        value=line
      }
      END {
        if (value == "")
          value=0
        print value
      }
    ' "$result_file"
        )"

        total_retries="$(
                awk '
      /^total number of retries:/ {
        line=$0
        sub(/^.*:[[:space:]]*/, "", line)
        sub(/[[:space:]].*$/, "", line)
        value=line
      }
      END {
        if (value == "")
          value=0
        print value
      }
    ' "$result_file"
        )"

        serialization_failures="$(
                awk '
      /^number of serialization failures:/ {
        line=$0
        sub(/^.*:[[:space:]]*/, "", line)
        sub(/[[:space:]].*$/, "", line)
        value=line
      }
      END {
        if (value == "")
          value=0
        print value
      }
    ' "$result_file"
        )"

        deadlock_failures="$(
                awk '
      /^number of deadlock failures:/ {
        line=$0
        sub(/^.*:[[:space:]]*/, "", line)
        sub(/[[:space:]].*$/, "", line)
        value=line
      }
      END {
        if (value == "")
          value=0
        print value
      }
    ' "$result_file"
        )"

        printf '%s,%s,%s,%s\n' \
                "$retried_transactions" \
                "$total_retries" \
                "$serialization_failures" \
                "$deadlock_failures"
}

### analyze run
# 1st parameter: number of clients C
# 2nd parameter: $LOG_DIR/pgbench-c${C}
# 3rd parameter: $RUN_DIR/result-c${C}.txt
# 4th parameter: pgbench return code
analyze_run() {
        local clients="$1"
        local prefix="$2"
        local result_file="$3"
        local pgbench_rc="${4:-0}"

        local combined="$LOG_DIR/transactions-c${clients}.log"
        local metrics_dir="$RUN_DIR/metrics-c${clients}"

        local all_latency_file="$metrics_dir/all-latency-us.txt"
        local unsuccessful_file="$metrics_dir/unsuccessful-log-records.txt"

        local total_success
        local overall_avg
        local overall_p50
        local overall_p95
        local overall_p99
        local overall_min
        local overall_max

        local unsuccessful_records
        local overall_tps

        local retried_transactions
        local total_retries
        local serialization_failures
        local deadlock_failures

        mkdir -p "$metrics_dir"

        #
        # Combine all per-client pgbench transaction log files.
        #
        if ! collect_logs "$prefix" "$combined"; then
                if ((pgbench_rc == 0)); then
                        fail "pgbench completed successfully without transaction logs for c${clients}"
                fi
                : >"$combined"
                workload_log "pgbench_log_missing" "complete" "" "" "" "" "" "" "" "" "" "" "" "incomplete" "pgbench_exit_code=$pgbench_rc"
        fi

        #
        # pgbench per-transaction log format starts with:
        #
        #   client_id transaction_no latency_us script_no ...
        #
        # A successful transaction has a numeric latency value in field 3.
        # An unsuccessful transaction can have a nonnumeric value in field 3,
        # such as "serialization" or "deadlock" when --failures-detailed is used.
        #
        awk '$3 ~ /^[0-9]+$/ { print $3 }' \
                "$combined" >"$all_latency_file"

        awk '$3 !~ /^[0-9]+$/ { print }' \
                "$combined" >"$unsuccessful_file"

        #
        # Compute overall latency statistics from successful transactions.
        #
        IFS=',' read -r \
                total_success \
                overall_avg \
                overall_p50 \
                overall_p95 \
                overall_p99 \
                overall_min \
                overall_max \
                <<<"$(calculate_latency_metrics "$all_latency_file")"

        unsuccessful_records="$(
                wc -l <"$unsuccessful_file" | tr -d ' '
        )"

        #
        # Counts and TPS derived from pgbench transaction logs are correct only
        # when every transaction is logged.
        #
        if [[ "$LOG_SAMPLE_RATE" != "1" && "$LOG_SAMPLE_RATE" != "1.0" ]]; then
                fail "LOG_SAMPLE_RATE must be 1 or 1.0 when deriving transaction counts and TPS from pgbench logs"
        fi

        overall_tps="$(
                awk \
                        -v count="$total_success" \
                        -v duration="$DURATION" \
                        'BEGIN {
         if (duration > 0)
           printf "%.3f", count / duration
         else
           printf "0.000"
       }'
        )"

        #
        # Extract pgbench retry/failure statistics from pgbench's textual result.
        #
        IFS=',' read -r \
                retried_transactions \
                total_retries \
                serialization_failures \
                deadlock_failures \
                <<<"$(extract_pgbench_retry_stats "$result_file")"

        #
        # Overall benchmark summary.
        #
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$clients" \
                "$total_success" \
                "$unsuccessful_records" \
                "$overall_tps" \
                "$overall_avg" \
                "$overall_p50" \
                "$overall_p95" \
                "$overall_p99" \
                "$retried_transactions" \
                "$total_retries" \
                "$serialization_failures" \
                "$deadlock_failures" \
                "$pgbench_rc" \
                >>"$SUMMARY_FILE"

        #
        # Per-transaction latency statistics.
        #
        local txn
        for txn in T1 T2 T3 T4 T5 T6 T7 T8 T9; do
                local latency_file="$metrics_dir/${txn}-latency-us.txt"

                local count
                local avg
                local p50
                local p95
                local p99
                local min
                local max

                local txn_tps
                local txn_name

                : >"$latency_file"

                #
                # SCRIPT_NUMBER only exists for transactions whose weight is > 0.
                #
                if [[ -v "SCRIPT_NUMBER[$txn]" ]]; then
                        awk \
                                -v script_no="${SCRIPT_NUMBER[$txn]}" \
                                '$3 ~ /^[0-9]+$/ && $4 == script_no { print $3 }' \
                                "$combined" >"$latency_file"
                fi

                IFS=',' read -r \
                        count \
                        avg \
                        p50 \
                        p95 \
                        p99 \
                        min \
                        max \
                        <<<"$(calculate_latency_metrics "$latency_file")"

                txn_tps="$(
                        awk \
                                -v count="$count" \
                                -v duration="$DURATION" \
                                'BEGIN {
           if (duration > 0)
             printf "%.3f", count / duration
           else
             printf "0.000"
         }'
                )"

                txn_name="${SCRIPT_NAME[$txn]:-disabled}"

                printf '%s,%s,"%s",%s,%s,%s,%s,%s,%s\n' \
                        "$clients" \
                        "$txn" \
                        "$txn_name" \
                        "$count" \
                        "$txn_tps" \
                        "$avg" \
                        "$p50" \
                        "$p95" \
                        "$p99" \
                        >>"$TX_METRICS_FILE"
        done

        #
        # Human-readable summary for this client-count experiment.
        #
        cat >"$RUN_DIR/latency-summary-c${clients}.txt" <<EOF
clients=$clients

overall_average_latency_ms=$overall_avg
overall_median_latency_ms=$overall_p50
overall_p95_latency_ms=$overall_p95
overall_p99_latency_ms=$overall_p99
overall_min_latency_ms=$overall_min
overall_max_latency_ms=$overall_max

successful_transactions=$total_success
unsuccessful_log_records=$unsuccessful_records
overall_tps=$overall_tps

retried_transactions=$retried_transactions
total_retries=$total_retries
serialization_failures=$serialization_failures
deadlock_failures=$deadlock_failures

pgbench_exit_code=$pgbench_rc
EOF
}

############### Functions: benchmarking

### check that second parameter value is an non-negative integer
require_integer() {
        local name="$1" value="$2"
        [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be a non-negative integer"
}

### add workload
add_workload() {
        local txn="$1" file="$2" weight="$3" name="$4"
        ((weight > 0)) || return
        workload+=("-f" "$TX_DIR/$file@$weight")
        SCRIPT_NUMBER["$txn"]="$idx"
        SCRIPT_NAME["$txn"]="$name"
        idx=$((idx + 1))
}

### run pgbench
run_pgbench() {
        local clients="$1"
        local duration="$2"
        local output="$3"
        local label="$4"
        local prefix="$5"
        local logging="$6"
        local threads="$THREADS"
        local -a pipe_status

        ((threads <= clients)) || threads="$clients"

        local args=(
                "$PGBENCH"
                --random-seed="$PGBENCH_SEED"
                --max-tries="$PGBENCH_MAX_TRIES"
                -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE"
                -n -c "$clients" -j "$threads" -T "$duration"
                -M "$PGBENCH_QUERY_MODE"
                -P "$PROGRESS_INTERVAL"
                -r
        )

        if ((PGBENCH_FAILURES_DETAILED)); then
                args+=(--failures-detailed)
        fi

        if [[ "$logging" == "1" ]]; then
                args+=(-l --log-prefix="$prefix" --sampling-rate="$LOG_SAMPLE_RATE")
        fi

        args+=("${common_defs[@]}")
        args+=("${workload[@]}")

        info "$label: clients=$clients threads=$threads duration=${duration}s"

        set +e
        {
                printf '# Command:'
                printf ' %q' "${args[@]}"
                echo
                "${args[@]}"
        } 2>&1 | tee "$output"

        pipe_status=("${PIPESTATUS[@]}")
        local pgbench_rc="${pipe_status[0]}"
        local tee_rc="${pipe_status[1]}"
        set -e

        {
                echo "pgbench_exit_code=$pgbench_rc"
                echo "tee_exit_code=$tee_rc"
        } >>"$output"

        if ((tee_rc != 0)); then
                echo "ERROR: tee failed while writing $output (exit code $tee_rc)" >&2
                return "$tee_rc"
        fi

        return "$pgbench_rc"

}

### reset "deterministic" benchmark state
reset_benchmark_sequences() {
        "$PSQL" -X -v ON_ERROR_STOP=1 \
                -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<'SQL'
DO $$
DECLARE
  max_order_id bigint;
  max_order_item_id bigint;
BEGIN
  SELECT COALESCE(MAX(order_id),0) INTO max_order_id FROM orders;
  SELECT COALESCE(MAX(order_item_id),0) INTO max_order_item_id FROM order_items;

  IF to_regclass('benchmark_order_id_seq') IS NULL THEN
    EXECUTE format('CREATE SEQUENCE benchmark_order_id_seq START WITH %s',
                   max_order_id + 1);
  ELSE
    PERFORM setval('benchmark_order_id_seq', max_order_id + 1, false);
  END IF;

  IF to_regclass('benchmark_order_item_id_seq') IS NULL THEN
    EXECUTE format('CREATE SEQUENCE benchmark_order_item_id_seq START WITH %s',
                   max_order_item_id + 1);
  ELSE
    PERFORM setval('benchmark_order_item_id_seq',
                   max_order_item_id + 1, false);
  END IF;
END $$;
SQL
}

### start the measured run without waiting so migration overlaps the workload
start_pgbench_background() {
        local clients="$1" duration="$2" output="$3" prefix="$4" threads="$THREADS"
        local -a args
        ((threads <= clients)) || threads="$clients"
        args=(
                "$PGBENCH"
                --random-seed="$PGBENCH_SEED"
                --max-tries="$PGBENCH_MAX_TRIES"
                -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE"
                -n -c "$clients" -j "$threads" -T "$duration"
                -M "$PGBENCH_QUERY_MODE" -P "$PROGRESS_INTERVAL" -r
                -l --log-prefix="$prefix" --sampling-rate="$LOG_SAMPLE_RATE"
        )
        if ((PGBENCH_FAILURES_DETAILED)); then args+=(--failures-detailed); fi
        args+=("${common_defs[@]}" "${workload[@]}")
        info "Dynamic measured run: clients=$clients threads=$threads duration=${duration}s"
        printf '# Command:' >"$output"
        printf ' %q' "${args[@]}" >>"$output"
        printf '\n' >>"$output"
        "${args[@]}" >>"$output" 2>&1 &
        PGBENCH_PID=$!
}

finish_pgbench_background() {
        local rc=0
        if [[ -n "$PGBENCH_PID" ]]; then
                wait "$PGBENCH_PID" || rc=$?
                PGBENCH_PID=""
        fi
        printf 'pgbench_exit_code=%s\n' "$rc" >>"$1"
        printf 'tee_exit_code=0\n' >>"$1"
        return "$rc"
}

### reset benchmark database
reset_benchmark_database() {
        local reason="${1:-benchmark reset}"
        local saved_truncate_first="${TRUNCATE_FIRST:-1}"
        local saved_run_analyze="${RUN_ANALYZE:-1}"

        info "Resetting database to somewhat deterministic initial state: $reason"

        TRUNCATE_FIRST=1
        RUN_ANALYZE=1
        generate_data

        TRUNCATE_FIRST="$saved_truncate_first"
        RUN_ANALYZE="$saved_run_analyze"

        reset_benchmark_sequences
        check_server_steps || fail "Cluster health check failed after database reset"

        info "Database reset complete: $reason"
}

### restart postgres servers
restart_postgres_servers() {
        local n
        local p
        local ready
        local restart_log

        info "Restarting PostgreSQL servers before next client-count experiment"

        # Ask every PostgreSQL instance to stop cleanly.
        for n in "${NODES[@]}"; do
                srun \
                        --overlap \
                        --exact \
                        --nodes=1 \
                        --ntasks=1 \
                        --cpus-per-task=1 \
                        --nodelist="$n" \
                        bash -c \
                        "${PG_BIN_DIR}/pg_ctl -D '${PGDATA}' stop -m fast \
       >/dev/null 2>&1 || true" ||
                        true
        done

        # Reap the old background srun processes
        bounded_wait_server_pids || true

        SERVER_PIDS=()

        # Start a fresh PostgreSQL process on each node using the existing PGDATA.
        for n in "${NODES[@]}"; do
                restart_log="${JOB_RESULT_DIR}/${n}-postgresql.log"

                srun \
                        --overlap \
                        --nodes=1 \
                        --ntasks=1 \
                        --nodelist="$n" \
                        bash -c \
                        "exec ${PG_BIN_DIR}/postgres -D '${PGDATA}' >> '${restart_log}' 2>&1" &

                SERVER_PIDS+=("$!")
        done

        # Wait for every node to accept connections again.
        for n in "${NODES[@]}"; do
                ready=0

                for _ in $(seq 1 "$SERVER_RESTART_TIMEOUT"); do
                        if "${PG_BIN_DIR}/pg_isready" \
                                -h "$n" \
                                -p "$PGPORT" \
                                -U "$PGUSER" \
                                -d postgres \
                                >/dev/null 2>&1; then
                                ready=1
                                break
                        fi

                        sleep 1
                done

                ((ready == 1)) || fail "PostgreSQL failed to restart on $n"
        done

        check_server_steps || fail "Cluster health check failed after PostgreSQL restart"

        info "All PostgreSQL servers restarted successfully"
}

### append a correctly escaped row to the dedicated workload log
workload_log() {
        local timestamp clients event phase merchant count shard source target duration tps avg p95 p99 failures status message
        local -a values
        timestamp="$(date +%s)"
        clients="${CURRENT_CLIENTS:-NA}"
        event="$1"; phase="$2"; merchant="$3"; count="$4"; shard="$5"; source="$6"; target="$7"
        duration="$8"; tps="$9"; avg="${10}"; p95="${11}"; p99="${12}"; failures="${13}"; status="${14}"; message="${15}"
        values=("$timestamp" "$clients" "$event" "$phase" "$merchant" "$count" "$shard" "$source" "$target" "$duration" "$tps" "$avg" "$p95" "$p99" "$failures" "$status" "$message")
        local i value
        for i in "${!values[@]}"; do
                value="${values[$i]//\"/\"\"}"
                values[$i]="\"$value\""
        done
        (IFS=,; printf '%s\n' "${values[*]}") >>"$WORKLOAD_LOG_FILE"
}

pgbench_is_running() {
        local process_state
        [[ -n "$PGBENCH_PID" ]] || return 1
        kill -0 "$PGBENCH_PID" 2>/dev/null || return 1
        process_state="$(ps -o stat= -p "$PGBENCH_PID" 2>/dev/null)"
        [[ "$process_state" != *Z* && -n "$process_state" ]]
}

### sample worker CPU only when choosing a destination
measure_worker_cpu() {
        local node="$1"
        srun --overlap --exact --nodes=1 --ntasks=1 --cpus-per-task=1 --nodelist="$node" bash -s <<'REMOTE'
set -euo pipefail
read -r _ u1 n1 s1 i1 w1 irq1 sirq1 steal1 _ _ < /proc/stat
idle1=$((i1 + w1)); total1=$((u1 + n1 + s1 + i1 + w1 + irq1 + sirq1 + steal1))
sleep 1
read -r _ u2 n2 s2 i2 w2 irq2 sirq2 steal2 _ _ < /proc/stat
idle2=$((i2 + w2)); total2=$((u2 + n2 + s2 + i2 + w2 + irq2 + sirq2 + steal2))
awk -v dt="$((total2-total1))" -v di="$((idle2-idle1))" 'BEGIN { if (dt > 0) printf "%.3f", 100 * (dt-di) / dt; else print "100.000" }'
REMOTE
}

choose_destination_worker() {
        local source="$1" node load best_node="" best_load=""
        for node in "${WORKERS[@]}"; do
                [[ "$node" == "$source" ]] && continue
                load="$(measure_worker_cpu "$node")" || return 1
                if [[ -z "$best_load" ]] || awk -v a="$load" -v b="$best_load" 'BEGIN { exit !(a < b) }'; then
                        best_load="$load"
                        best_node="$node"
                fi
        done
        [[ -n "$best_node" ]] || return 1
        printf '%s|%s\n' "$best_node" "$best_load"
}

remaining_adaptation_seconds() {
        local elapsed=$(( $(date +%s) - ADAPTATION_START_EPOCH ))
        local remaining=$(( ADAPTATION_TIMEOUT - elapsed ))
        ((remaining > 0)) && printf '%s\n' "$remaining" || printf '0\n'
}

run_dynamic_adaptation() {
        local clients="$1" snapshot="$2" baseline_start="$3" baseline_end="$4"
        local candidates output merchant count rank status source shard target target_load
        local operation_start operation_end operation_ms remaining remaining_ms placement_rows table node
        local moved=0
        local -a rows

        ADAPTATION_START_EPOCH="$(date +%s)"
        ADAPTATION_START_MS="$(now_epoch_ms)"
        workload_log "detection_start" "detection" "" "" "" "" "" "" "" "" "" "" "" "started" ""
        candidates="$(PGOPTIONS="-c statement_timeout=$((ADAPTATION_TIMEOUT * 1000))" psqlx -A -t -F '|' -c "
WITH ranked AS (
  SELECT merchant_id, COUNT(*)::bigint AS order_count,
         ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, merchant_id ASC) AS rank
    FROM orders
   WHERE order_id > $snapshot
     AND created_at >= to_timestamp($baseline_start)
     AND created_at < to_timestamp($baseline_end)
   GROUP BY merchant_id
)
SELECT merchant_id, order_count, rank FROM ranked ORDER BY rank;")" || {
                workload_log "detection_failed" "detection" "" "" "" "" "" "" "" "" "" "" "" "failed" "query failed"
                return 1
        }

        mapfile -t rows <<<"$candidates"
        local candidate_count=0
        for output in "${rows[@]}"; do
                [[ -z "$output" ]] && continue
                IFS='|' read -r merchant count rank <<<"$output"
                candidate_count=$((candidate_count + 1))
                if ((rank <= HOT_MERCHANT_LIMIT)); then status="selected"; else status="ranked"; fi
                workload_log "merchant_detected" "detection" "$merchant" "$count" "" "" "" "" "" "" "" "" "" "$status" "rank=$rank"
        done
        workload_log "detection_end" "detection" "" "$candidate_count" "" "" "" "" "" "" "" "" "" "complete" "selected_limit=$HOT_MERCHANT_LIMIT"

        if ((candidate_count < HOT_MERCHANT_LIMIT)); then
                workload_log "adaptation_skipped" "migration" "" "$candidate_count" "" "" "" "" "" "" "" "" "" "insufficient_candidates" "need=$HOT_MERCHANT_LIMIT"
                return 0
        fi

        workload_log "migration_start" "migration" "" "" "" "" "" "" "" "" "" "" "" "started" ""
        for output in "${rows[@]}"; do
                [[ -z "$output" ]] && continue
                IFS='|' read -r merchant count rank <<<"$output"
                ((rank <= HOT_MERCHANT_LIMIT)) || continue
                if ! pgbench_is_running; then
                        workload_log "adaptation_failed" "migration" "$merchant" "$count" "" "" "" "" "" "" "" "" "" "pgbench_not_running" "pgbench exited before isolation"
                        break
                fi
                remaining="$(remaining_adaptation_seconds)"
                if ((remaining <= 0)); then
                        workload_log "adaptation_timeout" "migration" "$merchant" "$count" "" "" "" "" "" "" "" "" "" "timeout" "budget=${ADAPTATION_TIMEOUT}s"
                        break
                fi

                operation_start="$(now_epoch_ms)"
                workload_log "isolation_start" "migration" "$merchant" "$count" "" "" "" "" "" "" "" "" "" "started" "cascade=all_colocated_tables mode=$SHARD_TRANSFER_MODE"
                remaining_ms=$((remaining * 1000))
                output="$(PGOPTIONS="-c statement_timeout=$remaining_ms" psqlx -A -t -c "SELECT isolate_tenant_to_new_shard('customers', $merchant, 'CASCADE', '$SHARD_TRANSFER_MODE');")" || {
                        operation_end="$(now_epoch_ms)"
                        operation_ms=$((operation_end-operation_start))
                        workload_log "isolation_end" "migration" "$merchant" "$count" "" "" "" "" "$operation_ms" "" "" "" "" "failed" "isolate_tenant_to_new_shard failed"
                        if (($(remaining_adaptation_seconds) <= 0)); then
                                workload_log "adaptation_timeout" "migration" "$merchant" "$count" "" "" "" "$operation_ms" "" "" "" "" "" "timeout" "isolation exceeded budget=${ADAPTATION_TIMEOUT}s"
                        fi
                        continue
                }
                shard="$(printf '%s\n' "$output" | awk '/^[0-9]+$/ { value=$1 } END { print value }')"
                operation_end="$(now_epoch_ms)"
                operation_ms=$((operation_end-operation_start))
                if [[ -z "$shard" ]]; then
                        workload_log "isolation_end" "migration" "$merchant" "$count" "" "" "" "" "$operation_ms" "" "" "" "" "failed" "no shard id returned"
                        continue
                fi
                workload_log "isolation_end" "migration" "$merchant" "$count" "$shard" "" "" "$operation_ms" "" "" "" "" "" "success" ""

                if ! pgbench_is_running; then
                        workload_log "adaptation_failed" "migration" "$merchant" "$count" "$shard" "" "" "" "" "" "" "" "" "pgbench_not_running" "pgbench exited after isolation"
                        break
                fi
                source="$(psqlx -A -t -c "SELECT node.nodename FROM pg_dist_placement placement JOIN pg_dist_node node USING (groupid) WHERE placement.shardid=$shard AND placement.shardstate=1 AND node.noderole='primary' LIMIT 1;")" || source=""
                if [[ -z "$source" ]]; then
                        workload_log "move_failed" "migration" "$merchant" "$count" "$shard" "" "" "" "" "" "" "" "" "no_source_placement" "could not identify source node"
                        continue
                fi
                target_load="$(choose_destination_worker "$source")" || {
                        workload_log "move_failed" "migration" "$merchant" "$count" "$shard" "$source" "" "" "" "" "" "" "" "cpu_sample_failed" "could not select destination worker"
                        continue
                }
                IFS='|' read -r target _ <<<"$target_load"
                remaining="$(remaining_adaptation_seconds)"
                if ((remaining <= 0)); then
                        workload_log "adaptation_timeout" "migration" "$merchant" "$count" "$shard" "$source" "$target" "" "" "" "" "" "" "timeout" "budget=${ADAPTATION_TIMEOUT}s"
                        break
                fi
                operation_start="$(now_epoch_ms)"
                if ! pgbench_is_running; then
                        workload_log "adaptation_failed" "migration" "$merchant" "$count" "$shard" "$source" "$target" "" "" "" "" "" "" "pgbench_not_running" "pgbench exited before move"
                        break
                fi
                workload_log "move_start" "migration" "$merchant" "$count" "$shard" "$source" "$target" "" "" "" "" "" "" "started" "mode=$SHARD_TRANSFER_MODE"
                remaining_ms=$((remaining * 1000))
                if ! PGOPTIONS="-c statement_timeout=$remaining_ms" psqlx -v ON_ERROR_STOP=1 -c "SELECT citus_move_shard_placement($shard, '$source', $PGPORT, '$target', $PGPORT, '$SHARD_TRANSFER_MODE');" >/dev/null; then
                        operation_end="$(now_epoch_ms)"
                        operation_ms=$((operation_end-operation_start))
                        workload_log "move_end" "migration" "$merchant" "$count" "$shard" "$source" "$target" "$operation_ms" "" "" "" "" "" "failed" "citus_move_shard_placement failed"
                        if (($(remaining_adaptation_seconds) <= 0)); then
                                workload_log "adaptation_timeout" "migration" "$merchant" "$count" "$shard" "$source" "$target" "$operation_ms" "" "" "" "" "" "timeout" "move exceeded budget=${ADAPTATION_TIMEOUT}s"
                        fi
                        continue
                fi
                operation_end="$(now_epoch_ms)"
                operation_ms=$((operation_end-operation_start))
                moved=$((moved + 1))
                workload_log "move_end" "migration" "$merchant" "$count" "$shard" "$source" "$target" "$operation_ms" "" "" "" "" "" "success" ""
                if ! pgbench_is_running; then
                        workload_log "adaptation_failed" "migration" "$merchant" "$count" "$shard" "$source" "$target" "" "" "" "" "" "" "pgbench_not_running" "pgbench exited after move"
                        break
                fi

                placement_rows="$(psqlx -A -t -F '|' -c "
SELECT table_name, node.nodename
  FROM (VALUES ('customers'), ('products'), ('inventory'), ('orders'), ('order_items')) AS tables(table_name)
  CROSS JOIN LATERAL get_shard_id_for_distribution_column(table_name::regclass, $merchant) AS isolated(shardid)
  JOIN pg_dist_placement placement USING (shardid)
  JOIN pg_dist_node node USING (groupid)
 WHERE placement.shardstate = 1 AND node.noderole = 'primary'
 ORDER BY table_name;")" || placement_rows=""
                local verified=1
                local verification_count=0
                while IFS='|' read -r table node; do
                        [[ -z "$table" ]] && continue
                        verification_count=$((verification_count + 1))
                        [[ "$node" == "$target" ]] || verified=0
                done <<<"$placement_rows"
                ((verification_count == 5)) || verified=0
                if ((verified)); then
                        workload_log "placement_verified" "migration" "$merchant" "$count" "$shard" "$source" "$target" "" "" "" "" "" "" "success" "all_five_tables_on_destination"
                else
                        workload_log "placement_verified" "migration" "$merchant" "$count" "$shard" "$source" "$target" "" "" "" "" "" "" "failed" "placement mismatch or missing table shard"
                fi
                if ! pgbench_is_running; then
                        workload_log "adaptation_failed" "migration" "$merchant" "$count" "$shard" "$source" "$target" "" "" "" "" "" "" "pgbench_not_running" "pgbench exited after move"
                        break
                fi
        done
        workload_log "migration_end" "migration" "" "$moved" "" "" "" "$(( $(now_epoch_ms) - ADAPTATION_START_MS ))" "" "" "" "" "" "complete" "successful_moves=$moved"
}

### derive phase throughput and latency from pgbench timestamped transaction logs
log_phase_metrics() {
        local input="$1" phase="$2" start_epoch="$3" end_epoch="$4"
        local duration=$((end_epoch-start_epoch))
        local samples="${input}.${phase}.latency-us"
        local failures total avg p95 p99 tps
        ((duration > 0)) || return 0
        awk -v start="$start_epoch" -v end="$end_epoch" '
          NF >= 6 && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ {
            completed=$5 + ($6 / 1000000.0)
            if (completed >= start && completed < end) {
              if ($3 ~ /^[0-9]+$/) print $3; else failed++
            }
          }
          END { printf "%d\n", failed+0 > "/dev/stderr" }
        ' "$input" >"$samples" 2>"${samples}.failures"
        failures="$(tail -n 1 "${samples}.failures")"
        IFS=',' read -r total avg _ p95 p99 _ _ <<<"$(calculate_latency_metrics "$samples")"
        tps="$(awk -v n="$total" -v d="$duration" '
          BEGIN {
            if (d > 0)
              printf "%.3f", n / d
            else
              printf "0.000"
          }
        ')"
        workload_log "phase_metrics" "$phase" "" "" "" "" "" "$((duration*1000))" "$tps" "$avg" "$p95" "$p99" "$failures" "complete" "successful_transactions=$total"
        rm -f "$samples" "${samples}.failures"
}

### run benchmark
run_benchmark() {

        mkdir -p "$LOG_DIR"

        for cmd in "$PGBENCH" "$PSQL" awk sort; do
                if [[ "$cmd" == */* ]]; then
                        [[ -x "$cmd" ]] || fail "Required executable not found: $cmd"
                else
                        command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
                fi
        done

        for pair in \
                "DURATION:$DURATION" \
                "WARMUP_DURATION:$WARMUP_DURATION" \
                "BASELINE_DURATION:$BASELINE_DURATION" \
                "POST_ADAPT_DURATION:$POST_ADAPT_DURATION" \
                "HOT_MERCHANT_LIMIT:$HOT_MERCHANT_LIMIT" \
                "ADAPTATION_TIMEOUT:$ADAPTATION_TIMEOUT" \
                "THREADS:$THREADS" \
                "PROGRESS_INTERVAL:$PROGRESS_INTERVAL" \
                "T1_WEIGHT:$T1_WEIGHT" \
                "T2_WEIGHT:$T2_WEIGHT" \
                "T3_WEIGHT:$T3_WEIGHT" \
                "T4_WEIGHT:$T4_WEIGHT" \
                "T5_WEIGHT:$T5_WEIGHT" \
                "T6_WEIGHT:$T6_WEIGHT" \
                "T7_WEIGHT:$T7_WEIGHT" \
                "T8_WEIGHT:$T8_WEIGHT" \
                "T9_WEIGHT:$T9_WEIGHT" \
                "MIN_ITEMS_PER_ORDER:$MIN_ITEMS_PER_ORDER" \
                "MAX_ITEMS_PER_ORDER:$MAX_ITEMS_PER_ORDER"; do
                require_integer "${pair%%:*}" "${pair#*:}"
        done

        ((DURATION > 0)) || fail "DURATION must be > 0"
        ((THREADS > 0)) || fail "THREADS must be > 0"
        ((HOT_MERCHANT_LIMIT > 0)) || fail "HOT_MERCHANT_LIMIT must be > 0"
        ((BASELINE_DURATION > 0 && POST_ADAPT_DURATION > 0 && ADAPTATION_TIMEOUT > 0)) ||
                fail "BASELINE_DURATION, POST_ADAPT_DURATION, and ADAPTATION_TIMEOUT must be > 0"
        ((DURATION >= WARMUP_DURATION + BASELINE_DURATION + ADAPTATION_TIMEOUT + POST_ADAPT_DURATION)) ||
                fail "DURATION must cover warm-up, baseline, adaptation timeout, and post-adaptation windows"
        case "$SHARD_TRANSFER_MODE" in
                auto|block_writes|force_logical) ;;
                *) fail "SHARD_TRANSFER_MODE must be auto, block_writes, or force_logical" ;;
        esac

        ((MAX_ITEMS_PER_ORDER <= 5)) || fail "MAX_ITEMS_PER_ORDER must be <= 5 with static T1"
        ((MIN_ITEMS_PER_ORDER >= 1)) || fail "MIN_ITEMS_PER_ORDER must be >= 1"

        ((MAX_ITEMS_PER_ORDER >= MIN_ITEMS_PER_ORDER)) || fail "MAX_ITEMS_PER_ORDER must be >= MIN_ITEMS_PER_ORDER"
        ((T1_WEIGHT + T2_WEIGHT + T3_WEIGHT + T4_WEIGHT + T5_WEIGHT + T6_WEIGHT + T7_WEIGHT + T8_WEIGHT + T9_WEIGHT > 0)) ||
                fail "At least one transaction weight must be positive"

        for f in \
                T1_place_order.sql \
                T2_update_inventory.sql \
                T3_order_history.sql \
                T4_product_lookup.sql \
                T5_update_order_status.sql \
                T6_global_sales.sql \
                T7_inventory_transfer.sql \
                T8_update_customer.sql \
                T9_update_product.sql; do
                [[ -f "$TX_DIR/$f" ]] || fail "Missing $TX_DIR/$f"
        done

        IFS='|' read -r NUM_MERCHANTS NUM_CUSTOMERS NUM_PRODUCTS INITIAL_NUM_ORDERS <<EOF
$("$PSQL" -X -A -t -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "
SELECT
  COALESCE((SELECT MAX(merchant_id) FROM merchants),0),
  COALESCE((SELECT MAX(customer_id) FROM customers),0),
  COALESCE((SELECT MAX(product_id) FROM products),0),
  COALESCE((SELECT MAX(order_id) FROM orders),0);
")
EOF

        echo "Loaded data dimensions:"
        echo "  merchants = $NUM_MERCHANTS"
        echo "  customers = $NUM_CUSTOMERS"
        echo "  products  = $NUM_PRODUCTS"
        echo "  orders    = $INITIAL_NUM_ORDERS"

        ((NUM_MERCHANTS > 1)) || fail "Need at least 2 merchants"
        ((NUM_CUSTOMERS > 0)) || fail "No customers loaded"
        ((NUM_PRODUCTS > 0)) || fail "No products loaded"
        ((INITIAL_NUM_ORDERS > 0)) || fail "No orders loaded"

        HOT_MERCHANTS=$((NUM_MERCHANTS * HOT_MERCHANT_PERCENT / 100))
        ((HOT_MERCHANTS >= 1)) || HOT_MERCHANTS=1
        ((HOT_MERCHANTS < NUM_MERCHANTS)) || HOT_MERCHANTS=$((NUM_MERCHANTS - 1))

        reset_benchmark_sequences

        # arguments for pgbench
        common_defs=(
                -D DEBUG_MODE=0
                -D NUM_MERCHANTS="$NUM_MERCHANTS"
                -D NUM_CUSTOMERS="$NUM_CUSTOMERS"
                -D NUM_PRODUCTS="$NUM_PRODUCTS"
                -D INITIAL_NUM_ORDERS="$INITIAL_NUM_ORDERS"
                -D HOT_ORDER_PERCENT="$HOT_ORDER_PERCENT"
                -D HOT_MERCHANTS="$HOT_MERCHANTS"
                -D MIN_ITEMS_PER_ORDER="$MIN_ITEMS_PER_ORDER"
                -D MAX_ITEMS_PER_ORDER="$MAX_ITEMS_PER_ORDER"
                -D MIN_ORDER_QTY="$MIN_ORDER_QTY"
                -D MAX_ORDER_QTY="$MAX_ORDER_QTY"
                -D INVENTORY_CHANGE_MIN="$INVENTORY_CHANGE_MIN"
                -D INVENTORY_CHANGE_MAX="$INVENTORY_CHANGE_MAX"
                -D REPORT_DAYS="$REPORT_DAYS"
                -D T7_MIN_TRANSFER_QTY="$T7_MIN_TRANSFER_QTY"
                -D T7_MAX_TRANSFER_QTY="$T7_MAX_TRANSFER_QTY"
        )

        declare -a workload=()
        declare -A SCRIPT_NUMBER SCRIPT_NAME
        idx=0
        add_workload T1 T1_place_order.sql "$T1_WEIGHT" "Place Order"
        add_workload T2 T2_update_inventory.sql "$T2_WEIGHT" "Update Inventory"
        add_workload T3 T3_order_history.sql "$T3_WEIGHT" "Customer Order History"
        add_workload T4 T4_product_lookup.sql "$T4_WEIGHT" "Product Lookup"
        add_workload T5 T5_update_order_status.sql "$T5_WEIGHT" "Update Order Status"
        add_workload T6 T6_global_sales.sql "$T6_WEIGHT" "Global Sales"
        add_workload T7 T7_inventory_transfer.sql "$T7_WEIGHT" "Inventory Transfer"
        add_workload T8 T8_update_customer.sql "$T8_WEIGHT" "Update Customer"
        add_workload T9 T9_update_product.sql "$T9_WEIGHT" "Update Product"

        cat >"${BENCHMARK_CONFIG_FILE}" <<EOF
coordinator=$COORDINATOR
workers=${#WORKERS[@]}
scale=$SCALE


PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS}"
PG_WORK_MEM="${PG_WORK_MEM}"
PG_MAINTENANCE_WORK_MEM="${PG_MAINTENANCE_WORK_MEM}"
PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS}"
PG_ISOLATION_LEVEL="${PG_ISOLATION_LEVEL}"
PG_MAX_WAL_SIZE="${PG_MAX_WAL_SIZE}"
PG_MIN_WAL_SIZE="${PG_MIN_WAL_SIZE}"
PG_CHECKPOINT_TIMEOUT="${PG_CHECKPOINT_TIMEOUT}"
PG_CHECKPOINT_COMPLETION_TARGET="${PG_CHECKPOINT_COMPLETION_TARGET}"
output_plugin_libraries='pgoutput, test_decoding, citus'
wal_level=logical
max_wal_senders=32
max_replication_slots=32
CITUS_ENABLE_REPARTITION_JOINS="${CITUS_ENABLE_REPARTITION_JOINS}"
CITUS_MAX_SHARED_POOL_SIZE="${CITUS_MAX_SHARED_POOL_SIZE}"
CITUS_MAX_ADAPTIVE_EXECUTOR_POOL_SIZE="${CITUS_MAX_ADAPTIVE_EXECUTOR_POOL_SIZE}"
CITUS_LOCAL_SHARED_POOL_SIZE="${CITUS_LOCAL_SHARED_POOL_SIZE}"

DATA_SEED="${DATA_SEED}"
HOT_MERCHANT_PERCENT="${HOT_MERCHANT_PERCENT}"
HOT_ORDER_PERCENT="${HOT_ORDER_PERCENT}"


clients=$CLIENT_COUNTS
PGHOST=$PGHOST
PGPORT=$PGPORT
PGDATABASE=$PGDATABASE
PGUSER=$PGUSER
DURATION=$DURATION
WARMUP_DURATION=$WARMUP_DURATION
BASELINE_DURATION=$BASELINE_DURATION
POST_ADAPT_DURATION=$POST_ADAPT_DURATION
HOT_MERCHANT_LIMIT=$HOT_MERCHANT_LIMIT
ADAPTATION_TIMEOUT=$ADAPTATION_TIMEOUT
SHARD_TRANSFER_MODE=$SHARD_TRANSFER_MODE
CLIENT_COUNTS=$CLIENT_COUNTS
THREADS=$THREADS
PGBENCH_QUERY_MODE=$PGBENCH_QUERY_MODE
PROGRESS_INTERVAL=$PROGRESS_INTERVAL
PGBENCH_SEED=$PGBENCH_SEED
LOG_SAMPLE_RATE=$LOG_SAMPLE_RATE
PGBENCH_MAX_TRIES=$PGBENCH_MAX_TRIES
PGBENCH_FAILURES_DETAILED=$PGBENCH_FAILURES_DETAILED
RESET_AFTER_WARMUP=$RESET_AFTER_WARMUP
RESTART_SERVERS_BETWEEN_CLIENT_COUNTS=$RESTART_SERVERS_BETWEEN_CLIENT_COUNTS
SERVER_RESTART_TIMEOUT=$SERVER_RESTART_TIMEOUT
T1_WEIGHT=$T1_WEIGHT
T2_WEIGHT=$T2_WEIGHT
T3_WEIGHT=$T3_WEIGHT
T4_WEIGHT=$T4_WEIGHT
T5_WEIGHT=$T5_WEIGHT
T6_WEIGHT=$T6_WEIGHT
T7_WEIGHT=$T7_WEIGHT
T8_WEIGHT=$T8_WEIGHT
T9_WEIGHT=$T9_WEIGHT
NUM_MERCHANTS=$NUM_MERCHANTS
NUM_CUSTOMERS=$NUM_CUSTOMERS
NUM_PRODUCTS=$NUM_PRODUCTS
INITIAL_NUM_ORDERS=$INITIAL_NUM_ORDERS
HOT_MERCHANTS=$HOT_MERCHANTS
MIN_ITEMS_PER_ORDER=$MIN_ITEMS_PER_ORDER
MAX_ITEMS_PER_ORDER=$MAX_ITEMS_PER_ORDER
MIN_ORDER_QTY=$MIN_ORDER_QTY
MAX_ORDER_QTY=$MAX_ORDER_QTY
INVENTORY_CHANGE_MIN="${INVENTORY_CHANGE_MIN}"
INVENTORY_CHANGE_MAX="${INVENTORY_CHANGE_MAX}"
REPORT_DAYS="${REPORT_DAYS}"
T7_MIN_TRANSFER_QTY="${T7_MIN_TRANSFER_QTY}"
T7_MAX_TRANSFER_QTY="${T7_MAX_TRANSFER_QTY}"
EOF

        echo "clients,successful_transactions,failed_log_records,overall_tps,overall_avg_latency_ms,overall_median_latency_ms,overall_p95_latency_ms,overall_p99_latency_ms,retried_transactions,total_retries,serialization_failures,deadlock_failures,pgbench_exit_code" \
                >"$SUMMARY_FILE"

        echo "clients,transaction,name,successful_transactions,tps,avg_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms" \
                >"$TX_METRICS_FILE"

        echo 'timestamp_epoch,clients,event,phase,merchant_id,baseline_order_count,shard_id,source_node,target_node,duration_ms,tps,avg_latency_ms,p95_latency_ms,p99_latency_ms,failures,status,message' \
                >"$WORKLOAD_LOG_FILE"

        first_client_run=1

        for clients in $CLIENT_COUNTS; do
                require_integer CLIENTS "$clients"
                ((clients >= 1)) || fail "CLIENT_COUNTS values must be >= 1"

                # Restart server processes between client-count runs, then recreate the
                # schema and data so no isolated shard placement leaks into the next run.
                if ((first_client_run == 0 && RESTART_SERVERS_BETWEEN_CLIENT_COUNTS)); then
                        restart_postgres_servers
                fi
                if ((first_client_run == 0)); then
                        info "Recreating distributed schema and data before client-count c${clients}"
                        create_schema >/dev/null 2>&1
                        generate_data >/dev/null 2>&1
                        reset_benchmark_sequences
                        check_server_steps || fail "Cluster health check failed after schema recreation for c${clients}"
                fi
                first_client_run=0

                prefix="$LOG_DIR/pgbench-c${clients}"
                rm -f "${prefix}".*
                pgbench_rc=0

                CURRENT_CLIENTS="$clients"
                workload_log "workload_start" "warmup" "" "" "" "" "" "" "" "" "" "" "" "started" ""
                workload_log "phase_start" "warmup" "" "" "" "" "" "" "" "" "" "" "" "started" "duration=${WARMUP_DURATION}s"
                if ((WARMUP_DURATION > 0)); then
                        warmup_rc=0
                        run_pgbench "$clients" "$WARMUP_DURATION" "$RUN_DIR/warmup-c${clients}.txt" "Warmup" "$LOG_DIR/warmup-c${clients}" 0 || warmup_rc=$?
                        workload_log "phase_end" "warmup" "" "" "" "" "" "$((WARMUP_DURATION*1000))" "" "" "" "" "" "$([[ $warmup_rc == 0 ]] && echo success || echo failed)" "pgbench_exit_code=$warmup_rc"
                        check_server_steps || fail "PostgreSQL/Citus cluster became unhealthy during warmup c${clients}"
                fi
                if ((RESET_AFTER_WARMUP)); then
                        reset_benchmark_database "after warmup for c${clients}"
                fi

                baseline_order_snapshot="$(psqlx -A -t -c "SELECT COALESCE(MAX(order_id), 0) FROM orders;")"
                run_start_epoch="$(date +%s)"
                baseline_start_epoch="$run_start_epoch"
                baseline_end_epoch=$((baseline_start_epoch + BASELINE_DURATION))
                post_start_epoch=""
                workload_log "phase_start" "baseline" "" "$baseline_order_snapshot" "" "" "" "" "" "" "" "" "" "started" "duration=${BASELINE_DURATION}s"
                start_pgbench_background "$clients" "$DURATION" "$RUN_DIR/result-c${clients}.txt" "$prefix"
                sleep "$BASELINE_DURATION"
                workload_log "phase_end" "baseline" "" "" "" "" "" "$((BASELINE_DURATION*1000))" "" "" "" "" "" "complete" ""
                run_dynamic_adaptation "$clients" "$baseline_order_snapshot" "$baseline_start_epoch" "$baseline_end_epoch" || true
                post_start_epoch="$(date +%s)"
                workload_log "phase_start" "post_adaptation" "" "" "" "" "" "" "" "" "" "" "" "started" "minimum_duration=${POST_ADAPT_DURATION}s"
                sleep "$POST_ADAPT_DURATION"
                workload_log "phase_end" "post_adaptation" "" "" "" "" "" "$((POST_ADAPT_DURATION*1000))" "" "" "" "" "" "complete" ""
                finish_pgbench_background "$RUN_DIR/result-c${clients}.txt" || pgbench_rc=$?
                run_end_epoch="$(date +%s)"

                analyze_run "$clients" "$prefix" "$RUN_DIR/result-c${clients}.txt" "$pgbench_rc"
                combined="$LOG_DIR/transactions-c${clients}.log"
                log_phase_metrics "$combined" "before" "$baseline_start_epoch" "$baseline_end_epoch"
                adaptation_end_epoch="$post_start_epoch"
                ((adaptation_end_epoch < baseline_end_epoch)) && adaptation_end_epoch="$baseline_end_epoch"
                log_phase_metrics "$combined" "migration" "$baseline_end_epoch" "$adaptation_end_epoch"
                log_phase_metrics "$combined" "after" "$post_start_epoch" "$run_end_epoch"
                workload_log "workload_end" "complete" "" "" "" "" "" "" "" "" "" "" "" "$([[ $pgbench_rc == 0 ]] && echo success || echo failed)" "pgbench_exit_code=$pgbench_rc"

                if ! check_server_steps; then
                        fail "PostgreSQL/Citus cluster became unhealthy during c${clients}"
                fi

                if ((pgbench_rc != 0)); then
                        info "Measured c${clients} completed with pgbench exit code $pgbench_rc; results retained and benchmark continues"
                fi
        done

        cat >"${README_METRICS_FILE}" <<EOF
Benchmark metrics
=================

summary.csv
  One row per client count. Includes:
  - overall average latency (ms)
  - overall median / p50 latency (ms)
  - overall p95 and p99 latency (ms)
  - successful transaction count
  - overall TPS
  - number of transactions that had to retried at least once
  - total number of transaction retries
  - number of serialization failures
  - number of deadlock failures
  - pgbench exit code

transaction_metrics.csv
  One row per client count and transaction type (T1-T9). Includes:
  - average latency (ms)
  - p50 latency (ms)
  - p95 latency (ms)
  - p99 latency (ms)
  - successful transaction count
  - per-transaction TPS

logs/
  Raw pgbench per-transaction logs and one combined transaction log per client count.

metrics-cN/
  Extracted latency samples in microseconds for the overall workload and each
  transaction type.

workload_logs.csv
  Dynamic phase boundaries, baseline hot-merchant rankings, isolation and move
  events, placement verification, and before/migration/after phase metrics.

Notes:
  Latency metrics are computed from pgbench's per-transaction log records.
  LOG_SAMPLE_RATE=$LOG_SAMPLE_RATE. For complete latency distributions, leave
  LOG_SAMPLE_RATE=1.0.
EOF

        echo "Benchmark results directory: $RUN_DIR"
        echo "Overall metrics: $SUMMARY_FILE"
        echo "Per-transaction metrics: $TX_METRICS_FILE"
}

#####################  perform benchmarking
run_benchmark &>"${BENCHMARK_LOG_FILE}"
info "Experiment complete: $JOB_RESULT_DIR"

