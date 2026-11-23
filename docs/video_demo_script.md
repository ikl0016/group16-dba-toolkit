# Recorded Demonstration Script – Group 16

Target length: 12–15 minutes. Record screen + narration (OBS, Zoom, or Teams recording). Every member narrates and drives the screen for their own part. Upload as **Unlisted** on YouTube and test the link in an incognito window before submitting.

**Before recording:** run `./scripts/run_all.sh` once so the database and `results/` exist. Open psql: `psql -d dba_toolkit`, turn on `\timing on`, and enlarge the terminal font.

Numbers below come from the reference run. Yours will differ a little; read your own off the screen.

---

## 1. Introduction – Isaac (≈1 min)

- "We're Group 16: Doreen Lobe, Eric Whisenhunt and Isaac Lindsay. Our project is a PostgreSQL query-optimization toolkit."
- Problem: as tables grow, queries slow down because of missing indexes, stale statistics, poor estimates and bad join choices. We built a repeatable way to diagnose that with execution-plan evidence and to prove each fix works.
- Show the GitHub repo page and folder structure briefly.

## 2. Architecture – Isaac (≈1 min)

- Show the architecture figure from the report: workload scripts → PostgreSQL database → measurement harness (EXPLAIN ANALYZE, pg_stats, pg_stat_user_indexes) → tuning steps → validation and results.
- Name each module and its owner.

## 3. Database and baseline – Doreen (≈3 min)

```sql
\dt shop.*
SELECT 'orders', count(*) FROM shop.orders UNION ALL SELECT 'order_items', count(*) FROM shop.order_items;
\i sql/99_reset_to_baseline.sql         -- removes all tuning indexes
SELECT query_id, description FROM toolkit.workload;
```

- Explain that PostgreSQL indexes primary keys and UNIQUE columns automatically but **not foreign keys**.
- Run Q5 live (copy it from `sql/04_workload.sql`) with `EXPLAIN (ANALYZE, BUFFERS)`. Point at: Parallel Seq Scan on `order_items`, Rows Removed by Filter, ~32,000 buffers, ~270 ms.

## 4. Indexing fix – Doreen (≈2 min)

```sql
CREATE INDEX idx_orders_customer_id   ON shop.orders (customer_id);
CREATE INDEX idx_order_items_order_id ON shop.order_items (order_id);
ANALYZE shop.orders; ANALYZE shop.order_items;
```

- Re-run Q5: now Nested Loop + index scans, ~127 buffers, ~0.1 ms. Same 25 rows returned.
- Mention Q3: show `results/plans/step3_date_idx/Q3.txt` (487 ms, 990,666 rows removed by filter) and then `step4b_status_date_idx/Q3.txt` (0.02 ms). Explain: one change at a time caught a regression.

## 5. Statistics and joins – Eric (≈3 min)

```sql
SELECT attname, n_distinct, correlation, most_common_vals
FROM pg_stats WHERE tablename = 'orders' AND attname IN ('status','ship_city','ship_state');
SELECT * FROM toolkit.estimate_checks ORDER BY measured_at;
```

- Correlated columns: Dallas AND TX estimated 3,192 rows, actual 25,222 (planner multiplies 1/40 × 1/8). After `CREATE STATISTICS st_orders_city_state (dependencies, mcv)`: estimated 24,900.
- Stale statistics: 150k pending orders inserted, estimate stayed ~3,000 (q-error 51) until `ANALYZE`; plan switched from a serial hash join to a parallel plan (101 ms → 79 ms in the reference run, see `results/logs/06_statistics_analysis.log`).
- Join methods: `SELECT run_label, query_id, median_exec_ms FROM toolkit.perf_results WHERE run_label LIKE 'join_%';` – Q5 nested loop 0.17 ms vs forced hash 279 ms vs forced merge 355 ms.

## 6. Monitoring and validation – Isaac (≈3 min)

```sql
SELECT * FROM toolkit.v_table_access;
SELECT * FROM toolkit.v_index_recommendations;
SELECT * FROM toolkit.v_comparison;
SELECT test_id, test_name, status FROM toolkit.test_results ORDER BY test_id;
```

- Point out `idx_orders_status`: idx_scan = 0, recommendation DROP (its column already leads the composite index). It was dropped and Q3 still uses the composite index (T19).
- Maintenance cost: indexes on orders/order_items went from 2 to 7, a 20k-order insert batch went from 647 ms to 853 ms (+32%), and the new indexes use about 120 MB.
- Show 19/19 tests PASS, including identical results before/after for all 7 queries.

## 7. Summary – each member, one sentence (≈1 min)

- Doreen: "I built the schema, data, baseline workload and indexing steps. FK and composite indexes made Q1, Q3 and Q5 more than 1,000x faster."
- Eric: "I analyzed planner statistics and joins. Extended statistics and ANALYZE fixed estimates that were off by 8x and 51x."
- Isaac: "I built the measurement harness, monitoring and the 19 validation tests. Monitoring found an unused index, and the tests prove tuning never changed a result."
- Limitations: timings depend on hardware and cache; Q2 and Q7 are not faster (correctly); Q4 group-count estimate is still off.
