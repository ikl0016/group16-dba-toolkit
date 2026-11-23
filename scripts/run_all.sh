#!/usr/bin/env bash
# =====================================================================
# run_all.sh - rebuild the database and reproduce every experiment.
#
# Usage:   ./scripts/run_all.sh            (database name: dba_toolkit)
#          DB=my_db ./scripts/run_all.sh
#
# Connection settings come from the standard libpq environment
# variables (PGHOST, PGPORT, PGUSER). Passwords belong in ~/.pgpass or
# a PGPASSWORD you export in your own shell - never in this repo.
#
# Takes about 3-4 minutes on a laptop. Output:
#   results/logs/*.log          full psql output of every step
#   results/plans/<label>/Q*.txt  EXPLAIN (ANALYZE, BUFFERS) text plans
#   results/*.csv               measurements, tests, estimates, monitoring
# =====================================================================
set -euo pipefail

DB="${DB:-dba_toolkit}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQL="$ROOT/sql"
OUT="$ROOT/results"
PSQL=(psql -X -v ON_ERROR_STOP=1 -d "$DB")

mkdir -p "$OUT/logs" "$OUT/plans"

step() {   # step <sql file>  - run one script, log its output
    local f="$1"
    echo ">>> $(date +%H:%M:%S)  $f"
    "${PSQL[@]}" -f "$SQL/$f" > "$OUT/logs/${f%.sql}.log" 2>&1 \
        || { echo "FAILED: see $OUT/logs/${f%.sql}.log"; tail -20 "$OUT/logs/${f%.sql}.log"; exit 1; }
}

echo ">>> recreating database $DB"
psql -X -d postgres -v ON_ERROR_STOP=1 -q \
     -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"

step 01_schema.sql
step 02_data_generation.sql
step 03_toolkit.sql
step 04_workload.sql
step 05_baseline.sql
step 06_statistics_analysis.sql
step 07_optimization.sql
step 08_join_experiments.sql
step 09_index_monitoring.sql
step 10_validation.sql

echo ">>> exporting results"
csv() { "${PSQL[@]}" -c "\\copy ($1) TO '$OUT/$2' WITH (FORMAT csv, HEADER)"; }

csv "SELECT run_id, run_label, query_id, settings, median_exec_ms, min_exec_ms, max_exec_ms,
            planning_ms, root_node, array_to_string(node_types,'; ') AS node_types,
            array_to_string(indexes_used,'; ') AS indexes_used, est_rows, actual_rows,
            max_q_error, shared_hit, shared_read, result_rows, result_md5
     FROM toolkit.perf_results ORDER BY run_id"                       perf_results_all.csv
csv "SELECT * FROM toolkit.v_comparison"                              perf_comparison.csv
csv "SELECT test_id, module, test_name, expected, actual, status
     FROM toolkit.test_results ORDER BY test_id"                     validation_results.csv
csv "SELECT check_label, predicate, estimated, actual, q_error
     FROM toolkit.estimate_checks ORDER BY measured_at"              estimate_checks.csv
csv "SELECT table_name, index_name, idx_scan, idx_tup_read, size_bytes, index_size, recommendation
     FROM toolkit.index_usage_snapshot ORDER BY table_name, index_name" index_usage.csv
csv "SELECT * FROM toolkit.write_cost ORDER BY measured_at"           write_cost.csv

# one text plan per (label, query) - latest measurement wins
"${PSQL[@]}" -At -F $'\t' -c "SELECT run_label, query_id FROM toolkit.v_latest ORDER BY 1,2" |
while IFS=$'\t' read -r label qid; do
    mkdir -p "$OUT/plans/$label"
    "${PSQL[@]}" -At -c "SELECT plan_text FROM toolkit.v_latest
                         WHERE run_label = '$label' AND query_id = '$qid'" > "$OUT/plans/$label/$qid.txt"
done

echo
"${PSQL[@]}" -c "SELECT query_id, baseline_ms, optimized_ms, speedup_x, same_result FROM toolkit.v_comparison"
"${PSQL[@]}" -c "SELECT count(*) FILTER (WHERE status='PASS') AS passed, count(*) AS total FROM toolkit.test_results"
echo ">>> done. Evidence is in $OUT"
