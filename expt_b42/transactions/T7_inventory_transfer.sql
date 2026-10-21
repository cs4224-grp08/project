-- Serializability: strict two-phase locking with coordinator advisory locks,
-- taken first and held until commit (see the Serializability tab). Keys: (1, 0) is G,
-- the orders read by T6; (2, m) is merchant m. Shared for reads, exclusive for writes.
\if :DEBUG_MODE
\set source_product_id :DEBUG_T7_SOURCE_PRODUCT_ID
\set dest_product_id :DEBUG_T7_DEST_PRODUCT_ID
\set transfer_qty :DEBUG_T7_TRANSFER_QTY
\else
\set source_product_id random(1, :NUM_PRODUCTS)
\set dest_product_id random(1, :NUM_PRODUCTS)
\set transfer_qty random(:T7_MIN_TRANSFER_QTY, :T7_MAX_TRANSFER_QTY)
\endif

\set transfer_ok 1
-- Final design: inventory is distributed by merchant_id; a product's merchant is
-- 1 + (product_id - 1) mod NUM_MERCHANTS (as the provided T9 also uses).
\set source_merchant_id 1 + ((:source_product_id - 1) % :NUM_MERCHANTS)
\set dest_merchant_id 1 + ((:dest_product_id - 1) % :NUM_MERCHANTS)

-- O3: one statement debits the source and credits the destination.
-- inventory_id = product_id for every inventory row (loaded from products,
-- never re-keyed), so the baseline's four product_id lookups are not needed.
-- Exactly two rows change only if both products exist and the source has
-- enough stock; otherwise the transaction rolls back, as in the baseline.
-- (The stock guard avoids OR so that Citus prunes the UPDATE to two shards.)
\if :source_product_id = :dest_product_id
\set transfer_ok 0
\endif

BEGIN;

\if :transfer_ok
SELECT pg_advisory_xact_lock(2, least(:source_merchant_id, :dest_merchant_id)::int),
       pg_advisory_xact_lock(2, greatest(:source_merchant_id, :dest_merchant_id)::int);
WITH moved AS (
  UPDATE inventory
  SET quantity = quantity + CASE WHEN inventory_id = (:dest_product_id)::bigint
                                 THEN (:transfer_qty)::integer
                                 ELSE -(:transfer_qty)::integer END,
      updated_at = CURRENT_TIMESTAMP
  WHERE merchant_id IN ((:source_merchant_id)::bigint, (:dest_merchant_id)::bigint)
    AND inventory_id IN ((:source_product_id)::bigint, (:dest_product_id)::bigint)
    AND quantity >= CASE WHEN inventory_id = (:dest_product_id)::bigint
                         THEN 0 ELSE (:transfer_qty)::integer END
  RETURNING 1
)
SELECT count(*) = 2 AS moved_ok FROM moved
\gset t7_

\if :t7_moved_ok
\else
\set transfer_ok 0
\endif
\endif

\if :transfer_ok
COMMIT;
\else
ROLLBACK;
\endif
