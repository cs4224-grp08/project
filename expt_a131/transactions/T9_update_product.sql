-- Serializable baseline: this transaction first takes coordinator advisory locks
-- and holds them until commit (see README, "Serializable baseline").
-- Keys: (1, 0) is G, the orders read by T6; (2, m) is merchant m.


\if :DEBUG_MODE
\set product_id :DEBUG_PRODUCT_ID
\else
\set product_id random(1, :NUM_PRODUCTS)
\endif

\set merchant_id  1 + ((:product_id - 1) % :NUM_MERCHANTS)
\set price_increase random(1, 10)

BEGIN;
SELECT pg_advisory_xact_lock(2, (:merchant_id)::int);

UPDATE products
SET price = price + (:price_increase)::numeric(12,2)
WHERE product_id = (:product_id)::bigint
  AND merchant_id = (:merchant_id)::bigint;

COMMIT;
