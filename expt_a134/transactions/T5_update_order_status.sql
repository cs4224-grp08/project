-- Serializable baseline: this transaction first takes coordinator advisory locks
-- and holds them until commit (see README, "Serializable baseline").
-- Keys: (1, 0) is G, the orders read by T6; (2, m) is merchant m.
\if :DEBUG_MODE
\set order_id :DEBUG_ORDER_ID
\set status_roll :DEBUG_STATUS_ROLL
\else
\set order_id random(1, :INITIAL_NUM_ORDERS)
\set status_roll random(1, 3)
\endif

-- The order's merchant, for its lock. merchant_id never changes, so this read
-- needs no lock; an order that doesn't exist is left alone, as in the baseline.
-- O8: order_routing is distributed by order_id, so this is a routed lookup to avoid cross-shard query using orders.
SELECT coalesce(max(merchant_id), 0) AS t5_merchant_id
FROM order_routing
WHERE order_id = (:order_id)::bigint
\gset

\if :t5_merchant_id > 0
BEGIN;
SELECT pg_advisory_xact_lock(2, (:t5_merchant_id)::int);

\if :status_roll = 1
UPDATE orders
SET order_status = 'PENDING'::text
WHERE order_id = (:order_id)::bigint
  AND merchant_id = (:t5_merchant_id)::bigint;
\elif :status_roll = 2
UPDATE orders
SET order_status = 'SHIPPED'::text
WHERE order_id = (:order_id)::bigint
  AND merchant_id = (:t5_merchant_id)::bigint;
\else
UPDATE orders
SET order_status = 'COMPLETED'::text
WHERE order_id = (:order_id)::bigint
  AND merchant_id = (:t5_merchant_id)::bigint;
\endif

COMMIT;
\endif
