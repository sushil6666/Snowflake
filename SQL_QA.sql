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
