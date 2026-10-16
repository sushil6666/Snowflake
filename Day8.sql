-- ============================================================
-- SNOWFLAKE CACHING DEMO — All 3 Cache Layers
-- ============================================================
-- Layer 1: Metadata Cache      (Cloud Services — always on)
-- Layer 2: Query Result Cache  (Cloud Services — 24h, cross-warehouse)
-- Layer 3: Warehouse SSD Cache (Compute Layer  — per-warehouse)
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- SETUP: Create demo database, schema, and sample table
-- ============================================================
CREATE OR REPLACE DATABASE cache_demo_db;
USE DATABASE cache_demo_db;
USE SCHEMA public;

CREATE OR REPLACE TABLE sales_data (
    id          INT AUTOINCREMENT,
    region      VARCHAR(20),
    product     VARCHAR(50),
    amount      DECIMAL(12,2),
    sale_date   DATE,
    customer_id INT
);

-- Insert ~1M rows so cache effects are visible in query profiles
INSERT INTO sales_data (region, product, amount, sale_date, customer_id)
SELECT
    CASE UNIFORM(1, 5, RANDOM())
        WHEN 1 THEN 'North'
        WHEN 2 THEN 'South'
        WHEN 3 THEN 'East'
        WHEN 4 THEN 'West'
        ELSE        'Central'
    END                                              AS region,
    'Product_' || UNIFORM(1, 100, RANDOM())::STRING  AS product,
    ROUND(UNIFORM(10, 5000, RANDOM())::DECIMAL(12,2), 2) AS amount,
    DATEADD(day, -UNIFORM(0, 730, RANDOM()), CURRENT_DATE()) AS sale_date,
    UNIFORM(1000, 9999, RANDOM())                    AS customer_id
FROM TABLE(GENERATOR(ROWCOUNT => 1000000));

-- Verify row count
SELECT COUNT(*) AS total_rows FROM sales_data;


-- ============================================================
-- LAYER 1: METADATA CACHE
-- ============================================================
-- Snowflake tracks metadata (row counts, min/max per partition)
-- in the Cloud Services layer. These queries need NO warehouse.
-- Check the query profile: you'll see "METADATA-BASED RESULT".

-- 1a) Row count — answered from metadata, not a table scan
SELECT COUNT(*) FROM sales_data;

-- 1b) Min/Max — also metadata-based
SELECT MIN(id), MAX(id) FROM sales_data;

-- 1c) Combined metadata query
SELECT COUNT(*), MIN(sale_date), MAX(sale_date) FROM sales_data;

SELECT * FROM sales_data limit 5;

-- TIP: You CANNOT disable the metadata cache. It's always active.
ALTER WAREHOUSE COMPUTE_WH SET AUTO_RESUME = FALSE;
ALTER WAREHOUSE COMPUTE_WH SUSPEND;
ALTER WAREHOUSE COMPUTE_WH SUSPEND;
show warehouses;

ALTER WAREHOUSE COMPUTE_WH RESUME;

-- ============================================================
-- LAYER 2: QUERY RESULT CACHE
-- ============================================================
-- Persists full result sets for 24 hours (up to 31 days on reuse).
-- Shared across ALL warehouses and users with matching privileges.
-- Controlled by the session parameter USE_CACHED_RESULT.

-- 2a) First run — executes fully, populates result cache
SELECT region, SUM(amount) AS total_sales
FROM sales_data
GROUP BY region
ORDER BY total_sales DESC;

-- 2b) IDENTICAL query — instant return from result cache
--     Profile will show "QUERY RESULT REUSE"
SELECT region, SUM(amount) AS total_sales
FROM sales_data
GROUP BY region
ORDER BY total_sales DESC;

-- 2c) No CACHE MISS: different case → treated as a different query
select region, sum(amount) as total_sales
from sales_data
group by region
order by total_sales desc;

-- 2d) CACHE MISS: added a table alias
SELECT region, SUM(amount) as total_sales1
FROM sales_data s
GROUP BY region
ORDER BY 2 DESC;

-- 2e) CACHE MISS: non-deterministic function forces re-execution
SELECT region, SUM(amount) AS total_sales, CURRENT_TIMESTAMP() AS run_at
FROM sales_data
GROUP BY region
ORDER BY total_sales DESC;


-- ---------- How to DISABLE the Result Cache ----------

-- Disable for this session
ALTER SESSION SET USE_CACHED_RESULT = true;

-- Now this identical query will re-execute (no result reuse)
SELECT region, SUM(amount) AS total_sales
FROM sales_data
GROUP BY region
ORDER BY total_sales DESC;

-- Re-enable for this session (default is TRUE)
ALTER SESSION SET USE_CACHED_RESULT = TRUE;

-- Other scopes:
-- ALTER USER SUSHIL SET USE_CACHED_RESULT = FALSE;   -- per user
-- ALTER ACCOUNT SET USE_CACHED_RESULT = FALSE;        -- account-wide


-- ============================================================
-- LAYER 3: WAREHOUSE (LOCAL DISK / SSD) CACHE
-- ============================================================
-- Each warehouse caches micro-partition data on its SSD nodes.
-- The cache is LOCAL to the warehouse and drops on suspend.
-- You cannot disable it directly; control it via AUTO_SUSPEND.

-- 3a) Suspend & resume to start with a COLD (empty) cache
ALTER WAREHOUSE COMPUTE_WH SUSPEND;
ALTER WAREHOUSE COMPUTE_WH RESUME;

-- 3b) COLD run — reads from remote storage (S3 / Blob)
--     Profile: PERCENTAGE_SCANNED_FROM_CACHE ≈ 0%
ALTER SESSION SET USE_CACHED_RESULT = FALSE;  -- avoid result cache hit

SELECT product, COUNT(*) AS order_count, AVG(amount) AS avg_amount
FROM sales_data
WHERE region = 'North'
GROUP BY product
ORDER BY order_count DESC
LIMIT 20;

-- 3c) WARM run — same query re-reads from local SSD cache
--     Profile: PERCENTAGE_SCANNED_FROM_CACHE ≈ 99-100%
SELECT product, COUNT(*) AS order_count, AVG(amount) AS avg_amount
FROM sales_data
WHERE region = 'North'
GROUP BY product
ORDER BY order_count DESC
LIMIT 20;

show warehouses;

ALTER SESSION SET USE_CACHED_RESULT = TRUE;  -- restore default


-- ---------- How to CONTROL the Warehouse Cache ----------

-- Keep cache warm longer (10 minutes = 600 seconds, good for BI)
ALTER WAREHOUSE COMPUTE_WH SET AUTO_SUSPEND = 600;

-- Aggressive suspend (1 minute — cache drops quickly, saves credits)
-- ALTER WAREHOUSE COMPUTE_WH SET AUTO_SUSPEND = 60;

-- Never suspend (cache always warm, but always consuming credits)
-- ALTER WAREHOUSE COMPUTE_WH SET AUTO_SUSPEND = NULL;

-- Reset to default (10 minutes)
ALTER WAREHOUSE COMPUTE_WH SET AUTO_SUSPEND = 600;


-- ============================================================
-- DIAGNOSTIC: Check cache utilization per warehouse (past month)
-- ============================================================
SELECT warehouse_name,
       COUNT(*)                          AS query_count,
       SUM(bytes_scanned)               AS total_bytes_scanned,
       ROUND(SUM(bytes_scanned * percentage_scanned_from_cache)
           / NULLIF(SUM(bytes_scanned), 0) * 100, 2) AS pct_from_ssd_cache
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD(month, -1, CURRENT_TIMESTAMP())
  AND bytes_scanned > 0
GROUP BY 1
ORDER BY 4 DESC;


-- ============================================================
-- DIAGNOSTIC: Find queries that used the Result Cache
-- ============================================================
SELECT query_id, query_text, warehouse_name,
       bytes_scanned, percentage_scanned_from_cache
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD(day, -1, CURRENT_TIMESTAMP())
  AND bytes_scanned = 0
  AND partitions_scanned = 0
  AND execution_status = 'SUCCESS'
ORDER BY start_time DESC
LIMIT 20;


-- ============================================================
-- SUMMARY
-- ============================================================
--  Cache Layer       | Scope             | TTL          | Disable?
-- -------------------|-------------------|--------------|------------------------------
--  Metadata          | Global            | Always       | Cannot disable
--  Result Cache      | Global            | 24h (31d max)| USE_CACHED_RESULT = FALSE
--  Warehouse SSD     | Per-warehouse     | Until suspend| AUTO_SUSPEND (indirect)
-- ============================================================


-- ============================================================
-- CLEANUP (uncomment to remove demo objects)
-- ============================================================
-- DROP DATABASE IF EXISTS cache_demo_db;




SELECT COUNT(*), MIN(sale_date), max(amount), id FROM sales_data
group by all;--metadata 

SELECT * FROM sales_data limit 5;

ALTER SESSION SET USE_CACHED_RESULT = true;


show warehouses;