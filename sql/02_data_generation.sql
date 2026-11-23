-- =====================================================================
-- 02_data_generation.sql  |  Module 1 (Doreen Lobe): repeatable dataset
--
-- Sizes: 100,000 customers | 5,000 products | 1,000,000 orders
--        | ~3,000,000 order_items
-- setseed() makes random() deterministic, so every run produces the
-- same rows (as long as the same PostgreSQL major version is used).
--
-- Deliberate data properties (each one feeds an experiment):
--   * status is SKEWED: ~94% 'delivered', 'pending' only exists in the
--     last 14 days (~0.3% of rows)        -> selectivity experiments
--   * order_date increases with order_id  -> high physical correlation
--   * ship_city determines ship_state (40 cities in 8 states)
--                                           -> correlated-column
--                                              estimate experiment
-- =====================================================================

SELECT setseed(0.16);

-- 40 cities, 5 per state, 8 states. Index i in both arrays = same city.
CREATE TEMP TABLE ref_geo AS
SELECT ARRAY['Dallas','Houston','Austin','Denton','Mansfield',
             'Phoenix','Tucson','Mesa','Tempe','Flagstaff',
             'Denver','Boulder','Aurora','Pueblo','Golden',
             'Atlanta','Savannah','Macon','Athens','Augusta',
             'Chicago','Peoria','Naperville','Joliet','Springfield',
             'Miami','Tampa','Orlando','Jacksonville','Tallahassee',
             'Seattle','Spokane','Tacoma','Olympia','Everett',
             'Portland','Salem','Eugene','Bend','Medford'] AS cities,
       ARRAY['TX','TX','TX','TX','TX','AZ','AZ','AZ','AZ','AZ',
             'CO','CO','CO','CO','CO','GA','GA','GA','GA','GA',
             'IL','IL','IL','IL','IL','FL','FL','FL','FL','FL',
             'WA','WA','WA','WA','WA','OR','OR','OR','OR','OR'] AS states;

-- ---------- customers (100k) ----------
INSERT INTO shop.customers (email, full_name, city, state, loyalty_tier, signup_date)
SELECT 'customer' || s.g || '@example.com',
       'Customer ' || s.g,
       r.cities[s.ci], r.states[s.ci],
       (ARRAY['bronze','bronze','bronze','silver','silver','gold','platinum'])[s.ti],
       date '2019-01-01' + s.dd
FROM (SELECT g,
             1 + floor(random()*40)::int  AS ci,
             1 + floor(random()*7)::int   AS ti,
             floor(random()*2000)::int    AS dd
      FROM generate_series(1,100000) g) s
CROSS JOIN ref_geo r
ORDER BY s.g;

-- ---------- products (5k) ----------
-- Price is a deterministic function of product_id so order_items can
-- copy it without a join.
INSERT INTO shop.products (sku, product_name, category, unit_price, is_active)
SELECT 'SKU-' || lpad(g::text, 6, '0'),
       'Product ' || g,
       (ARRAY['Electronics','Books','Home','Garden','Toys','Sports',
              'Clothing','Beauty','Grocery','Automotive','Office','Pets'])[1 + (g % 12)],
       round((5 + (g*37 % 500) + (g % 100)/100.0)::numeric, 2),
       (g % 10) <> 0
FROM generate_series(1,5000) g;

-- ---------- orders (1M) ----------
-- order_date spreads 2023-01-01 .. 2026-10-31 in order_id order.
-- Status depends on age: recent orders are still in flight.
INSERT INTO shop.orders (customer_id, order_date, status, ship_city, ship_state)
SELECT s.cust,
       s.od,
       CASE WHEN s.od >= timestamp '2026-10-18' THEN
                 (ARRAY['pending','processing','shipped'])[1 + floor(s.r1*3)::int]
            WHEN s.r1 < 0.95 THEN 'delivered'
            WHEN s.r1 < 0.98 THEN 'cancelled'
            ELSE 'returned' END,
       r.cities[s.ci], r.states[s.ci]
FROM (SELECT g,
             1 + floor(random()*100000)::int AS cust,
             timestamp '2023-01-01'
               + ((g - 1)::double precision / 1000000 * 1399) * interval '1 day'
               + floor(random()*600) * interval '1 minute' AS od,
             random() AS r1,
             1 + floor(random()*40)::int AS ci
      FROM generate_series(1,1000000) g) s
CROSS JOIN ref_geo r
ORDER BY s.g;

-- ---------- order_items (~3M) ----------
-- 1..5 items per order (deterministic from order_id), random product.
INSERT INTO shop.order_items (order_id, product_id, quantity, unit_price)
SELECT x.order_id, x.pid, x.qty,
       round((5 + (x.pid*37 % 500) + (x.pid % 100)/100.0)::numeric, 2)
FROM (SELECT o.order_id,
             1 + floor(random()*5000)::int AS pid,
             1 + floor(random()*4)::int    AS qty
      FROM shop.orders o
      CROSS JOIN LATERAL generate_series(1, 1 + ((o.order_id * 7919) % 5)::int) n
      ORDER BY o.order_id, n) x;

-- ---------- derived totals ----------
UPDATE shop.orders o
SET    total_amount = t.amt
FROM  (SELECT order_id, sum(quantity * unit_price) AS amt
       FROM shop.order_items GROUP BY order_id) t
WHERE  t.order_id = o.order_id;

-- The UPDATE left 1M dead tuples (autovacuum is off on purpose).
-- VACUUM FULL rewrites the table compactly; ANALYZE builds statistics.
VACUUM FULL shop.orders;
VACUUM (ANALYZE) shop.order_items;
ANALYZE shop.customers;
ANALYZE shop.products;
ANALYZE shop.orders;

SELECT 'customers' AS table_name, count(*) AS row_count FROM shop.customers
UNION ALL SELECT 'products',    count(*) FROM shop.products
UNION ALL SELECT 'orders',      count(*) FROM shop.orders
UNION ALL SELECT 'order_items', count(*) FROM shop.order_items;
