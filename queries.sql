-- =====================================================================
-- Olist KPI Framework (SQLite)
-- Data loading: CSV files are loaded with pandas into *_raw tables
-- (df.to_sql(table + "_raw", conn)), then copied into keyed tables below.
-- =====================================================================

-- ---------------------------------------------------------------------
-- DDL: tables with primary and foreign keys
-- ---------------------------------------------------------------------
PRAGMA foreign_keys = OFF;
DROP TABLE IF EXISTS order_reviews;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS sellers;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS category_translation;
PRAGMA foreign_keys = ON;

CREATE TABLE customers (
    customer_id TEXT PRIMARY KEY,
    customer_unique_id TEXT,
    customer_zip_code_prefix INTEGER,
    customer_city TEXT,
    customer_state TEXT
);

CREATE TABLE sellers (
    seller_id TEXT PRIMARY KEY,
    seller_zip_code_prefix INTEGER,
    seller_city TEXT,
    seller_state TEXT
);

CREATE TABLE category_translation (
    product_category_name TEXT PRIMARY KEY,
    product_category_name_english TEXT
);

CREATE TABLE products (
    product_id TEXT PRIMARY KEY,
    product_category_name TEXT,
    product_name_lenght REAL,
    product_description_lenght REAL,
    product_photos_qty REAL,
    product_weight_g REAL,
    product_length_cm REAL,
    product_height_cm REAL,
    product_width_cm REAL
);

CREATE TABLE orders (
    order_id TEXT PRIMARY KEY,
    customer_id TEXT,
    order_status TEXT,
    order_purchase_timestamp TEXT,
    order_approved_at TEXT,
    order_delivered_carrier_date TEXT,
    order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Composite key: one order can contain several items
CREATE TABLE order_items (
    order_id TEXT,
    order_item_id INTEGER,
    product_id TEXT,
    seller_id TEXT,
    shipping_limit_date TEXT,
    price REAL,
    freight_value REAL,
    PRIMARY KEY (order_id, order_item_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id),
    FOREIGN KEY (seller_id) REFERENCES sellers(seller_id)
);

-- Composite key: review_id alone is not unique, an order can have several reviews
CREATE TABLE order_reviews (
    review_id TEXT,
    order_id TEXT,
    review_score INTEGER,
    review_comment_title TEXT,
    review_comment_message TEXT,
    review_creation_date TEXT,
    review_answer_timestamp TEXT,
    PRIMARY KEY (review_id, order_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id)
);

INSERT INTO customers SELECT * FROM customers_raw;
INSERT INTO sellers SELECT * FROM sellers_raw;
INSERT INTO category_translation SELECT * FROM category_translation_raw;
INSERT INTO products SELECT * FROM products_raw;
INSERT INTO orders SELECT * FROM orders_raw;
INSERT INTO order_items SELECT * FROM order_items_raw;
INSERT INTO order_reviews SELECT * FROM order_reviews_raw;

-- ---------------------------------------------------------------------
-- Q1a: Row counts per table
-- ---------------------------------------------------------------------
SELECT 'orders' AS table_name, COUNT(*) AS row_count FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'order_reviews', COUNT(*) FROM order_reviews
UNION ALL SELECT 'sellers', COUNT(*) FROM sellers
UNION ALL SELECT 'customers', COUNT(*) FROM customers
UNION ALL SELECT 'category_translation', COUNT(*) FROM category_translation;

-- ---------------------------------------------------------------------
-- Q1b: Join cardinality orders -> order_items (one-to-many)
-- avg_items_all_orders divides by all orders (incl. orders with no items)
-- avg_items_per_order_with_items divides only by orders that have items
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM orders) AS total_orders,
    (SELECT COUNT(DISTINCT order_id) FROM order_items) AS orders_with_items,
    (SELECT COUNT(*) FROM order_items) AS total_items,
    ROUND(1.0 * (SELECT COUNT(*) FROM order_items)
          / (SELECT COUNT(*) FROM orders), 2) AS avg_items_all_orders,
    ROUND(1.0 * (SELECT COUNT(*) FROM order_items)
          / (SELECT COUNT(DISTINCT order_id) FROM order_items), 2) AS avg_items_per_order_with_items;

-- ---------------------------------------------------------------------
-- Q1c: Distribution of items per order
-- ---------------------------------------------------------------------
SELECT items_in_order, COUNT(*) AS n_orders
FROM (
    SELECT order_id, COUNT(*) AS items_in_order
    FROM order_items
    GROUP BY order_id
)
GROUP BY items_in_order
ORDER BY items_in_order;

-- ---------------------------------------------------------------------
-- Q2: Analytical base VIEW (final version, double-counting fixed)
-- Joins:
--   orders -> order_items          INNER (no items = no revenue)
--   -> products                    LEFT  (keep sales even if product row missing)
--   -> category_translation        LEFT  (keep sales without English category)
--   -> reviews_per_order (CTE)     LEFT  (keep orders without a review)
-- Reviews are aggregated to ONE row per order BEFORE the join, so the
-- one-to-many orders -> reviews relationship cannot duplicate item rows.
-- Filter: order_status = 'delivered'
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS analytical_base;

CREATE VIEW analytical_base AS
WITH reviews_per_order AS (
    SELECT order_id,
           AVG(review_score) AS review_score,
           COUNT(*) AS n_reviews
    FROM order_reviews
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.customer_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    oi.price,
    oi.freight_value,
    p.product_category_name,
    ct.product_category_name_english AS category,
    r.review_score,
    o.order_purchase_timestamp,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    strftime('%Y-%m', o.order_purchase_timestamp) AS order_month,
    julianday(o.order_delivered_customer_date)
      - julianday(o.order_purchase_timestamp) AS delivery_days
FROM orders o
INNER JOIN order_items oi ON oi.order_id = o.order_id
LEFT JOIN products p ON p.product_id = oi.product_id
LEFT JOIN category_translation ct ON ct.product_category_name = p.product_category_name
LEFT JOIN reviews_per_order r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered';

-- ---------------------------------------------------------------------
-- Q2 (rows per join step): how many rows each join adds or drops
-- ---------------------------------------------------------------------
SELECT '1. delivered orders' AS step, COUNT(*) AS rows_
FROM orders WHERE order_status = 'delivered'
UNION ALL
SELECT '2. + order_items (INNER)', COUNT(*)
FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered'
UNION ALL
SELECT '3. + products (LEFT)', COUNT(*)
FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
LEFT JOIN products p ON p.product_id = oi.product_id
WHERE o.order_status = 'delivered'
UNION ALL
SELECT '4. + category_translation (LEFT)', COUNT(*)
FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
LEFT JOIN products p ON p.product_id = oi.product_id
LEFT JOIN category_translation ct ON ct.product_category_name = p.product_category_name
WHERE o.order_status = 'delivered'
UNION ALL
SELECT '5. + order_reviews raw (LEFT, not aggregated)', COUNT(*)
FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
LEFT JOIN products p ON p.product_id = oi.product_id
LEFT JOIN category_translation ct ON ct.product_category_name = p.product_category_name
LEFT JOIN order_reviews r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
UNION ALL
SELECT '6. final view (reviews aggregated)', COUNT(*) FROM analytical_base;

-- ---------------------------------------------------------------------
-- Q3: RECONCILIATION
-- (a) SUM(price) straight from order_items (delivered orders only)
-- (b) SUM(price) from the analytical view
-- With the raw reviews join, (b) was 13,279,836.59 vs (a) 13,221,498.11
-- (+58,338.48 BRL, +643 rows). Cause: LEFT JOIN order_reviews duplicated
-- item rows for orders with more than one review. After aggregating
-- reviews per order, (a) = (b) = 13,221,498.11.
-- ---------------------------------------------------------------------
SELECT
    (SELECT ROUND(SUM(oi.price), 2)
     FROM order_items oi
     JOIN orders o ON o.order_id = oi.order_id
     WHERE o.order_status = 'delivered') AS revenue_a_direct,
    (SELECT ROUND(SUM(price), 2) FROM analytical_base) AS revenue_b_view,
    (SELECT COUNT(*)
     FROM order_items oi
     JOIN orders o ON o.order_id = oi.order_id
     WHERE o.order_status = 'delivered') AS rows_a,
    (SELECT COUNT(*) FROM analytical_base) AS rows_b;

-- ---------------------------------------------------------------------
-- Q4: Core KPIs (delivered orders only)
-- Item rows repeat order-level values, so first collapse to one row per order
-- ---------------------------------------------------------------------
WITH order_level AS (
    SELECT order_id,
           SUM(price) AS revenue,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score) AS review_score
    FROM analytical_base
    GROUP BY order_id
)
SELECT
    COUNT(*) AS n_orders,
    ROUND(SUM(revenue), 2) AS total_revenue,
    ROUND(SUM(revenue) * 1.0 / COUNT(*), 2) AS aov,
    ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
    ROUND(AVG(review_score), 2) AS avg_review_score
FROM order_level;

-- ---------------------------------------------------------------------
-- Q5: KPIs by English category (ordered by revenue)
-- Grain: one row per (order, category), so an order with items from two
-- categories counts once in each category
-- ---------------------------------------------------------------------
WITH order_cat AS (
    SELECT order_id,
           COALESCE(category, 'unknown') AS category,
           SUM(price) AS revenue,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score) AS review_score
    FROM analytical_base
    GROUP BY order_id, COALESCE(category, 'unknown')
)
SELECT
    category,
    COUNT(*) AS n_orders,
    ROUND(SUM(revenue), 2) AS total_revenue,
    ROUND(SUM(revenue) * 1.0 / COUNT(*), 2) AS aov,
    ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
    ROUND(AVG(review_score), 2) AS avg_review_score
FROM order_cat
GROUP BY category
ORDER BY total_revenue DESC;

-- ---------------------------------------------------------------------
-- Q6: KPIs by month
-- ---------------------------------------------------------------------
WITH order_level AS (
    SELECT order_id,
           order_month,
           SUM(price) AS revenue,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score) AS review_score
    FROM analytical_base
    GROUP BY order_id, order_month
)
SELECT
    order_month,
    COUNT(*) AS n_orders,
    ROUND(SUM(revenue), 2) AS total_revenue,
    ROUND(SUM(revenue) * 1.0 / COUNT(*), 2) AS aov,
    ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
    ROUND(AVG(review_score), 2) AS avg_review_score
FROM order_level
GROUP BY order_month
ORDER BY order_month;

-- ---------------------------------------------------------------------
-- Q7: Top 5 and bottom 5 categories by revenue ('unknown' excluded)
-- ---------------------------------------------------------------------
WITH order_cat AS (
    SELECT order_id,
           COALESCE(category, 'unknown') AS category,
           SUM(price) AS revenue
    FROM analytical_base
    GROUP BY order_id, COALESCE(category, 'unknown')
),
cat AS (
    SELECT category,
           COUNT(*) AS n_orders,
           ROUND(SUM(revenue), 2) AS total_revenue
    FROM order_cat
    WHERE category <> 'unknown'
    GROUP BY category
)
SELECT * FROM (
    SELECT 'top 5' AS segment, category, n_orders, total_revenue
    FROM cat ORDER BY total_revenue DESC LIMIT 5
)
UNION ALL
SELECT * FROM (
    SELECT 'bottom 5' AS segment, category, n_orders, total_revenue
    FROM cat ORDER BY total_revenue ASC LIMIT 5
);

-- ---------------------------------------------------------------------
-- Q8: Top 5 and bottom 5 categories by avg review score
-- HAVING >= 100 orders removes tiny categories
-- ---------------------------------------------------------------------
WITH order_cat AS (
    SELECT order_id,
           COALESCE(category, 'unknown') AS category,
           MAX(review_score) AS review_score
    FROM analytical_base
    GROUP BY order_id, COALESCE(category, 'unknown')
),
cat AS (
    SELECT category,
           COUNT(DISTINCT order_id) AS n_orders,
           ROUND(AVG(review_score), 2) AS avg_review_score
    FROM order_cat
    WHERE category <> 'unknown'
    GROUP BY category
    HAVING COUNT(DISTINCT order_id) >= 100
)
SELECT * FROM (
    SELECT 'top 5' AS segment, category, n_orders, avg_review_score
    FROM cat ORDER BY avg_review_score DESC LIMIT 5
)
UNION ALL
SELECT * FROM (
    SELECT 'bottom 5' AS segment, category, n_orders, avg_review_score
    FROM cat ORDER BY avg_review_score ASC LIMIT 5
);

-- ---------------------------------------------------------------------
-- Q9: Seller KPIs with RANK() over revenue
-- Grain: one row per (order, seller), since one order can have several sellers
-- ---------------------------------------------------------------------
WITH order_seller AS (
    SELECT order_id,
           seller_id,
           SUM(price) AS revenue,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score) AS review_score
    FROM analytical_base
    GROUP BY order_id, seller_id
),
seller_kpi AS (
    SELECT seller_id,
           COUNT(*) AS n_orders,
           ROUND(SUM(revenue), 2) AS total_revenue,
           ROUND(AVG(review_score), 2) AS avg_review_score,
           ROUND(AVG(delivery_days), 2) AS avg_delivery_days
    FROM order_seller
    GROUP BY seller_id
)
SELECT RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank,
       *
FROM seller_kpi
ORDER BY revenue_rank;

-- ---------------------------------------------------------------------
-- Q10: Per category avg delivery days and avg review score (>= 100 orders)
-- Pulled into pandas for the correlation
-- ---------------------------------------------------------------------
WITH order_cat AS (
    SELECT order_id,
           COALESCE(category, 'unknown') AS category,
           MAX(delivery_days) AS delivery_days,
           MAX(review_score) AS review_score
    FROM analytical_base
    GROUP BY order_id, COALESCE(category, 'unknown')
)
SELECT category,
       COUNT(DISTINCT order_id) AS n_orders,
       ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
       ROUND(AVG(review_score), 2) AS avg_review_score
FROM order_cat
WHERE category <> 'unknown'
GROUP BY category
HAVING COUNT(DISTINCT order_id) >= 100
ORDER BY avg_delivery_days;
