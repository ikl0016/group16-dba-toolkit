-- =====================================================================
-- 05_baseline.sql  |  Module 2 (Doreen Lobe): capture the baseline
--
-- Only PK/UNIQUE indexes exist at this point. Every workload query is
-- measured (1 warm-up + 5 measured runs) and the write cost of a
-- 20,000-order insert batch is recorded for later comparison.
-- =====================================================================

DELETE FROM toolkit.perf_results WHERE run_label = 'baseline';
DELETE FROM toolkit.write_cost   WHERE label = 'baseline';

SELECT query_id, median_exec_ms, root_node, shared_hit + shared_read AS buffers
FROM toolkit.measure_all('baseline');

SELECT toolkit.measure_write_cost('baseline') AS insert_ms_baseline;

-- Indexes that exist at baseline (only the automatic ones)
SELECT tablename, indexname, indexdef
FROM pg_indexes WHERE schemaname = 'shop' ORDER BY tablename, indexname;
