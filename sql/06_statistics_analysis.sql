-- =====================================================================
-- 06_statistics_analysis.sql  |  Module 3 (Eric Whisenhunt):
-- planner statistics, selectivity and cardinality estimation
--
-- The planner never counts rows when it plans. It estimates them from
-- the statistics ANALYZE stores in pg_statistic (readable through the
-- pg_stats view). Bad estimates -> bad plan choices. This module
-- measures how good those estimates are.
-- =====================================================================

-- Planner estimate for any SQL (EXPLAIN without ANALYZE = no execution)
CREATE OR REPLACE FUNCTION toolkit.estimated_rows(p_sql text) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || p_sql INTO v;
    RETURN (v->0->'Plan'->>'Plan Rows')::numeric;
END $$;

CREATE OR REPLACE FUNCTION toolkit.actual_rows(p_sql text) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE n numeric;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') t' INTO n;
    RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- 6.1  What ANALYZE learned about the orders table
-- ---------------------------------------------------------------------
SELECT attname,
       n_distinct,                                   -- negative = fraction of rows
       round(correlation::numeric, 3) AS correlation, -- 1.0 = physical order matches value order
       (most_common_vals::text::text[])[1:4]   AS top_values,
       (most_common_freqs)[1:4]                AS top_freqs
FROM pg_stats
WHERE schemaname = 'shop' AND tablename = 'orders'
  AND attname IN ('customer_id','order_date','status','ship_city','ship_state')
ORDER BY attname;

-- ---------------------------------------------------------------------
-- 6.2  Estimate accuracy for single-column and combined predicates
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS toolkit.estimate_checks (
    check_label text, predicate text, estimated numeric, actual numeric,
    q_error numeric(12,2), measured_at timestamptz DEFAULT clock_timestamp());

CREATE OR REPLACE FUNCTION toolkit.check_estimate(p_label text, p_table text, p_predicate text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE e numeric; a numeric; s text;
BEGIN
    s := format('SELECT * FROM %s WHERE %s', p_table, p_predicate);
    e := toolkit.estimated_rows(s);
    a := toolkit.actual_rows(s);
    INSERT INTO toolkit.estimate_checks (check_label, predicate, estimated, actual, q_error)
    VALUES (p_label, p_predicate, e, a,
            greatest(greatest(e,1)/greatest(a,1), greatest(a,1)/greatest(e,1)));
END $$;

DELETE FROM toolkit.estimate_checks WHERE check_label IN ('before_ext_stats');
SELECT toolkit.check_estimate('before_ext_stats', 'shop.orders', p) FROM unnest(ARRAY[
    $$status = 'delivered'$$,
    $$status = 'pending'$$,
    $$status = 'cancelled'$$,
    $$customer_id = 4242$$,
    $$order_date >= '2026-10-01' AND order_date < '2026-10-08'$$,
    $$ship_city = 'Dallas'$$,
    $$ship_state = 'TX'$$,
    $$ship_city = 'Dallas' AND ship_state = 'TX'$$,
    $$ship_city = 'Dallas' AND ship_state = 'AZ'$$
]) p;

SELECT predicate, estimated, actual, q_error
FROM toolkit.estimate_checks WHERE check_label = 'before_ext_stats' ORDER BY measured_at;

-- ---------------------------------------------------------------------
-- 6.3  Stale-statistics experiment (on a scratch copy of orders)
--
-- Scenario: a warehouse outage creates a backlog of 150,000 pending
-- orders. Autovacuum is disabled on the copy, so statistics stay stale
-- until we run ANALYZE ourselves.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS shop.orders_stats_lab;
CREATE TABLE shop.orders_stats_lab (LIKE shop.orders INCLUDING DEFAULTS)
    WITH (autovacuum_enabled = false);
INSERT INTO shop.orders_stats_lab SELECT * FROM shop.orders;
CREATE INDEX ON shop.orders_stats_lab (status);
ANALYZE shop.orders_stats_lab;

DELETE FROM toolkit.estimate_checks WHERE check_label LIKE 'stale_%';
SELECT toolkit.check_estimate('stale_1_fresh_stats', 'shop.orders_stats_lab', $$status = 'pending'$$);

INSERT INTO shop.orders_stats_lab (order_id, customer_id, order_date, status, ship_city, ship_state, total_amount)
SELECT 2000000 + g, 1 + (g % 100000), timestamp '2026-10-31' + g * interval '1 second',
       'pending', 'Dallas', 'TX', 25
FROM generate_series(1,150000) g;

SELECT toolkit.check_estimate('stale_2_after_bulk_insert', 'shop.orders_stats_lab', $$status = 'pending'$$);

-- Plan chosen while statistics are stale (saved for the report).
-- A join is used because the estimate decides the JOIN METHOD:
-- ~3,000 expected rows -> nested loop with 3,000 index probes looks cheap.
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.loyalty_tier, count(*), sum(o.total_amount)
FROM shop.orders_stats_lab o JOIN shop.customers c ON c.customer_id = o.customer_id
WHERE o.status = 'pending' GROUP BY c.loyalty_tier;

ANALYZE shop.orders_stats_lab;
SELECT toolkit.check_estimate('stale_3_after_analyze', 'shop.orders_stats_lab', $$status = 'pending'$$);

EXPLAIN (ANALYZE, BUFFERS)
SELECT c.loyalty_tier, count(*), sum(o.total_amount)
FROM shop.orders_stats_lab o JOIN shop.customers c ON c.customer_id = o.customer_id
WHERE o.status = 'pending' GROUP BY c.loyalty_tier;

SELECT check_label, estimated, actual, q_error
FROM toolkit.estimate_checks WHERE check_label LIKE 'stale_%' ORDER BY check_label;

DROP TABLE shop.orders_stats_lab;
