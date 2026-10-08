# CS4224/CS5424 Citus project: team 08

Each `expt_wN` folder is one experiment for workload `w` (`a` or `b`). It holds
`run.sh`, the nine transactions in `transactions/`, and, on the cluster, the
outputs `slurm-results/job-<id>/` and `citus-<id>.out` / `citus-<id>.err`.

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
| `expt_b0` | Task 3 | Baseline design, workload B | none (baseline) | 882953 |
| `expt_b1` | Task 4 | V0 + O1 | T3 | 883683 |
| `expt_b2` | Task 4 | V1 + O3 | T3, T7 | 883685 |
| `expt_b3` | Task 4 | V2 + O2 | T3, T4, T7 | 883774 |
| `expt_b4` | Task 4 | V3 + O5 | T2, T3, T4, T5, T6, T7, T8, T9 | 883776 |
| `expt_b5` | Task 4 | V4 + O4 | T1, T2, T3, T4, T5, T6, T7, T8, T9 | 884052 |
| `expt_b6` | Task 4 | V1 + O3a (alternative to `expt_b2`) | T3, T7 | 884053 |

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

`expt_a0` and `expt_b0` are the provided scripts with `TEAM_ID=8` and the
notification email set; they differ only in `WORKLOAD`.

## Conventions for new experiments

1. Copy the folder you build on, change `run.sh` and/or `transactions/`, and
   add a row above. Numbers already used: `a0`-`a5`, `b0`-`b6`; take the next
   free number.
2. Submit from inside the folder so outputs land in the folder:
   `cd expt_wN && sbatch --constraint=xcnc run.sh`. Keep `RESULT_ROOT` at its
   default. All reported runs so far used `xcnc` nodes.
3. Keep one reported job per folder; move reruns and failed attempts elsewhere
   before packaging.
4. Slurm outputs are not committed to Git. They stay in each folder on the
   cluster and are copied into `citus_project_team_08/` when packaging.

## Tools (not part of the submission)

- `tools/compare_runs.py label=<job dir> ...`: side-by-side TPS (as in
  `summary.csv` and as reported by pgbench), p50/p95/p99 latency,
  serialization failures and aborted clients per client count.
- `tools/count_aborts.py <job dir>/benchmark-results`: aborted pgbench clients
  per client count, split into the known Citus commit error and other errors.
