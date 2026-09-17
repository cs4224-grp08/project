import json
import os
import queue
import subprocess
import sys
import threading
from pathlib import Path


ROW_COUNT = 128
INITIAL_QUANTITY = 100


class Session:
    def __init__(self, psql, root, name):
        self.name = name
        self.sequence = 0
        self.lines = queue.Queue()
        self.errors = (root / f"{name}.stderr").open("w")
        self.process = subprocess.Popen(
            [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=0", "-v", "VERBOSITY=verbose"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
            text=True, bufsize=1, env={**os.environ, "PGAPPNAME": name},
        )
        self.reader = threading.Thread(target=self.read_lines, daemon=True)
        self.reader.start()

    def read_lines(self):
        for line in self.process.stdout:
            self.lines.put(line.rstrip("\n"))
        self.lines.put(None)

    def execute(self, sql):
        self.sequence += 1
        marker = f"DIAGNOSTIC_{self.sequence}"
        self.process.stdin.write(f"{sql}\n\\echo {marker} :SQLSTATE\n")
        self.process.stdin.flush()
        output = []
        while True:
            line = self.lines.get(timeout=45)
            if line is None:
                raise RuntimeError(f"{self.name}: psql exited before status marker")
            if line.startswith(marker + " "):
                state = line.split()[1]
                print(json.dumps({"session": self.name, "sql": sql,
                                  "sqlstate": state, "output": output}), flush=True)
                return state, output
            output.append(line)

    def close(self):
        try:
            if self.process.poll() is None:
                self.process.stdin.write("\\q\n")
                self.process.stdin.flush()
                self.process.wait(timeout=10)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.errors.close()


def query(psql, sql, host=None):
    args = [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
    if host:
        args += ["-h", host]
    result = subprocess.run(args + ["-c", sql], check=True, capture_output=True,
                            text=True, timeout=60)
    return result.stdout.strip()


def expected_quantities(source, destination, witness, transfer_ok, competitor_ok):
    expected = {number: INITIAL_QUANTITY for number in range(1, ROW_COUNT + 1)}
    if transfer_ok:
        expected[source] -= 1
        expected[destination] += 1
    if competitor_ok:
        expected[witness] += 1
    return expected


def transfer_statement(source, destination):
    return (
        "UPDATE inventory SET quantity=quantity+CASE "
        f"WHEN inventory_id={source} THEN -1 ELSE 1 END, "
        "updated_at=CURRENT_TIMESTAMP "
        f"WHERE inventory_id IN ({source},{destination}) "
        f"AND {source}<>{destination} "
        f"AND (inventory_id<>{source} OR quantity>=1) RETURNING inventory_id;"
    )


def run_case(psql, root, name, source, destination, witness, explicit_witness,
             combined=False):
    query(psql, "TRUNCATE inventory;")
    query(psql, f"INSERT INTO inventory SELECT number, 1, number, {INITIAL_QUANTITY}, "
          f"CURRENT_TIMESTAMP FROM generate_series(1, {ROW_COUNT}) AS number;")
    query(psql, "ANALYZE inventory;")
    transfer = Session(psql, root, name + "_transfer")
    competitor = Session(psql, root, name + "_competitor")
    events = []
    transfer_ok = False
    competitor_ok = False

    def step(session, label, sql):
        state, output = session.execute(sql)
        events.append({"step": label, "sqlstate": state, "output": output})
        return state == "00000"

    try:
        for session in (transfer, competitor):
            if not step(session, "timeouts", "SET statement_timeout='15s'; SET lock_timeout='5s';"):
                raise RuntimeError(f"Cannot set diagnostic timeouts for {session.name}")
        ready = step(transfer, "transfer_begin", "BEGIN ISOLATION LEVEL SERIALIZABLE;")
        ready = step(competitor, "competitor_begin", "BEGIN ISOLATION LEVEL SERIALIZABLE;") and ready
        for product in (source, destination):
            ready = step(transfer, "exists", f"SELECT EXISTS(SELECT 1 FROM inventory WHERE product_id={product});") and ready
            ready = step(transfer, "lookup", f"SELECT inventory_id FROM inventory WHERE product_id={product};") and ready
        if explicit_witness:
            ready = step(transfer, "forced_dependency", f"SELECT quantity FROM inventory WHERE inventory_id={witness};") and ready
        ready = step(competitor, "competitor_read_source", f"SELECT quantity FROM inventory WHERE inventory_id={source};") and ready
        if ready and combined:
            ready = step(transfer, "combined_transfer", transfer_statement(source, destination))
            ready = ready and sorted(events[-1]["output"]) == sorted([str(source), str(destination)])
        elif ready:
            ready = step(transfer, "debit", f"UPDATE inventory SET quantity=quantity-1, updated_at=CURRENT_TIMESTAMP WHERE inventory_id={source} AND quantity>=1 RETURNING inventory_id;")
        if ready and not combined:
            ready = step(transfer, "credit", f"UPDATE inventory SET quantity=quantity+1, updated_at=CURRENT_TIMESTAMP WHERE inventory_id={destination} RETURNING inventory_id;")
        if ready:
            changed = step(competitor, "competitor_write_witness", f"UPDATE inventory SET quantity=quantity+1, updated_at=CURRENT_TIMESTAMP WHERE inventory_id={witness} RETURNING inventory_id;")
            if changed:
                competitor_ok = step(competitor, "competitor_commit", "COMMIT;")
            else:
                step(competitor, "competitor_rollback", "ROLLBACK;")
            transfer_ok = step(transfer, "transfer_commit", "COMMIT;")
        step(transfer, "transfer_cleanup", "ROLLBACK;")
        step(competitor, "competitor_cleanup", "ROLLBACK;")
    finally:
        transfer.close()
        competitor.close()

    actual = dict(json.loads(query(psql, "SELECT json_agg(ARRAY[inventory_id, quantity] ORDER BY inventory_id) FROM inventory;")))
    expected = expected_quantities(source, destination, witness, transfer_ok, competitor_ok)
    outcome = {"case": name, "source": source, "destination": destination,
               "witness": witness, "explicit_witness": explicit_witness,
               "combined": combined,
               "transfer_acknowledged": transfer_ok, "competitor_acknowledged": competitor_ok,
               "events": events, "actual": actual, "expected": expected,
               "matches_acknowledged_effects": actual == expected}
    (root / f"{name}.json").write_text(json.dumps(outcome, indent=2) + "\n")
    print(json.dumps({key: value for key, value in outcome.items()
                      if key not in {"events", "actual", "expected"}}), flush=True)
    return outcome


def check_transfer_boundaries(psql, root, source, destination):
    outcomes = []
    for scenario in ("success", "insufficient", "missing_source", "missing_destination", "identical"):
        query(psql, "TRUNCATE inventory;")
        query(psql, f"INSERT INTO inventory SELECT number, 1, number, {INITIAL_QUANTITY}, CURRENT_TIMESTAMP FROM generate_series(1,{ROW_COUNT}) AS number;")
        if scenario == "insufficient":
            query(psql, f"UPDATE inventory SET quantity=0 WHERE inventory_id={source};")
        if scenario.startswith("missing_"):
            missing = source if scenario == "missing_source" else destination
            query(psql, f"DELETE FROM inventory WHERE inventory_id={missing};")
        target = source if scenario == "identical" else destination
        before = dict(json.loads(query(psql, "SELECT json_agg(ARRAY[inventory_id,quantity]) FROM inventory;")))
        session = Session(psql, root, f"boundary_{source}_{destination}_{scenario}")
        try:
            begin_state, _ = session.execute("BEGIN ISOLATION LEVEL SERIALIZABLE;")
            if begin_state != "00000":
                raise RuntimeError("Boundary test could not begin")
            update_state, rows = session.execute(transfer_statement(source, target))
            accepted = update_state == "00000" and sorted(rows) == sorted([str(source), str(target)]) and source != target
            end_state, _ = session.execute("COMMIT;" if accepted else "ROLLBACK;")
        finally:
            session.close()
        expected = before.copy()
        if scenario == "success":
            expected[source] -= 1
            expected[destination] += 1
        actual = dict(json.loads(query(psql, "SELECT json_agg(ARRAY[inventory_id,quantity]) FROM inventory;")))
        passed = update_state == "00000" and end_state == "00000" and accepted == (scenario == "success") and actual == expected
        outcome = {"scenario": scenario, "source": source, "destination": target,
                   "accepted": accepted, "update_sqlstate": update_state,
                   "end_sqlstate": end_state, "passed": passed,
                   "before": before, "actual": actual, "expected": expected}
        (root / f"boundary_{source}_{destination}_{scenario}.json").write_text(json.dumps(outcome, indent=2) + "\n")
        outcomes.append(outcome)
        if not passed:
            raise RuntimeError(f"Transfer boundary check failed: {scenario}")
    return outcomes


def main():
    psql, result_path = sys.argv[1:]
    root = Path(result_path)
    nodes = query(psql, "SELECT nodename FROM pg_dist_node WHERE isactive AND noderole='primary' ORDER BY nodeid;").splitlines()
    for host in [os.environ["PGHOST"], *nodes]:
        for setting in ("log_statement = 'all'", "log_error_verbosity = 'verbose'",
                        "log_line_prefix = '%m [%p] app=%a sqlstate=%e '"):
            query(psql, f"ALTER SYSTEM SET {setting};", host)
        query(psql, "SELECT pg_reload_conf();", host)
    settings = {}
    for host in [os.environ["PGHOST"], *nodes]:
        settings[host] = json.loads(query(psql, "SELECT json_object_agg(name, setting) FROM pg_settings WHERE name IN ('default_transaction_isolation','log_statement','log_error_verbosity','log_line_prefix','citus.shard_count','citus.max_adaptive_executor_pool_size','synchronous_commit','fsync');", host))
        if settings[host]["default_transaction_isolation"] != "serializable":
            raise RuntimeError(f"Unexpected isolation on {host}")
    (root / "diagnostic-settings.json").write_text(json.dumps(settings, indent=2) + "\n")
    query(psql, "CREATE TABLE inventory(inventory_id bigint PRIMARY KEY, merchant_id bigint NOT NULL, product_id bigint NOT NULL, quantity integer NOT NULL CHECK(quantity>=0), updated_at timestamp NOT NULL);")
    query(psql, "CREATE INDEX idx_inventory_merchant_id ON inventory(merchant_id);")
    query(psql, "SELECT create_distributed_table('inventory','inventory_id');")
    mapping = json.loads(query(psql, f"SELECT json_agg(json_build_object('id', number, 'shard', placement.shardid, 'node', node.nodename) ORDER BY number) FROM generate_series(1,{ROW_COUNT}) AS number JOIN pg_dist_placement placement ON placement.shardid=get_shard_id_for_distribution_column('inventory',number::bigint) JOIN pg_dist_node node ON node.groupid=placement.groupid AND node.isactive AND node.noderole='primary';"))
    (root / "placement-map.json").write_text(json.dumps(mapping, indent=2) + "\n")
    source = mapping[0]
    local = [row for row in mapping if row["node"] == source["node"] and row["id"] != source["id"]]
    witness = next(row for row in local if row["shard"] == source["shard"])
    same_shard = next(row for row in local if row["shard"] == source["shard"] and row["id"] != witness["id"])
    same = next(row for row in local if row["shard"] != source["shard"])
    remote = next(row for row in mapping if row["node"] != source["node"])
    boundaries = []
    for destination in (same_shard, same, remote):
        boundaries.extend(check_transfer_boundaries(psql, root, source["id"], destination["id"]))
    outcomes = []
    for topology, destination in (("same_shard", same_shard), ("same_worker", same), ("cross_worker", remote)):
        for combined in (False, True):
            for explicit in (False, True):
                for repeat in range(3):
                    name = f"{topology}_combined_{int(combined)}_forced_{int(explicit)}_repeat_{repeat}"
                    outcomes.append(run_case(psql, root, name, source["id"], destination["id"], witness["id"], explicit, combined))
    prepared = {host: int(query(psql, "SELECT count(*) FROM pg_prepared_xacts WHERE database=current_database();", host))
                for host in [os.environ["PGHOST"], *nodes]}
    summary = {"cases": len(outcomes),
               "prepared_transactions_after_tests": prepared,
               "boundary_checks": len(boundaries),
               "xx000_cases": [item["case"] for item in outcomes if any(event["sqlstate"] == "XX000" for event in item["events"])],
               "effect_mismatches": [item["case"] for item in outcomes if not item["matches_acknowledged_effects"]]}
    (root / "diagnostic-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
    if summary["effect_mismatches"] or any(prepared.values()):
        raise RuntimeError("Diagnostic found unexpected effects or unresolved prepared transactions")
    if os.environ.get("REQUIRE_RETRYABLE_COMMITS") == "1":
        for outcome in outcomes:
            commits = [event for event in outcome["events"] if event["step"] == "transfer_commit"]
            if len(commits) != 1 or commits[0]["sqlstate"] != "40001":
                raise RuntimeError(f"Candidate did not preserve retryable commit failure: {outcome['case']}")


if __name__ == "__main__":
    main()