-- ============================================================
-- DEMO: Loading Data When Source Has No Primary Key
-- ============================================================

-- ============================================================
-- SETUP
-- ============================================================
USE DATABASE DEMO_NO_PK;
USE SCHEMA RAW;

-- Source table: NO primary key, raw data as-is from ingestion
SELECT * FROM DEMO_NO_PK.RAW.ORDERS_SOURCE;

-- Notice: 10 rows total, with duplicates (Alice/Laptop, Diana/Mouse)
SELECT *, COUNT(*) OVER (
    PARTITION BY order_date, customer_name, product, quantity, unit_price, region
) AS dup_count
FROM DEMO_NO_PK.RAW.ORDERS_SOURCE
ORDER BY order_date, customer_name;


-- ============================================================
-- APPROACH 1: Hash-Based Surrogate Key (Initial Full Load)
-- ============================================================
-- Generate a deterministic hash from ALL columns to act as a synthetic PK.
-- Use ROW_NUMBER to deduplicate identical rows.

SELECT
    SHA2(CONCAT_WS('|',
        NVL(order_date::STRING, ''),
        NVL(customer_name, ''),
        NVL(product, ''),
        NVL(quantity::STRING, ''),
        NVL(unit_price::STRING, ''),
        NVL(region, '')
    )) AS row_hash_key,
    order_date, customer_name, product, quantity, unit_price, region
FROM DEMO_NO_PK.RAW.ORDERS_SOURCE
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY SHA2(CONCAT_WS('|',
        NVL(order_date::STRING, ''),
        NVL(customer_name, ''),
        NVL(product, ''),
        NVL(quantity::STRING, ''),
        NVL(unit_price::STRING, ''),
        NVL(region, '')
    ))
    ORDER BY order_date
) = 1;
-- Result: 8 duplicated rows --> 6 unique rows


-- ============================================================
-- APPROACH 2: Incremental MERGE Using Hash Key
-- ============================================================
-- The curated table already has 6 rows from the initial load.
-- After new rows were added to source, MERGE inserts only NEW hash keys.

SELECT * FROM DEMO_NO_PK.CURATED.ORDERS_HASH_KEY ORDER BY order_date, customer_name;
-- Result: 8 rows (6 original + 2 new)


-- ============================================================
-- APPROACH 3: STREAM + TASK (Automated Incremental Pipeline)
-- ============================================================
-- For production: use a Stream to capture CDC, then a Task to auto-merge.

CREATE OR REPLACE STREAM DEMO_NO_PK.RAW.ORDERS_STREAM
  ON TABLE DEMO_NO_PK.RAW.ORDERS_SOURCE
  APPEND_ONLY = TRUE;

CREATE OR REPLACE TASK DEMO_NO_PK.RAW.ORDERS_LOAD_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE  = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('DEMO_NO_PK.RAW.ORDERS_STREAM')
AS
MERGE INTO DEMO_NO_PK.CURATED.ORDERS_HASH_KEY AS tgt
USING (
    SELECT
        SHA2(CONCAT_WS('|',
            NVL(order_date::STRING, ''),
            NVL(customer_name, ''),
            NVL(product, ''),
            NVL(quantity::STRING, ''),
            NVL(unit_price::STRING, ''),
            NVL(region, '')
        )) AS row_hash_key,
        order_date, customer_name, product, quantity, unit_price, region
    FROM DEMO_NO_PK.RAW.ORDERS_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY
        SHA2(CONCAT_WS('|',
            NVL(order_date::STRING, ''),
            NVL(customer_name, ''),
            NVL(product, ''),
            NVL(quantity::STRING, ''),
            NVL(unit_price::STRING, ''),
            NVL(region, '')
        ))
        ORDER BY order_date DESC
    ) = 1
) AS src
ON tgt.row_hash_key = src.row_hash_key
WHEN NOT MATCHED THEN INSERT
    (row_hash_key, order_date, customer_name, product, quantity, unit_price, region, loaded_at)
VALUES
    (src.row_hash_key, src.order_date, src.customer_name, src.product, src.quantity,
     src.unit_price, src.region, CURRENT_TIMESTAMP());

-- To activate the automated pipeline:
-- ALTER TASK DEMO_NO_PK.RAW.ORDERS_LOAD_TASK RESUME;

-- Test: insert new rows and watch the stream/task pick them up
-- INSERT INTO DEMO_NO_PK.RAW.ORDERS_SOURCE VALUES ('2024-01-14','Frank','Webcam',1,89.99,'South');
-- SELECT * FROM DEMO_NO_PK.RAW.ORDERS_STREAM;  -- shows new row


-- ============================================================
-- CLEANUP (run when done)
-- ============================================================
-- DROP DATABASE DEMO_NO_PK;


-- ############################################################
-- INTERVIEW Q: How to Get the Latest Data of Any Entity?
-- ############################################################
-- SCENARIO: A table receives multiple updates per customer.
--           We need ONLY the most recent row per customer_id.
--
-- Raw data (9 rows, 4 customers):
--   Customer 1 (Alice) → 3 versions (Jan, Mar, Jun)
--   Customer 2 (Bob)   → 2 versions (Feb, May)
--   Customer 3 (Carol) → 3 versions (Jan, Apr, Jul)
--   Customer 4 (Dave)  → 1 version  (Mar)
-- Expected result: 4 rows (one per customer, the latest)

SELECT * FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES ORDER BY customer_id, updated_at;


-- ============================================================
-- APPROACH 1: ROW_NUMBER + QUALIFY (Best for Snowflake)
-- ============================================================
-- ROW_NUMBER assigns 1, 2, 3... per customer ordered by timestamp DESC.
-- QUALIFY filters directly on window functions (Snowflake-specific, no subquery needed).

SELECT customer_id, name, email, city, updated_at
FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY customer_id
    ORDER BY updated_at DESC
) = 1
ORDER BY customer_id;

-- WHY THIS IS BEST:
--   ✓ Clean, readable, no subquery or CTE
--   ✓ QUALIFY is Snowflake-native (like HAVING for window functions)
--   ✓ Handles ties deterministically (picks one row)
--   ✓ Works even if updated_at has NULLs (they sort last with DESC)


-- ============================================================
-- APPROACH 2: ROW_NUMBER + CTE (Standard SQL, works everywhere)
-- ============================================================
-- Same logic, but uses a CTE + WHERE instead of QUALIFY.
-- Use this when explaining to interviewers unfamiliar with Snowflake.

WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY updated_at DESC
        ) AS rn
    FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES
)
SELECT customer_id, name, email, city, updated_at
FROM ranked
WHERE rn = 1
ORDER BY customer_id;


-- ============================================================
-- APPROACH 3: Correlated Subquery with MAX()
-- ============================================================
-- Finds the MAX updated_at per customer, then joins back.
-- Simple but can be slower on large tables.

SELECT c.customer_id, c.name, c.email, c.city, c.updated_at
FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES c
WHERE c.updated_at = (
    SELECT MAX(updated_at)
    FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES
    WHERE customer_id = c.customer_id
)
ORDER BY c.customer_id;

-- WARNING: If two rows share the exact same MAX timestamp,
--          this returns BOTH rows (duplicates). ROW_NUMBER avoids this.


-- ============================================================
-- APPROACH 4: INNER JOIN on MAX (Set-based, no subquery per row)
-- ============================================================
-- Computes MAX timestamp per entity in one pass, then joins.

SELECT c.customer_id, c.name, c.email, c.city, c.updated_at
FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES c
INNER JOIN (
    SELECT customer_id, MAX(updated_at) AS max_ts
    FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES
    GROUP BY customer_id
) latest
  ON c.customer_id = latest.customer_id
 AND c.updated_at  = latest.max_ts
ORDER BY c.customer_id;

-- Same duplicate risk as Approach 3 when timestamps tie.


-- ============================================================
-- APPROACH 5: LAST_VALUE window function
-- ============================================================
-- Uses LAST_VALUE to peek at the latest value, then dedup.

SELECT DISTINCT
    customer_id,
    LAST_VALUE(name)       OVER (PARTITION BY customer_id ORDER BY updated_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS name,
    LAST_VALUE(email)      OVER (PARTITION BY customer_id ORDER BY updated_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS email,
    LAST_VALUE(city)       OVER (PARTITION BY customer_id ORDER BY updated_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS city,
    MAX(updated_at)        OVER (PARTITION BY customer_id) AS updated_at
FROM DEMO_NO_PK.RAW.CUSTOMER_UPDATES
ORDER BY customer_id;

-- Works but verbose. Better for grabbing one or two latest columns
-- without needing the full row.


-- ============================================================
-- COMPARISON TABLE
-- ============================================================
--
--  Approach             | Handles Ties? | Performance   | Portability
--  ---------------------+---------------+---------------+-----------------
--  1. QUALIFY + ROW_NUM | Yes (picks 1) | Best          | Snowflake only
--  2. CTE + ROW_NUMBER  | Yes (picks 1) | Best          | All SQL engines
--  3. Correlated MAX    | No (dupes)    | Slow on big   | All SQL engines
--  4. JOIN on MAX       | No (dupes)    | Good          | All SQL engines
--  5. LAST_VALUE        | Yes           | Good          | Most engines
--
--  INTERVIEW TIP: Start with Approach 1 (QUALIFY) for Snowflake.
--                 Mention Approach 2 (CTE) as the portable version.
--                 Explain the duplicate risk of Approach 3/4.
--                 This shows depth of understanding.


-- ############################################################
-- INTERVIEW Q: How to Verify Relationships Without PK/FK?
-- ############################################################
-- SCENARIO: Two tables have no constraints defined.
--   DEPARTMENTS: dept_id (should be unique, but has a duplicate)
--   EMPLOYEES:   dept_id (should reference departments, but has orphans + NULLs)
--
-- In Snowflake, PK/FK constraints are NOT ENFORCED (except NOT NULL).
-- So even if defined, you still need these checks in production.

-- Raw data
SELECT 'DEPARTMENTS' AS tbl, * FROM DEMO_NO_PK.RAW.DEPARTMENTS;
SELECT 'EMPLOYEES'   AS tbl, * FROM DEMO_NO_PK.RAW.EMPLOYEES;


-- ============================================================
-- CHECK 1: Is the "parent key" actually unique?
-- ============================================================
-- Before trusting a relationship, verify the parent column has no duplicates.

-- Method A: GROUP BY + HAVING (find duplicates)
SELECT dept_id, COUNT(*) AS cnt
FROM DEMO_NO_PK.RAW.DEPARTMENTS
GROUP BY dept_id
HAVING COUNT(*) > 1;
-- Result: dept_id 10 appears twice → NOT a valid key yet!

-- Method B: Compare COUNT vs COUNT(DISTINCT)
SELECT
    COUNT(*)              AS total_rows,
    COUNT(DISTINCT dept_id) AS unique_keys,
    total_rows - unique_keys AS duplicate_count,
    IFF(total_rows = unique_keys, 'UNIQUE', 'HAS DUPLICATES') AS status
FROM DEMO_NO_PK.RAW.DEPARTMENTS;


-- ============================================================
-- CHECK 2: Find orphan records (child → missing parent)
-- ============================================================
-- Rows in EMPLOYEES whose dept_id does NOT exist in DEPARTMENTS.

-- Method A: LEFT JOIN where parent is NULL (most common)
SELECT e.emp_id, e.emp_name, e.dept_id AS orphan_dept_id
FROM DEMO_NO_PK.RAW.EMPLOYEES e
LEFT JOIN DEMO_NO_PK.RAW.DEPARTMENTS d
    ON e.dept_id = d.dept_id
WHERE d.dept_id IS NULL
  AND e.dept_id IS NOT NULL;
-- Result: Eve (dept 50) and Grace (dept 99) are orphans

-- Method B: NOT EXISTS (cleaner, avoids join fanout)
SELECT emp_id, emp_name, dept_id
FROM DEMO_NO_PK.RAW.EMPLOYEES e
WHERE dept_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM DEMO_NO_PK.RAW.DEPARTMENTS d
      WHERE d.dept_id = e.dept_id
  );

-- Method C: MINUS / EXCEPT (find unmatched keys)
SELECT DISTINCT dept_id FROM DEMO_NO_PK.RAW.EMPLOYEES WHERE dept_id IS NOT NULL
MINUS
SELECT DISTINCT dept_id FROM DEMO_NO_PK.RAW.DEPARTMENTS;
-- Result: 50, 99 — these dept_ids exist in employees but not departments


-- ============================================================
-- CHECK 3: Find NULL foreign keys
-- ============================================================
-- NULLs in the "FK" column mean the relationship is unknown.

SELECT emp_id, emp_name, dept_id
FROM DEMO_NO_PK.RAW.EMPLOYEES
WHERE dept_id IS NULL;
-- Result: Frank has no department assigned

-- Count NULLs as a percentage
SELECT
    COUNT(*)                               AS total_rows,
    COUNT(dept_id)                         AS non_null_fk,
    SUM(IFF(dept_id IS NULL, 1, 0))       AS null_fk,
    ROUND(null_fk * 100.0 / total_rows, 1) AS null_pct
FROM DEMO_NO_PK.RAW.EMPLOYEES;


-- ============================================================
-- CHECK 4: Referential integrity score (full health check)
-- ============================================================
-- One query that gives you the complete picture.

WITH integrity AS (
    SELECT
        e.emp_id,
        e.dept_id,
        CASE
            WHEN e.dept_id IS NULL           THEN 'NULL_FK'
            WHEN d.dept_id IS NULL           THEN 'ORPHAN'
            ELSE                                  'VALID'
        END AS ri_status
    FROM DEMO_NO_PK.RAW.EMPLOYEES e
    LEFT JOIN (SELECT DISTINCT dept_id FROM DEMO_NO_PK.RAW.DEPARTMENTS) d
        ON e.dept_id = d.dept_id
)
SELECT
    ri_status,
    COUNT(*)                                          AS row_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct
FROM integrity
GROUP BY ri_status
ORDER BY ri_status;
-- Expected:
--   NULL_FK  → 1 row  (14.3%)
--   ORPHAN   → 2 rows (28.6%)
--   VALID    → 4 rows (57.1%)


-- ============================================================
-- CHECK 5: Join fanout detection (1-to-many gone wrong)
-- ============================================================
-- If the parent has duplicates, a JOIN produces extra rows.

-- Without dedup: JOIN fanout!
SELECT COUNT(*) AS row_count_with_fanout
FROM DEMO_NO_PK.RAW.EMPLOYEES e
INNER JOIN DEMO_NO_PK.RAW.DEPARTMENTS d
    ON e.dept_id = d.dept_id;
-- Result: 5 instead of expected 4 (Alice and Dave match dept 10 TWICE)

-- Detect which rows are fanning out
SELECT e.emp_id, e.emp_name, e.dept_id, COUNT(*) AS join_matches
FROM DEMO_NO_PK.RAW.EMPLOYEES e
INNER JOIN DEMO_NO_PK.RAW.DEPARTMENTS d
    ON e.dept_id = d.dept_id
GROUP BY e.emp_id, e.emp_name, e.dept_id
HAVING COUNT(*) > 1;
-- Result: Alice and Dave both match 2 rows in departments

-- Fix: Dedup parent before joining
SELECT e.emp_id, e.emp_name, d.dept_id, d.dept_name
FROM DEMO_NO_PK.RAW.EMPLOYEES e
INNER JOIN (
    SELECT DISTINCT dept_id, dept_name
    FROM DEMO_NO_PK.RAW.DEPARTMENTS
) d ON e.dept_id = d.dept_id
ORDER BY e.emp_id;


-- ============================================================
-- CHECK 6: Cardinality check (1:1 vs 1:N vs M:N)
-- ============================================================
-- Understand the actual relationship shape.

-- How many employees per department?
SELECT d.dept_id, d.dept_name, COUNT(e.emp_id) AS emp_count
FROM (SELECT DISTINCT dept_id, dept_name FROM DEMO_NO_PK.RAW.DEPARTMENTS) d
LEFT JOIN DEMO_NO_PK.RAW.EMPLOYEES e ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY emp_count DESC;

-- How many departments per employee? (should be 1 for 1:N)
SELECT emp_id, emp_name, COUNT(DISTINCT dept_id) AS dept_count
FROM DEMO_NO_PK.RAW.EMPLOYEES
WHERE dept_id IS NOT NULL
GROUP BY emp_id, emp_name
HAVING COUNT(DISTINCT dept_id) > 1;
-- Empty = good. Each employee belongs to exactly one department.


-- ============================================================
-- SUMMARY: Complete Verification Checklist
-- ============================================================
--
--  Check                  | What It Catches              | Query Pattern
--  -----------------------+------------------------------+------------------------
--  1. Uniqueness          | Duplicate parent keys        | GROUP BY + HAVING > 1
--  2. Orphan records      | Child refs missing parent    | LEFT JOIN WHERE NULL
--  3. NULL foreign keys   | Unknown relationships        | WHERE fk IS NULL
--  4. RI score            | Overall health percentage    | CASE + LEFT JOIN
--  5. Join fanout         | Duplicates inflating results | COUNT after JOIN > 1
--  6. Cardinality         | 1:1 vs 1:N vs M:N shape     | COUNT(DISTINCT) per side
--
--  INTERVIEW TIP: Explain that Snowflake does NOT enforce PK/FK constraints.
--                 They are metadata hints for query optimization only.
--                 So these checks are REQUIRED in any real pipeline,
--                 even if constraints are defined on the table.


-- ############################################################
-- INTERVIEW Q: How to Get Cumulative / Running Totals?
-- ############################################################
-- SCENARIO: Daily sales data. We need running totals, cumulative
--           percentages, and other progressive aggregations.
--
-- Table: DAILY_SALES (15 rows, 5 days, 2 regions, 2 products)

SELECT * FROM DEMO_NO_PK.RAW.DAILY_SALES ORDER BY sale_date, region, product;


-- ============================================================
-- 1. Basic Cumulative SUM (Running Total)
-- ============================================================
-- "What is the total sales amount up to each date?"

SELECT
    sale_date,
    SUM(amount) AS daily_total,
    SUM(SUM(amount)) OVER (ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_total
FROM DEMO_NO_PK.RAW.DAILY_SALES
GROUP BY sale_date
ORDER BY sale_date;

-- Result:
--  Jan 01 → daily 2300, cumulative 2300
--  Jan 02 → daily 2200, cumulative 4500
--  Jan 03 → daily 2700, cumulative 7200
--  Jan 04 → daily 2750, cumulative 9950
--  Jan 05 → daily 2300, cumulative 12250

-- KEY CONCEPT: SUM() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING)
-- The window frame starts at the first row and grows with each row.


-- ============================================================
-- 2. Cumulative SUM by Partition (per Region)
-- ============================================================
-- "Running total for East and West separately"

SELECT
    sale_date,
    region,
    SUM(amount) AS daily_total,
    SUM(SUM(amount)) OVER (
        PARTITION BY region
        ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_by_region
FROM DEMO_NO_PK.RAW.DAILY_SALES
GROUP BY sale_date, region
ORDER BY region, sale_date;


-- ============================================================
-- 3. Cumulative Percentage (% of Grand Total so far)
-- ============================================================
-- "What percentage of total revenue was earned by each date?"

SELECT
    sale_date,
    SUM(amount) AS daily_total,
    SUM(SUM(amount)) OVER (ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_total,
    SUM(SUM(amount)) OVER () AS grand_total,
    ROUND(cumulative_total * 100.0 / grand_total, 1) AS cumulative_pct
FROM DEMO_NO_PK.RAW.DAILY_SALES
GROUP BY sale_date
ORDER BY sale_date;

-- Result:
--  Jan 01 → 18.8%
--  Jan 02 → 36.7%
--  Jan 03 → 58.8%
--  Jan 04 → 81.2%
--  Jan 05 → 100.0%


-- ============================================================
-- 4. Cumulative COUNT (Running count of transactions)
-- ============================================================
-- "How many transactions have occurred up to each date?"

SELECT
    sale_date,
    COUNT(*) AS daily_txns,
    SUM(COUNT(*)) OVER (ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_txns
FROM DEMO_NO_PK.RAW.DAILY_SALES
GROUP BY sale_date
ORDER BY sale_date;


-- ============================================================
-- 5. Cumulative AVG (Running average)
-- ============================================================
-- "What is the average daily revenue up to each date?"

WITH daily AS (
    SELECT sale_date, SUM(amount) AS daily_total
    FROM DEMO_NO_PK.RAW.DAILY_SALES
    GROUP BY sale_date
)
SELECT
    sale_date,
    daily_total,
    AVG(daily_total) OVER (ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_avg_daily,
    ROUND(cumulative_avg_daily, 2) AS cumulative_avg_rounded
FROM daily
ORDER BY sale_date;

-- Result:
--  Jan 01 → avg 2300.00  (just day 1)
--  Jan 02 → avg 2250.00  (avg of day 1+2)
--  Jan 03 → avg 2400.00  (avg of day 1+2+3)


-- ============================================================
-- 6. Cumulative MAX / MIN (Running high/low)
-- ============================================================
-- "What was the highest single-day revenue up to each date?"

WITH daily AS (
    SELECT sale_date, SUM(amount) AS daily_total
    FROM DEMO_NO_PK.RAW.DAILY_SALES
    GROUP BY sale_date
)
SELECT
    sale_date,
    daily_total,
    MAX(daily_total) OVER (ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_max,
    MIN(daily_total) OVER (ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_min
FROM daily
ORDER BY sale_date;


-- ============================================================
-- 7. Moving / Rolling Window (Last 3 days)
-- ============================================================
-- NOT cumulative from start — only looks back N rows.

WITH daily AS (
    SELECT sale_date, SUM(amount) AS daily_total
    FROM DEMO_NO_PK.RAW.DAILY_SALES
    GROUP BY sale_date
)
SELECT
    sale_date,
    daily_total,
    SUM(daily_total) OVER (ORDER BY sale_date
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS rolling_3day_sum,
    ROUND(AVG(daily_total) OVER (ORDER BY sale_date
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 2) AS rolling_3day_avg
FROM daily
ORDER BY sale_date;

-- KEY DIFFERENCE:
--  UNBOUNDED PRECEDING → cumulative (grows forever)
--  2 PRECEDING         → rolling window (fixed size of 3 rows)


-- ============================================================
-- 8. Cumulative with Day-over-Day Growth
-- ============================================================
-- Combines cumulative total with daily change metrics.

WITH daily AS (
    SELECT sale_date, SUM(amount) AS daily_total
    FROM DEMO_NO_PK.RAW.DAILY_SALES
    GROUP BY sale_date
)
SELECT
    sale_date,
    daily_total,
    LAG(daily_total) OVER (ORDER BY sale_date) AS prev_day,
    daily_total - prev_day AS day_over_day_change,
    ROUND(IFF(prev_day = 0, NULL,
        day_over_day_change * 100.0 / prev_day), 1) AS dod_pct_change,
    SUM(daily_total) OVER (ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_total
FROM daily
ORDER BY sale_date;


-- ============================================================
-- SUMMARY: Window Frame Cheat Sheet
-- ============================================================
--
--  Frame Clause                                  | Meaning
--  ----------------------------------------------+---------------------------
--  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT  | Cumulative (from start)
--  ROWS BETWEEN 2 PRECEDING AND CURRENT ROW      | Rolling 3-row window
--  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED| Entire partition (total)
--  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOW | Reverse cumulative
--
--  Function        | Cumulative Use
--  ----------------+------------------------------------
--  SUM() OVER      | Running total
--  COUNT() OVER    | Running count
--  AVG() OVER      | Running average
--  MAX() OVER      | Running high
--  MIN() OVER      | Running low
--  LAG() / LEAD()  | Compare with previous/next row
--
--  INTERVIEW TIP: Always specify the ROWS/RANGE frame explicitly.
--                 Default frame with ORDER BY is:
--                   RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--                 which treats ties differently than ROWS.
--                 Using ROWS is safer and more predictable.
