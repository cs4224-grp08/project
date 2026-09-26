# Baseline findings: workload B commit aborts and throughput

Working notes for the report (Section 4, Task 3) and for planning Tasks 2 and 4.
This file is not part of the submission folder layout (brief §11.1). Leave
`docs/` out when building `citus_project_team_08/`.

Most of this investigation was done with AI assistance (OpenCode with Claude).
Record that in the AI-tool disclosure (brief §11.2 cover page, §11.3).

## Summary

- In the baseline design, workload B loses pgbench clients mid-run at 4 or
  more clients. Every abort seen (43 in two jobs) is one Citus error:
  `could not commit transaction for shard N on at least one active node`.
- Cause: when a transaction's writes commit on a single worker without
  two-phase commit (2PC), Citus 14.1 re-raises a worker serialization failure
  as SQLSTATE XX000 instead of 40001. pgbench only retries 40001/40P01, so the
  client aborts for the rest of the run.
- Serializable conflicts themselves are expected under this workload.
  Conflicts that reach the coordinator as 40001 (for example, cross-worker
  transfers that use 2PC) are retried normally.
- Working assumption (pending instructor confirmation): these aborts are
  acceptable. Report the aborted-client count next to throughput.
- More important for Tasks 2 and 4: baseline B throughput is flat at about
  3.3 TPS from 1 to 64 clients, and T3 (Customer Order History) takes about
  4.5 s even with one client. Throughput is limited by expensive reads, not
  only by conflicts.

## Baseline B run: job 853208

Settings: scale 1, 1 coordinator + 4 workers (xcnc0-4), serializable,
`--max-tries=3`, 60 s warmup, 600 s measured run per client count. It used
the provided `expt_b0` scripts with TEAM_ID=8.

| Clients | TPS | p50 ms | p95 ms | p99 ms | Serialization failures | pgbench exit | Aborted clients (warmup / measured) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 3.450 | 27 | 535 | 4,626 | 0 | 0 | 0 / 0 |
| 4 | 3.230 | 106 | 6,853 | 17,594 | 8 | 2 | 0 / 2 |
| 8 | 3.462 | 300 | 19,203 | 43,952 | 84 | 0 | 0 / 0 |
| 16 | 3.757 | 185 | 15,584 | 48,128 | 93 | 2 | 1 / 9 |
| 32 | 3.325 | 346 | 65,741 | 116,359 | 348 | 2 | 1 / 12 |
| 64 | 2.693 | 323 | 313,882 | 722,525 | 337 | 2 | 2 / 8 |

The c8 run shows that serialization failures alone do not abort clients: 84
transactions failed after their retries, but every client finished.

Per-transaction p50 latency (ms):

| Clients | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 22 | 3 | 4,508 | 522 | 3 | 323 | 96 | 3 | 3 |
| 32 | 481 | 101 | 77,102 | 21,656 | 103 | 3,915 | 2,631 | 107 | 61 |

Evidence: `~/citus_project_archives/citus_project_b_20260916.tar.gz` on the
cluster (SHA-256 `6b37b76881058db13099ca56a1d50c8b478356f3e9316435b9ce30fdfe693dbb`).
It contains `expt_b0/slurm-results/job-853208/` and `expt_b0/citus-853208.{out,err}`.

## Root cause of the aborts

The logs and the source trace (Citus 14.1.0, PostgreSQL 18.6) show the same
mechanism:

1. A worker reports a serialization failure on `COMMIT`, e.g.
   xcnc3-postgresql.log:160, 2026-09-16 22:48:26.089.
2. `FinishRemoteTransactionCommit` handles the failed commit with
   `raiseErrors=false`. The worker error becomes a WARNING and the connection
   is marked failed (`remote_transaction.c:572`, `:966`).
3. `ErrorIfPostCommitFailedShardPlacements` then raises a new ERROR with no
   errcode, which defaults to XX000 (`placement_connection.c:994`,
   PostgreSQL `elog.c:450`).
4. pgbench's `canRetryError` accepts only 40001 and 40P01
   (`pgbench.c:3237`, `:3376`), so the client aborts. Raising `--max-tries`
   does not help.

Aborts correlated in the baseline logs:

| Transaction | pgbench record (job 853208) | Coordinator error | Worker evidence |
| --- | --- | --- | --- |
| T7 | result-c4.txt:45, client 0, shard 102090 | xcnc0-postgresql.log:1186 | xcnc3-postgresql.log:160 |
| T2 | result-c16.txt:10, client 8, shard 102102 | xcnc0-postgresql.log:10633 | xcnc3-postgresql.log:1088 |
| T1 | result-c16.txt:43, client 0, shard 102110 | xcnc0-postgresql.log:12576 | xcnc3-postgresql.log:1241 |

## Controlled reproduction: jobs 854086 and 854116

A minimal inventory table (128 rows, 32 shards, serializable) with two
overlapping sessions. A transfer reads source and destination, then debits and
credits one unit. A competing transaction reads the source and updates a
distinct witness row, committing first, which creates a controlled
serializable conflict. Each case was repeated 3 times, with and without an
explicit witness read.

| Row placement | Original two-UPDATE transfer | Single multi-row UPDATE transfer |
| --- | --- | --- |
| Same shard | XX000 (6/6) | XX000 (6/6) |
| Same worker, different shards | XX000 (6/6) | 40001 (6/6) |
| Different workers | 40001 (6/6) | 40001 (6/6) |

- Same-worker transfers used plain `COMMIT`. Cross-worker transfers used
  `PREPARE TRANSACTION` (2PC), and their conflict surfaced as a retryable 40001.
- In all 48 conflict cases the failed transfer fully rolled back. Full-table
  comparisons found no partial effects, and no prepared transactions were left
  over. Fifteen boundary checks (success, insufficient stock, missing rows,
  identical IDs) passed for the rewrite.
- These tests show the error classification, not general atomicity. With plain
  `COMMIT` across several connections, a partial commit is not ruled out.

## Implications for the optimization tasks

The brief (§5) allows changing the schema, data distribution and indexes,
tuning PostgreSQL/Citus parameters, and re-implementing transactions. Patching
Citus is not on that list, so an engine fix is out of scope. Candidate
optimizations, each to be benchmarked as its own `expt_aN`/`expt_bN`:

1. **Co-locate by `merchant_id`.** The brief says most transactions concern a
   single merchant, but the baseline shards every table on its own key
   (`orders.order_id`, `order_items.order_item_id`,
   `inventory.inventory_id`, `products.product_id`, `customers.customer_id`).
   Hypothesis to confirm with `EXPLAIN`:
   - T3 joins `orders` and `order_items` on `order_id`, but `order_items` is
     sharded on `order_item_id`. The join is not co-located and depends on
     `citus.enable_repartition_joins=on`.
   - There is no index on `orders.customer_id`.
   - This would explain T3's 4.5 s latency at one client and the flat
     throughput.
2. **Indexes for the read paths** of T3 (orders by merchant/customer and
   `created_at`) and T4 (products joined to inventory).
3. **Rewrite T7 as a single multi-row UPDATE** (T7 is 30% of workload B).
   Job 854116 shows it turns same-worker, different-shard conflicts into
   retryable 40001. It does not help same-shard transfers or T2. Measure its
   effect on throughput and on aborted clients.
4. **Reference tables or other distribution choices** for small or rarely
   updated tables (e.g. `merchants`), then parameter tuning.

Report throughput alongside p50/p95/p99 latency (brief §9), serialization
failures and aborted clients. When clients abort, the measured TPS comes from
fewer clients than configured.

## Explored and not carried forward

These are kept on branch `fix/benchmark-lifecycle-checks` (PR #1, closed
without merging; latest commit `1afd044`) and in the worktree
`~/citus_project_worktrees/baseline-b-investigation` on the cluster:

- `expt_b0/commit_diagnostic.py` and its `COMMIT_DIAGNOSTIC=1` mode (the
  reproduction harness); summary JSONs are under
  `expt_b0/diagnostic-results/`. To cite the reproduction in the report,
  re-create it as a separate experiment folder (e.g. `expt_b1`).
- Server lifecycle safeguards (port lock, data-directory identity check,
  verified shutdown). They added a top-level `lifecycle/` directory and made
  the baseline scripts differ from the provided ones.
- A run-validity gate inside `run.sh`, which classified aborts per client
  count and added columns to `summary.csv`. It was replaced by
  `tools/count_aborts.py`, which reads the pgbench outputs after a run.
- `engine/serializable-prepare.patch`, a proposal to force 2PC under
  serializable isolation. It was never built successfully and is out of scope.

Related Slurm jobs:

| Job | What it was |
| --- | --- |
| 853208 | Full baseline B run |
| 854086 | Controlled reproduction |
| 854116 | T7 rewrite comparison |
| 854178, 854191, 854210 | Engine patch builds, all failed |
| 854204 | Diagnostic against an unpatched rebuild |
| 854254 | Lifecycle-safeguard smoke test |
| 882608 | Validity-gate check (scale 0.1, c32 lost 4 clients in warmup and 4 in the measured run) |
