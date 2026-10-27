\if :DEBUG_MODE
\set merchant_id :DEBUG_MERCHANT_ID
\else
\set merchant_id CASE WHEN random(1, 100) <= :HOT_ORDER_PERCENT THEN random(1, :HOT_MERCHANTS) ELSE random((:HOT_MERCHANTS + 1), :NUM_MERCHANTS) END
\endif

\if :DEBUG_MODE
\set customer_id :DEBUG_CUSTOMER_ID
\set item_count :DEBUG_ITEM_COUNT
\else
\set customer_slot random(0, ((:NUM_CUSTOMERS - :merchant_id) / :NUM_MERCHANTS))
\set customer_id :merchant_id + (:customer_slot * :NUM_MERCHANTS)
\set item_count random(:MIN_ITEMS_PER_ORDER, :MAX_ITEMS_PER_ORDER)
\endif

\set order_ok 1
\set order_total 0.0

BEGIN;
-- G=(1,0) is shared by order writers and exclusive to T6's snapshot barrier.
SELECT pg_advisory_xact_lock_shared(1, 0);
-- (2,m) exclusively protects all rows belonging to merchant m.
SELECT pg_advisory_xact_lock(2, (:merchant_id)::int);

-- retrieve customer information
SELECT CASE WHEN EXISTS (
  SELECT customer_name, email
  FROM customers
  WHERE merchant_id = (:merchant_id)::bigint
    AND customer_id = (:customer_id)::bigint
) THEN 1 ELSE 0 END AS customer_ok
\gset t1_

\if :t1_customer_ok
SELECT nextval('benchmark_order_id_seq') AS new_order_id
\gset
\else
\set order_ok 0
\set new_order_id 0
\endif

-- insert new order
\if :order_ok
INSERT INTO orders(
  order_id, merchant_id, customer_id, order_status, total_amount, created_at
)
VALUES(
  (:new_order_id)::bigint,
  (:merchant_id)::bigint,
  (:customer_id)::bigint,
  'PENDING'::text,
  0.00,
  CURRENT_TIMESTAMP
);
\endif

\if :order_ok

WITH generated_items AS MATERIALIZED (

    SELECT
        i AS item_no,
        (:merchant_id)::bigint AS merchant_id,
        (:new_order_id)::bigint AS order_id,

        -- ----------------------------------------------------
        -- Product ID
        -- ----------------------------------------------------
        :merchant_id + random(0, ((:NUM_PRODUCTS - :merchant_id) / :NUM_MERCHANTS)) * :NUM_MERCHANTS AS product_id,

        -- ----------------------------------------------------
        -- Quantity
        -- ----------------------------------------------------
        random(:MIN_ORDER_QTY,:MAX_ORDER_QTY)::integer AS quantity

    FROM generate_series(1,(:item_count)::integer) AS i
),


-- ============================================================
-- Look up ALL products once
-- ============================================================

item_details AS (

    SELECT
        gi.item_no,
        gi.merchant_id,
        gi.order_id,
        gi.product_id,
        gi.quantity,
        p.price AS price

    FROM generated_items gi

    JOIN products p
      ON p.merchant_id = gi.merchant_id
     AND p.product_id = gi.product_id
),


-- ============================================================
-- Combine quantities for duplicate products
-- ============================================================

required_inventory AS (
    SELECT
        merchant_id,
        product_id,
        SUM(quantity) AS required_quantity,
        SUM(quantity * price) AS product_total
    FROM item_details
    GROUP BY
        merchant_id, product_id
),


-- ============================================================
-- Reserve ALL required inventory
-- ============================================================

reserved_inventory AS (
    UPDATE inventory inv

    SET
        quantity = inv.quantity - ri.required_quantity,
        updated_at = CURRENT_TIMESTAMP

    FROM required_inventory ri

    WHERE inv.merchant_id = ri.merchant_id
      AND inv.inventory_id = ri.product_id
      AND inv.quantity >= ri.required_quantity

    RETURNING
        inv.merchant_id,
        inv.inventory_id
),


-- ============================================================
-- Validate the complete order
-- ============================================================

validation AS (
    SELECT
        (SELECT COUNT(*) FROM item_details) = :item_count AS products_valid,
        (SELECT COUNT(*) FROM required_inventory) =  (SELECT COUNT(*) FROM reserved_inventory) AS inventory_valid,
        (SELECT SUM(product_total) FROM required_inventory)::numeric(12,2) AS order_total
),


-- ============================================================
-- Insert the SAME item_details that were validated
-- ============================================================

inserted_items AS (
    INSERT INTO order_items (
        order_item_id,
        merchant_id,
        order_id,
        product_id,
        quantity,
        unit_price
    )
    SELECT
        nextval('benchmark_order_item_id_seq'),
        id.merchant_id,
        id.order_id,
        id.product_id,
        id.quantity,
        id.price
    FROM item_details id
    WHERE EXISTS (
        SELECT 1
        FROM validation
        WHERE products_valid
          AND inventory_valid
    )
)


-- ============================================================
-- Return result to psql
-- ============================================================

SELECT
    CASE
        WHEN products_valid
         AND inventory_valid
        THEN 1
        ELSE 0
    END AS order_ok, order_total
FROM validation

\gset t1_


-- ============================================================
-- Update order total only if entire order succeeded
-- ============================================================

\if :t1_order_ok

UPDATE orders
SET total_amount = (:t1_order_total)::numeric(12,2)
WHERE order_id = (:new_order_id)::bigint;


-- ============================================================
-- Commit successful order
-- ============================================================

COMMIT;

\else

-- ============================================================
-- Product missing OR insufficient inventory
-- ============================================================

ROLLBACK;

\endif

\else

-- ============================================================
-- Customer does not exist
-- ============================================================

ROLLBACK;

\endif
