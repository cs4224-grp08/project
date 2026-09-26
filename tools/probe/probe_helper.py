#!/usr/bin/env python3
"""Helpers for the rewrite probe jobs (tools/probe/probe.sh).

Subcommands (psql connection comes from PGHOST/PGPORT/PGUSER/PGDATABASE, the
psql binary from $PSQL):

  explain OUT FILE...        EXPLAIN ANALYZE every distinct SQL statement of
                             each pgbench script (each in BEGIN ... ROLLBACK)
  compare-reads OUT NUM_MERCHANTS NUM_CUSTOMERS NUM_PRODUCTS BASE NEW KIND
                             run a read transaction's SQL from BASE and NEW for
                             many random inputs and compare (KIND: t3 or t4)
  dump-state DIR INITIAL_NUM_ORDERS
                             dump table contents for effect comparison
  compare-state BASE_DIR NEW_DIR
                             compare two dumps (new orders compared without
                             their surrogate ids)
"""
import os
import random
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

PSQL = os.environ.get("PSQL", "psql")

# Values for every pgbench variable the transactions use, for EXPLAIN only.
EXPLAIN_VARS = {
    "merchant_id": 5, "customer_id": 7005, "product_id": 3005, "item_count": 5,
    **{f"product_id_{k}": 5 + k * 1000 for k in range(1, 6)},
    **{f"qty_{k}": 1 for k in range(1, 6)},
    **{f"t1_price_{k}": "10.00" for k in range(1, 6)},
    **{f"item{k}_price": "10.00" for k in range(1, 6)},
    **{f"item{k}_order_item_id": 900000000 + k for k in range(1, 6)},
    "n_distinct": 5, "new_order_id": 999999999, "order_total": 50,
    "source_product_id": 12345, "dest_product_id": 67890, "transfer_qty": 1,
    "source_inventory_id": 12345, "dest_inventory_id": 67890,
    "inventory_change": 1, "REPORT_DAYS": 30, "order_id": 100,
    "new_email_number": 5, "price_increase": 1,
}


def statements(path):
    """Split a pgbench script into its SQL statements (ignoring \\if logic)."""
    out, cur = [], []
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if s.startswith("\\"):
            if s.startswith(("\\gset", "\\aset")) and cur:
                out.append("\n".join(cur))
                cur = []
            continue
        if not s or s.startswith("--"):
            continue
        cur.append(line)
        if s.endswith(";"):
            out.append("\n".join(cur).rstrip().rstrip(";"))
            cur = []
    return [q for q in out if q.strip().upper() not in ("BEGIN", "COMMIT", "ROLLBACK")]


def psql(script, extra=()):
    r = subprocess.run([PSQL, "-X", "-A", "-t", "-F", "|", *extra], input=script,
                       capture_output=True, text=True)
    return r.stdout, r.stderr


def set_vars(values):
    return "".join(f"\\set {k} {v}\n" for k, v in values.items())


def cmd_explain(out, files):
    seen, parts = set(), [set_vars(EXPLAIN_VARS)]
    for f in files:
        for i, q in enumerate(statements(f)):
            if q in seen:
                continue
            seen.add(q)
            parts.append(f"\\echo '=== {f} statement {i}'\n\\echo {q.splitlines()[0]!r}\n"
                         f"BEGIN;\nEXPLAIN (ANALYZE, COSTS OFF)\n{q};\nROLLBACK;\n")
    stdout, stderr = psql("".join(parts), extra=("-e",))
    Path(out).write_text(stdout + "\n--- stderr ---\n" + stderr)


def run_cases(sql, cases):
    parts = []
    for i, values in enumerate(cases):
        parts.append(set_vars(values) + f"\\echo '@@CASE {i}'\n{sql};\n")
    stdout, stderr = psql("".join(parts))
    results, cur = {}, None
    for line in stdout.splitlines():
        if line.startswith("@@CASE "):
            cur = int(line.split()[1])
            results[cur] = []
        elif line and cur is not None:
            results[cur].append(line)
    return results, stderr


def t3_equivalent(base, new):
    """Tie-aware comparison for ORDER BY created_at DESC LIMIT 20 (column 4)."""
    if len(base) != len(new):
        return False
    if not base:
        return True
    key = lambda row: row.split("|")[3]
    if sorted(map(key, base)) != sorted(map(key, new)):
        return False
    last = min(map(key, base))
    strict = lambda rows: Counter(r for r in rows if key(r) > last)
    return strict(base) == strict(new)


def cmd_compare_reads(out, nm, nc, np_, base, new, kind):
    nm, nc, np_ = int(nm), int(nc), int(np_)
    rng = random.Random(42)
    cases = []
    for _ in range(300):
        m = rng.randint(1, nm)
        if kind == "t3":
            cases.append({"merchant_id": m, "customer_id": m + rng.randint(0, (nc - m) // nm) * nm})
        else:
            owner = m if rng.random() < 0.9 else rng.randint(1, nm)  # some mismatched pairs
            cases.append({"merchant_id": m, "product_id": owner + rng.randint(0, (np_ - owner) // nm) * nm})
    (bq,), (nq,) = statements(base), statements(new)
    b, be = run_cases(bq, cases)
    n, ne = run_cases(nq, cases)
    bad = [i for i in range(len(cases))
           if not (t3_equivalent(b.get(i, []), n.get(i, [])) if kind == "t3"
                   else sorted(b.get(i, [])) == sorted(n.get(i, [])))]
    rows = sum(len(v) for v in b.values())
    empty = sum(1 for v in b.values() if not v)
    report = [f"{kind}: {len(cases)} cases, {rows} baseline rows, {empty} empty results, "
              f"{len(bad)} mismatches", f"baseline stderr: {be.strip() or '-'}",
              f"rewrite stderr: {ne.strip() or '-'}"]
    for i in bad[:5]:
        report += [f"MISMATCH case {cases[i]}", "  base: " + "; ".join(b.get(i, [])),
                   "  new:  " + "; ".join(n.get(i, []))]
    ok = not bad and len(b) == len(n) == len(cases) and not be.strip() and not ne.strip()
    Path(out).write_text("\n".join(report) + f"\nRESULT {'PASS' if ok else 'FAIL'}\n")
    print(report[0], "PASS" if ok else "FAIL")
    return 0 if ok else 1


DUMPS = {
    "inventory": "SELECT inventory_id, merchant_id, product_id, quantity FROM inventory ORDER BY 1",
    "products": "SELECT product_id, merchant_id, price FROM products ORDER BY 1",
    "customers": "SELECT customer_id, merchant_id, email FROM customers ORDER BY 1",
    "orders_initial": "SELECT order_id, merchant_id, customer_id, order_status, total_amount "
                      "FROM orders WHERE order_id <= {init} ORDER BY 1",
    "items_initial": "SELECT order_item_id, order_id, product_id, quantity, unit_price "
                     "FROM order_items WHERE order_id <= {init} ORDER BY 1",
    "orders_new": "SELECT order_id, merchant_id, customer_id, order_status, total_amount "
                  "FROM orders WHERE order_id > {init}",
    "items_new": "SELECT order_id, merchant_id, product_id, quantity, unit_price "
                 "FROM order_items WHERE order_id > {init}",
}


def cmd_dump_state(d, init):
    d = Path(d)
    d.mkdir(parents=True, exist_ok=True)
    for name, q in DUMPS.items():
        stdout, stderr = psql(q.format(init=int(init)) + ";\n")
        if stderr.strip():
            sys.exit(f"dump {name} failed: {stderr}")
        (d / f"{name}.txt").write_text(stdout)


def canonical_new_orders(d):
    items = {}
    for line in (d / "items_new.txt").read_text().splitlines():
        oid, *rest = line.split("|")
        items.setdefault(oid, []).append(tuple(rest))
    out = Counter()
    for line in (d / "orders_new.txt").read_text().splitlines():
        oid, *rest = line.split("|")
        out[(tuple(rest), tuple(sorted(items.pop(oid, []))))] += 1
    return out, sum(len(v) for v in items.values())  # orphan items should be 0


def cmd_compare_state(a, b):
    a, b = Path(a), Path(b)
    diffs = [n for n in DUMPS if n not in ("orders_new", "items_new")
             and (a / f"{n}.txt").read_text() != (b / f"{n}.txt").read_text()]
    (na, oa), (nb, ob) = canonical_new_orders(a), canonical_new_orders(b)
    if na != nb:
        diffs.append("new orders")
    if oa or ob:
        diffs.append(f"orphan items ({oa} vs {ob})")
    changed = sum(1 for x, y in zip((a / "inventory.txt").read_text().splitlines(),
                                    (Path(os.environ.get("PRISTINE", a)) / "inventory.txt").read_text().splitlines())
                  if x != y) if os.environ.get("PRISTINE") else "n/a"
    print(f"{b.name} vs {a.name}: {sum(na.values())} vs {sum(nb.values())} new orders; "
          f"inventory rows changed vs pristine: {changed}; "
          + ("MATCH" if not diffs else "DIFFER: " + ", ".join(diffs)))
    return 0 if not diffs else 1


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "explain":
        cmd_explain(args[0], args[1:])
    elif cmd == "compare-reads":
        sys.exit(cmd_compare_reads(*args))
    elif cmd == "dump-state":
        cmd_dump_state(*args)
    elif cmd == "compare-state":
        sys.exit(cmd_compare_state(*args))
    elif cmd == "statements":
        for q in statements(args[0]):
            print(q + ";\n")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
