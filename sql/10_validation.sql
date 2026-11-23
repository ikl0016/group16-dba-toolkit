-- =====================================================================
-- 10_validation.sql  |  Module 5 (Isaac Lindsay): tuning validation and
-- integration tests
--
-- Every claim the report makes is checked here automatically and gets
-- a PASS/FAIL row in toolkit.test_results. If a tuning change ever
-- broke correctness or stopped helping, a test would FAIL.
-- =====================================================================

DROP TABLE IF EXISTS toolkit.test_results;
CREATE TABLE toolkit.test_results (
    test_id   text PRIMARY KEY,
    module    text,
    test_name text,
    expected  text,
    actual    text,
    status    text CHECK (status IN ('PASS','FAIL'))
);

CREATE OR REPLACE FUNCTION toolkit.record_test(p_id text, p_module text, p_name text,
                                               p_expected text, p_actual text, p_pass boolean)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO toolkit.test_results
    VALUES (p_id, p_module, p_name, p_expected, p_actual,
            CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END);
$$;

-- Latest measurement per (label, query) for comparisons
CREATE OR REPLACE VIEW toolkit.v_latest AS
SELECT DISTINCT ON (run_label, query_id) *
FROM toolkit.perf_results
ORDER BY run_label, query_id, run_id DESC;

-- Baseline vs optimized side by side (exported to results/perf_comparison.csv)
CREATE OR REPLACE VIEW toolkit.v_comparison AS
SELECT b.query_id,
       w.category,
       b.median_exec_ms                                  AS baseline_ms,
       o.median_exec_ms                                  AS optimized_ms,
       round(b.median_exec_ms / nullif(o.median_exec_ms,0), 1) AS speedup_x,
       b.shared_hit + b.shared_read                      AS baseline_buffers,
       o.shared_hit + o.shared_read                      AS optimized_buffers,
       array_to_string(ARRAY(SELECT n FROM unnest(b.node_types) n WHERE n ~ 'Scan' ORDER BY 1), ', ') AS baseline_scans,
       array_to_string(ARRAY(SELECT n FROM unnest(o.node_types) n WHERE n ~ 'Scan' ORDER BY 1), ', ') AS optimized_scans,
       coalesce(array_to_string(o.indexes_used, ', '), '')  AS optimized_indexes,
       b.max_q_error                                     AS baseline_q_error,
       o.max_q_error                                     AS optimized_q_error,
       b.result_md5 = o.result_md5                       AS same_result
FROM toolkit.v_latest b
JOIN toolkit.v_latest o ON o.query_id = b.query_id AND o.run_label = 'optimized'
JOIN toolkit.workload w ON w.query_id = b.query_id
WHERE b.run_label = 'baseline'
ORDER BY b.query_id;

-- ---------------- T01-T07: correctness (same answers) ----------------
SELECT toolkit.record_test('T0' || substr(query_id,2), 'Integration',
       query_id || ' returns identical result set after tuning',
       'baseline md5 = optimized md5',
       CASE WHEN same_result THEN 'identical' ELSE 'DIFFERENT' END,
       same_result)
FROM toolkit.v_comparison;

-- ---------------- T08: each targeted query uses its new index ----------
SELECT toolkit.record_test('T08', 'Tuning validation',
       'Q1/Q3/Q4/Q5/Q6 use the index built for them',
       'Q1 customer_id, Q3 status_date, Q4 order_date, Q5 customer_id+order_id, Q6 order_date+order_id',
       string_agg(query_id || '=' || optimized_indexes, '; ' ORDER BY query_id),
       bool_and(CASE query_id
           WHEN 'Q1' THEN optimized_indexes LIKE '%idx_orders_customer_id%'
           WHEN 'Q3' THEN optimized_indexes LIKE '%idx_orders_status_date%'
           WHEN 'Q4' THEN optimized_indexes LIKE '%idx_orders_order_date%'
           WHEN 'Q5' THEN optimized_indexes LIKE '%idx_orders_customer_id%'
                      AND optimized_indexes LIKE '%idx_order_items_order_id%'
           WHEN 'Q6' THEN optimized_indexes LIKE '%idx_orders_order_date%'
                      AND optimized_indexes LIKE '%idx_order_items_order_id%' END))
FROM toolkit.v_comparison WHERE query_id IN ('Q1','Q3','Q4','Q5','Q6');

-- ---------------- T09: speedup threshold ------------------------------
SELECT toolkit.record_test('T09', 'Tuning validation',
       'Targeted queries are at least 2x faster (median of 5 warm runs)',
       'speedup >= 2.0 for Q1, Q3, Q4, Q5, Q6',
       string_agg(query_id || '=' || speedup_x || 'x', ', ' ORDER BY query_id),
       bool_and(speedup_x >= 2.0))
FROM toolkit.v_comparison WHERE query_id IN ('Q1','Q3','Q4','Q5','Q6');

-- ---------------- T10: buffers reduced --------------------------------
SELECT toolkit.record_test('T10', 'Tuning validation',
       'Targeted queries read fewer buffers (less I/O work)',
       'optimized_buffers < baseline_buffers',
       string_agg(query_id || ': ' || baseline_buffers || '->' || optimized_buffers, ', ' ORDER BY query_id),
       bool_and(optimized_buffers < baseline_buffers))
FROM toolkit.v_comparison WHERE query_id IN ('Q1','Q3','Q4','Q5','Q6');

-- ---------------- T11: broad filter stays a sequential scan -----------
SELECT toolkit.record_test('T11', 'Planner behavior',
       'Q2 (94% of rows) still uses a sequential scan although idx_orders_status exists',
       'Seq Scan, no index used',
       optimized_scans || ' / indexes: ' || coalesce(nullif(optimized_indexes,''),'none'),
       optimized_scans ~ 'Seq Scan' AND optimized_indexes = '')
FROM toolkit.v_comparison WHERE query_id = 'Q2';

-- ---------------- T12: extended statistics fix the estimate -----------
SELECT toolkit.record_test('T12', 'Statistics',
       'Extended statistics fix the Dallas/TX row estimate',
       'q-error before > 5, after < 1.5',
       'before ' || b.q_error || ', after ' || a.q_error,
       b.q_error > 5 AND a.q_error < 1.5)
FROM toolkit.estimate_checks b, toolkit.estimate_checks a
WHERE b.check_label = 'before_ext_stats' AND a.check_label = 'after_ext_stats'
  AND b.predicate = $$ship_city = 'Dallas' AND ship_state = 'TX'$$
  AND a.predicate = b.predicate;

-- ---------------- T13: stale statistics detected and repaired ---------
SELECT toolkit.record_test('T13', 'Statistics',
       'ANALYZE repairs stale estimates after a 150k-row bulk insert',
       'q-error stale > 10, after ANALYZE < 1.5',
       'stale ' || s.q_error || ', after ANALYZE ' || a.q_error,
       s.q_error > 10 AND a.q_error < 1.5)
FROM toolkit.estimate_checks s, toolkit.estimate_checks a
WHERE s.check_label = 'stale_2_after_bulk_insert' AND a.check_label = 'stale_3_after_analyze';

-- ---------------- T14: Q3 regression caught by step-wise testing ------
SELECT toolkit.record_test('T14', 'Tuning validation',
       'Step-wise testing exposes the Q3 regression from idx_orders_order_date and step 4b fixes it',
       'step3 Q3 slower than baseline; step4b Q3 faster than baseline',
       'baseline ' || b.median_exec_ms || ' ms, step3 ' || s3.median_exec_ms || ' ms, step4b ' || s4.median_exec_ms || ' ms',
       s3.median_exec_ms > b.median_exec_ms AND s4.median_exec_ms < b.median_exec_ms)
FROM toolkit.v_latest b, toolkit.v_latest s3, toolkit.v_latest s4
WHERE b.run_label = 'baseline' AND b.query_id = 'Q3'
  AND s3.run_label = 'step3_date_idx' AND s3.query_id = 'Q3'
  AND s4.run_label = 'step4b_status_date_idx' AND s4.query_id = 'Q3';

-- ---------------- T15: unused index detected by monitoring ------------
SELECT toolkit.record_test('T15', 'Monitoring',
       'Monitoring flags idx_orders_status as unused/redundant',
       'idx_scan = 0 and recommendation DROP',
       coalesce((SELECT 'idx_scan=' || idx_scan || ', ' || recommendation
                 FROM toolkit.index_usage_snapshot WHERE index_name = 'idx_orders_status'), 'not found'),
       EXISTS (SELECT 1 FROM toolkit.index_usage_snapshot
               WHERE index_name = 'idx_orders_status' AND idx_scan = 0
                 AND recommendation LIKE 'DROP%'));

-- ---------------- T16-T17: integrity constraints still enforced -------
DO $$
BEGIN
    BEGIN
        INSERT INTO shop.orders (customer_id, order_date, status, ship_city, ship_state)
        VALUES (1, '2026-10-31', 'lost_in_space', 'Dallas', 'TX');
        PERFORM toolkit.record_test('T16','Integration','CHECK rejects invalid status',
                                    'insert rejected','insert ACCEPTED', false);
    EXCEPTION WHEN check_violation THEN
        PERFORM toolkit.record_test('T16','Integration','CHECK rejects invalid status',
                                    'insert rejected','rejected (check_violation)', true);
    END;
    BEGIN
        INSERT INTO shop.order_items (order_id, product_id, quantity, unit_price)
        VALUES (99999999, 1, 1, 10);
        PERFORM toolkit.record_test('T17','Integration','FOREIGN KEY rejects orphan order item',
                                    'insert rejected','insert ACCEPTED', false);
    EXCEPTION WHEN foreign_key_violation THEN
        PERFORM toolkit.record_test('T17','Integration','FOREIGN KEY rejects orphan order item',
                                    'insert rejected','rejected (foreign_key_violation)', true);
    END;
END $$;

-- ---------------- T18: data volume as designed -------------------------
SELECT toolkit.record_test('T18', 'Integration',
       'Dataset has the designed volume',
       'customers=100000, products=5000, orders=1000000, order_items=3000000',
       format('customers=%s, products=%s, orders=%s, order_items=%s',
              (SELECT count(*) FROM shop.customers), (SELECT count(*) FROM shop.products),
              (SELECT count(*) FROM shop.orders),    (SELECT count(*) FROM shop.order_items)),
       (SELECT count(*) FROM shop.customers) = 100000 AND (SELECT count(*) FROM shop.products) = 5000
       AND (SELECT count(*) FROM shop.orders) = 1000000 AND (SELECT count(*) FROM shop.order_items) = 3000000);

-- ---------------- Action from monitoring: drop the unused index -------
DROP INDEX IF EXISTS shop.idx_orders_status;
SELECT query_id, median_exec_ms, indexes_used FROM toolkit.measure('after_drop_unused', 'Q3');
SELECT toolkit.record_test('T19', 'Monitoring',
       'Unused index removed and Q3 still uses the composite index',
       'idx_orders_status gone; Q3 plan uses idx_orders_status_date',
       (SELECT coalesce(array_to_string(indexes_used, ', '), 'none') FROM toolkit.v_latest
         WHERE run_label='after_drop_unused' AND query_id='Q3'),
       NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_orders_status')
       AND (SELECT indexes_used FROM toolkit.v_latest WHERE run_label='after_drop_unused' AND query_id='Q3')
           @> ARRAY['idx_orders_status_date']);

SELECT test_id, module, test_name, actual, status FROM toolkit.test_results ORDER BY test_id;
SELECT count(*) FILTER (WHERE status='PASS') AS passed, count(*) AS total FROM toolkit.test_results;

SELECT * FROM toolkit.v_comparison;
