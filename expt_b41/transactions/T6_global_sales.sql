-- Serializability: strict two-phase locking with coordinator advisory locks,
-- taken first and held until commit (see the Serializability tab). Keys: (1, 0) is G,
-- the orders read by T6; (2, m) is merchant m. Shared for reads, exclusive for writes.

BEGIN;
SELECT pg_advisory_xact_lock(1, 0);
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
