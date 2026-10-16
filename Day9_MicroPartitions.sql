-- ============================================================================
-- SNOWFLAKE INTERVIEW QUESTION: MICRO-PARTITIONS
-- ============================================================================

-- ============================================================================
-- SCENARIO
-- ============================================================================
-- Imagine a table with:
--   - 10 million rows
--   - 100 micro-partitions
--   - 100,000 rows per micro-partition
--
-- Now execute:

UPDATE my_table
SET status = 'UPDATED'
WHERE id = 5;

-- Assume id is unique.

-- QUESTION: How many micro-partitions will Snowflake scan and rewrite?

-- ============================================================================
-- ANSWER
-- ============================================================================

-- ---------------------------------------------------------------------------
-- SCANNING
-- ---------------------------------------------------------------------------
-- Snowflake stores min/max metadata for every column in every micro-partition.
-- Before touching any data, it uses this metadata to PRUNE partitions whose
-- min/max range for `id` cannot contain the value 5.
--
-- BEST CASE  : id is well-clustered (e.g., inserted in order).
--              Only 1 micro-partition's range includes id = 5.
--              Snowflake scans just 1 partition.
--
-- WORST CASE : id values are randomly distributed; min/max ranges overlap
--              across many or all partitions.
--              Snowflake may need to scan multiple — potentially all 100
--              partitions — to locate the row.
--
-- KEY POINT  : A unique id does NOT guarantee only 1 partition is scanned.
--              Pruning effectiveness depends on how well the data is
--              physically clustered, not on logical uniqueness.

-- ---------------------------------------------------------------------------
-- REWRITING
-- ---------------------------------------------------------------------------
-- Snowflake micro-partitions are IMMUTABLE. There is no in-place update.
--
-- When a row is updated:
--   1. The micro-partition containing that row is marked for replacement.
--   2. A NEW micro-partition is written with the updated row + all other
--      unchanged rows from that same partition.
--   3. The old micro-partition is eventually garbage-collected.
--
-- Since id is unique, only ONE micro-partition contains the matching row.
-- Therefore, exactly 1 micro-partition is rewritten — NOT the entire table.

-- ---------------------------------------------------------------------------
-- SUMMARY
-- ---------------------------------------------------------------------------
-- Partitions SCANNED  : 1 to 100 (depends on clustering / pruning)
-- Partitions REWRITTEN: exactly 1 (since only 1 partition holds id = 5)
--
-- IMPORTANT DISTINCTION:
--   Scanned != Rewritten
--   Snowflake may read many partitions to find the row,
--   but only rewrites the one that actually contains it.

-- ============================================================================
-- KEY LESSONS
-- ============================================================================
-- 1. Unique ID does NOT guarantee one partition scanned.
-- 2. Micro-partition pruning (min/max metadata) determines scan scope.
-- 3. A single-row update rewrites the entire affected micro-partition.
-- 4. Updating one row does NOT rewrite the entire table.
-- 5. Scanned partitions and rewritten partitions are two different numbers.

-- ============================================================================
-- DEMO: SEE PRUNING IN ACTION
-- ============================================================================

-- Step 1: Create the table with 10M rows
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO (
    id        INT,
    status    VARCHAR(20),
    payload   VARCHAR(100)
);

-- Insert 10M rows with sequential IDs (well-clustered)
INSERT INTO DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO
SELECT
    SEQ4()                        AS id,
    'ACTIVE'                      AS status,
    'row_' || SEQ4()::VARCHAR     AS payload
FROM TABLE(GENERATOR(ROWCOUNT => 10000000));

-- Step 2: Check micro-partition count and clustering info
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO', '(id)');

-- Step 3: Run the update and check the query profile
UPDATE DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO
SET status = 'UPDATED'
WHERE id = 5;

-- After running, check the Query Profile in Snowsight:
--   - "Partitions scanned"  vs  "Partitions total"
--   - This tells you exactly how many partitions Snowflake examined

-- Step 4: Now see what happens with POORLY clustered data
CREATE OR REPLACE TABLE DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO_RANDOM (
    id        INT,
    status    VARCHAR(20),
    payload   VARCHAR(100)
);

-- Insert same data but with random ordering (poor clustering on id)
INSERT INTO DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO_RANDOM
SELECT
    id,
    status,
    payload
FROM DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO
ORDER BY RANDOM();

-- Step 5: Check clustering — expect poor depth for id
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO_RANDOM', '(id)');

-- Step 6: Run the same update on the randomly ordered table
UPDATE DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO_RANDOM
SET status = 'UPDATED'
WHERE id = 5;

-- Compare the query profiles:
--   SEQUENTIAL table : partitions scanned ≈ 1
--   RANDOM table     : partitions scanned ≈ ALL
--   Both tables      : partitions rewritten = 1

-- ============================================================================
-- CLEANUP
-- ============================================================================
-- DROP TABLE IF EXISTS DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO;
-- DROP TABLE IF EXISTS DEMO_NO_PK.RAW.MICRO_PARTITION_DEMO_RANDOM;
