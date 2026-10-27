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

BEGIN;
\if :source_merchant_id = :dest_merchant_id
SELECT pg_advisory_xact_lock(2, (:source_merchant_id)::int);
\else
-- Ascending acquisition order prevents merchant-lock deadlocks.
SELECT pg_advisory_xact_lock(2, least(:source_merchant_id, :dest_merchant_id)::int);
SELECT pg_advisory_xact_lock(2, greatest(:source_merchant_id, :dest_merchant_id)::int);
\endif

SELECT EXISTS(
  SELECT 1 FROM product_inventory
  WHERE product_id = (:source_product_id)::bigint
) AS source_exists
\gset t7_

SELECT EXISTS(
  SELECT 1 FROM product_inventory
  WHERE product_id = (:dest_product_id)::bigint
) AS dest_exists
\gset t7_


\if :t7_source_exists
SELECT product_id AS source_inventory_id FROM product_inventory WHERE product_id = (:source_product_id)::bigint
\gset
\else
\set transfer_ok 0
\endif


\if :t7_dest_exists
SELECT product_id AS dest_inventory_id FROM product_inventory WHERE product_id = (:dest_product_id)::bigint
\gset
\else
\set transfer_ok 0
\endif


\if :source_product_id = :dest_product_id
\set transfer_ok 0
\endif

\if :transfer_ok
WITH debit AS (
  UPDATE product_inventory
  SET quantity = quantity - (:transfer_qty)::integer,
      updated_at = CURRENT_TIMESTAMP
  WHERE product_id = (:source_inventory_id)::bigint
    AND quantity >= (:transfer_qty)::integer
  RETURNING 1
)
SELECT EXISTS(SELECT 1 FROM debit) AS debit_ok
\gset t7_

\if :t7_debit_ok
WITH credit AS (
  UPDATE product_inventory
  SET quantity = quantity + (:transfer_qty)::integer,
      updated_at = CURRENT_TIMESTAMP
  WHERE product_id = (:dest_inventory_id)::bigint
  RETURNING 1
)
SELECT EXISTS(SELECT 1 FROM credit) AS credit_ok
\gset t7_

\if :t7_credit_ok
\else
\set transfer_ok 0
\endif
\else
\set transfer_ok 0
\endif
\endif

\if :transfer_ok
COMMIT;
\else
ROLLBACK;
\endif
