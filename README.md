# CS4224/CS5424 Citus project: team 08

Each `expt_wN` folder is one experiment (`w` is the workload, `a` or `b`). It
contains `run.sh`, `transactions/`, `slurm-results/job-<id>/` and the Slurm logs
`citus-<id>.out` / `citus-<id>.err`.

| Folder | Task | Description |
| --- | --- | --- |
| `expt_a0` | Task 1 | Performance of the baseline design as a function of the number of clients for workload A |
| `expt_b0` | Task 3 | Performance of the baseline design as a function of the number of clients for workload B |

`expt_a0` and `expt_b0` are the provided scripts, changed only to set
`TEAM_ID=8` and the notification email; they differ only in `WORKLOAD`.

## Not part of the submission

Leave these out when building `citus_project_team_08/` (brief §11.1):

- `docs/`: working notes for the report. See `docs/baseline-b-findings.md`
  for the baseline workload B analysis (Citus commit-error aborts, flat
  throughput, candidate optimizations).
- `tools/count_aborts.py`: counts pgbench client aborts per client count after
  a run, e.g.
  `python3 tools/count_aborts.py expt_b0/slurm-results/job-<id>/benchmark-results`.

Slurm outputs (`slurm-results/`, `citus-*.out`, `citus-*.err`) are ignored by Git.
Copy them into the result folder from the cluster when packaging.
