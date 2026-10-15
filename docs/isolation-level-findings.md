# Isolation level: serializable vs read committed

Working notes for the report. Not part of the submission folder layout (brief
§11.1). Most of this analysis was done with AI assistance (OpenCode with
Claude); record that in the AI-tool disclosure (§11.3).

## Summary

- The provided `run.sh` sets `default_transaction_isolation='serializable'`.
  Citus does not provide serializable execution across nodes: each worker only
  detects conflicts among its own transactions and there is no shared snapshot.
  Our professor raised this too. So the baseline's "serializable" is per worker.
- Running the same experiments at **read committed** removed every
  serialization failure and every aborted client (0 across all 13 jobs).
- **Throughput did not improve.** Baselines are unchanged (T3's ~4.5 s join
  dominates) and the final designs are within about ±15% of serializable, which
  is within the node-to-node variation on the shared cluster.
- Checking the workload transaction by transaction, none of the anomalies that
  read committed allows can violate a business invariant, and an invariant
  checker found no violation at either level.
- O3's large gain under serializable came from removing read conflicts, so its
  value depends on the isolation level (see Results).

## Why the baseline's serializable setting is weaker than it looks
- Each worker runs PostgreSQL SSI on its own transactions. A transaction that
  spans workers is not checked across them, so write skew and read skew across
  workers are possible at every level.
- Citus gives no common snapshot, even between shards on one worker that are
  read over different connections.
- The XX000 client aborts in the baseline come from per-worker serialization
  conflicts reported as non-retryable (see `baseline-b-findings.md`).

## Anomaly analysis per transaction

Notation: `r1(x)`, `w1(x)`, `c1`; x is a row. A client-side read-modify-write
(`SELECT`, compute, `UPDATE ... SET q = <value>`) is the lost-update schedule
`r1(x) r2(x) w1(x) c1 w2(x) c2` (not serializable). `SET quantity = quantity + x`
reads and writes in one statement under the row lock, so it is one indivisible
`rw(x)`: the pattern `r1[x] ... w2[x] ... w1[x]` cannot occur. A blocked UPDATE
at read committed re-reads the newest row version and re-checks its `WHERE`.

| Anomaly | Possible at read committed? | In our workload |
| --- | --- | --- |
| Lost update (P4) | Yes, for read-then-write | No. Stock changes are single-statement relative updates (T1 reservation, T2, T7, T9). T5 and T8 are blind writes (last writer wins, nothing derived from a read). |
| Non-repeatable read (P2) | Yes | No. Baseline T7 reads inventory ids twice, but ids never change. |
| Phantom (P3) | Yes | No. T3, T4 and T6 are single statements; no range is read twice in a transaction. |
| Read skew (A5A) | Yes | Only across shards/workers, which Citus does not protect at any level. T3, T4 and T6 can see a half-applied cross-worker commit. No stored data is affected. |
| Write skew (A5B) | Yes | No case: it needs each transaction to read what the other writes plus a constraint over the combined rows. T1 reads prices and customers it never writes; T7 writes both rows in one statement. |

- **T6:** a phantom (an order committed while it runs is not counted) and read
  skew across shards. The result is as of roughly its start time; no stored
  invariant is affected. An order and its total are one row on one shard, so T6
  never sees half an order.
- **T1:** no anomaly. A price changed by T9 before T1 commits means T1 charges
  the older price, which is equivalent to T1 running before T9, a valid serial
  order, so serializable allows it too.
- Repeatable read (snapshot isolation in PostgreSQL) would prevent lost update,
  non-repeatable read and read skew within a worker, but not write skew.

## Invariant checks (`tools/probe/probe.sh`, mode `invariants`)

Run on freshly loaded SCALE=0.1 data with 16 clients, 90 s per phase,
`--max-tries=3`. The coordinator and all four workers were confirmed at the
requested isolation level.
- Phase `conserve`: only T1 and T7. Final total stock must equal initial total
  stock minus the quantity of every new order item.
- Phase `mix`: all nine transactions with workload B weights.
- Checks after each phase: no negative stock; every new order has items and no
  new item lacks its order; each order's total equals the sum of its items'
  `quantity * unit_price`; each item's merchant equals its order's; no prepared
  transactions left after `recover_prepared_transactions()`.

| Job | Transactions | Isolation | Result |
| --- | --- | --- | --- |
| 946060 | `expt_b0` | serializable | all pass |
| 946061 | `expt_b5` | serializable | all pass |
| 946062 | `expt_b0` | read committed | all pass |
| 946063 | `expt_b5` | read committed | all pass |

A passing run is corroboration, not proof: it cannot show that write skew is
impossible. The argument is the per-transaction analysis above.

## Results: all 13 experiments at read committed

Same `run.sh` and transactions as the serializable runs (scale 1, clients 1-64,
60 s warmup, 600 s measured, `xcnc` nodes); only `PG_ISOLATION_LEVEL` differs.
Overall TPS as in `summary.csv`, serializable S vs read committed R:

| | c1 | c8 | c16 | c32 | c64 |
| --- | --- | --- | --- | --- | --- |
| a0 baseline S / R | 2.04 / 1.73 | 1.72 / 1.75 | 1.56 / 1.32 | 1.94 / 1.96 | 0.93 / 0.94 |
| a5 final S / R | 25.3 / 27.1 | 60.7 / 53.1 | 62.2 / 52.5 | 47.9 / 50.6 | 48.4 / 49.0 |
| b0 baseline S / R | 3.54 / 3.43 | 3.25 / 3.68 | 2.85 / 3.40 | 3.38 / 3.87 | 2.40 / 2.84 |
| b5 final S / R | 26.2 / 21.4 | 36.5 / 37.2 | 36.8 / 33.7 | 35.5 / 33.3 | 36.9 / 34.0 |

Failures and aborted clients (measured run, c4 / c8 / c16 / c32 / c64):
- b0 serializable: 17 / 62 / 112 / 342 / 314 failures; 2 / 1 / 6 / 9 / 10 aborted clients.
- a0 serializable: 0 / 3 / 9 / 29 / 21 failures; 0 / 1 / 3 / 2 / 0 aborted clients.
- All 13 read-committed jobs: 0 failures and 0 aborted clients, no other errors.

**O3 depends on the isolation level.** Overall TPS at 32 clients:
- b2 (O3) 20.2 S / 20.5 R; b6 (O3a) 14.4 S / 19.2 R. Under serializable O3a's
  all-shard read causes conflicts (1,565 failures); under read committed there
  are none, and the gap shrinks to about 10%.
- a4 (without O3) 49.9 S / 62.1 R; a5 (with O3) 47.9 S / 50.6 R. At 8-16
  clients O3 helped under serializable (a4 50.5 / 48.0 vs a5 60.7 / 62.2) but
  not under read committed (a4 60.3 / 60.3 vs a5 53.1 / 52.5), though the
  difference is within the node variation.

## Caveats
- Runs on a shared cluster vary by 12-24% and by node set (the same
  unchanged transaction can differ up to 2x between node sets). Treat gaps under
  about 25% as not significant.
- Each read-committed lane ran on its own pinned node set, only to keep our own
  jobs from sharing port 5440, so serializable and read-committed runs of the
  same experiment used different nodes.
- `summary.csv` divides by the configured 600 s, so TPS is overstated when slow
  runs overrun (e.g. b0 at 64 clients: 2.84 vs 1.84 as pgbench reports).
- The provided configuration is serializable; the report should present
  read committed as an additional experiment with the argument above.

## Where things are
Serializable jobs: a0 882950, a1 883680, a2 883684, a3 883773, a4 883775,
a5 884051, b0 882953, b1 883683, b2 883685, b3 883774, b4 883776, b5 884052,
b6 884053.

Read-committed jobs: a0 946081, a1 946233, a2 946236, a3 946238, a4 946234,
a5 946082, b0 946083, b1 946240, b2 946241, b3 946237, b4 946239, b5 946084,
b6 946235.

Convention: read-committed results are in `expt_*/slurm-results-rc/job-<id>/`
inside `~/citus_project_worktrees/isolation-checks` (not committed), listed in
`rc-jobs.txt`; serializable results stay in `slurm-results/`. Final experiment
numbers for the report are still to be decided, because `a6` / `b7` onward are
reserved for the storage/index group.

Reproduce:
```
# invariants (from the repository root, on the cluster)
TX_EXPT=expt_b5 ISO="read committed" tools/probe/submit_probe.sh invariants 0.1 --constraint=xcnc

# a read-committed benchmark run
cd expt_b5 && sbatch --constraint=xcnc \
  --export="ALL,PG_ISOLATION_LEVEL=read committed,RESULT_ROOT=$PWD/slurm-results-rc" run.sh
```
