# PostgreSQL Query Optimization and Performance Analysis Toolkit

**CSCE 4355 – Database Administration · Group 16 Final Project**

A repeatable toolkit that builds a 4-million-row order-processing database in PostgreSQL, captures baseline `EXPLAIN (ANALYZE, BUFFERS)` plans for a 7-query workload, analyzes planner statistics and join strategies, applies tuning changes **one at a time**, monitors index usage, and verifies every result with 19 automated PASS/FAIL tests.

## Team

| Member | Implementation modules |
|---|---|
| Doreen Lobe | Schema, data generation, baseline workload, indexing steps (`01`, `02`, `04`, `05`, `07` steps 1–4) |
| Eric Whisenhunt | Planner statistics, selectivity, stale-statistics and extended-statistics experiments, join-method experiments (`06`, `07` step 5, `08`) |
| Isaac Lindsay | Measurement harness, index-usage monitoring, tuning validation, integration tests, runner and README (`03`, `09`, `10`, `scripts/run_all.sh`) |

## Headline results (median of 5 warm runs, PostgreSQL 16)

| Query | What it does | Baseline | Optimized | Speedup |
|---|---|---:|---:|---:|
| Q1 | Orders for one customer | 32.4 ms | 0.014 ms | ~2,300x |
| Q2 | Revenue of delivered orders (94% of rows) | 97.4 ms | 91.6 ms | 1.1x (seq scan is correct) |
| Q3 | Oldest 50 pending orders | 35.2 ms | 0.020 ms | ~1,800x |
| Q4 | Daily revenue for one week | 36.8 ms | 4.4 ms | 8.3x |
| Q5 | 4-table join, one customer's history | 272.9 ms | 0.103 ms | ~2,600x |
| Q6 | Revenue by category, last 7 days | 260.3 ms | 25.7 ms | 10.1x |
| Q7 | Dallas/TX orders by loyalty tier | 65.0 ms | 62.3 ms | 1.0x (estimate fixed: q-error 9.7 → 2.0) |

Every query returns the identical result set before and after tuning (md5 check). Full numbers: `results/perf_comparison.csv`. Your timings will differ by hardware; plan shapes and buffer counts should match.

## Prerequisites

- PostgreSQL **16** (14+ works; `pg_stat_force_next_flush()` in `09` needs 15+)
- `psql` on your PATH and a role allowed to create databases
- bash (macOS, Linux, or WSL on Windows). ~1 GB free disk.

## Setup and execution

```bash
git clone <this-repo-url>
cd group16-dba-toolkit

# Optional: point at your server (defaults to local socket / current OS user)
export PGHOST=localhost PGPORT=5432 PGUSER=postgres
# Put the password in ~/.pgpass - never commit it.

./scripts/run_all.sh            # creates database "dba_toolkit" and runs everything (~2-4 min)
DB=my_db ./scripts/run_all.sh   # use another database name
```

`run_all.sh` drops and re-creates the database, runs `sql/01` → `sql/10` in order, and exports the evidence into `results/`. It stops at the first error and prints the log tail.

To run a single step manually: `psql -d dba_toolkit -f sql/06_statistics_analysis.sql`

### Database creation and data import

There is no external dataset. `sql/02_data_generation.sql` generates all data with `setseed(0.16)`, so everyone gets identical rows:

| Table | Rows | Notes |
|---|---:|---|
| `shop.customers` | 100,000 | 40 cities in 8 states |
| `shop.products` | 5,000 | 12 categories |
| `shop.orders` | 1,000,000 | 2023-01-01 to 2026-10-31; status skewed (94% delivered, pending only in the last 2 weeks) |
| `shop.order_items` | 3,000,000 | 1–5 items per order |

## Repository structure

```
sql/
  01_schema.sql               tables, keys, CHECK/FK constraints, reporting view
  02_data_generation.sql      repeatable dataset + VACUUM/ANALYZE
  03_toolkit.sql              measurement harness: toolkit.measure(), result fingerprints, write-cost probe
  04_workload.sql             the 7 workload queries (Q1-Q7)
  05_baseline.sql             baseline measurements + insert cost
  06_statistics_analysis.sql  pg_stats, estimate accuracy, stale-statistics experiment
  07_optimization.sql         5 tuning steps, one change at a time, then full optimized run
  08_join_experiments.sql     nested loop vs hash vs merge join, join order
  09_index_monitoring.sql     pg_stat_user_tables / pg_stat_user_indexes, unused-index report, storage cost
  10_validation.sql           19 PASS/FAIL tests, baseline-vs-optimized comparison view
  99_reset_to_baseline.sql    demo helper: removes all tuning changes
scripts/run_all.sh            one-command rebuild + export
results/
  perf_comparison.csv         baseline vs optimized per query
  perf_results_all.csv        every measurement (baseline, each step, joins, optimized)
  validation_results.csv      test results
  estimate_checks.csv         estimated vs actual rows
  index_usage.csv             monitoring snapshot + recommendations
  write_cost.csv              insert cost before/after indexes
  plans/<label>/Q*.txt        EXPLAIN (ANALYZE, BUFFERS) plans for every measurement
docs/
  Group16_Proposal.docx
  video_demo_script.md        who shows what in the recorded demo
```

## How the measurement works

`toolkit.measure(label, query_id)` runs a query once to warm the cache, then 5 more times under `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`. It stores the median execution time, plan node types, indexes used, estimated vs actual rows, the worst per-node estimate error (q-error = max(est/actual, actual/est)), buffer counts, an md5 of the result set, and the text plan. Everything lands in `toolkit.perf_results`:

```sql
SELECT * FROM toolkit.v_results;      -- every measurement
SELECT * FROM toolkit.v_comparison;   -- baseline vs optimized
SELECT * FROM toolkit.test_results;   -- PASS/FAIL
```

## Demonstration scenarios

1. **Missing FK index (Q5):** `\i sql/99_reset_to_baseline.sql`, run `EXPLAIN (ANALYZE, BUFFERS)` on Q5 (hash joins + seq scan of 3M items, ~270 ms), create `idx_orders_customer_id` and `idx_order_items_order_id`, rerun (nested loops, ~0.1 ms).
2. **When an index should NOT be used (Q2):** the planner keeps a sequential scan for a predicate matching 94% of rows.
3. **Regression caught by step-wise testing (Q3):** adding `idx_orders_order_date` makes Q3 13x *slower*; the composite `(status, order_date)` index fixes it.
4. **Statistics:** stale estimates after a 150k-row insert (q-error 51 → 1.0 after `ANALYZE`); correlated columns fixed with `CREATE STATISTICS` (q-error 7.9 → 1.0).
5. **Monitoring:** `SELECT * FROM toolkit.v_index_recommendations;` flags `idx_orders_status` as unused → dropped.

See `docs/video_demo_script.md` for the full recorded-demo plan.

## Notes

- `autovacuum_enabled = false` is set on `orders` and `order_items` so statistics only change when the scripts run `ANALYZE`. That keeps experiments controlled; do not copy this setting to production.
- No credentials are stored in this repository.
- AI assistance (Anthropic's Claude) was used in drafting scripts and documentation; the team reviewed, ran, and is responsible for all submitted work.
