-- =====================================================================
-- 07_optimization.sql  |  Module 4 (Doreen: indexes, Eric: statistics)
--
-- ONE change at a time. After each change only the queries that change
-- is meant to help are re-measured, under the label 'stepN', so every
-- improvement can be traced to exactly one change.
-- =====================================================================

DELETE FROM toolkit.perf_results WHERE run_label LIKE 'step%' OR run_label = 'optimized';
DELETE FROM toolkit.write_cost   WHERE label <> 'baseline';

-- ---------------------------------------------------------------------
-- Step 1: index the foreign key orders.customer_id
-- Targets Q1 (customer lookup) and Q5 (join from customers to orders).
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_customer_id ON shop.orders (customer_id);
ANALYZE shop.orders;
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step1_customer_idx', 'Q1');
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step1_customer_idx', 'Q5');

-- ---------------------------------------------------------------------
-- Step 2: index the foreign key order_items.order_id
-- Targets Q5 and Q6 (orders -> order_items join).
-- ---------------------------------------------------------------------
CREATE INDEX idx_order_items_order_id ON shop.order_items (order_id);
ANALYZE shop.order_items;
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step2_items_idx', 'Q5');
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step2_items_idx', 'Q6');

-- ---------------------------------------------------------------------
-- Step 3: B-tree on order_date (range predicates)
-- Targets Q4 (one-week range) and Q6 (last 7 days).
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_order_date ON shop.orders (order_date);
ANALYZE shop.orders;
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step3_date_idx', 'Q4');
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step3_date_idx', 'Q6');
-- Regression check: Q3 (ORDER BY order_date LIMIT 50) can now walk this
-- index in date order and filter status = 'pending'. The planner assumes
-- pending rows are spread evenly through time, so it expects to stop
-- early. They are all at the END of the date range, so it reads almost
-- the whole index. Measuring Q3 here catches that.
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step3_date_idx', 'Q3');

-- ---------------------------------------------------------------------
-- Step 4a: single-column index on status (a common first guess)
-- Q2 asks for 94% of the table, so the planner should IGNORE this index.
-- Q3 can use it to find pending rows but still has to sort them.
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_status ON shop.orders (status);
ANALYZE shop.orders;
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step4a_status_idx', 'Q2');
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step4a_status_idx', 'Q3');

-- ---------------------------------------------------------------------
-- Step 4b: composite index (status, order_date)
-- Equality column first, then the ORDER BY column: rows come out of
-- the index already sorted, so Q3 reads ~50 entries and stops (no Sort).
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_status_date ON shop.orders (status, order_date);
ANALYZE shop.orders;
SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure('step4b_status_date_idx', 'Q3');

-- ---------------------------------------------------------------------
-- Step 5: extended statistics for correlated columns
-- The planner assumes ship_city and ship_state are independent and
-- multiplies their selectivities: 1/40 * 1/8 = 1/320 of the rows.
-- In reality the city implies the state, so the true fraction is 1/40.
-- CREATE STATISTICS ... (dependencies, mcv) teaches it the correlation.
-- ---------------------------------------------------------------------
CREATE STATISTICS st_orders_city_state (dependencies, mcv)
    ON ship_city, ship_state FROM shop.orders;
ANALYZE shop.orders;
SELECT query_id, median_exec_ms, root_node, max_q_error FROM toolkit.measure('step5_ext_stats', 'Q7');

DELETE FROM toolkit.estimate_checks WHERE check_label = 'after_ext_stats';
SELECT toolkit.check_estimate('after_ext_stats', 'shop.orders', p) FROM unnest(ARRAY[
    $$ship_city = 'Dallas' AND ship_state = 'TX'$$,
    $$ship_city = 'Dallas' AND ship_state = 'AZ'$$
]) p;

-- ---------------------------------------------------------------------
-- Final: VACUUM so the visibility map is set (enables index-only
-- scans), reset statistics counters, then re-run the whole workload.
-- pg_stat_reset() zeroes idx_scan / seq_scan so Module 5 (monitoring)
-- sees ONLY the optimized workload's activity.
-- ---------------------------------------------------------------------
VACUUM (ANALYZE) shop.orders;
VACUUM (ANALYZE) shop.order_items;
SELECT pg_stat_reset();

SELECT query_id, median_exec_ms, root_node, indexes_used FROM toolkit.measure_all('optimized');
SELECT toolkit.measure_write_cost('optimized') AS insert_ms_optimized;
