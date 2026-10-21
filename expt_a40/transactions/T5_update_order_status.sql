-- Final design: orders are distributed by merchant_id, so T5 first finds the
-- order's merchant in order_routing (initial orders, never changed). An order
-- created during the run is not in it; then T5 looks the merchant up in orders.
\if :DEBUG_MODE
\set order_id :DEBUG_ORDER_ID
\set status_roll :DEBUG_STATUS_ROLL
\else
\set order_id random(1, :INITIAL_NUM_ORDERS)
\set status_roll random(1, 3)
\endif

SELECT coalesce(max(merchant_id), 0) AS t5_merchant_id
FROM order_routing
WHERE order_id = (:order_id)::bigint
\gset

\if :t5_merchant_id = 0
SELECT coalesce(max(merchant_id), 0) AS t5_merchant_id
FROM orders
WHERE order_id = (:order_id)::bigint
\gset
\endif

\if :t5_merchant_id > 0
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
\endif
