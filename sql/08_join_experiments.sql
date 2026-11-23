-- =====================================================================
-- 08_join_experiments.sql  |  Module 3 (Eric Whisenhunt): join methods
--
-- PostgreSQL has three join algorithms:
--   Nested Loop  - for each outer row, probe the inner side (great when
--                  the outer side is small and the inner side indexed)
--   Hash Join    - build a hash table on one side, scan the other
--                  (great for large unsorted inputs)
--   Merge Join   - walk two inputs sorted on the join key
-- The planner picks by estimated cost. Here we DISABLE the chosen
-- method with enable_* settings (transaction-local, inside
-- toolkit.measure) to see what the alternatives would have cost.
-- enable_* = off does not forbid a method; it adds a huge cost penalty,
-- so the planner only uses it when nothing else is possible.
-- =====================================================================

DELETE FROM toolkit.perf_results WHERE run_label LIKE 'join_%';

-- Q5: selective 4-table join (one customer)
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_planner_choice', 'Q5', 5, '{}');
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_force_hash',  'Q5', 5,
       '{"enable_nestloop":"off","enable_mergejoin":"off"}');
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_force_merge', 'Q5', 5,
       '{"enable_nestloop":"off","enable_hashjoin":"off"}');

-- Q6: join + aggregation over a 7-day window (4,445 orders, 13,345 items)
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_planner_choice', 'Q6', 5, '{}');
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_force_hash',  'Q6', 5,
       '{"enable_nestloop":"off","enable_mergejoin":"off"}');
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_force_merge', 'Q6', 5,
       '{"enable_nestloop":"off","enable_hashjoin":"off"}');
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_force_nestloop', 'Q6', 5,
       '{"enable_hashjoin":"off","enable_mergejoin":"off"}');

-- Join order: with join_collapse_limit = 1 the planner must join in the
-- order the query is written instead of searching for the best order.
SELECT query_id, median_exec_ms, node_types FROM toolkit.measure('join_fixed_order', 'Q5', 5,
       '{"join_collapse_limit":"1"}');

SELECT run_label, query_id, median_exec_ms,
       array_to_string(ARRAY(SELECT n FROM unnest(node_types) n WHERE n ~ 'Join|Nested'
                             ORDER BY 1), ', ') AS join_nodes
FROM toolkit.perf_results WHERE run_label LIKE 'join_%' ORDER BY query_id, run_id;
