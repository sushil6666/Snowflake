-- ============================================================================
-- MODULE 3: CLONING (ZERO-COPY CLONE) (~40 minutes)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 3.1  Table Cloning
-- ----------------------------------------------------------------------------

-- Clone a single table — zero-copy, instant, no extra storage
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE
CLONE DEMO_NO_PK.RAW.ORDERS_SOURCE;

create table ORDERS_SOURCE_bkp as select * from DEMO_NO_PK.RAW.ORDERS_SOURCE;---

-- Verify: same data, same row count
SELECT COUNT(*) AS original_count FROM DEMO_NO_PK.RAW.ORDERS_SOURCE;
SELECT COUNT(*) AS clone_count    FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE;


SELECT *  FROM DEMO_NO_PK.RAW.ORDERS_SOURCE;

select * from ORDERS_SOURCE_bkp;

SELECT TABLE_NAME, CLONE_GROUP_ID, ACTIVE_BYTES
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME in ('ORDERS_SOURCE','ORDERS_SOURCE_BKP', 'ORDERS_SOURCE_CLONE') ;

create table ORDERS_SOURCE_bkp as select * from DEMO_NO_PK.RAW.ORDERS_SOURCE;---

-- Both tables share the same micropartitions initially
SELECT * FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE ORDER BY ORDER_DATE;

-- Modify the clone — only changed partitions are new (copy-on-write)
INSERT INTO DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE
VALUES ('2026-10-05', 'Clone Customer', 'Clone Product', 99, 49.99, 'CLONE_REGION');

-- Clone now has 1 more row; original is unchanged
SELECT 'ORIGINAL' AS source, COUNT(*) AS cnt FROM DEMO_NO_PK.RAW.ORDERS_SOURCE
UNION ALL
SELECT 'CLONE'    AS source, COUNT(*) AS cnt FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE;

-- DELETE from clone does not affect original
DELETE FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE WHERE CUSTOMER_NAME = 'Clone Customer';

-- Confirm original is untouched
SELECT COUNT(*) FROM DEMO_NO_PK.RAW.ORDERS_SOURCE;

-- ----------------------------------------------------------------------------
-- 3.2  Schema Cloning
-- ----------------------------------------------------------------------------

-- Clone an entire schema — all tables, views, stages, etc.
CREATE OR REPLACE SCHEMA DEMO_NO_PK.RAW_CLONE CLONE DEMO_NO_PK.RAW;

-- Verify all objects came across
SHOW TABLES IN SCHEMA DEMO_NO_PK.RAW_CLONE;

-- Compare row counts
SELECT 'RAW'       AS schema, TABLE_NAME, ROW_COUNT
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'RAW' AND TABLE_NAME != 'ORDERS_SOURCE_CLONE'
UNION ALL
SELECT 'RAW_CLONE' AS schema, TABLE_NAME, ROW_COUNT
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'RAW_CLONE'
ORDER BY TABLE_NAME, schema;

-- ----------------------------------------------------------------------------
-- 3.3  Database Cloning
-- ----------------------------------------------------------------------------

-- Clone the entire database
CREATE OR REPLACE DATABASE DEMO_NO_PK_CLONE CLONE DEMO_NO_PK;

-- All schemas and tables come across
SHOW SCHEMAS IN DATABASE DEMO_NO_PK_CLONE;
SHOW TABLES IN SCHEMA DEMO_NO_PK_CLONE.RAW;

-- Verify data
SELECT COUNT(*) FROM DEMO_NO_PK_CLONE.RAW.ORDERS_SOURCE;

-- ----------------------------------------------------------------------------
-- 3.4  Time Travel + Cloning (Clone from the Past)
-- ----------------------------------------------------------------------------

-- Check current data
SELECT COUNT(*) AS before_delete FROM DEMO_NO_PK.RAW.DAILY_SALES;

-- Delete some rows
DELETE FROM DEMO_NO_PK.RAW.DAILY_SALES WHERE REGION = 'East';

-- Check after delete
SELECT COUNT(*) AS after_delete FROM DEMO_NO_PK.RAW.DAILY_SALES;

-- Clone the table AS IT WAS 1 minute ago (before the delete)
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.DAILY_SALES_RESTORED
CLONE DEMO_NO_PK.RAW.DAILY_SALES
  AT (OFFSET => -60);

-- Restored table has all original rows
SELECT COUNT(*) AS restored_count FROM DEMO_NO_PK.RAW.DAILY_SALES_RESTORED;

-- Restore the original table from the clone
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.DAILY_SALES
CLONE DEMO_NO_PK.RAW.DAILY_SALES_RESTORED;

-- Confirm restoration
SELECT COUNT(*) AS final_count FROM DEMO_NO_PK.RAW.DAILY_SALES;

-- ----------------------------------------------------------------------------
-- 3.5  Storage Impact of Clones
-- ----------------------------------------------------------------------------

-- Clones share storage until data diverges
-- Check TABLE_STORAGE_METRICS to see real impact
SELECT TABLE_CATALOG,
       TABLE_SCHEMA,
       TABLE_NAME,
       ACTIVE_BYTES,
       TIME_TRAVEL_BYTES,
       FAILSAFE_BYTES,
       RETAINED_FOR_CLONE_BYTES
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
 WHERE TABLE_CATALOG IN ('DEMO_NO_PK', 'DEMO_NO_PK_CLONE')
   AND ACTIVE_BYTES > 0
 ORDER BY TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME;

-- ----------------------------------------------------------------------------
-- 3.6  Cloning Use Cases Summary
-- ----------------------------------------------------------------------------

-- Use Case 1: Dev/Test environment from Production (database clone)
-- Use Case 2: Backup before risky ETL (table clone + time travel)
-- Use Case 3: Schema migration testing (schema clone)
-- Use Case 4: Disaster recovery (clone at timestamp)


-- What does NOT get cloned:
--   • Privileges/grants (unless using COPY GRANTS)
--   • External tables, external stages
--   • Pipes referencing external stages

-- Example with COPY GRANTS:
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.EMPLOYEES_CLONE
COPY GRANTS
CLONE DEMO_NO_PK.RAW.EMPLOYEES;

SHOW GRANTS ON TABLE DEMO_NO_PK.RAW.EMPLOYEES_CLONE;


-- Clone a single table — zero-copy, instant, no extra storage
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE
CLONE DEMO_NO_PK.RAW.ORDERS_SOURCE;




create table ORDERS_SOURCE_bkp as select * from DEMO_NO_PK.RAW.ORDERS_SOURCE;---

-- Verify: same data, same row count
SELECT COUNT(*) AS original_count FROM DEMO_NO_PK.RAW.ORDERS_SOURCE; --parent


SELECT COUNT(*) AS clone_count    FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE; --child

select * from ORDERS_SOURCE_bkp;

update ORDERS_SOURCE_bkp set quantity =50;

SELECT TABLE_NAME, ACTIVE_BYTES, CLONE_GROUP_ID, ID, TABLE_CREATED
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME IN ('ORDERS_SOURCE', 'ORDERS_SOURCE_CLONE', 'ORDERS_SOURCE_BKP')
  --AND ACTIVE_BYTES > 0
ORDER BY TABLE_NAME;

insert into ORDERS_SOURCE_CLONE 
(
select * from ORDERS_SOURCE_bkp limit 2
);

SELECT TABLE_NAME, ACTIVE_BYTES, CLONE_GROUP_ID, ID
FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_NAME IN ('ORDERS_SOURCE', 'ORDERS_SOURCE_CLONE', 'ORDERS_SOURCE_BKP')
ORDER BY TABLE_NAME;

SELECT 
  (SELECT COUNT(*) FROM DEMO_NO_PK.RAW.ORDERS_SOURCE) AS ORDERS_SOURCE_ROWS,
  (SELECT COUNT(*) FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE) AS CLONE_ROWS,
  (SELECT COUNT(*) FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_BKP) AS BKP_ROWS;


