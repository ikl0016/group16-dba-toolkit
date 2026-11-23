-- =====================================================================
-- 03_toolkit.sql  |  Measurement harness (shared by all modules;
-- maintained by Isaac Lindsay as part of integration/validation).
--
-- toolkit.measure(label, query_id) runs one workload query several
-- times under EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) and stores:
--   median / min / max execution time, planning time, every plan node
--   type, indexes used, estimated vs actual rows, the worst
--   estimate error ("q-error") of any node, shared buffer hits/reads,
--   an md5 of the result set (to prove tuning did not change answers)
--   and the full text plan as evidence.
--
-- Why median of warm runs?  The first run may read pages from disk;
-- later runs hit shared_buffers. Discarding one warm-up run and taking
-- the median of the rest removes most caching noise. Buffer counts are
-- reported too because they are far less noisy than milliseconds.
-- =====================================================================

DROP SCHEMA IF EXISTS toolkit CASCADE;
CREATE SCHEMA toolkit;

-- The workload: every query the project measures, with fixed parameters.
CREATE TABLE toolkit.workload (
    query_id     text PRIMARY KEY,
    category     text NOT NULL,
    description  text NOT NULL,
    sql          text NOT NULL,
    owner        text NOT NULL
);

CREATE TABLE toolkit.perf_results (
    run_id          serial PRIMARY KEY,
    run_label       text        NOT NULL,   -- 'baseline', 'step1', 'optimized', ...
    query_id        text        NOT NULL REFERENCES toolkit.workload,
    settings        jsonb       NOT NULL DEFAULT '{}',
    measured_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    runs            int         NOT NULL,
    median_exec_ms  numeric(12,3),
    min_exec_ms     numeric(12,3),
    max_exec_ms     numeric(12,3),
    planning_ms     numeric(12,3),
    root_node       text,
    node_types      text[],
    indexes_used    text[],
    est_rows        numeric,
    actual_rows     numeric,
    max_q_error     numeric(14,2),
    shared_hit      bigint,
    shared_read     bigint,
    result_rows     bigint,
    result_md5      text,
    plan_json       jsonb,
    plan_text       text
);

-- ---------------------------------------------------------------------
-- Helper: run any SQL and return md5 + row count of its result set.
-- Rows are sorted by their text form so physical order does not matter.
-- ---------------------------------------------------------------------
CREATE FUNCTION toolkit.result_fingerprint(p_sql text,
                                           OUT md5 text, OUT n bigint)
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format(
      'SELECT md5(coalesce(string_agg(t::text, %L ORDER BY t::text), %L)), count(*)
         FROM (%s) t', '|', '', p_sql)
    INTO md5, n;
END $$;

-- ---------------------------------------------------------------------
-- Main measurement function.
--   p_settings: planner settings applied for this measurement only,
--   e.g. '{"enable_hashjoin":"off"}'  (used by the join experiments).
--   set_config(..., true) = transaction-local, so nothing leaks.
-- ---------------------------------------------------------------------
CREATE FUNCTION toolkit.measure(p_label    text,
                                p_query_id text,
                                p_runs     int   DEFAULT 5,
                                p_settings jsonb DEFAULT '{}')
RETURNS toolkit.perf_results
LANGUAGE plpgsql AS $$
DECLARE
    v_sql    text;
    v_plan   jsonb;
    v_times  numeric[] := '{}';
    v_text   text := '';
    v_line   text;
    v_key    text;
    v_val    text;
    v_fp     record;
    r        toolkit.perf_results;
BEGIN
    SELECT sql INTO STRICT v_sql FROM toolkit.workload WHERE query_id = p_query_id;

    FOR v_key, v_val IN SELECT * FROM jsonb_each_text(p_settings) LOOP
        PERFORM set_config(v_key, v_val, true);
    END LOOP;

    -- warm-up run (discarded)
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || v_sql INTO v_plan;

    FOR i IN 1..p_runs LOOP
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || v_sql INTO v_plan;
        v_times := v_times || (v_plan->0->>'Execution Time')::numeric;
    END LOOP;

    -- human-readable plan of one more run, kept as evidence
    FOR v_line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) ' || v_sql LOOP
        v_text := v_text || v_line || E'\n';
    END LOOP;

    v_fp := toolkit.result_fingerprint(v_sql);

    r.run_label      := p_label;
    r.query_id       := p_query_id;
    r.settings       := p_settings;
    r.runs           := p_runs;
    r.median_exec_ms := (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t) FROM unnest(v_times) t);
    r.min_exec_ms    := (SELECT min(t) FROM unnest(v_times) t);
    r.max_exec_ms    := (SELECT max(t) FROM unnest(v_times) t);
    r.planning_ms    := (v_plan->0->>'Planning Time')::numeric;
    r.root_node      := v_plan->0->'Plan'->>'Node Type';
    r.est_rows       := (v_plan->0->'Plan'->>'Plan Rows')::numeric;
    r.actual_rows    := (v_plan->0->'Plan'->>'Actual Rows')::numeric;
    r.shared_hit     := (v_plan->0->'Plan'->>'Shared Hit Blocks')::bigint;
    r.shared_read    := (v_plan->0->'Plan'->>'Shared Read Blocks')::bigint;
    r.result_md5     := v_fp.md5;
    r.result_rows    := v_fp.n;
    r.plan_json      := v_plan;
    r.plan_text      := v_text;

    -- every node in the tree ($.** walks the whole JSON plan)
    SELECT array_agg(DISTINCT n->>'Node Type'),
           array_agg(DISTINCT n->>'Index Name') FILTER (WHERE n ? 'Index Name'),
           -- q-error = max(est/actual, actual/est); 1.0 = perfect estimate.
           -- Nodes that never executed (loops = 0) are skipped.
           max(greatest(greatest((n->>'Plan Rows')::numeric,1) / greatest((n->>'Actual Rows')::numeric,1),
                        greatest((n->>'Actual Rows')::numeric,1) / greatest((n->>'Plan Rows')::numeric,1)))
             FILTER (WHERE (n->>'Actual Loops')::numeric > 0)
    INTO r.node_types, r.indexes_used, r.max_q_error
    FROM jsonb_path_query(v_plan, 'lax $.**') n
    WHERE jsonb_typeof(n) = 'object' AND n ? 'Node Type';

    INSERT INTO toolkit.perf_results
        (run_label, query_id, settings, runs, median_exec_ms, min_exec_ms, max_exec_ms,
         planning_ms, root_node, node_types, indexes_used, est_rows, actual_rows,
         max_q_error, shared_hit, shared_read, result_rows, result_md5, plan_json, plan_text)
    VALUES
        (r.run_label, r.query_id, r.settings, r.runs, r.median_exec_ms, r.min_exec_ms, r.max_exec_ms,
         r.planning_ms, r.root_node, r.node_types, r.indexes_used, r.est_rows, r.actual_rows,
         r.max_q_error, r.shared_hit, r.shared_read, r.result_rows, r.result_md5, r.plan_json, r.plan_text)
    RETURNING * INTO r;
    RETURN r;
END $$;

-- Measure every workload query under one label.
CREATE FUNCTION toolkit.measure_all(p_label text, p_runs int DEFAULT 5)
RETURNS SETOF toolkit.perf_results
LANGUAGE plpgsql AS $$
DECLARE q record;
BEGIN
    FOR q IN SELECT query_id FROM toolkit.workload ORDER BY query_id LOOP
        RETURN NEXT toolkit.measure(p_label, q.query_id, p_runs);
    END LOOP;
END $$;

-- Short summary view of results (what the demo shows on screen).
CREATE VIEW toolkit.v_results AS
SELECT run_label, query_id, settings::text AS settings, median_exec_ms,
       root_node, array_to_string(indexes_used, ', ') AS indexes_used,
       est_rows, actual_rows, max_q_error,
       shared_hit + shared_read AS buffers_total, result_rows
FROM toolkit.perf_results
ORDER BY run_id;

-- Write-cost probe: how long does inserting N new orders + items take?
-- Every extra index must be updated on INSERT, so this measures the
-- maintenance cost of tuning. Runs inside a transaction then rolls back
-- by raising/catching an exception (data is left unchanged).
CREATE TABLE toolkit.write_cost (
    label        text,
    rows_written int,
    elapsed_ms   numeric(12,3),
    index_count  int,
    measured_at  timestamptz DEFAULT clock_timestamp()
);

CREATE FUNCTION toolkit.measure_write_cost(p_label text, p_orders int DEFAULT 20000)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; v_ms numeric; v_idx int; v_rows int;
BEGIN
    SELECT count(*) INTO v_idx FROM pg_indexes
    WHERE schemaname = 'shop' AND tablename IN ('orders','order_items');
    BEGIN
        t0 := clock_timestamp();
        WITH new_orders AS (
            INSERT INTO shop.orders (customer_id, order_date, status, ship_city, ship_state, total_amount)
            SELECT 1 + (g % 100000), timestamp '2026-10-31' + g * interval '1 second',
                   'pending', 'Dallas', 'TX', 50
            FROM generate_series(1, p_orders) g
            RETURNING order_id)
        INSERT INTO shop.order_items (order_id, product_id, quantity, unit_price)
        SELECT order_id, 1 + (order_id % 5000)::int, 1, 10 FROM new_orders, generate_series(1,3);
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
        RAISE EXCEPTION 'rollback_probe';
    EXCEPTION WHEN raise_exception THEN
        NULL;  -- inner block rolled back; measurement kept in v_ms
    END;
    INSERT INTO toolkit.write_cost VALUES (p_label, p_orders + v_rows, v_ms, v_idx);
    RETURN v_ms;
END $$;
