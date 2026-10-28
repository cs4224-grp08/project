\if :DEBUG_MODE
\set merchant_id :DEBUG_MERCHANT_ID
\else
\set merchant_id CASE WHEN random(1, 100) <= :HOT_ORDER_PERCENT THEN random(1, :HOT_MERCHANTS) ELSE random((:HOT_MERCHANTS + 1), :NUM_MERCHANTS) END
\endif

\if :DEBUG_MODE
\set product_id :DEBUG_PRODUCT_ID
\else
\set product_slot random(0, ((:NUM_PRODUCTS - :merchant_id) / :NUM_MERCHANTS))
\set product_id :merchant_id + (:product_slot * :NUM_MERCHANTS)
\endif

BEGIN;
SELECT pg_advisory_xact_lock_shared(2, (:merchant_id)::int);

-- O2: inventory_id is the distribution key and is maintained equal to
-- product_id. Filtering both sides by their distribution keys makes this a
-- pair of single-shard lookups instead of a repartition join.
WITH inv AS MATERIALIZED (
  SELECT product_id, merchant_id, quantity
  FROM inventory
  WHERE inventory_id = (:product_id)::bigint
    AND product_id = (:product_id)::bigint
    AND merchant_id = (:merchant_id)::bigint
)
SELECT
  p.product_id,
  p.product_name,
  p.category,
  p.price,
  i.quantity
FROM products AS p
JOIN inv AS i
  ON i.product_id = p.product_id
 AND i.merchant_id = p.merchant_id
WHERE p.merchant_id = (:merchant_id)::bigint
  AND p.product_id = (:product_id)::bigint;

COMMIT;
