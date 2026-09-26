# CS4224/CS5424 Citus project: team 08

Each `expt_wN` folder is one experiment (`w` is the workload, `a` or `b`). It
contains `run.sh`, `transactions/`, `slurm-results/job-<id>/` and the Slurm logs
`citus-<id>.out` / `citus-<id>.err`.

| Folder | Task | Description |
| --- | --- | --- |
| `expt_a0` | Task 1 | Performance of the baseline design as a function of the number of clients for workload A |
| `expt_b0` | Task 3 | Performance of the baseline design as a function of the number of clients for workload B |

Optimization experiments (query rewrites). Each builds on the previous one
(`V_N = V_{N-1} + O_N`); `run.sh` is identical to the baseline's.

| Folder | Task | Adds | Transactions changed |
| --- | --- | --- | --- |
| `expt_a1` | Task 2 | O1 | T3 |
| `expt_a2` | Task 2 | O1 + O2 | T3, T4 |
| `expt_a3` | Task 2 | O1 + O2 + O4 | T1, T3, T4 |
| `expt_a4` | Task 2 | O1 + O2 + O4 + O5 | T1-T6, T8, T9 |
| `expt_a5` | Task 2 | O1 + O2 + O4 + O5 + O3 | T1-T9 |
| `expt_b1` | Task 4 | O1 | T3 |
| `expt_b2` | Task 4 | O1 + O3 | T3, T7 |
| `expt_b3` | Task 4 | O1 + O3 + O2 | T3, T4, T7 |
| `expt_b4` | Task 4 | O1 + O3 + O2 + O5 | T2-T9 |
| `expt_b5` | Task 4 | O1 + O3 + O2 + O5 + O4 | T1-T9 |
| `expt_b6` | Task 4 | O1 + O3a (alternative to `expt_b2`) | T3, T7 |

- O1 (T3): fetch the customer's 20 most recent orders first, then join only
  their items (also filtered by merchant, which every item shares with its order).
- O2 (T4): look up inventory by its distribution key (`inventory_id = product_id`).
- O3 (T7): one UPDATE debits and credits both products (`inventory_id = product_id`).
- O3a (T7): one lookup for both products instead of four; debit and credit unchanged.
- O4 (T1): check, reserve and insert all items with one statement each.
- O5: single-statement transactions run in autocommit (no BEGIN/COMMIT).

`expt_a0` and `expt_b0` are the provided scripts, changed only to set
`TEAM_ID=8` and the notification email; they differ only in `WORKLOAD`.

## Not part of the submission

Leave these out when building `citus_project_team_08/` (brief §11.1):

- `docs/`: working notes for the report. See `docs/baseline-b-findings.md`
  for the baseline workload B analysis (Citus commit-error aborts, flat
  throughput, candidate optimizations).
- `tools/rewrites/`, `tools/build_experiments.sh`: the rewritten transactions and
  the script that assembles `expt_a1`-`expt_b6` from them.
- `tools/probe/`: probe jobs used to validate the rewrites (EXPLAIN, single-client
  latency, result/effect equivalence against the baseline).
- `tools/run_queue.sh`: submits experiments on disjoint nodes.
- `tools/count_aborts.py`: counts pgbench client aborts per client count after
  a run, e.g.
  `python3 tools/count_aborts.py expt_b0/slurm-results/job-<id>/benchmark-results`.

Slurm outputs (`slurm-results/`, `citus-*.out`, `citus-*.err`) are ignored by Git.
Copy them into the result folder from the cluster when packaging.
