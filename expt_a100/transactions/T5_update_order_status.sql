-- Serializable baseline: this transaction first takes coordinator advisory locks
-- and holds them until commit (see README, "Serializable baseline").
-- Keys: (1, 0) is G, the orders read by T6; (2, c) is customer c; (3, p) is product p.
\if :DEBUG_MODE
\set order_id :DEBUG_ORDER_ID
\set status_roll :DEBUG_STATUS_ROLL
\else
\set order_id random(1, :INITIAL_NUM_ORDERS)
\set status_roll random(1, 3)
\endif

-- The order's customer, for its lock. customer_id never changes, so this read
-- needs no lock; an order that doesn't exist is left alone, as in the baseline.
SELECT coalesce(max(customer_id), 0) AS t5_customer_id
FROM orders
WHERE order_id = (:order_id)::bigint
\gset

\if :t5_customer_id > 0
BEGIN;
SELECT pg_advisory_xact_lock(2, (:t5_customer_id)::int);

\if :status_roll = 1
UPDATE orders
SET order_status = 'PENDING'::text
WHERE order_id = (:order_id)::bigint;
\elif :status_roll = 2
UPDATE orders
SET order_status = 'SHIPPED'::text
WHERE order_id = (:order_id)::bigint;
\else
UPDATE orders
SET order_status = 'COMPLETED'::text
WHERE order_id = (:order_id)::bigint;
\endif

COMMIT;
\endif
