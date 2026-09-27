#!/usr/bin/env python3
"""Count aborted pgbench clients per client count of one finished job.

Why: pgbench stops a client for the rest of the run when it hits an error it
cannot retry. summary.csv does not show this, so a c32 run may really have run
with fewer than 32 clients. Report these counts next to throughput.

What it gives: one CSV row per client count with the warmup and measured
pgbench exit codes and the number of aborted clients, split into
  known  - the Citus commit error "could not commit transaction for shard N on
           at least one active node": a serialization conflict that Citus
           reports as non-retryable (SQLSTATE XX000). Expected under load.
  other  - any other error (lost connection, timeout, SQL bug). Should be 0;
           otherwise check benchmark.log and the <node>-postgresql.log files.

How to run (on the cluster, after the job finishes; standard library only):
    python3 tools/count_aborts.py expt_b0/slurm-results/job-<id>/benchmark-results

Example output (baseline workload B, job 882953):
    clients,warmup_exit,warmup_known_aborts,warmup_other_aborts,measured_exit,measured_known_aborts,measured_other_aborts
    1,0,0,0,0,0,0
    4,2,1,0,2,2,0

It reads only warmup-cN.txt and result-cN.txt written by the provided run.sh,
so it works on any job directory without changing run.sh.
"""
import csv
import re
import sys
from pathlib import Path

ABORT = re.compile(r"^pgbench: error: client \d+ .*aborted")
KNOWN = re.compile(r"could not commit transaction for shard \d+ on at least one active node")
EXIT = re.compile(r"^pgbench_exit_code=(\d+)")


def scan(path):
    """Return (exit_code, known_aborts, other_aborts) for one pgbench output file."""
    if not path.exists():
        return "", 0, 0
    exit_code, known, other = "", 0, 0
    for line in path.read_text(errors="replace").splitlines():
        if ABORT.match(line):
            if KNOWN.search(line):
                known += 1
            else:
                other += 1
        elif m := EXIT.match(line):
            exit_code = m.group(1)
    return exit_code, known, other


def main(argv):
    if len(argv) != 2 or not Path(argv[1]).is_dir():
        sys.exit(__doc__)
    results = Path(argv[1])
    clients = sorted(int(m.group(1)) for p in results.glob("result-c*.txt")
                     if (m := re.fullmatch(r"result-c(\d+)\.txt", p.name)))
    out = csv.writer(sys.stdout)
    out.writerow(["clients", "warmup_exit", "warmup_known_aborts", "warmup_other_aborts",
                  "measured_exit", "measured_known_aborts", "measured_other_aborts"])
    for c in clients:
        out.writerow([c, *scan(results / f"warmup-c{c}.txt"), *scan(results / f"result-c{c}.txt")])


if __name__ == "__main__":
    main(sys.argv)
