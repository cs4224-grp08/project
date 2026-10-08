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

BEGIN;

-- O3a: one lookup for both products instead of four (no reliance on
-- inventory_id = product_id); the debit and credit are unchanged.
SELECT
  COALESCE(max(inventory_id) FILTER (WHERE product_id = (:source_product_id)::bigint), 0) AS source_inventory_id,
  COALESCE(max(inventory_id) FILTER (WHERE product_id = (:dest_product_id)::bigint), 0) AS dest_inventory_id
FROM inventory
WHERE product_id IN ((:source_product_id)::bigint, (:dest_product_id)::bigint)
\gset

\if :source_inventory_id = 0
\set transfer_ok 0
\endif

\if :dest_inventory_id = 0
\set transfer_ok 0
\endif

\if :source_product_id = :dest_product_id
\set transfer_ok 0
\endif
\if :transfer_ok
WITH debit AS (
  UPDATE inventory
  SET quantity = quantity - (:transfer_qty)::integer,
      updated_at = CURRENT_TIMESTAMP
  WHERE inventory_id = (:source_inventory_id)::bigint
    AND quantity >= (:transfer_qty)::integer
  RETURNING 1
)
SELECT EXISTS(SELECT 1 FROM debit) AS debit_ok
\gset t7_

\if :t7_debit_ok
WITH credit AS (
  UPDATE inventory
  SET quantity = quantity + (:transfer_qty)::integer,
      updated_at = CURRENT_TIMESTAMP
  WHERE inventory_id = (:dest_inventory_id)::bigint
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
