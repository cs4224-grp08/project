# CS4224/CS5424 Citus Project: Team 08

Each `expt_wN` folder is one experiment for workload `w` (`a` or `b`). It holds
`run.sh`, the nine transactions in `transactions/`, and, after a run, the
outputs `slurm-results/job-<job>/` and `citus-<job>.out` / `citus-<job>.err`.

## Experiments

Optimizations are applied progressively: V_N = V_{N-1} + O_N. Unless stated,
`run.sh` is identical to the baseline's and only `transactions/` changes.
To see a change directly: `diff -rq expt_a2 expt_a3` (files changed by one
step) or `diff -u expt_b1/transactions/T7_inventory_transfer.sql
expt_b2/transactions/T7_inventory_transfer.sql` (the change itself).

| Folder | Task | Design | Transactions changed (vs baseline) | Reported job |
| --- | --- | --- | --- | --- |
| `expt_a0` | Task 1 | Baseline design, workload A | none (baseline) | 882950 |
| `expt_a1` | Task 2 | V0 + O1 | T3 | 883680 |
| `expt_a2` | Task 2 | V1 + O2 | T3, T4 | 883684 |
| `expt_a3` | Task 2 | V2 + O4 | T1, T3, T4 | 883773 |
| `expt_a4` | Task 2 | V3 + O5 | T1, T2, T3, T4, T5, T6, T8, T9 | 883775 |
| `expt_a5` | Task 2 | V4 + O3 | T1, T2, T3, T4, T5, T6, T7, T8, T9 | 884051 |
| `expt_a99` | Task 1 (extra) | Serializable baseline, workload A | T1-T9 (locks; T5 merchant lookup; T6 snapshot barrier) | 990809 |
| `expt_a100` | Task 1 (extra) | `expt_a99` with per-customer and per-product locks, `G` last | T1-T9 | not run |
| `expt_a101` | Task 2 | S0 + O1 | T3 (vs `expt_a99`) | 991556 |
| `expt_a111` | Task 2 | S1 + O2 | T3, T4 (vs `expt_a99`) | 991557 |
| `expt_a121` | Task 2 | S2 + O4 | T1, T3, T4 (vs `expt_a99`) | 991600 |
| `expt_a131` | Task 2 | S3 + O3 | T1, T3, T4, T7 (vs `expt_a99`) | 991601 |
| `expt_a134` | - | S3 + O8 | T1, T3, T4, T5, T7 | 1024985 | 
| `expt_b0` | Task 3 | Baseline design, workload B | none (baseline) | 882953 |
| `expt_b1` | Task 4 | V0 + O1 | T3 | 883683 |
| `expt_b2` | Task 4 | V1 + O3 | T3, T7 | 883685 |
| `expt_b3` | Task 4 | V2 + O2 | T3, T4, T7 | 883774 |
| `expt_b4` | Task 4 | V3 + O5 | T2, T3, T4, T5, T6, T7, T8, T9 | 883776 |
| `expt_b5` | Task 4 | V4 + O4 | T1, T2, T3, T4, T5, T6, T7, T8, T9 | 884052 |
| `expt_b6` | Task 4 | V1 + O3a (alternative to `expt_b2`) | T3, T7 | 884053 |
| `expt_b99` | Task 3 (extra) | Serializable baseline, workload B | T1-T9 (locks; T5 merchant lookup; T6 snapshot barrier) | 990813 |
| `expt_b100` | Task 3 (extra) | `expt_b99` with per-customer and per-product locks, `G` last | T1-T9 | not run |
| `expt_b101` | Task 4 | S0 + O1 | T3 (vs `expt_b99`) | 991604 |
| `expt_b111` | Task 4 | S1 + O3 | T3, T7 (vs `expt_b99`) | 991605 |
| `expt_b121` | Task 4 | S2 + O2 | T3, T4, T7 (vs `expt_b99`) | 991608 |
| `expt_b131` | Task 4 | S3 + O4 | T1, T3, T4, T7 (vs `expt_b99`) | 991609 |
| `expt_b124` | - | S3 + O8 | T1, T3, T4, T5, T7 | 1025276 | 

Query-rewrite optimizations:

- O1 (T3): fetch the customer's 20 most recent orders first, then join only
  their items, filtered by merchant. Avoids the repartition join.
- O2 (T4): look up inventory by its distribution key (`inventory_id =
  product_id`), so both lookups touch one shard.
- O3 (T7): one UPDATE debits and credits both products by their distribution
  key, touching only their two shards.
- O3a (T7): one lookup for both products instead of four; debit and credit
  unchanged.
- O4 (T1): check, reserve and insert all items with one statement each.
- O5: single-statement transactions (T2-T6, T8, T9) run in autocommit.
- O8: Combine query rewrites with horizontal partitioning

`expt_a0` and `expt_b0` are the provided scripts with `TEAM_ID=8` and the
notification email set; they differ only in `WORKLOAD`.

## Serializable baseline

Citus enforces SERIALIZABLE only within each worker: it has no distributed
snapshot and doesn't detect conflicts that span nodes. So the provided baseline
isn't serializable across the cluster.

`expt_a99` and `expt_b99` are the provided baseline
(same schema and distribution; the SQL gains only the locks, T5's merchant
lookup and T6's snapshot barrier) made serializable with strict two-phase
locking on the coordinator. Build optimizations on these folders so every
design we report stays serializable. The full argument is in the
Serializability tab of the team plan doc.

### How it works

- Locks are PostgreSQL advisory locks taken on the coordinator, with two keys:
  - `(2, m)`: merchant `m`. Covers every row of merchant `m` in every table,
    including ranges over them (e.g. T3's order history).
  - `(1, 0)`: `G`, the orders that T6 reads across all merchants.
- Each transaction takes all its locks right after `BEGIN`, one statement per
  lock, before touching any table, and holds them until `COMMIT`
  (`pg_advisory_xact_lock`). T6 is the one exception (snapshot barrier below).
- A lock is shared (`pg_advisory_xact_lock_shared`) if the transaction only
  reads that merchant's rows, and exclusive if it writes any of them.
- Locks are taken in a fixed order: `G` first, then merchants ascending (`least`,
  then `greatest`, for two merchants). That rules out deadlocks. Each lock has
  its own statement because PostgreSQL doesn't define the order in which it
  evaluates the expressions within one statement.
- Citus releases the coordinator's locks only after every worker has committed,
  so the next transaction to hold a lock sees all committed changes.
- Data statements run at read committed (`PG_ISOLATION_LEVEL` in `run.sh`), so
  each statement reads the latest committed data after the locks are held.
  Without serializable checks there are no serialization failures and no XX000
  client aborts; conflicting transactions wait instead.

| Transaction | Locks |
| --- | --- |
| T1 | `G` shared, `(2, m)` exclusive |
| T2, T8, T9 | `(2, m)` exclusive |
| T3, T4 | `(2, m)` shared |
| T5 | `(2, m)` exclusive; `m` is first read from `orders` (`merchant_id` never changes) |
| T6 | `G` exclusive, only while opening its snapshots (snapshot barrier) |
| T7 | `(2, m1)` and `(2, m2)` exclusive, ascending (one lock if both products have the same merchant); a product's merchant is `1 + (product_id - 1) % NUM_MERCHANTS`, as T9 uses |

**T6 snapshot barrier.** T6 reads every merchant's recent orders, and only T1
writes what it reads. (T5 changes `order_status`, which T6 doesn't read.) T6
runs at REPEATABLE READ over one connection per worker. It holds `G` only while
one statement opens a snapshot on every worker, then releases `G` and runs its
query on those snapshots. So T1 waits only for the barrier, not for T6's whole
query.
The barrier can't leave `G` held: T6 is read-only at REPEATABLE READ and holds
no other lock, so nothing between taking and releasing `G` can fail with an
error pgbench retries. Any other failure aborts the client, and closing its
connection releases `G`.

### Serializable optimizations

`expt_a101`, `a111`, `a121`, `a131` and `expt_b101`, `b111`, `b121`, `b131`
apply our query rewrites on top of the serializable baseline, one per step (S0
is `expt_a99`/`expt_b99`). Each rewritten transaction keeps the baseline's
locks, because no rewrite changes which merchants' rows a transaction touches.

- Kept: O1 (T3), O2 (T4), O3 (T7) and O4 (T1). With locks, O3 no longer avoids
  serialization conflicts (there are none), but it still shortens T7 and so the
  time T7 holds its two merchant locks.
- Dropped: O5 (autocommit). A lock and its statement must run in one
  transaction.
- Dropped: O3a. It only showed where serialization conflicts came from.
- Not added: stored procedures. pgbench runs on the coordinator node, so they
  would save only local round trips. A coordinator-side procedure still opens a
  transaction on each worker. Running the procedure on the worker (Citus
  function delegation) would move the locks off the coordinator, breaking the
  protocol.

### Combining query rewrites with merchant partitioning (O8)

`expt_a134` (A) and `expt_b124` (B) combine the existing transaction
rewrites with static partitioning and colocation of all five transactional
tables by `merchant_id`.

- Retain T1's batched product checks, stock reservation and item insertion.
- T3: join on both merchant and order IDs; add
  `orders(merchant_id, customer_id, created_at DESC)` for recent-order lookup.
- T4: replace the materialized inventory CTE with a direct colocated join.
- T5: resolve the merchant through `order_routing`, distributed by `order_id`,
  then update using both IDs to avoid lookup and update fan-out.
- T7: add merchant predicates to prune the batched update to the relevant shards.

The existing advisory locks and T6 snapshot barrier are retained.
`order_routing` is populated and reset with the initial orders; T5 skips IDs
missing from this mapping. Both workloads use identical transaction SQL
with their respective workload weights.

### Rules when building on these folders

1. Every transaction except T6, read-only ones included, keeps its lock
   statements, one per lock, as the first statements after `BEGIN`. If a rewrite changes which
   merchants' rows a transaction reads or writes, update its locks by the rules
   above.
   - T5 may read its order's `merchant_id` before `BEGIN`, because
     `merchant_id` never changes.
   - T6 keeps its barrier in this order: `BEGIN ISOLATION LEVEL REPEATABLE
     READ`, the two `SET LOCAL` settings (one connection per worker),
     `pg_advisory_unlock_all()`, `pg_advisory_lock(1, 0)`, the statement that
     opens a snapshot on every worker, then `pg_advisory_unlock(1, 0)`.
2. No autocommit, except T5's merchant lookup: a transaction's lock and its
   statements must run in one transaction (`BEGIN … COMMIT`, or a stored
   procedure that does both).
3. Never change a row's `merchant_id`. Every row of a new table must belong to
   one merchant, unless nothing writes the table after loading.
4. Keep `PG_ISOLATION_LEVEL=read committed` in `run.sh`.
5. If `orders` moves (e.g. a new distribution key), T6's barrier statement must
   still touch every worker that holds `orders`.
6. A run should end with zero serialization failures and zero aborted clients
   (`scripts/compare-runs.py` shows both).

## Developer Workflow

Develop and test on the Local Cluster; benchmark on the Remote Cluster.

| | Before | After |
| --- | --- | --- |
| Testing a change | Hours on the Remote Cluster | Minutes on the Local Cluster |
| Finding bugs | After a Remote Cluster run | Before a Remote Cluster run |
| Workspace | One shared home directory | Each developer's own laptop |
| Commit author | `cs4224-service` | Each developer |
| Results | Not associated with git commit | Associated with git commit |

### Overview

1. Copy the experiment you build on to your next free `expt_wN` (see
   [Experiment numbers](#experiment-numbers)), and add it to the
   [Experiments](#experiments) table. Keep `RESULT_ROOT` at its default.
2. Test each change on the [Local Cluster](#local-cluster) until it runs.
3. Open a pull request; the [GitHub Cluster](#github-cluster) runs each experiment.
4. Once each experiment passes, benchmark on the [Remote Cluster](#remote-cluster).
5. [Compare runs](#comparing-runs) for the report.
6. Copy each experiment's reported job into `citus_project_team_08/` for the submission.

### Experiment numbers

From 101, numbers are assigned round-robin:

| Developer | Numbers |
| --- | --- |
| Don | 101, 111, 121, … |
| Kotaro | 102, 112, 122, … |
| Chris | 103, 113, 123, … |
| Tim | 104, 114, 124, … |

### Setup

1. Install `bash`, `git`, `rsync`, `python3` and Docker.
2. In `~/.ssh/config`, add `cs5424` to the `Host` line you use for the SoC cluster as `cs08`,
   e.g. `Host soc cs5424`.

### Local Cluster

The SoC compute cluster, in Docker. Useful for testing changes.

Usage:

```
scripts/cluster/local.sh up [nodes]
scripts/cluster/local.sh run <expt> [VAR=value ...]
scripts/cluster/local.sh down
```

Output:

```
Pushing <expt> to cs5424-local-xlogin:citus_project/<expt>
Submitted <expt> as job <job>
<time> job <job>: RUNNING
Job <job> is no longer queued
Pulling <expt> results from cs5424-local-xlogin:citus_project/<expt>
==> citus-<job>.out <==
…
==> slurm-results/job-<job>/benchmark.log <==
…
```

Results are in `<expt>/slurm-results/job-<job>/`.

After changing the image or `install_citus_slurm.sh`, run `scripts/cluster/local.sh build`.

### GitHub Cluster

The Local Cluster, in GitHub Actions, for each experiment in each pull request. Useful for
catching bugs before benchmarking.

Usage:

```
scripts/smoke-test-experiment.sh <expt>
```

Output:

```
==> Starting a Local Cluster with <nodes> nodes
==> Pushing <expt>
==> Running <expt>
==> Checking job <job>
    clients,successful_transactions,failed_log_records,overall_tps,…
    <clients>,<transactions>,<failed>,<tps>,…
PASS <expt>
```

### Remote Cluster

The SoC compute cluster. Useful for benchmarking.

Usage:

```
scripts/cluster/remote.sh run <expt> [VAR=value ...]
scripts/cluster/remote.sh status
scripts/cluster/remote.sh tail <expt> [job]
```

Output:

```
Pushing <expt> to cs5424:runs/<git branch>/<expt>
Submitted <expt> as job <job>
<time> job <job>: PENDING
<time> job <job>: RUNNING
<job>  COMPLETED  0:0  <elapsed>
Job <job> is no longer queued
Pulling <expt> results from cs5424:runs/<git branch>/<expt>
==> citus-<job>.out <==
…
==> slurm-results/job-<job>/benchmark.log <==
…
```

Results are in `<expt>/slurm-results/job-<job>/`.

### Comparing Runs

Side-by-side tables of finished jobs. Useful for comparing benchmarks.

Usage:

```
scripts/compare-runs.py <expt>[/job-<job>] ...
```

Output:

```
overall_tps [pgbench tps]
clients   <expt>:<job>    <expt>:<job>
<clients> <tps> [<tps>]   <tps> [<tps>]
…
```
