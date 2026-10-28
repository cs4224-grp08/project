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
\set source_merchant_id 1 + ((:source_product_id - 1) % :NUM_MERCHANTS)
\set dest_merchant_id 1 + ((:dest_product_id - 1) % :NUM_MERCHANTS)

-- O3: inventory_id is the distribution key and equals product_id. Update the
-- source and destination together, then commit only if both rows changed.
\if :source_product_id = :dest_product_id
\set transfer_ok 0
\endif

BEGIN;
\if :source_merchant_id = :dest_merchant_id
SELECT pg_advisory_xact_lock(2, (:source_merchant_id)::int);
\else
-- Ascending acquisition order prevents merchant-lock deadlocks.
SELECT pg_advisory_xact_lock(2, least(:source_merchant_id, :dest_merchant_id)::int);
SELECT pg_advisory_xact_lock(2, greatest(:source_merchant_id, :dest_merchant_id)::int);
\endif

\if :transfer_ok
WITH moved AS (
  UPDATE inventory
  SET quantity = quantity + CASE WHEN inventory_id = (:dest_product_id)::bigint
                                 THEN (:transfer_qty)::integer
                                 ELSE -(:transfer_qty)::integer END,
      updated_at = CURRENT_TIMESTAMP
  WHERE inventory_id IN ((:source_product_id)::bigint, (:dest_product_id)::bigint)
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
