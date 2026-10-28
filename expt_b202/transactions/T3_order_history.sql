\if :DEBUG_MODE
\set merchant_id :DEBUG_MERCHANT_ID
\else
\set merchant_id CASE WHEN random(1, 100) <= :HOT_ORDER_PERCENT THEN random(1, :HOT_MERCHANTS) ELSE random((:HOT_MERCHANTS + 1), :NUM_MERCHANTS) END
\endif

\if :DEBUG_MODE
\set customer_id :DEBUG_CUSTOMER_ID
\else
\set customer_slot random(0, ((:NUM_CUSTOMERS - :merchant_id) / :NUM_MERCHANTS))
\set customer_id :merchant_id + (:customer_slot * :NUM_MERCHANTS)
\endif

BEGIN;
SELECT pg_advisory_xact_lock_shared(2, (:merchant_id)::int);

SELECT
  order_id,
  order_status,
  total_amount,
  created_at,
  product_id,
  quantity,
  unit_price
FROM customer_order_history
WHERE merchant_id = (:merchant_id)::bigint
  AND customer_id = (:customer_id)::bigint
ORDER BY created_at DESC
LIMIT 20;

COMMIT;
