-- =====================================================================
-- 99_reset_to_baseline.sql  |  Demo helper
-- Removes every tuning change (indexes + extended statistics) so the
-- video can show a query slow -> apply one change -> fast, live.
-- Data and measurement history are kept.
-- =====================================================================
DROP INDEX IF EXISTS shop.idx_orders_customer_id;
DROP INDEX IF EXISTS shop.idx_order_items_order_id;
DROP INDEX IF EXISTS shop.idx_orders_order_date;
DROP INDEX IF EXISTS shop.idx_orders_status;
DROP INDEX IF EXISTS shop.idx_orders_status_date;
DROP STATISTICS IF EXISTS shop.st_orders_city_state;
ANALYZE shop.orders;
ANALYZE shop.order_items;

SELECT indexname FROM pg_indexes WHERE schemaname = 'shop' ORDER BY 1;
