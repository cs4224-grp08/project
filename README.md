
expt_a0 - performance of baseline design as a function of number of clients for workload A

expt_b0 - performance of baseline design as a function of number of clients for workload B

Locked experiment variants

- `expt_a6_locked`, `expt_a7_locked`, and `expt_a8_locked`: locked copies of
  the corresponding workload-A query variants.
- `expt_b7_locked` and `expt_b8_locked`: locked copies of the corresponding
  workload-B query variants.
- `expt_a9_locked` and `expt_b9_locked`: locked A/B variants based on
  `expt_a6_locked`/`expt_b7_locked`, with a customer-keyed denormalized
  `customer_order_history` projection for T3. T1 maintains new projection rows
  and T5 propagates status changes.
- `expt_a10_locked` and `expt_b10_locked`: canonical merge of `products` and
  `inventory` into `product_inventory`. The merged table is distributed by
  `merchant_id` and uses `(merchant_id, product_id)` as its primary lookup
  index; the workload no longer creates or reads separate product/inventory
  tables.
- `expt_a11_locked` and `expt_b11_locked`: workload-A/B vertical partitions of
  the merged product data.
  Frequently accessed and updated fields (`price`, `quantity`, and
  `updated_at`) live in `product_stock`, while descriptive fields
  (`product_name` and `category`) live in `product_catalog`. Both tables are
  distributed and colocated by `merchant_id`; T1/T2/T7/T9 access only the hot
  stock table and T4 performs a colocated join.

The original experiment folders are unchanged.

The lock key `(2, m)` represents all data for merchant `m`. Read-only
merchant transactions take it shared; merchant writers take it exclusive and
hold it through commit. T1 additionally takes shared `(1, 0)` (`G`). T6 takes
`G` exclusively while opening a `REPEATABLE READ` snapshot on each worker, then
releases it before running the global report. All other data statements default
to `READ COMMITTED`, so a statement run after a lock wait sees its committed
predecessor.

