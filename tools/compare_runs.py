#!/usr/bin/env python3
"""Compare benchmark jobs side by side.

Usage: python3 tools/compare_runs.py LABEL=JOB_DIR [LABEL=JOB_DIR ...]
  JOB_DIR is an expt_*/slurm-results/job-<id> directory.

Prints, per client count: overall TPS as reported in summary.csv (successful
transactions / configured duration) with pgbench's own TPS in brackets, p50/
p95/p99 latency, serialization failures, and measured-run aborted clients.
"""
import csv
import re
import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent


def load(job):
    res = Path(job) / "benchmark-results"
    rows = {int(r["clients"]): r for r in csv.DictReader(open(res / "summary.csv"))}
    out = subprocess.run([sys.executable, str(TOOLS / "count_aborts.py"), str(res)],
                         capture_output=True, text=True, check=True).stdout
    aborts = {int(r["clients"]): int(r["measured_known_aborts"]) + int(r["measured_other_aborts"])
              for r in csv.DictReader(out.splitlines())}
    pg = {}
    for c in rows:
        m = re.search(r"^tps = ([0-9.]+)", (res / f"result-c{c}.txt").read_text(), re.M)
        pg[c] = float(m.group(1)) if m else float("nan")
    return rows, aborts, pg


def main(args):
    if not args:
        sys.exit(__doc__)
    runs = dict(a.split("=", 1) for a in args)
    data = {k: load(v) for k, v in runs.items()}
    clients = sorted(next(iter(data.values()))[0])
    w = 16
    head = "clients " + "".join(f"{k:>{w}}" for k in data)
    print("overall_tps [pgbench tps]\n" + head)
    for c in clients:
        print(f"{c:>7} " + "".join(f"{float(d[0][c]['overall_tps']):>9.2f} [{d[2][c]:>5.2f}]" for d in data.values()))
    print("speed-up of overall_tps vs first column\n" + head)
    for c in clients:
        base = float(next(iter(data.values()))[0][c]["overall_tps"])
        print(f"{c:>7} " + "".join(f"{float(d[0][c]['overall_tps']) / base:>{w}.1f}" for d in data.values()))
    for col, label in (("overall_median_latency_ms", "p50 latency ms"), ("overall_p95_latency_ms", "p95 latency ms"),
                       ("overall_p99_latency_ms", "p99 latency ms"), ("serialization_failures", "serialization failures")):
        print(label + "\n" + head)
        for c in clients:
            print(f"{c:>7} " + "".join(f"{float(d[0][c][col]):>{w}.0f}" for d in data.values()))
    print("aborted clients (measured run)\n" + head)
    for c in clients:
        print(f"{c:>7} " + "".join(f"{d[1][c]:>{w}}" for d in data.values()))


if __name__ == "__main__":
    main(sys.argv[1:])
