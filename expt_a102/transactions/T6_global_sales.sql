-- Establish one stable orders snapshot per worker while T1 is excluded by G.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL citus.multi_shard_modify_mode TO 'sequential';
SET LOCAL citus.max_adaptive_executor_pool_size TO 1;
-- Clear any session lock left on a pgbench connection after an interrupted try.
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
