-- Serializable baseline: T6 is the exception to "lock first, hold until commit"
-- (see README, "Serializable baseline"): it holds G only for the barrier below.
-- Keys: (1, 0) is G, the orders read by T6; (2, c) is customer c; (3, p) is product p.
-- Snapshot barrier: hold G only while opening one REPEATABLE READ snapshot per
-- worker (one connection per worker), then release it and read from those
-- snapshots, so T1 (G shared) waits only for the barrier, not the whole query.
-- pg_advisory_unlock_all clears a session lock left by an earlier retry.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL citus.multi_shard_modify_mode TO 'sequential';
SET LOCAL citus.max_adaptive_executor_pool_size TO 1;
SELECT pg_advisory_unlock_all();
SELECT pg_advisory_lock(1, 0);
SELECT count(*) FROM orders WHERE order_id < 0;
SELECT pg_advisory_unlock(1, 0);

SELECT
  merchant_id,
  COUNT(*) AS order_count,
  SUM(total_amount) AS revenue
FROM orders
WHERE created_at >= CURRENT_TIMESTAMP - (:REPORT_DAYS)::integer * INTERVAL '1 day'
  AND created_at < CURRENT_TIMESTAMP
GROUP BY merchant_id
ORDER BY revenue DESC
LIMIT 20;

COMMIT;
