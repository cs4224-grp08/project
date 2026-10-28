-- Serializable denormalized design: coordinator locks provide the workload's
-- serial order. O4 batches item work while maintaining customer_order_history.
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

-- Draw item inputs in the baseline order. Zero identifies an unused slot and
-- cannot match a generated product or inventory row.
\if :item_count >= 1
\if :DEBUG_MODE
\set product_id_1 :DEBUG_PRODUCT_ID_1
\set qty_1 :DEBUG_QTY_1
\else
\set product_slot_1 random(0, ((:NUM_PRODUCTS - :merchant_id) / :NUM_MERCHANTS))
\set product_id_1 :merchant_id + (:product_slot_1 * :NUM_MERCHANTS)
\set qty_1 random(:MIN_ORDER_QTY, :MAX_ORDER_QTY)
\endif
\else
\set product_id_1 0
\set qty_1 0
\endif

\if :item_count >= 2
\if :DEBUG_MODE
\set product_id_2 :DEBUG_PRODUCT_ID_2
\set qty_2 :DEBUG_QTY_2
\else
\set product_slot_2 random(0, ((:NUM_PRODUCTS - :merchant_id) / :NUM_MERCHANTS))
\set product_id_2 :merchant_id + (:product_slot_2 * :NUM_MERCHANTS)
\set qty_2 random(:MIN_ORDER_QTY, :MAX_ORDER_QTY)
\endif
\else
\set product_id_2 0
\set qty_2 0
\endif

\if :item_count >= 3
\if :DEBUG_MODE
\set product_id_3 :DEBUG_PRODUCT_ID_3
\set qty_3 :DEBUG_QTY_3
\else
\set product_slot_3 random(0, ((:NUM_PRODUCTS - :merchant_id) / :NUM_MERCHANTS))
\set product_id_3 :merchant_id + (:product_slot_3 * :NUM_MERCHANTS)
\set qty_3 random(:MIN_ORDER_QTY, :MAX_ORDER_QTY)
\endif
\else
\set product_id_3 0
\set qty_3 0
\endif

\if :item_count >= 4
\if :DEBUG_MODE
\set product_id_4 :DEBUG_PRODUCT_ID_4
\set qty_4 :DEBUG_QTY_4
\else
\set product_slot_4 random(0, ((:NUM_PRODUCTS - :merchant_id) / :NUM_MERCHANTS))
\set product_id_4 :merchant_id + (:product_slot_4 * :NUM_MERCHANTS)
\set qty_4 random(:MIN_ORDER_QTY, :MAX_ORDER_QTY)
\endif
\else
\set product_id_4 0
\set qty_4 0
\endif

\if :item_count >= 5
\if :DEBUG_MODE
\set product_id_5 :DEBUG_PRODUCT_ID_5
\set qty_5 :DEBUG_QTY_5
\else
\set product_slot_5 random(0, ((:NUM_PRODUCTS - :merchant_id) / :NUM_MERCHANTS))
\set product_id_5 :merchant_id + (:product_slot_5 * :NUM_MERCHANTS)
\set qty_5 random(:MIN_ORDER_QTY, :MAX_ORDER_QTY)
\endif
\else
\set product_id_5 0
\set qty_5 0
\endif

-- A product may occur more than once in an order. Validation and reservation
-- operate on distinct inventory rows, while the item tables retain every item.
\set distinct_1 CASE WHEN :product_id_1 > 0 THEN 1 ELSE 0 END
\set distinct_2 CASE WHEN :product_id_2 > 0 AND :product_id_2 <> :product_id_1 THEN 1 ELSE 0 END
\set distinct_3 CASE WHEN :product_id_3 > 0 AND :product_id_3 <> :product_id_1 AND :product_id_3 <> :product_id_2 THEN 1 ELSE 0 END
\set distinct_4 CASE WHEN :product_id_4 > 0 AND :product_id_4 <> :product_id_1 AND :product_id_4 <> :product_id_2 AND :product_id_4 <> :product_id_3 THEN 1 ELSE 0 END
\set distinct_5 CASE WHEN :product_id_5 > 0 AND :product_id_5 <> :product_id_1 AND :product_id_5 <> :product_id_2 AND :product_id_5 <> :product_id_3 AND :product_id_5 <> :product_id_4 THEN 1 ELSE 0 END
\set n_distinct :distinct_1 + :distinct_2 + :distinct_3 + :distinct_4 + :distinct_5

\set order_ok 1
\set order_total 0.0

BEGIN;
-- One statement per lock fixes the acquisition order: G, then merchant.
SELECT pg_advisory_xact_lock_shared(1, 0);
SELECT pg_advisory_xact_lock(2, (:merchant_id)::int);

SELECT CASE WHEN EXISTS (
  SELECT 1
  FROM customers
  WHERE merchant_id = (:merchant_id)::bigint
    AND customer_id = (:customer_id)::bigint
) THEN 1 ELSE 0 END AS customer_ok
\gset t1_

\if :t1_customer_ok
\else
\set order_ok 0
\endif

-- Fetch all prices and reject the whole order if any distinct product is absent.
\if :order_ok
SELECT
  CASE WHEN count(*) = :n_distinct THEN 1 ELSE 0 END AS products_ok,
  COALESCE(max(CASE WHEN product_id = (:product_id_1)::bigint THEN price END), 0.00)::numeric(12,2) AS price_1,
  COALESCE(max(CASE WHEN product_id = (:product_id_2)::bigint THEN price END), 0.00)::numeric(12,2) AS price_2,
  COALESCE(max(CASE WHEN product_id = (:product_id_3)::bigint THEN price END), 0.00)::numeric(12,2) AS price_3,
  COALESCE(max(CASE WHEN product_id = (:product_id_4)::bigint THEN price END), 0.00)::numeric(12,2) AS price_4,
  COALESCE(max(CASE WHEN product_id = (:product_id_5)::bigint THEN price END), 0.00)::numeric(12,2) AS price_5
FROM products
WHERE merchant_id = (:merchant_id)::bigint
  AND product_id IN ((:product_id_1)::bigint, (:product_id_2)::bigint, (:product_id_3)::bigint, (:product_id_4)::bigint, (:product_id_5)::bigint)
\gset t1_

\if :t1_products_ok
\else
\set order_ok 0
\endif
\endif

-- Reserve every distinct inventory row once. Repeated items are debited by
-- their combined quantity, matching the success condition of sequential debits.
\if :order_ok
WITH reserved AS (
  UPDATE inventory
  SET quantity = quantity - (
        CASE WHEN inventory_id = (:product_id_1)::bigint THEN (:qty_1)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_2)::bigint THEN (:qty_2)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_3)::bigint THEN (:qty_3)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_4)::bigint THEN (:qty_4)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_5)::bigint THEN (:qty_5)::integer ELSE 0 END),
      updated_at = CURRENT_TIMESTAMP
  WHERE inventory_id IN ((:product_id_1)::bigint, (:product_id_2)::bigint, (:product_id_3)::bigint, (:product_id_4)::bigint, (:product_id_5)::bigint)
    AND merchant_id = (:merchant_id)::bigint
    AND product_id = inventory_id
    AND quantity >= (
        CASE WHEN inventory_id = (:product_id_1)::bigint THEN (:qty_1)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_2)::bigint THEN (:qty_2)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_3)::bigint THEN (:qty_3)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_4)::bigint THEN (:qty_4)::integer ELSE 0 END +
        CASE WHEN inventory_id = (:product_id_5)::bigint THEN (:qty_5)::integer ELSE 0 END)
  RETURNING 1
)
SELECT CASE WHEN count(*) = :n_distinct THEN 1 ELSE 0 END AS stock_ok
FROM reserved
\gset t1_

\if :t1_stock_ok
\else
\set order_ok 0
\endif
\endif

\if :order_ok
\if :item_count >= 1
\set order_total :order_total + (:qty_1 * :t1_price_1)
\endif
\if :item_count >= 2
\set order_total :order_total + (:qty_2 * :t1_price_2)
\endif
\if :item_count >= 3
\set order_total :order_total + (:qty_3 * :t1_price_3)
\endif
\if :item_count >= 4
\set order_total :order_total + (:qty_4 * :t1_price_4)
\endif
\if :item_count >= 5
\set order_total :order_total + (:qty_5 * :t1_price_5)
\endif

INSERT INTO orders(
  order_id, merchant_id, customer_id, order_status, total_amount, created_at
)
VALUES(
  nextval('benchmark_order_id_seq'),
  (:merchant_id)::bigint,
  (:customer_id)::bigint,
  'PENDING'::text,
  (:order_total)::numeric(12,2),
  CURRENT_TIMESTAMP
)
RETURNING order_id AS new_order_id
\gset

-- Allocate item IDs once so the canonical and denormalized rows share keys.
SELECT
  nextval('benchmark_order_item_id_seq') AS order_item_id_1,
  CASE WHEN (:item_count)::integer >= 2 THEN nextval('benchmark_order_item_id_seq') ELSE 0 END AS order_item_id_2,
  CASE WHEN (:item_count)::integer >= 3 THEN nextval('benchmark_order_item_id_seq') ELSE 0 END AS order_item_id_3,
  CASE WHEN (:item_count)::integer >= 4 THEN nextval('benchmark_order_item_id_seq') ELSE 0 END AS order_item_id_4,
  CASE WHEN (:item_count)::integer >= 5 THEN nextval('benchmark_order_item_id_seq') ELSE 0 END AS order_item_id_5
\gset t1_

-- One multi-row insert regardless of the selected item count.
\if :item_count = 1
INSERT INTO order_items(
  order_item_id, merchant_id, order_id, product_id, quantity, unit_price
)
VALUES
  ((:t1_order_item_id_1)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_1)::bigint, (:qty_1)::integer, (:t1_price_1)::numeric(12,2));
\elif :item_count = 2
INSERT INTO order_items(
  order_item_id, merchant_id, order_id, product_id, quantity, unit_price
)
VALUES
  ((:t1_order_item_id_1)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_1)::bigint, (:qty_1)::integer, (:t1_price_1)::numeric(12,2)),
  ((:t1_order_item_id_2)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_2)::bigint, (:qty_2)::integer, (:t1_price_2)::numeric(12,2));
\elif :item_count = 3
INSERT INTO order_items(
  order_item_id, merchant_id, order_id, product_id, quantity, unit_price
)
VALUES
  ((:t1_order_item_id_1)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_1)::bigint, (:qty_1)::integer, (:t1_price_1)::numeric(12,2)),
  ((:t1_order_item_id_2)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_2)::bigint, (:qty_2)::integer, (:t1_price_2)::numeric(12,2)),
  ((:t1_order_item_id_3)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_3)::bigint, (:qty_3)::integer, (:t1_price_3)::numeric(12,2));
\elif :item_count = 4
INSERT INTO order_items(
  order_item_id, merchant_id, order_id, product_id, quantity, unit_price
)
VALUES
  ((:t1_order_item_id_1)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_1)::bigint, (:qty_1)::integer, (:t1_price_1)::numeric(12,2)),
  ((:t1_order_item_id_2)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_2)::bigint, (:qty_2)::integer, (:t1_price_2)::numeric(12,2)),
  ((:t1_order_item_id_3)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_3)::bigint, (:qty_3)::integer, (:t1_price_3)::numeric(12,2)),
  ((:t1_order_item_id_4)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_4)::bigint, (:qty_4)::integer, (:t1_price_4)::numeric(12,2));
\elif :item_count = 5
INSERT INTO order_items(
  order_item_id, merchant_id, order_id, product_id, quantity, unit_price
)
VALUES
  ((:t1_order_item_id_1)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_1)::bigint, (:qty_1)::integer, (:t1_price_1)::numeric(12,2)),
  ((:t1_order_item_id_2)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_2)::bigint, (:qty_2)::integer, (:t1_price_2)::numeric(12,2)),
  ((:t1_order_item_id_3)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_3)::bigint, (:qty_3)::integer, (:t1_price_3)::numeric(12,2)),
  ((:t1_order_item_id_4)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_4)::bigint, (:qty_4)::integer, (:t1_price_4)::numeric(12,2)),
  ((:t1_order_item_id_5)::bigint, (:merchant_id)::bigint, (:new_order_id)::bigint, (:product_id_5)::bigint, (:qty_5)::integer, (:t1_price_5)::numeric(12,2));
\endif

INSERT INTO customer_order_history(
  customer_id, order_item_id, merchant_id, order_id, order_status,
  total_amount, created_at, product_id, quantity, unit_price
)
SELECT (:customer_id)::bigint, item.order_item_id, (:merchant_id)::bigint,
       (:new_order_id)::bigint, 'PENDING'::text,
       (:order_total)::numeric(12,2), CURRENT_TIMESTAMP,
       item.product_id, item.quantity, item.unit_price
FROM (VALUES
  (1, (:t1_order_item_id_1)::bigint, (:product_id_1)::bigint, (:qty_1)::integer, (:t1_price_1)::numeric(12,2)),
  (2, (:t1_order_item_id_2)::bigint, (:product_id_2)::bigint, (:qty_2)::integer, (:t1_price_2)::numeric(12,2)),
  (3, (:t1_order_item_id_3)::bigint, (:product_id_3)::bigint, (:qty_3)::integer, (:t1_price_3)::numeric(12,2)),
  (4, (:t1_order_item_id_4)::bigint, (:product_id_4)::bigint, (:qty_4)::integer, (:t1_price_4)::numeric(12,2)),
  (5, (:t1_order_item_id_5)::bigint, (:product_id_5)::bigint, (:qty_5)::integer, (:t1_price_5)::numeric(12,2))
) AS item(item_no, order_item_id, product_id, quantity, unit_price)
WHERE item.item_no <= (:item_count)::integer;
\endif

\if :order_ok
COMMIT;
\else
ROLLBACK;
\endif
