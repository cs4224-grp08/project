-- Optimizer costs for AutoPart's scan scaling factor (SR) and join cost (J):
-- key lookups and full scans of fragments of one to six attributes, alone and
-- joined in pairs, each fragment one shard of orders (5,000,000 rows / 32 shards)
BEGIN;
SET LOCAL calibration.rows_per_shard = 156250;

CREATE TEMP TABLE fragment_plan_costs(plan_shape TEXT, fragment_attributes INT[], plan_cost NUMERIC);

DO $$
DECLARE
	attribute_count INT;
	attribute_list TEXT;
BEGIN
	FOR attribute_count IN 1..6 LOOP
		SELECT string_agg(format('attribute_%s BIGINT NOT NULL', attribute), ', ')
		INTO attribute_list
		FROM generate_series(1, attribute_count) AS attribute;
		EXECUTE format('CREATE TABLE fragment_%s(order_id BIGINT, merchant_id BIGINT, %s, PRIMARY KEY(order_id, merchant_id))', attribute_count, attribute_list);
		EXECUTE format('CREATE TABLE second_fragment_%s(order_id BIGINT, merchant_id BIGINT, %s, PRIMARY KEY(order_id, merchant_id))', attribute_count, attribute_list);
	END LOOP;
END $$;

DO $$
DECLARE
	attribute_count INT;
	attribute_values TEXT;
BEGIN
	FOR attribute_count IN 1..6 LOOP
		SELECT string_agg('order_id * ' || attribute, ', ')
		INTO attribute_values
		FROM generate_series(1, attribute_count) AS attribute;
		EXECUTE format('INSERT INTO fragment_%s SELECT order_id, order_id %% 1000, %s FROM generate_series(1, %s) AS order_id',
			attribute_count, attribute_values, current_setting('calibration.rows_per_shard'));
		EXECUTE format('INSERT INTO second_fragment_%1$s SELECT * FROM fragment_%1$s', attribute_count);
		EXECUTE format('ANALYZE fragment_%1$s, second_fragment_%1$s', attribute_count);
	END LOOP;
END $$;

CREATE FUNCTION plan_cost(query TEXT) RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
	query_plan JSON;
BEGIN
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO query_plan;
	RETURN (query_plan -> 0 -> 'Plan' ->> 'Total Cost')::NUMERIC;
END $$;

DO $$
DECLARE
	first_count INT;
	second_count INT;
BEGIN
	FOR first_count IN 1..6 LOOP
		INSERT INTO fragment_plan_costs VALUES ('key lookup', ARRAY[first_count], plan_cost(format(
			'SELECT * FROM fragment_%s WHERE order_id = 42 AND merchant_id = 42', first_count)));
		INSERT INTO fragment_plan_costs VALUES ('full scan', ARRAY[first_count], plan_cost(format(
			'SELECT * FROM fragment_%s', first_count)));

		FOR second_count IN 1..(6 - first_count) LOOP
			INSERT INTO fragment_plan_costs VALUES ('key lookup', ARRAY[first_count, second_count], plan_cost(format(
				'SELECT * FROM fragment_%s AS first_fragment JOIN second_fragment_%s AS second_fragment USING (order_id, merchant_id) '
				'WHERE first_fragment.order_id = 42 AND first_fragment.merchant_id = 42', first_count, second_count)));
			INSERT INTO fragment_plan_costs VALUES ('full scan', ARRAY[first_count, second_count], plan_cost(format(
				'SELECT * FROM fragment_%s AS first_fragment JOIN second_fragment_%s AS second_fragment USING (order_id, merchant_id)',
				first_count, second_count)));
		END LOOP;
	END LOOP;
END $$;

-- Least squares for plan_cost = SR × attributes + J × (fragments − 1)
WITH observations AS (
	SELECT
		plan_shape,
		(SELECT sum(attributes) FROM unnest(fragment_attributes) AS attributes)::NUMERIC AS attributes,
		(cardinality(fragment_attributes) - 1)::NUMERIC AS joins,
		plan_cost
	FROM fragment_plan_costs
), sums AS (
	SELECT
		plan_shape,
		sum(attributes * attributes) AS attributes_attributes,
		sum(attributes * joins) AS attributes_joins,
		sum(joins * joins) AS joins_joins,
		sum(attributes * plan_cost) AS attributes_cost,
		sum(joins * plan_cost) AS joins_cost
	FROM observations
	GROUP BY plan_shape
), fit AS (
	SELECT
		plan_shape,
		(attributes_cost * joins_joins - joins_cost * attributes_joins) / (attributes_attributes * joins_joins - attributes_joins ^ 2) AS scan_scaling_factor,
		(joins_cost * attributes_attributes - attributes_cost * attributes_joins) / (attributes_attributes * joins_joins - attributes_joins ^ 2) AS fragment_join_cost
	FROM sums
)
SELECT
	plan_shape,
	round(scan_scaling_factor, 4) AS scan_scaling_factor,
	round(fragment_join_cost, 4) AS fragment_join_cost,
	round(fragment_join_cost / scan_scaling_factor, 2) AS join_cost_in_attribute_scans
FROM fit
ORDER BY plan_shape;

SELECT plan_shape, fragment_attributes, plan_cost FROM fragment_plan_costs ORDER BY plan_shape, cardinality(fragment_attributes), fragment_attributes;

ROLLBACK;
