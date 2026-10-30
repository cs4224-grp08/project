# Q&A notes for the report (not submitted)

Every comparison the report makes, the nodes behind it, and why it holds. Node sets come from `SLURM_JOB_NODELIST` in each `citus-<job>.out`.

## Node speed, if asked

- **xcnc0–4 is consistently faster on short transactions.** T2 (a one-row update) takes 3.1–3.9 ms at 1 client there, against 4.7–8.2 ms on xcnc5–9, 33–37 and 36–40. Bulk data reload takes the same time on every node set (about 200–245 s).
- **The one identical-code test** is b206, run twice:

  | Job | Nodes | TPS at 1 client | TPS at 8 clients | TPS at 64 clients |
  |---|---|---|---|---|
  | 1038832 | xcnc0–4 | 74.4 | 514.0 | 537.0 |
  | 1042354 | xcnc33–37 | 56.6 | 287.8 | 445.9 |

  That is 1.2–1.8× faster on xcnc0–4.
- **Rule used in the report:**
  - same node set: compare, with the 10% descriptive threshold;
  - xcnd sets: compare (T2 at 9.1–9.8 ms on all of them);
  - different node sets: compare only for changes ≥4×, which is more than twice the 1.8× seen for identical code.

## Claims and their basis

| Claim | Runs (nodes) | Basis |
|---|---|---|
| a5 ≈ a131 up to 16 clients; a131 +39–43% at 32–64 | a5, a131 (both 36–40) | same nodes |
| a99 as fast as a0 at 1 client | a0, a99 (both 36–40) | same nodes |
| T3 rewrite: T3 p50 330 s → 0.51 s; 1.34 → 17.3 TPS | a99 (36–40) → a101 (6,11,14,18,31) | ≥4× (650× and 12.9×) |
| T4 rewrite: T4 p50 9.7 s → 11 ms | a101 → a111 (same nodes) | same nodes |
| T7 rewrite: p50 358 → 37 ms, p99 692 → 824 ms, +6% | a121 → a131 (both 36–40) | same nodes |
| T1 batching on A | a111 → a121 (different) | no claim made |
| a102: T3 avg 258 s → 36 ms; 1.34 → 17.4 TPS | a99 → a102 (5–9) | ≥4× |
| a112/a122: T4 avg 522 → 3.1/2.8 ms | a99 → a112/a122 | ≥4× |
| a114: T4 p50 520 → 3.7 ms; T5 6.6 → 75 ms | a99 → a114 (39–43) | ≥4× |
| a104: T3 p50 at 1 client stays at 4.5 s | a99 → a104 (0–4, faster nodes) | "no change" despite faster nodes, so conservative |
| a204: T1 avg at 64 clients 1,982 → 59 ms; T6 23% → 94% of time | a131 → a204 (5–9) | ≥4×; shares are within-run |
| Covering index A: 8.3× at 64 clients; T6 16 s → 0.59 s and 353 → 88 ms | a204 (5–9) → a205 (0–4) | ≥4× (a205 had faster nodes, which can't explain 8×) |
| Covering index B: 10.9×; T6 16.2 s → 0.80 s | b204 (5–9) → b205 (33–37) | ≥4×, and both node sets are in the slower group |
| VP before index: a113 −28%, a103/a123 within 4% | xcnd0–4, xcnd4–8 | xcnd sets alike |
| a206 vs a207 within 5%; T6 −20%, T1 +7.5% | both 33–37 | same nodes |
| b205/b206/b207: +7% at 32–64, −2 to −5% at 4–16; T6 −18% | all 33–37 | same nodes |
| a204 vs b204 T6 rate 3.80 vs 3.82 per second | both 5–9 | same nodes |
| B rewrites: b99 → b101 → b111 | all on 5,9,17,19,30 | same nodes |
| b111 → b121: T4 p50 16.3 s → 13 ms | different | ≥4× (no throughput ratio claimed) |
| b121 → b131 within 1% | both 0–1,33–35 | same nodes |
| b102: 5.9×; lock waits T1 25.6 → 3.4 s, T7 6.0 → 0.34 s | b99 → b102 (5–9) | ≥4× (from pgbench per-statement latencies in `result-c64.txt`) |
| b114: T7 p50 at 64 clients 1.7 → 11.5 s | b99 → b114 | ≥4× |
| Final speedups: A 47×/468×, B 18.6×/138× | baselines vs finals | ≥4× |

## Likely questions

- **Why b206 if +7% is below your 10% threshold?**
  - It's the best design at 32–64 clients, on the same nodes.
  - Its gain comes from T6, the transaction the split speeds up (−18% average at 64 clients).
  - The report says b205 performs about as well.
- **Why not compare a205 with a206 and a207?**
  - They ran on different nodes: a205 on xcnc0–4, the other two on xcnc33–37.
  - a207 (AutoPart, which only moves `email`) stands in for a205 on those nodes. On B, b207 is within 8% of b205 on the same nodes.
- **b206 has two jobs in its folder. Which one counts?** 1042354, on the same nodes as b205 and b207. 1038832 ran on xcnc0–4 and isn't comparable with them.
- **Why is the protocol serializable if T6 releases G early?** See the barrier table (Table 3). T6 is equivalent to running alone at the barrier, and every other transaction follows strict 2PL.
- **How do you know the barrier works?** The argument is in §2.3. Don's snapshot test (job 995999, SCALE=0.1, not in the submission) saw 0 of 200 new orders with the barrier, 200 of 200 without it, and 155 of 200 with a one-worker barrier.
- **How is TPS computed?** The supplied `run.sh`: successful transactions from the logs ÷ `DURATION` (600 s). pgbench's own "tps" divides by the actual elapsed time, which runs past 600 s when long transactions are still in flight. So the two differ for slow designs.
- **Why does Navathe's split make T7 slower on B (50 → 65 ms)?** We don't know, and the report says so.
- **a99/b99 and the 101–131 chains ran T1/T7 with both locks in one SELECT.** The submitted code uses one statement per lock, and no run had a deadlock or retry. (Agreed to explain in person.)
