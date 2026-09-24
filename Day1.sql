-- ============================================================
-- RETAIL DOMAIN - SF_LEARN.DEMO_CLASS
-- ~10K sample rows | Designed for Snowflake feature demos
-- Day1 - 23-Sept-2026
-- ============================================================

USE DATABASE SF_LEARN;
USE SCHEMA DEMO_CLASS;

-- ============================================================
-- SECTION 1: DDL - TABLE DEFINITIONS
-- ============================================================

-- 1.1 Customers (500 rows) — clustered by loyalty_tier for pruning demos
CREATE OR REPLACE TABLE customers (
    customer_id     INT AUTOINCREMENT PRIMARY KEY,
    first_name      VARCHAR(50) NOT NULL,
    last_name       VARCHAR(50) NOT NULL,
    email           VARCHAR(100),
    phone           VARCHAR(20),
    loyalty_tier    VARCHAR(10) DEFAULT 'BRONZE',
    signup_date     DATE,
    city            VARCHAR(50),
    state           VARCHAR(2),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (loyalty_tier)
DATA_RETENTION_TIME_IN_DAYS = 90
CHANGE_TRACKING = TRUE
COMMENT = 'Retail customers with loyalty tiers — clustered for pruning demos';

-- 1.2 Stores (10 rows)
CREATE OR REPLACE TABLE stores (
    store_id     INT AUTOINCREMENT PRIMARY KEY,
    store_name   VARCHAR(100) NOT NULL,
    city         VARCHAR(50),
    state        VARCHAR(2),
    zip_code     VARCHAR(10),
    region       VARCHAR(20),
    store_type   VARCHAR(20),
    opened_date  DATE,
    is_active    BOOLEAN DEFAULT TRUE
)
COMMENT = 'Retail store locations across regions';

-- 1.3 Categories (15 rows) — hierarchical for recursive CTE demos
CREATE OR REPLACE TABLE categories (
    category_id        INT AUTOINCREMENT PRIMARY KEY,
    category_name      VARCHAR(50) NOT NULL,
    parent_category_id INT,
    category_level     INT DEFAULT 1
)
COMMENT = 'Product categories with parent-child hierarchy';

-- 1.4 Products (100 rows) — clustered by category for join pruning
CREATE OR REPLACE TABLE products (
    product_id    INT AUTOINCREMENT PRIMARY KEY,
    product_name  VARCHAR(200) NOT NULL,
    category_id   INT REFERENCES categories(category_id),
    brand         VARCHAR(100),
    unit_price    DECIMAL(10,2) NOT NULL,
    unit_cost     DECIMAL(10,2),
    sku           VARCHAR(30) UNIQUE,
    weight_kg     DECIMAL(6,2),
    is_active     BOOLEAN DEFAULT TRUE,
    created_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (category_id)
COMMENT = 'Product catalog — clustered by category';

-- 1.5 Inventory (1000 rows) — store × product stock levels
CREATE OR REPLACE TABLE inventory (
    store_id          INT REFERENCES stores(store_id),
    product_id        INT REFERENCES products(product_id),
    quantity_on_hand  INT DEFAULT 0,
    reorder_point     INT DEFAULT 10,
    last_restock_date DATE,
    PRIMARY KEY (store_id, product_id)
)
CHANGE_TRACKING = TRUE
COMMENT = 'Stock levels per store/product — change tracking for streams';

-- 1.6 Orders (5000 rows) — clustered by date for time-range pruning
CREATE OR REPLACE TABLE orders (
    order_id       INT AUTOINCREMENT PRIMARY KEY,
    customer_id    INT REFERENCES customers(customer_id),
    store_id       INT REFERENCES stores(store_id),
    order_date     TIMESTAMP_NTZ,
    order_status   VARCHAR(20) DEFAULT 'PENDING',
    payment_method VARCHAR(20),
    shipping_cost  DECIMAL(8,2) DEFAULT 0,
    total_amount   DECIMAL(12,2)
)
CLUSTER BY (order_date)
DATA_RETENTION_TIME_IN_DAYS = 90
CHANGE_TRACKING = TRUE
COMMENT = 'Order headers — clustered by date, change tracking for CDC';

-- 1.7 Order Items (8000 rows)
CREATE OR REPLACE TABLE order_items (
    order_item_id INT AUTOINCREMENT PRIMARY KEY,
    order_id      INT REFERENCES orders(order_id),
    product_id    INT REFERENCES products(product_id),
    quantity      INT NOT NULL,
    unit_price    DECIMAL(10,2) NOT NULL,
    discount_pct  DECIMAL(5,2) DEFAULT 0,
    line_total    DECIMAL(12,2)
)
COMMENT = 'Order line items with computed line totals';

-- 1.8 Promotions (20 rows) — transient for table-type comparison demos
CREATE OR REPLACE TRANSIENT TABLE promotions (
    promo_id       INT AUTOINCREMENT PRIMARY KEY,
    promo_name     VARCHAR(100) NOT NULL,
    discount_type  VARCHAR(20),
    discount_value DECIMAL(10,2),
    start_date     DATE,
    end_date       DATE,
    min_order_amt  DECIMAL(10,2) DEFAULT 0,
    active         BOOLEAN DEFAULT TRUE
)
DATA_RETENTION_TIME_IN_DAYS = 1
COMMENT = 'Promotions — TRANSIENT table for table-type comparison demos';

-- 1.9 Product Reviews (2000 rows) — semi-structured VARIANT for JSON demos
CREATE OR REPLACE TABLE product_reviews (
    review_id    INT AUTOINCREMENT PRIMARY KEY,
    product_id   INT REFERENCES products(product_id),
    customer_id  INT REFERENCES customers(customer_id),
    rating       INT,
    review_text  VARCHAR(1000),
    review_date  DATE,
    review_meta  VARIANT
)
COMMENT = 'Product reviews with VARIANT column for semi-structured data demos';

-- 1.10 Order Events (audit/CDC log) — append-only for stream demos
CREATE OR REPLACE TABLE order_events (
    event_id    INT AUTOINCREMENT PRIMARY KEY,
    order_id    INT,
    event_type  VARCHAR(30),
    event_ts    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    event_data  VARIANT
)
CHANGE_TRACKING = TRUE
COMMENT = 'Order lifecycle events — append-only for stream/task demos';


-- ============================================================
-- SECTION 2: SEED DATA (~10K rows via GENERATOR)
-- ============================================================

-- 2.1 Stores (10)
INSERT INTO stores (store_name, city, state, zip_code, region, store_type, opened_date, is_active)
VALUES
    ('Downtown Flagship',  'New York',      'NY', '10001', 'Northeast', 'FLAGSHIP',  '2018-03-15', TRUE),
    ('Lakeside Mall',      'Chicago',       'IL', '60601', 'Midwest',   'MALL',      '2019-07-20', TRUE),
    ('Sunset Plaza',       'Los Angeles',   'CA', '90001', 'West',      'MALL',      '2020-01-10', TRUE),
    ('Peachtree Center',   'Atlanta',       'GA', '30301', 'Southeast', 'STANDALONE','2021-05-05', TRUE),
    ('Pioneer Square',     'Seattle',       'WA', '98101', 'West',      'STANDALONE','2022-09-12', TRUE),
    ('River Walk',         'San Antonio',   'TX', '78201', 'South',     'OUTLET',    '2019-11-01', TRUE),
    ('Harbor Point',       'Boston',        'MA', '02101', 'Northeast', 'MALL',      '2020-06-15', TRUE),
    ('Cherry Creek',       'Denver',        'CO', '80201', 'Mountain',  'STANDALONE','2023-01-20', TRUE),
    ('Old Town',           'Portland',      'OR', '97201', 'West',      'OUTLET',    '2023-08-10', TRUE),
    ('Midtown Express',    'Miami',         'FL', '33101', 'Southeast', 'FLAGSHIP',  '2024-02-14', FALSE);

-- 2.2 Categories (15 — 3 levels)
INSERT INTO categories (category_name, parent_category_id, category_level) VALUES
    ('Electronics',     NULL, 1),
    ('Clothing',        NULL, 1),
    ('Home & Kitchen',  NULL, 1),
    ('Sports & Outdoors', NULL, 1),
    ('Smartphones',     1, 2),
    ('Laptops',         1, 2),
    ('Audio',           1, 2),
    ('Men''s Apparel',  2, 2),
    ('Women''s Apparel',2, 2),
    ('Cookware',        3, 2),
    ('Furniture',       3, 2),
    ('Camping',         4, 2),
    ('Fitness',         4, 2),
    ('Premium Phones',  5, 3),
    ('Budget Phones',   5, 3);

-- 2.3 Products (100)
INSERT INTO products (product_name, category_id, brand, unit_price, unit_cost, sku, weight_kg, is_active)
SELECT
    'Product_' || SEQ4()                                                       AS product_name,
    UNIFORM(1, 15, RANDOM())                                                   AS category_id,
    CASE UNIFORM(1, 10, RANDOM())
        WHEN 1 THEN 'Apple'      WHEN 2 THEN 'Samsung'   WHEN 3 THEN 'Nike'
        WHEN 4 THEN 'Adidas'     WHEN 5 THEN 'Sony'      WHEN 6 THEN 'LG'
        WHEN 7 THEN 'Bose'       WHEN 8 THEN 'Lodge'     WHEN 9 THEN 'Coleman'
        ELSE 'Generic'
    END                                                                         AS brand,
    ROUND(UNIFORM(10, 2000, RANDOM()) + UNIFORM(0, 99, RANDOM()) / 100.0, 2)   AS unit_price,
    ROUND((UNIFORM(10, 2000, RANDOM()) + UNIFORM(0, 99, RANDOM()) / 100.0) * 0.6, 2) AS unit_cost,
    'SKU-' || LPAD(SEQ4()::VARCHAR, 5, '0')                                    AS sku,
    ROUND(UNIFORM(1, 500, RANDOM()) / 10.0, 2)                                 AS weight_kg,
    IFF(UNIFORM(1, 100, RANDOM()) > 10, TRUE, FALSE)                           AS is_active
FROM TABLE(GENERATOR(ROWCOUNT => 100));

-- 2.4 Customers (500)
INSERT INTO customers (first_name, last_name, email, phone, loyalty_tier, signup_date, city, state)
SELECT
    CASE UNIFORM(1, 20, RANDOM())
        WHEN 1  THEN 'James'   WHEN 2  THEN 'Mary'    WHEN 3  THEN 'Robert'
        WHEN 4  THEN 'Patricia'WHEN 5  THEN 'John'    WHEN 6  THEN 'Jennifer'
        WHEN 7  THEN 'Michael' WHEN 8  THEN 'Linda'   WHEN 9  THEN 'David'
        WHEN 10 THEN 'Elizabeth' WHEN 11 THEN 'William' WHEN 12 THEN 'Barbara'
        WHEN 13 THEN 'Richard' WHEN 14 THEN 'Susan'   WHEN 15 THEN 'Joseph'
        WHEN 16 THEN 'Jessica' WHEN 17 THEN 'Thomas'  WHEN 18 THEN 'Sarah'
        WHEN 19 THEN 'Charles' ELSE 'Karen'
    END                                                         AS first_name,
    CASE UNIFORM(1, 15, RANDOM())
        WHEN 1  THEN 'Smith'   WHEN 2  THEN 'Johnson' WHEN 3  THEN 'Williams'
        WHEN 4  THEN 'Brown'   WHEN 5  THEN 'Jones'   WHEN 6  THEN 'Garcia'
        WHEN 7  THEN 'Miller'  WHEN 8  THEN 'Davis'   WHEN 9  THEN 'Rodriguez'
        WHEN 10 THEN 'Martinez' WHEN 11 THEN 'Anderson' WHEN 12 THEN 'Taylor'
        WHEN 13 THEN 'Thomas'  WHEN 14 THEN 'Moore'   ELSE 'Jackson'
    END                                                         AS last_name,
    'cust_' || SEQ4() || '@retaildemo.com'                      AS email,
    '555-' || LPAD(UNIFORM(1000, 9999, RANDOM())::VARCHAR, 4, '0') AS phone,
    CASE
        WHEN UNIFORM(1, 100, RANDOM()) <= 40 THEN 'BRONZE'
        WHEN UNIFORM(1, 100, RANDOM()) <= 70 THEN 'SILVER'
        WHEN UNIFORM(1, 100, RANDOM()) <= 90 THEN 'GOLD'
        ELSE 'PLATINUM'
    END                                                         AS loyalty_tier,
    DATEADD(DAY, -UNIFORM(30, 1500, RANDOM()), CURRENT_DATE()) AS signup_date,
    CASE UNIFORM(1, 10, RANDOM())
        WHEN 1 THEN 'New York' WHEN 2 THEN 'Chicago' WHEN 3 THEN 'Los Angeles'
        WHEN 4 THEN 'Atlanta'  WHEN 5 THEN 'Seattle' WHEN 6 THEN 'San Antonio'
        WHEN 7 THEN 'Boston'   WHEN 8 THEN 'Denver'  WHEN 9 THEN 'Portland'
        ELSE 'Miami'
    END                                                         AS city,
    CASE UNIFORM(1, 10, RANDOM())
        WHEN 1 THEN 'NY' WHEN 2 THEN 'IL' WHEN 3 THEN 'CA'
        WHEN 4 THEN 'GA' WHEN 5 THEN 'WA' WHEN 6 THEN 'TX'
        WHEN 7 THEN 'MA' WHEN 8 THEN 'CO' WHEN 9 THEN 'OR'
        ELSE 'FL'
    END                                                         AS state
FROM TABLE(GENERATOR(ROWCOUNT => 500));

-- 2.5 Orders (5000 — spanning 2 years for time-series analysis)
INSERT INTO orders (customer_id, store_id, order_date, order_status, payment_method, shipping_cost, total_amount)
SELECT
    UNIFORM(1, 500, RANDOM())                                           AS customer_id,
    UNIFORM(1, 10, RANDOM())                                            AS store_id,
    DATEADD(SECOND,
            -UNIFORM(0, 63072000, RANDOM()),
            CURRENT_TIMESTAMP())                                        AS order_date,
    CASE
        WHEN UNIFORM(1, 100, RANDOM()) <= 40 THEN 'COMPLETED'
        WHEN UNIFORM(1, 100, RANDOM()) <= 60 THEN 'SHIPPED'
        WHEN UNIFORM(1, 100, RANDOM()) <= 75 THEN 'PROCESSING'
        WHEN UNIFORM(1, 100, RANDOM()) <= 90 THEN 'PENDING'
        WHEN UNIFORM(1, 100, RANDOM()) <= 95 THEN 'CANCELLED'
        ELSE 'RETURNED'
    END                                                                  AS order_status,
    CASE UNIFORM(1, 5, RANDOM())
        WHEN 1 THEN 'CREDIT_CARD' WHEN 2 THEN 'DEBIT_CARD'
        WHEN 3 THEN 'PAYPAL'      WHEN 4 THEN 'APPLE_PAY'
        ELSE 'GIFT_CARD'
    END                                                                  AS payment_method,
    ROUND(UNIFORM(0, 25, RANDOM()) + UNIFORM(0, 99, RANDOM()) / 100.0, 2) AS shipping_cost,
    0                                                                    AS total_amount
FROM TABLE(GENERATOR(ROWCOUNT => 5000));

-- 2.6 Order Items (8000 — multiple items per order)
INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_pct, line_total)
SELECT
    UNIFORM(1, 5000, RANDOM())                                                  AS order_id,
    p.product_id,
    UNIFORM(1, 5, RANDOM())                                                     AS quantity,
    p.unit_price,
    CASE WHEN UNIFORM(1, 100, RANDOM()) <= 30
         THEN ROUND(UNIFORM(5, 25, RANDOM()), 2) ELSE 0 END                    AS discount_pct,
    ROUND(UNIFORM(1, 5, RANDOM()) * p.unit_price *
          (1 - CASE WHEN UNIFORM(1, 100, RANDOM()) <= 30
                     THEN UNIFORM(5, 25, RANDOM()) / 100.0 ELSE 0 END), 2)     AS line_total
FROM TABLE(GENERATOR(ROWCOUNT => 8000)) g
JOIN products p ON p.product_id = UNIFORM(1, 100, RANDOM());

-- 2.7 Update order totals from line items
MERGE INTO orders o
USING (
    SELECT order_id, SUM(line_total) AS calc_total
    FROM order_items
    GROUP BY order_id
) oi ON o.order_id = oi.order_id
WHEN MATCHED THEN UPDATE SET o.total_amount = oi.calc_total + o.shipping_cost;

-- 2.8 Inventory (1000 — 10 stores × 100 products)
INSERT INTO inventory (store_id, product_id, quantity_on_hand, reorder_point, last_restock_date)
SELECT
    s.store_id,
    p.product_id,
    UNIFORM(0, 200, RANDOM())                                     AS quantity_on_hand,
    UNIFORM(5, 50, RANDOM())                                      AS reorder_point,
    DATEADD(DAY, -UNIFORM(1, 60, RANDOM()), CURRENT_DATE())       AS last_restock_date
FROM stores s
CROSS JOIN products p;

-- 2.9 Promotions (20)
INSERT INTO promotions (promo_name, discount_type, discount_value, start_date, end_date, min_order_amt, active)
VALUES
    ('New Year Kickoff',       'PERCENTAGE', 10.00, '2025-01-01', '2025-01-15', 50,   FALSE),
    ('Valentine''s Special',   'FIXED',      20.00, '2025-02-10', '2025-02-14', 100,  FALSE),
    ('Spring Clearance',       'PERCENTAGE', 30.00, '2025-03-15', '2025-04-15', 0,    FALSE),
    ('Summer Blowout',         'PERCENTAGE', 25.00, '2025-06-01', '2025-06-30', 0,    FALSE),
    ('Back to School',         'PERCENTAGE', 20.00, '2025-08-01', '2025-09-05', 75,   FALSE),
    ('Labor Day Weekend',      'FIXED',      50.00, '2025-08-30', '2025-09-02', 200,  FALSE),
    ('Black Friday',           'PERCENTAGE', 40.00, '2025-11-28', '2025-11-29', 0,    FALSE),
    ('Cyber Monday',           'PERCENTAGE', 35.00, '2025-12-01', '2025-12-01', 0,    FALSE),
    ('Holiday Season',         'PERCENTAGE', 15.00, '2025-12-10', '2025-12-31', 50,   FALSE),
    ('Loyalty Exclusive',      'FIXED',      30.00, '2025-01-01', '2025-12-31', 150,  FALSE),
    ('New Year 2026',          'PERCENTAGE', 12.00, '2026-01-01', '2026-01-15', 50,   FALSE),
    ('Spring Forward',         'PERCENTAGE', 18.00, '2026-03-01', '2026-03-31', 0,    TRUE),
    ('Summer Sale 2026',       'PERCENTAGE', 22.00, '2026-06-01', '2026-06-30', 0,    TRUE),
    ('Back to School 2026',    'PERCENTAGE', 20.00, '2026-08-01', '2026-09-05', 75,   FALSE),
    ('Fall Electronics Sale',  'PERCENTAGE', 15.00, '2026-09-15', '2026-09-30', 0,    TRUE),
    ('Labor Day 2026',         'FIXED',      50.00, '2026-08-30', '2026-09-02', 200,  FALSE),
    ('Halloween Flash',        'PERCENTAGE', 20.00, '2026-10-28', '2026-10-31', 0,    TRUE),
    ('Veterans Day Deal',      'FIXED',      25.00, '2026-11-11', '2026-11-11', 100,  TRUE),
    ('New Customer Welcome',   'PERCENTAGE', 10.00, '2025-01-01', '2026-12-31', 0,    TRUE),
    ('VIP Double Points',      'PERCENTAGE',  5.00, '2026-01-01', '2026-12-31', 500,  TRUE);

-- 2.10 Product Reviews (2000 — with VARIANT JSON metadata)
INSERT INTO product_reviews (product_id, customer_id, rating, review_text, review_date, review_meta)
SELECT
    UNIFORM(1, 100, RANDOM())                                       AS product_id,
    UNIFORM(1, 500, RANDOM())                                       AS customer_id,
    UNIFORM(1, 5, RANDOM())                                         AS rating,
    CASE UNIFORM(1, 8, RANDOM())
        WHEN 1 THEN 'Excellent product, highly recommend!'
        WHEN 2 THEN 'Good value for the price.'
        WHEN 3 THEN 'Average quality, nothing special.'
        WHEN 4 THEN 'Below expectations, would not buy again.'
        WHEN 5 THEN 'Terrible quality, returning immediately.'
        WHEN 6 THEN 'Perfect gift idea, arrived on time.'
        WHEN 7 THEN 'Solid build quality. Very satisfied.'
        ELSE 'Decent product but shipping was slow.'
    END                                                              AS review_text,
    DATEADD(DAY, -UNIFORM(1, 700, RANDOM()), CURRENT_DATE())        AS review_date,
    OBJECT_CONSTRUCT(
        'verified_purchase', IFF(UNIFORM(1, 100, RANDOM()) > 20, TRUE, FALSE),
        'helpful_votes',     UNIFORM(0, 50, RANDOM()),
        'device',            CASE UNIFORM(1, 3, RANDOM())
                                 WHEN 1 THEN 'mobile' WHEN 2 THEN 'desktop' ELSE 'tablet'
                             END,
        'photos_attached',   UNIFORM(0, 3, RANDOM())
    )                                                                AS review_meta
FROM TABLE(GENERATOR(ROWCOUNT => 2000));

-- 2.11 Order Events (seed historical events from existing orders)
INSERT INTO order_events (order_id, event_type, event_ts, event_data)
SELECT
    order_id,
    'ORDER_PLACED',
    order_date,
    OBJECT_CONSTRUCT('status', 'PENDING', 'payment_method', payment_method)
FROM orders
WHERE order_status IN ('COMPLETED', 'SHIPPED', 'PROCESSING', 'PENDING');

INSERT INTO order_events (order_id, event_type, event_ts, event_data)
SELECT
    order_id,
    'ORDER_SHIPPED',
    DATEADD(DAY, UNIFORM(1, 3, RANDOM()), order_date),
    OBJECT_CONSTRUCT('status', 'SHIPPED', 'carrier', 
        CASE UNIFORM(1,3,RANDOM()) WHEN 1 THEN 'FedEx' WHEN 2 THEN 'UPS' ELSE 'USPS' END)
FROM orders
WHERE order_status IN ('COMPLETED', 'SHIPPED');

INSERT INTO order_events (order_id, event_type, event_ts, event_data)
SELECT
    order_id,
    'ORDER_DELIVERED',
    DATEADD(DAY, UNIFORM(3, 7, RANDOM()), order_date),
    OBJECT_CONSTRUCT('status', 'COMPLETED', 'signature', IFF(UNIFORM(1,2,RANDOM())=1, TRUE, FALSE))
FROM orders
WHERE order_status = 'COMPLETED';


-- ============================================================
-- SECTION 3: ROW COUNTS VERIFICATION
-- ============================================================

SELECT 'customers'       AS tbl, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'stores',          COUNT(*) FROM stores
UNION ALL SELECT 'categories',      COUNT(*) FROM categories
UNION ALL SELECT 'products',        COUNT(*) FROM products
UNION ALL SELECT 'inventory',       COUNT(*) FROM inventory
UNION ALL SELECT 'orders',          COUNT(*) FROM orders
UNION ALL SELECT 'order_items',     COUNT(*) FROM order_items
UNION ALL SELECT 'promotions',      COUNT(*) FROM promotions
UNION ALL SELECT 'product_reviews', COUNT(*) FROM product_reviews
UNION ALL SELECT 'order_events',    COUNT(*) FROM order_events
ORDER BY tbl;


-- ============================================================
-- SECTION 4: SNOWFLAKE FEATURES YOU CAN DEMO WITH THIS DATA
-- ============================================================
-- Below are ready-to-run examples. Uncomment and execute as needed.

-- ── 4.1 TIME TRAVEL ─────────────────────────────────────────
-- SELECT * FROM orders AT(OFFSET => -300);
-- SELECT * FROM orders BEFORE(TIMESTAMP => '2026-09-23 12:00:00'::TIMESTAMP_NTZ);
-- SELECT * FROM customers AT(STATEMENT => '<query_id>');

-- ── 4.2 CLUSTERING INFO ─────────────────────────────────────
-- SELECT SYSTEM$CLUSTERING_INFORMATION('orders', '(order_date)');
-- SELECT SYSTEM$CLUSTERING_DEPTH('customers', '(loyalty_tier)');

-- ── 4.3 STREAMS (CDC) ───────────────────────────────────────
-- CREATE OR REPLACE STREAM orders_stream ON TABLE orders;
-- CREATE OR REPLACE STREAM inventory_stream ON TABLE inventory;
-- INSERT INTO orders (...) VALUES (...);  -- then: SELECT * FROM orders_stream;

-- ── 4.4 TASKS (SCHEDULING) ──────────────────────────────────
-- CREATE OR REPLACE TASK refresh_inventory
--   WAREHOUSE = COMPUTE_WH
--   SCHEDULE  = 'USING CRON 0 */6 * * * America/New_York'
-- AS
--   MERGE INTO inventory ...;

-- ── 4.5 DYNAMIC TABLES ──────────────────────────────────────
-- CREATE OR REPLACE DYNAMIC TABLE daily_sales
--   TARGET_LAG = '1 hour'
--   WAREHOUSE  = COMPUTE_WH
-- AS
--   SELECT DATE_TRUNC('DAY', o.order_date) AS sale_date,
--          s.region, SUM(o.total_amount) AS revenue
--   FROM orders o JOIN stores s ON o.store_id = s.store_id
--   WHERE o.order_status = 'COMPLETED'
--   GROUP BY 1, 2;

-- ── 4.6 VIEWS & SECURE VIEWS ────────────────────────────────
-- CREATE OR REPLACE VIEW v_order_summary AS
--   SELECT o.order_id, c.first_name || ' ' || c.last_name AS customer,
--          s.store_name, o.order_date, o.total_amount, o.order_status
--   FROM orders o
--   JOIN customers c ON o.customer_id = c.customer_id
--   JOIN stores s ON o.store_id = s.store_id;
--
-- CREATE OR REPLACE SECURE VIEW v_customer_masked AS
--   SELECT customer_id, first_name, '***' AS last_name, loyalty_tier
--   FROM customers;

-- ── 4.7 SEMI-STRUCTURED DATA (VARIANT) ──────────────────────
-- SELECT review_meta:verified_purchase::BOOLEAN, AVG(rating)
--   FROM product_reviews GROUP BY 1;
-- SELECT review_meta:device::STRING AS device, COUNT(*)
--   FROM product_reviews GROUP BY 1;
-- SELECT FLATTEN input => review_meta FROM product_reviews LIMIT 10;

-- ── 4.8 MASKING POLICIES ─────────────────────────────────────
-- CREATE OR REPLACE MASKING POLICY email_mask AS (val STRING)
--   RETURNS STRING ->
--   CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN') THEN val
--        ELSE REGEXP_REPLACE(val, '.+@', '****@') END;
-- ALTER TABLE customers MODIFY COLUMN email SET MASKING POLICY email_mask;

-- ── 4.9 ROW ACCESS POLICIES ─────────────────────────────────
-- CREATE OR REPLACE ROW ACCESS POLICY region_filter AS (region_val VARCHAR)
--   RETURNS BOOLEAN ->
--   CURRENT_ROLE() = 'ACCOUNTADMIN' OR region_val = CURRENT_REGION();

-- ── 4.10 WINDOW FUNCTIONS & ANALYTICS ────────────────────────
-- SELECT customer_id, order_date, total_amount,
--        SUM(total_amount) OVER (PARTITION BY customer_id ORDER BY order_date) AS running_total,
--        RANK() OVER (PARTITION BY store_id ORDER BY total_amount DESC) AS store_rank,
--        LAG(total_amount) OVER (PARTITION BY customer_id ORDER BY order_date) AS prev_order_amt
-- FROM orders;

-- ── 4.11 RECURSIVE CTE (CATEGORY HIERARCHY) ─────────────────
-- WITH RECURSIVE cat_tree AS (
--     SELECT category_id, category_name, parent_category_id, category_name AS full_path
--     FROM categories WHERE parent_category_id IS NULL
--     UNION ALL
--     SELECT c.category_id, c.category_name, c.parent_category_id,
--            t.full_path || ' > ' || c.category_name
--     FROM categories c JOIN cat_tree t ON c.parent_category_id = t.category_id
-- )
-- SELECT * FROM cat_tree ORDER BY full_path;

-- ── 4.12 CLONE & ZERO-COPY ──────────────────────────────────
-- CREATE TABLE orders_dev CLONE orders;
-- CREATE SCHEMA demo_class_dev CLONE demo_class;

-- ── 4.13 TAGS & DATA GOVERNANCE ──────────────────────────────
-- CREATE TAG IF NOT EXISTS pii_level ALLOWED_VALUES 'HIGH', 'MEDIUM', 'LOW';
-- ALTER TABLE customers MODIFY COLUMN email SET TAG pii_level = 'HIGH';
-- ALTER TABLE customers MODIFY COLUMN phone SET TAG pii_level = 'MEDIUM';

-- ── 4.14 SEARCH OPTIMIZATION ─────────────────────────────────
-- ALTER TABLE orders ADD SEARCH OPTIMIZATION ON EQUALITY(order_status);
-- ALTER TABLE customers ADD SEARCH OPTIMIZATION ON EQUALITY(email);

-- ── 4.15 UNDROP / TABLE HISTORY ──────────────────────────────
-- DROP TABLE promotions;
-- UNDROP TABLE promotions;
-- SHOW TABLES HISTORY LIKE 'PROMOTIONS' IN SCHEMA DEMO_CLASS;
