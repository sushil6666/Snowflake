ALTER SESSION SET TIMEZONE = 'America/Los_Angeles';

ALTER ACCOUNT SET TIMEZONE = 'America/Los_Angeles';

select current_timestamp();


SELECT CONVERT_TIMEZONE('America/Los_Angeles', 'Asia/Kolkata', current_timestamp()  );

-- What databases exist in this account?
SHOW DATABASES;

-- What roles are available?
SHOW ROLES;

-- What warehouses exist?
SHOW WAREHOUSES;

-- Current session context
SELECT CURRENT_ACCOUNT()    AS account,
       CURRENT_USER()       AS username,
       CURRENT_ROLE()       AS role,
       CURRENT_WAREHOUSE()  AS warehouse,
       CURRENT_DATABASE()   AS db,
       CURRENT_SCHEMA()     AS schema,
       CURRENT_SESSION()    AS session_id,
       CURRENT_TIMESTAMP()  AS ts;

-- ----------------------------------------------------------------------------
-- 1.2  INFORMATION_SCHEMA — Database-Level Catalog
-- ----------------------------------------------------------------------------

USE DATABASE DEMO_NO_PK;
USE SCHEMA RAW;

-- List all tables in the RAW schema with row counts and sizes
SELECT TABLE_CATALOG,
       TABLE_SCHEMA,
       TABLE_NAME,
       TABLE_TYPE,
       ROW_COUNT,
       BYTES,
       CREATED,
       LAST_ALTERED
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'RAW'
 ORDER BY TABLE_NAME;

-- Column-level metadata for all tables
SELECT TABLE_NAME,
       COLUMN_NAME,
       DATA_TYPE,
       IS_NULLABLE,
       COLUMN_DEFAULT,
       ORDINAL_POSITION
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_SCHEMA = 'RAW'
 ORDER BY TABLE_NAME, ORDINAL_POSITION;

-- Column metadata for a specific table
DESC TABLE ORDERS_SOURCE;

-- DDL generation — reverse-engineer the CREATE TABLE statement
SELECT GET_DDL('TABLE', 'DEMO_NO_PK.RAW.ORDERS_SOURCE');

-- DDL for an entire schema
SELECT GET_DDL('SCHEMA', 'DEMO_NO_PK.RAW');

-- ----------------------------------------------------------------------------
-- 1.3  ACCOUNT_USAGE — Historical / Operational Metadata
-- ----------------------------------------------------------------------------

-- Recent query history (last 1 hour)
SELECT QUERY_ID,
       QUERY_TEXT,
       USER_NAME,
       WAREHOUSE_NAME,
       EXECUTION_STATUS,
       TOTAL_ELAPSED_TIME,
       BYTES_SCANNED,
       ROWS_PRODUCED,
       START_TIME
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
 WHERE START_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
 ORDER BY START_TIME DESC
 LIMIT 20;

-- Storage usage by table
SELECT TABLE_CATALOG AS database_name,
       TABLE_SCHEMA,
       TABLE_NAME,
       ACTIVE_BYTES,
       TIME_TRAVEL_BYTES,
       FAILSAFE_BYTES,
       ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES AS total_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
 WHERE TABLE_CATALOG = 'DEMO_NO_PK'
   AND ACTIVE_BYTES > 0
 ORDER BY total_bytes DESC;

-- Login history — who connected recently?
SELECT USER_NAME,
       CLIENT_IP,
       REPORTED_CLIENT_TYPE,
       FIRST_AUTHENTICATION_FACTOR,
       IS_SUCCESS,
       EVENT_TIMESTAMP
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
 WHERE EVENT_TIMESTAMP >= DATEADD('day', -1, CURRENT_TIMESTAMP())
 ORDER BY EVENT_TIMESTAMP DESC
 LIMIT 20;

-- Warehouse credit usage today
SELECT WAREHOUSE_NAME,
       SUM(CREDITS_USED) AS total_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
 WHERE START_TIME >= CURRENT_DATE()
 GROUP BY WAREHOUSE_NAME
 ORDER BY total_credits DESC;

-- ----------------------------------------------------------------------------
-- 1.4  SHOW Commands vs INFORMATION_SCHEMA
-- ----------------------------------------------------------------------------

-- SHOW is real-time, returns metadata for the current context
SHOW TABLES IN SCHEMA DEMO_NO_PK.RAW;

-- SHOW with LIKE filter
SHOW TABLES LIKE '%ORDER%' IN SCHEMA DEMO_NO_PK.RAW;

-- SHOW COLUMNS
SHOW COLUMNS IN TABLE DEMO_NO_PK.RAW.ORDERS_SOURCE;

-- SHOW SCHEMAS with result filtering
SHOW SCHEMAS IN DATABASE DEMO_NO_PK;

-- The RESULT_SCAN trick: treat SHOW output as a table
-- SHOW TABLES output has "rows" and "bytes" columns; SHOW SCHEMAS does not
SHOW TABLES IN SCHEMA DEMO_NO_PK.RAW;

SELECT "name", "rows", "bytes", "created_on"
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
 ORDER BY "rows" DESC;

 -- ----------------------------------------------------------------------------
-- 3.1  Table Cloning
-- ----------------------------------------------------------------------------

select * from DEMO_NO_PK.RAW.ORDERS_SOURCE;


create table crc_CTAS as select * from DEMO_NO_PK.RAW.ORDERS_SOURCE;

SELECT TABLE_CATALOG AS database_name,
       TABLE_SCHEMA,
       TABLE_NAME,
       ACTIVE_BYTES,
       TIME_TRAVEL_BYTES,
       FAILSAFE_BYTES,
       ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES AS total_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
 WHERE TABLE_CATALOG = 'DEMO_NO_PK'
   AND ACTIVE_BYTES > 0
 ORDER BY total_bytes DESC;

 show tables like '%ORDERS_SOURCE%';

 SELECT TABLE_CATALOG,
       TABLE_SCHEMA,
       TABLE_NAME,
       ACTIVE_BYTES,
       TIME_TRAVEL_BYTES,
       FAILSAFE_BYTES,
       RETAINED_FOR_CLONE_BYTES
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
 WHERE TABLE_CATALOG IN ('DEMO_NO_PK', 'DEMO_NO_PK_CLONE')
   --AND ACTIVE_BYTES > 0
 ORDER BY TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME;

-- Clone a single table — zero-copy, instant, no extra storage
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE
CLONE DEMO_NO_PK.RAW.ORDERS_SOURCE;

-- Verify: same data, same row count
SELECT COUNT(*) AS original_count FROM DEMO_NO_PK.RAW.ORDERS_SOURCE;
SELECT COUNT(*) AS clone_count    FROM DEMO_NO_PK.RAW.ORDERS_SOURCE_CLONE;

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
-- Use Case 5: Data sharing sandboxes

-- What does NOT get cloned:
--   • Privileges/grants (unless using COPY GRANTS)
--   • External tables, external stages
--   • Pipes referencing external stages

-- Example with COPY GRANTS:
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.EMPLOYEES_CLONE
COPY GRANTS
CLONE DEMO_NO_PK.RAW.EMPLOYEES;

SHOW GRANTS ON TABLE DEMO_NO_PK.RAW.EMPLOYEES_CLONE;


SHOW TABLES LIKE 'MY_TABLE' IN SCHEMA MY_DB.MY_SCHEMA;

DATA RETENTION — HIERARCHY & INHERITANCE (~20 minutes);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 4.1  Check Current Defaults at Every Level
-- ----------------------------------------------------------------------------



create database demo1;

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE demo1;

create schema sc1;

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA sc1;

ALTER schema sc1 SET DATA_RETENTION_TIME_IN_DAYS = 35;

create table table1 as select 1 as id;

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE table1;



-- Account-level default
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN ACCOUNT;

create database reten_demo;




ALTER database reten_demo SET DATA_RETENTION_TIME_IN_DAYS = 9;

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE RETEN_DEMO;

create schema reten_demo.example;

ALTER schema example SET DATA_RETENTION_TIME_IN_DAYS = 15;

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA reten_demo.example;

ALTER ACCOUNT  SET DATA_RETENTION_TIME_IN_DAYS = 5;

create table reten_example as select 1 as id;

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE reten_example;

ALTER TABLE reten_example SET DATA_RETENTION_TIME_IN_DAYS = 5;

select current_account();

-- Database-level (inherits from account if not set)
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE DEMO_NO_PK;

-- Schema-level (inherits from database if not set)
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA DEMO_NO_PK.RAW;

-- Table-level (inherits from schema if not set)
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE DEMO_NO_PK.RAW.ORDERS_SOURCE;

ALTER TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- See all levels at once
SELECT 'ACCOUNT'  AS level, NULL AS object_name,
       (SELECT "value" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) LIMIT 1) AS retention_days;

-- Cleaner approach: check each object directly
-- Account
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN ACCOUNT;
-- Database
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE DEMO_NO_PK;
-- Schema
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA DEMO_NO_PK.RAW;
-- Table
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE DEMO_NO_PK.RAW.ORDERS_SOURCE;

-- ----------------------------------------------------------------------------
-- 4.2  Inheritance Hierarchy Demo
-- ----------------------------------------------------------------------------

-- RULE: Table inherits from Schema → Schema inherits from Database → Database inherits from Account
-- An explicit setting at ANY level OVERRIDES the inherited value

-- Step 1: Create a fresh demo database with default retention
CREATE OR REPLACE DATABASE RETENTION_DEMO;
CREATE OR REPLACE SCHEMA RETENTION_DEMO.TEST_SCHEMA;
CREATE OR REPLACE TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE (id INT, name VARCHAR);
INSERT INTO RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE VALUES (1, 'Alice'), (2, 'Bob');

-- Check: all levels should show default (1 day for Standard, 1 day unless account changed)
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE RETENTION_DEMO;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA RETENTION_DEMO.TEST_SCHEMA;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE;

-- Step 2: Set retention at the DATABASE level to 5 days
ALTER DATABASE RETENTION_DEMO SET DATA_RETENTION_TIME_IN_DAYS = 5;

-- Now check all levels — schema and table INHERIT the database setting
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE RETENTION_DEMO;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA RETENTION_DEMO.TEST_SCHEMA;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE;

-- Step 3: Override at the SCHEMA level to 10 days
ALTER SCHEMA RETENTION_DEMO.TEST_SCHEMA SET DATA_RETENTION_TIME_IN_DAYS = 10;

-- Database still 5, schema now 10, table inherits schema's 10
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE RETENTION_DEMO;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA RETENTION_DEMO.TEST_SCHEMA;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE;

-- Step 4: Override at the TABLE level to 30 days
ALTER TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- Database=5, Schema=10, Table=30 (each independently set)
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE RETENTION_DEMO;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA RETENTION_DEMO.TEST_SCHEMA;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE;

-- ----------------------------------------------------------------------------
-- 4.3  What Happens When You Change a Higher Level?
-- ----------------------------------------------------------------------------

-- Key question: If we change DATABASE retention, does it override the schema/table settings?
-- ANSWER: NO — explicit settings at lower levels are NOT overridden

-- Change database to 2 days
ALTER DATABASE RETENTION_DEMO SET DATA_RETENTION_TIME_IN_DAYS = 2;

-- Schema still 10, Table still 30 (explicit settings are preserved)
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE RETENTION_DEMO;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA RETENTION_DEMO.TEST_SCHEMA;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE;

-- Now UNSET the table-level override — it falls back to schema (10)
ALTER TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE UNSET DATA_RETENTION_TIME_IN_DAYS;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE;

-- UNSET the schema-level override — it falls back to database (2)
ALTER SCHEMA RETENTION_DEMO.TEST_SCHEMA UNSET DATA_RETENTION_TIME_IN_DAYS;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN SCHEMA RETENTION_DEMO.TEST_SCHEMA;
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEST_TABLE;

-------
-- 4.4  Retention Limits by Table Type
-- ----------------------------------------------------------------------------

-- Permanent tables: 0-90 days (Enterprise+), 0-1 day (Standard)
-- Transient tables: 0-1 day only
-- Temporary tables: 0-1 day only (and gone when session ends)

-- Create a transient table — max retention is 1 day
CREATE OR REPLACE TRANSIENT TABLE RETENTION_DEMO.TEST_SCHEMA.TRANSIENT_TABLE (id INT);

-- Try setting retention to 5 — this will ERROR for transient tables
-- ALTER TABLE RETENTION_DEMO.TEST_SCHEMA.TRANSIENT_TABLE SET DATA_RETENTION_TIME_IN_DAYS = 5;
-- ^ Uncomment to show the error in class

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TRANSIENT_TABLE;

-- Create a temporary table
CREATE OR REPLACE TEMPORARY TABLE RETENTION_DEMO.TEST_SCHEMA.TEMP_TABLE (id INT);
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.TEMP_TABLE;

-- ----------------------------------------------------------------------------
-- 4.5  The Dangerous Scenario: Reducing Retention + DML
-- ----------------------------------------------------------------------------

-- Set up: table with 5-day retention
ALTER DATABASE RETENTION_DEMO SET DATA_RETENTION_TIME_IN_DAYS = 5;

CREATE OR REPLACE TABLE RETENTION_DEMO.TEST_SCHEMA.IMPORTANT_DATA (id INT, val VARCHAR);
INSERT INTO RETENTION_DEMO.TEST_SCHEMA.IMPORTANT_DATA VALUES (1, 'critical_record');

-- Scenario: Someone reduces retention to 1 day at database level
-- (maybe trying to save storage, not realizing the impact)
ALTER DATABASE RETENTION_DEMO SET DATA_RETENTION_TIME_IN_DAYS = 1;

-- WITHOUT any DML on the table, old time-travel data retains original 5-day period
-- BUT time travel queries are limited to 1 day

-- If DML happens AFTER the reduction, Snowflake's background cleanup
-- enforces the new shorter retention on ALL historical data immediately
-- This is the dangerous scenario that catches people off guard

-- Verify current setting
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' FOR TABLE RETENTION_DEMO.TEST_SCHEMA.IMPORTANT_DATA;


-- ============================================================================
-- MODULE 5: MICROPARTITION IMPACT OF DML OPERATIONS (~20 minutes)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5.1  Setup: Create a Table and Observe Initial Partitions
-- ----------------------------------------------------------------------------

-- Create a table with known structure
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.DML_PARTITION_DEMO AS
SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id,
       DATEADD('day', -MOD(SEQ4(), 365), CURRENT_DATE()) AS event_date,
       'Region_' || MOD(SEQ4(), 4) AS region,
       UNIFORM(100, 10000, RANDOM())::NUMBER(10,2) AS amount
  FROM TABLE(GENERATOR(ROWCOUNT => 2000000));

-- Baseline: Check partition count and clustering
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_NO_PK.RAW.DML_PARTITION_DEMO', '(EVENT_DATE)') AS baseline_clustering;

-- Baseline: Check table size
SELECT TABLE_NAME, ROW_COUNT, BYTES,
       ROUND(BYTES / 1024 / 1024, 2) AS size_mb
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'RAW' AND TABLE_NAME = 'DML_PARTITION_DEMO';

-- Baseline: Save the partition count for comparison
-- (run this query and note the total_partition_count)

-- ----------------------------------------------------------------------------
-- 5.2  INSERT — Adds New Micropartitions
-- ----------------------------------------------------------------------------

-- INSERT 500K new rows
INSERT INTO DEMO_NO_PK.RAW.DML_PARTITION_DEMO
SELECT 2000000 + ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id,
       DATEADD('day', -MOD(SEQ4(), 365), CURRENT_DATE()) AS event_date,
       'Region_' || MOD(SEQ4(), 4) AS region,
       UNIFORM(100, 10000, RANDOM())::NUMBER(10,2) AS amount
  FROM TABLE(GENERATOR(ROWCOUNT => 500000));

-- After INSERT: new micropartitions are ADDED (old ones untouched)
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_NO_PK.RAW.DML_PARTITION_DEMO', '(EVENT_DATE)') AS after_insert_clustering;

SELECT TABLE_NAME, ROW_COUNT, BYTES,
       ROUND(BYTES / 1024 / 1024, 2) AS size_mb
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'RAW' AND TABLE_NAME = 'DML_PARTITION_DEMO';

-- Key insight: partition count INCREASED, existing partitions unchanged

-- ----------------------------------------------------------------------------
-- 5.3  DELETE — Rewrites Affected Micropartitions
-- ----------------------------------------------------------------------------

-- Count rows to be deleted
SELECT COUNT(*) AS rows_to_delete
  FROM DEMO_NO_PK.RAW.DML_PARTITION_DEMO
 WHERE region = 'Region_0';

-- DELETE rows where region = 'Region_0'
DELETE FROM DEMO_NO_PK.RAW.DML_PARTITION_DEMO
 WHERE region = 'Region_0';

-- After DELETE: affected partitions are REWRITTEN (minus deleted rows)
-- Old versions go to Time Travel, new versions replace them
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_NO_PK.RAW.DML_PARTITION_DEMO', '(EVENT_DATE)') AS after_delete_clustering;

SELECT TABLE_NAME, ROW_COUNT, BYTES,
       ROUND(BYTES / 1024 / 1024, 2) AS size_mb
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'RAW' AND TABLE_NAME = 'DML_PARTITION_DEMO';

-- Key insight: fewer rows, possibly fewer or same partitions, old partitions in time travel

-- ----------------------------------------------------------------------------
-- 5.4  UPDATE — Rewrites Affected Micropartitions (Most Expensive)
-- ----------------------------------------------------------------------------

-- UPDATE all Region_1 amounts — doubles the value
UPDATE DEMO_NO_PK.RAW.DML_PARTITION_DEMO
   SET amount = amount * 2
 WHERE region = 'Region_1';

-- After UPDATE: every partition containing Region_1 is REWRITTEN entirely
-- This is why UPDATE is the most expensive DML for micropartitions
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_NO_PK.RAW.DML_PARTITION_DEMO', '(EVENT_DATE)') AS after_update_clustering;

SELECT TABLE_NAME, ROW_COUNT, BYTES,
       ROUND(BYTES / 1024 / 1024, 2) AS size_mb
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'RAW' AND TABLE_NAME = 'DML_PARTITION_DEMO';

-- Key insight: same row count, but partitions were rewritten (time travel storage grows)

-- ----------------------------------------------------------------------------
-- 5.5  MERGE — Combined INSERT + UPDATE Partition Impact
-- ----------------------------------------------------------------------------

-- Create a source table with mixed new and existing IDs
CREATE OR REPLACE TEMPORARY TABLE DEMO_NO_PK.RAW.MERGE_SOURCE AS
(SELECT id,
        event_date,
        region,
        amount * 1.1 AS amount  -- 10% increase for existing records
   FROM DEMO_NO_PK.RAW.DML_PARTITION_DEMO
  WHERE region = 'Region_2'
  LIMIT 100000)
UNION ALL
(SELECT 9000000 + ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id,
        CURRENT_DATE() AS event_date,
        'Region_NEW' AS region,
        UNIFORM(500, 5000, RANDOM())::NUMBER(10,2) AS amount
   FROM TABLE(GENERATOR(ROWCOUNT => 50000)));

-- MERGE: updates existing + inserts new in one operation
MERGE INTO DEMO_NO_PK.RAW.DML_PARTITION_DEMO AS target
USING DEMO_NO_PK.RAW.MERGE_SOURCE AS source
   ON target.id = source.id
 WHEN MATCHED THEN
      UPDATE SET target.amount = source.amount
 WHEN NOT MATCHED THEN
      INSERT (id, event_date, region, amount)
      VALUES (source.id, source.event_date, source.region, source.amount);

-- After MERGE: partitions with matched rows are rewritten + new partitions for inserts
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_NO_PK.RAW.DML_PARTITION_DEMO', '(EVENT_DATE)') AS after_merge_clustering;

SELECT TABLE_NAME, ROW_COUNT, BYTES,
       ROUND(BYTES / 1024 / 1024, 2) AS size_mb
  FROM DEMO_NO_PK.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'RAW' AND TABLE_NAME = 'DML_PARTITION_DEMO';

-- ----------------------------------------------------------------------------
-- 5.6  Time Travel Storage Impact of DMLs
-- ----------------------------------------------------------------------------

-- Each DML creates time-travel versions of affected partitions
-- Check storage breakdown
SELECT TABLE_CATALOG,
       TABLE_NAME,
       ACTIVE_BYTES,
       TIME_TRAVEL_BYTES,
       FAILSAFE_BYTES,
       ROUND(ACTIVE_BYTES / 1024 / 1024, 2) AS active_mb,
       ROUND(TIME_TRAVEL_BYTES / 1024 / 1024, 2) AS time_travel_mb,
       ROUND(FAILSAFE_BYTES / 1024 / 1024, 2) AS failsafe_mb
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
 WHERE TABLE_CATALOG = 'DEMO_NO_PK'
   AND TABLE_NAME = 'DML_PARTITION_DEMO'
   AND ACTIVE_BYTES > 0;
