#!/usr/bin/env python3
"""Usage: scripts/compare-runs.py <expt>[/job-<job>] ...

Compares the latest job of each experiment, or the given jobs. The first is the
reference for speed-ups.
"""
import csv
import re
import sys
from pathlib import Path

CITUS_COMMIT_CONFLICT = re.compile(r"could not commit transaction for shard \d+ on at least one active node")
PGBENCH_TPS = re.compile(r"^tps = ([0-9.]+)", re.M)


def job_folder(run):
    path = Path(run)
    if path.name.startswith("job-"):
        if path.parent.name != "slurm-results":
            path = path.parent / "slurm-results" / path.name
    else:
        jobs = sorted((path / "slurm-results").glob("job-*"), key=lambda p: int(p.name.removeprefix("job-")))
        if not jobs:
            sys.exit(f"{run}: no jobs")
        path = jobs[-1]
    if not (path / "benchmark-results" / "summary.csv").is_file():
        sys.exit(f"{run}: no summary.csv")
    return path


def metrics_by_clients(job):
    results = job / "benchmark-results"
    rows = {int(r["clients"]): r for r in csv.DictReader(open(results / "summary.csv"))}
    for clients, row in rows.items():
        output = (results / f"result-c{clients}.txt").read_text(errors="replace")
        tps = PGBENCH_TPS.search(output)
        row["pgbench_tps"] = float(tps.group(1)) if tps else float("nan")
        aborts = [line for line in output.splitlines()
                  if line.startswith("pgbench: error: client ") and " aborted" in line]
        conflicts = sum(1 for line in aborts if CITUS_COMMIT_CONFLICT.search(line))
        row["aborts"] = f"{conflicts}/{len(aborts) - conflicts}"
    return rows


def main(args):
    if not args:
        sys.exit(__doc__)
    jobs = [job_folder(run) for run in args]
    labels = [f"{job.parent.parent.name}:{job.name.removeprefix('job-')}" for job in jobs]
    runs = [metrics_by_clients(job) for job in jobs]
    clients = sorted(set().union(*runs))
    width = max(16, *(len(label) + 2 for label in labels))

    def table(title, cell):
        print(f"\n{title}\nclients " + "".join(f"{label:>{width}}" for label in labels))
        for c in clients:
            print(f"{c:>7} " + "".join(f"{cell(run[c]) if c in run else '-':>{width}}" for run in runs))

    reference_tps = {c: float(r["overall_tps"]) for c, r in runs[0].items()}
    table("overall_tps [pgbench tps]", lambda r: f"{float(r['overall_tps']):.2f} [{r['pgbench_tps']:.2f}]")
    table("speed-up vs first run",
          lambda r: f"{float(r['overall_tps']) / reference_tps[int(r['clients'])]:.1f}"
          if int(r["clients"]) in reference_tps else "-")
    for column, title in (("overall_median_latency_ms", "p50 latency (ms)"),
                          ("overall_p95_latency_ms", "p95 latency (ms)"),
                          ("overall_p99_latency_ms", "p99 latency (ms)"),
                          ("serialization_failures", "serialization failures")):
        table(title, lambda r, column=column: f"{float(r[column]):.0f}")
    table("aborted clients (Citus commit conflicts/other)", lambda r: r["aborts"])


if __name__ == "__main__":
    main(sys.argv[1:])
