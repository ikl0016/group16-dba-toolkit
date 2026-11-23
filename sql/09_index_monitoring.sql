-- =====================================================================
-- 09_index_monitoring.sql  |  Module 5 (Isaac Lindsay):
-- index-usage monitoring
--
-- PostgreSQL's cumulative statistics system counts, per table and per
-- index, how often each was used:
--   pg_stat_user_tables.seq_scan  - full table scans started
--   pg_stat_user_tables.idx_scan  - index scans started on the table
--   pg_stat_user_indexes.idx_scan - times THIS index was used
-- 07_optimization.sql called pg_stat_reset() right before the final
-- optimized workload, so these counters describe only that workload
-- (plus the join experiments in 08).
--
-- An index nobody scans still costs disk space and slows every
-- INSERT/UPDATE/DELETE, so the monitoring report flags it for removal.
-- =====================================================================

-- Make sure counters from this session are visible to the views
SELECT pg_stat_force_next_flush();

-- 9.1 Table-level: sequential vs index access
CREATE OR REPLACE VIEW toolkit.v_table_access AS
SELECT relname                          AS table_name,
       seq_scan,
       seq_tup_read,
       idx_scan,
       idx_tup_fetch,
       n_live_tup,
       pg_size_pretty(pg_table_size(relid)) AS table_size
FROM pg_stat_user_tables
WHERE schemaname = 'shop'
ORDER BY relname;

-- 9.2 Index-level usage + size
CREATE OR REPLACE VIEW toolkit.v_index_usage AS
SELECT s.relname                                AS table_name,
       s.indexrelname                           AS index_name,
       s.idx_scan,
       s.idx_tup_read,
       pg_relation_size(s.indexrelid)           AS size_bytes,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       i.indisunique                            AS is_unique,
       i.indisprimary                           AS is_primary
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.schemaname = 'shop'
ORDER BY s.relname, s.indexrelname;

-- 9.3 Unused-index report: never scanned AND not enforcing a constraint
-- (PK/UNIQUE indexes guarantee correctness even if never scanned).
-- Also flags an index whose leading column is the leading column of
-- another, wider index (a "redundant prefix" candidate).
CREATE OR REPLACE VIEW toolkit.v_index_recommendations AS
WITH idx AS (
    SELECT u.*, ix.indkey::text AS keys, ix.indrelid
    FROM toolkit.v_index_usage u
    JOIN pg_class c  ON c.relname = u.index_name
    JOIN pg_index ix ON ix.indexrelid = c.oid
)
SELECT a.table_name, a.index_name, a.idx_scan, a.index_size,
       CASE
         WHEN a.is_primary OR a.is_unique THEN 'KEEP - enforces a constraint'
         WHEN a.idx_scan = 0 AND EXISTS (
              SELECT 1 FROM idx b
              WHERE b.indrelid = a.indrelid AND b.index_name <> a.index_name
                AND b.keys LIKE a.keys || ' %')
              THEN 'DROP - unused, and its column leads a wider index'
         WHEN a.idx_scan = 0 THEN 'REVIEW - not used by this workload'
         ELSE 'KEEP - used by workload'
       END AS recommendation
FROM idx a
ORDER BY a.table_name, a.index_name;

SELECT * FROM toolkit.v_table_access;
SELECT table_name, index_name, idx_scan, idx_tup_read, index_size FROM toolkit.v_index_usage;
SELECT * FROM toolkit.v_index_recommendations;

-- 9.4 Storage cost of tuning: how much disk the added indexes use
SELECT pg_size_pretty(sum(size_bytes)) AS added_index_storage,
       pg_size_pretty(pg_table_size('shop.orders') + pg_table_size('shop.order_items')) AS base_table_storage
FROM toolkit.v_index_usage
WHERE index_name LIKE 'idx_%';

-- 9.5 Snapshot the evidence into a table (exported to CSV by the runner)
DROP TABLE IF EXISTS toolkit.index_usage_snapshot;
CREATE TABLE toolkit.index_usage_snapshot AS
SELECT now() AS captured_at, r.*, u.idx_tup_read, u.size_bytes
FROM toolkit.v_index_recommendations r
JOIN toolkit.v_index_usage u USING (table_name, index_name);
