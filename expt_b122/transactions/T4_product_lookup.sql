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

SELECT
  stock.product_id,
  catalog.product_name,
  catalog.category,
  stock.price,
  stock.quantity
FROM product_stock AS stock
JOIN product_catalog AS catalog
  ON catalog.merchant_id = stock.merchant_id
 AND catalog.product_id = stock.product_id
WHERE stock.merchant_id = (:merchant_id)::bigint
  AND stock.product_id = (:product_id)::bigint;

COMMIT;
