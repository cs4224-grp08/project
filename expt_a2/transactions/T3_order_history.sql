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

-- O1: pick the customer's 20 most recent orders first, then join only those
-- orders' items. Every order has at least one item, so the 20 joined rows can
-- only come from these 20 orders. An item's merchant_id always equals its
-- order's (copied from the order on load and in T1, never updated), so the
-- merchant filter selects the same items via idx_order_items_merchant_id.
WITH recent AS MATERIALIZED (
  SELECT order_id, order_status, total_amount, created_at
  FROM orders
  WHERE merchant_id = (:merchant_id)::bigint
    AND customer_id = (:customer_id)::bigint
  ORDER BY created_at DESC
  LIMIT 20
)
SELECT
  r.order_id,
  r.order_status,
  r.total_amount,
  r.created_at,
  oi.product_id,
  oi.quantity,
  oi.unit_price
FROM recent AS r
JOIN order_items AS oi
  ON oi.order_id = r.order_id
WHERE oi.merchant_id = (:merchant_id)::bigint
ORDER BY r.created_at DESC
LIMIT 20;

COMMIT;
