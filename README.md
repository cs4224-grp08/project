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
| `expt_a6` | Task 1 (extra) | `expt_a0` at read committed | none (baseline) | 946081 |
| `expt_a7` | Task 2 (extra) | `expt_a5` at read committed | T1, T2, T3, T4, T5, T6, T7, T8, T9 | 946082 |
| `expt_b0` | Task 3 | Baseline design, workload B | none (baseline) | 882953 |
| `expt_b1` | Task 4 | V0 + O1 | T3 | 883683 |
| `expt_b2` | Task 4 | V1 + O3 | T3, T7 | 883685 |
| `expt_b3` | Task 4 | V2 + O2 | T3, T4, T7 | 883774 |
| `expt_b4` | Task 4 | V3 + O5 | T2, T3, T4, T5, T6, T7, T8, T9 | 883776 |
| `expt_b5` | Task 4 | V4 + O4 | T1, T2, T3, T4, T5, T6, T7, T8, T9 | 884052 |
| `expt_b6` | Task 4 | V1 + O3a (alternative to `expt_b2`) | T3, T7 | 884053 |
| `expt_b7` | Task 3 (extra) | `expt_b0` at read committed | none (baseline) | 946083 |
| `expt_b8` | Task 4 (extra) | `expt_b5` at read committed | T1, T2, T3, T4, T5, T6, T7, T8, T9 | 946084 |

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

1. Copy the experiment you build on to the next free `expt_wN`, and add it to the
   [Experiments](#experiments) table. Keep `RESULT_ROOT` at its default.
2. Test each change on the [Local Cluster](#local-cluster) until it runs.
3. Open a pull request; the [GitHub Cluster](#github-cluster) runs each experiment.
4. Once each experiment passes, benchmark on the [Remote Cluster](#remote-cluster).
5. [Compare runs](#comparing-runs) for the report.
6. Copy each experiment's reported job into `citus_project_team_08/` for the submission.

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
