-- =====================================================================
-- 04_workload.sql  |  Module 2 (Doreen Lobe): baseline query workload
--
-- Seven queries, each chosen to exercise a different planner behavior.
-- Parameters are fixed so results are repeatable.
-- =====================================================================

TRUNCATE toolkit.workload CASCADE;

INSERT INTO toolkit.workload (query_id, category, description, owner, sql) VALUES
('Q1', 'Selective filter',
 'All orders for one customer (about 10 of 1,000,000 rows)', 'Doreen',
 $q$SELECT order_id, order_date, status, total_amount
      FROM shop.orders
     WHERE customer_id = 4242
     ORDER BY order_date DESC$q$),

('Q2', 'Broad filter',
 'Revenue of all delivered orders (about 94% of rows)', 'Eric',
 $q$SELECT count(*), sum(total_amount)
      FROM shop.orders
     WHERE status = 'delivered'$q$),

('Q3', 'Rare value + sort + LIMIT',
 'Oldest 50 pending orders (fulfilment queue)', 'Doreen',
 $q$SELECT order_id, customer_id, order_date
      FROM shop.orders
     WHERE status = 'pending'
     ORDER BY order_date
     LIMIT 50$q$),

('Q4', 'Range filter + aggregation',
 'Daily order count and revenue for one week', 'Doreen',
 $q$SELECT date_trunc('day', order_date) AS day, count(*) AS orders, sum(total_amount) AS revenue
      FROM shop.orders
     WHERE order_date >= timestamp '2026-10-01' AND order_date < timestamp '2026-10-08'
     GROUP BY 1 ORDER BY 1$q$),

('Q5', 'Four-table join (selective)',
 'Order history with product names for one customer, looked up by email', 'Eric',
 $q$SELECT o.order_id, o.order_date, p.product_name, oi.quantity, oi.unit_price
      FROM shop.customers c
      JOIN shop.orders o       ON o.customer_id = c.customer_id
      JOIN shop.order_items oi ON oi.order_id   = o.order_id
      JOIN shop.products p     ON p.product_id  = oi.product_id
     WHERE c.email = 'customer4242@example.com'
     ORDER BY o.order_date DESC, oi.order_item_id$q$),

('Q6', 'Join + aggregation (recent window)',
 'Revenue by product category for the last 7 days of October', 'Eric',
 $q$SELECT p.category, sum(oi.quantity * oi.unit_price) AS revenue, count(DISTINCT o.order_id) AS orders
      FROM shop.orders o
      JOIN shop.order_items oi ON oi.order_id  = o.order_id
      JOIN shop.products p     ON p.product_id = oi.product_id
     WHERE o.order_date >= timestamp '2026-10-25'
     GROUP BY p.category
     ORDER BY revenue DESC$q$),

('Q7', 'Correlated predicates',
 'Dallas, TX orders by customer loyalty tier (city implies state)', 'Eric',
 $q$SELECT c.loyalty_tier, count(*) AS orders
      FROM shop.orders o
      JOIN shop.customers c ON c.customer_id = o.customer_id
     WHERE o.ship_city = 'Dallas' AND o.ship_state = 'TX'
     GROUP BY c.loyalty_tier
     ORDER BY c.loyalty_tier$q$);
