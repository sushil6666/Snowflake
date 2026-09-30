-- ============================================================
-- COMPLETE DEMO: Handling Duplicate Headers Across Multiple Files
-- Topics: SKIP_HEADER, $column extraction, METADATA$FILE_ROW_NUMBER
-- ============================================================

-- SETUP: Database, schema, stage, file format
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE DATABASE demo_headers;
USE DATABASE demo_headers;
USE SCHEMA public;

CREATE OR REPLACE WAREHOUSE demo_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
USE WAREHOUSE demo_wh;

-- File format WITHOUT skip_header (loads everything including headers)
CREATE OR REPLACE FILE FORMAT csv_raw
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 0;

-- File format WITH skip_header (skips first row of each file)
CREATE OR REPLACE FILE FORMAT csv_skip
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1;

-- Internal stage to hold our CSV files
CREATE OR REPLACE STAGE demo_stage
  FILE_FORMAT = csv_raw;


-- ============================================================
-- 2. CREATE SAMPLE CSV FILES (3 files, each with a header row)
-- ============================================================

-- File 1: employees_part1.csv
-- Use 3 columns so Snowflake writes a proper multi-column CSV
CREATE OR REPLACE TEMPORARY TABLE tmp_file1 (c1 VARCHAR, c2 VARCHAR, c3 VARCHAR) AS
SELECT 'Name', 'Age', 'Department' UNION ALL
SELECT 'Alice', '30', 'Engineering' UNION ALL
SELECT 'Bob', '25', 'Marketing';

select * from tmp_file1;

COPY INTO @demo_stage/employees_part1.csv
FROM tmp_file1
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'NONE')
OVERWRITE = TRUE
SINGLE = TRUE;

-- File 2: employees_part2.csv
CREATE OR REPLACE TEMPORARY TABLE tmp_file2 (c1 VARCHAR, c2 VARCHAR, c3 VARCHAR) AS
SELECT 'Name', 'Age', 'Department' UNION ALL
SELECT 'Charlie', '35', 'Finance' UNION ALL
SELECT 'Diana', '28', 'Engineering';

COPY INTO @demo_stage/employees_part2.csv
FROM tmp_file2
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'NONE')
OVERWRITE = TRUE
SINGLE = TRUE;

-- File 3: employees_part3.csv
CREATE OR REPLACE TEMPORARY TABLE tmp_file3 (c1 VARCHAR, c2 VARCHAR, c3 VARCHAR) AS
SELECT 'Name', 'Age', 'Department' UNION ALL
SELECT 'Eve', '32', 'Marketing' UNION ALL
SELECT 'Frank', '40', 'Finance';

COPY INTO @demo_stage/employees_part3.csv
FROM tmp_file3
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'NONE')
OVERWRITE = TRUE
SINGLE = TRUE;

-- Verify files are on stage
LIST @demo_stage;


-- ============================================================
-- 3. VALIDATION_MODE: Test loading WITHOUT inserting any rows
-- ============================================================
-- Use VALIDATION_MODE to dry-run a COPY INTO and catch errors
-- (column mismatches, type cast failures, bad data) BEFORE loading.

-- Create the target tables first (VALIDATION_MODE still needs them to exist)
CREATE OR REPLACE TABLE employees_raw (
  name       VARCHAR,
  age        VARCHAR,   -- VARCHAR so header rows don't fail on cast
  department VARCHAR
);

CREATE OR REPLACE TABLE employees_final (
  name       VARCHAR,
  age        INT,
  department VARCHAR
);

-- RETURN_ALL_ERRORS: scans all files, returns every error row
COPY INTO employees_raw
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
VALIDATION_MODE = 'RETURN_ALL_ERRORS';
-- No rows inserted. Returns any rows that would have caused errors.

-- RETURN_ERRORS: same as above but only for rows processed so far
COPY INTO employees_raw
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
VALIDATION_MODE = 'RETURN_ERRORS';

-- RETURN_n_ROWS: returns first n rows that WOULD be loaded (no insert)
-- Great for previewing what the load looks like before committing.
COPY INTO employees_raw
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
VALIDATION_MODE = 'RETURN_9_ROWS';
-- Returns 3 rows as a preview. Notice header rows appear as data!

select * from employees_raw;

-- Now test with SKIP_HEADER — preview should be clean data only
COPY INTO employees_raw
FROM @demo_stage
FILE_FORMAT = csv_skip
PATTERN = '.*employees_part.*[.]csv.*'
VALIDATION_MODE = 'RETURN_6_ROWS';
-- Returns 3 clean data rows. No headers. Safe to load.

-- Test a typed table — VALIDATION_MODE catches the cast failure
-- NOTE: VALIDATION_MODE does not support COPY with transforms (subqueries),
-- so load directly from stage into the typed table instead.
COPY INTO employees_final
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
VALIDATION_MODE = 'RETURN_ALL_ERRORS';
-- Returns the header rows that fail INT cast ('Age' can't become INT).
-- This confirms you need SKIP_HEADER or a WHERE filter.

-- Verify the tables are still empty — VALIDATION_MODE never inserts
SELECT 'employees_raw' AS tbl, COUNT(*) AS row_count FROM employees_raw
UNION ALL
SELECT 'employees_final', COUNT(*) FROM employees_final;
-- Both return 0. No data was loaded.


-- ============================================================
-- 3b. ON_ERROR: Control what happens when bad rows are encountered
-- ============================================================
-- ON_ERROR decides whether COPY INTO aborts, skips, or continues
-- when it hits a data error (type cast failure, column mismatch, etc.)

-- First, create a typed table where header rows WILL cause errors
CREATE OR REPLACE TABLE employees_typed_test (
  name       VARCHAR,
  age        INT,          -- header row 'Age' will fail INT cast
  department VARCHAR
);

-- DEFAULT (ABORT_STATEMENT): entire load fails on first error
-- Nothing is loaded — even the good rows are rolled back.
COPY INTO employees_typed_test
FROM @demo_stage
FILE_FORMAT = csv_raw       -- no SKIP_HEADER, so headers are loaded
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'ABORT_STATEMENT';
-- ERROR: Numeric value 'Age' is not recognized
-- 0 rows loaded.

SELECT 'After ABORT' AS stage, COUNT(*) AS row_count FROM employees_typed_test;
-- 0 rows


-- CONTINUE: skip bad rows, load everything else
TRUNCATE TABLE employees_typed_test;

COPY INTO employees_typed_test
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'CONTINUE';
-- Skips the 3 header rows (cast failure), loads the 6 data rows.

SELECT 'After CONTINUE' AS stage, COUNT(*) AS row_count FROM employees_typed_test;
-- 6 rows — only the valid data rows were loaded

SELECT * FROM employees_typed_test;


-- SKIP_FILE: if ANY row in a file has an error, skip the ENTIRE file
TRUNCATE TABLE employees_typed_test;

COPY INTO employees_typed_test
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'SKIP_FILE';
-- Every file has a header row that fails → ALL 3 files are skipped.

SELECT 'After SKIP_FILE' AS stage, COUNT(*) AS row_count FROM employees_typed_test;
-- 0 rows — every file had at least one bad row


-- SKIP_FILE_n: skip file when its error count reaches n (>= n)
TRUNCATE TABLE employees_typed_test;

COPY INTO employees_typed_test
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'SKIP_FILE_3';
-- Each file has only 1 error (the header row), which is < 3.
-- So no files are skipped; bad rows are silently dropped.

SELECT 'After SKIP_FILE_3' AS stage, COUNT(*) AS row_count FROM employees_typed_test;
-- 6 rows — all files loaded, only header rows dropped

SELECT * FROM employees_typed_test;


-- SKIP_FILE_n% : skip file when errors reach n% of its rows (limit rounds down, minimum 1)
TRUNCATE TABLE employees_typed_test;

COPY INTO employees_typed_test
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'SKIP_FILE_5%';
-- Limit = 10% of 3 rows = 0.3 -> rounds down, minimum 1 -> error_limit = 1.
-- 1 error reaches the limit, so all 3 files are skipped.

SELECT 'After SKIP_FILE_10%' AS stage, COUNT(*) AS row_count FROM employees_typed_test;
-- 0 rows

TRUNCATE TABLE employees_typed_test;  -- TRUNCATE also clears load history

COPY INTO employees_typed_test
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'SKIP_FILE_50%';
-- Gotcha: error limit = FLOOR(3 rows * 50%) = 1, and a file is skipped when
-- errors REACH the limit. 1 error >= 1 -> all files skipped (see error_limit column).

SELECT 'After SKIP_FILE_50%' AS stage, COUNT(*) AS row_count FROM employees_typed_test;
-- 0 rows

TRUNCATE TABLE employees_typed_test;

COPY INTO employees_typed_test
FROM @demo_stage
FILE_FORMAT = csv_raw
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'SKIP_FILE_67%';
-- Error limit = FLOOR(3 * 67%) = 2. 1 error < 2 -> files load, bad row dropped.

SELECT 'After SKIP_FILE_67%' AS stage, COUNT(*) AS row_count FROM employees_typed_test;
-- 6 rows


-- Cleanup test table
DROP TABLE employees_typed_test;

/*
  ON_ERROR SUMMARY
  ─────────────────────────────────────────────────────────────
  ABORT_STATEMENT    | Default. Entire COPY fails on first error.
                     | No rows loaded at all.
  ─────────────────────────────────────────────────────────────
  CONTINUE           | Skip bad rows, load the rest.
                     | Best when a few scattered bad rows are OK.
  ─────────────────────────────────────────────────────────────
  SKIP_FILE          | Skip entire file if ANY row has an error.
                     | Best for all-or-nothing per-file loading.
  ─────────────────────────────────────────────────────────────
  SKIP_FILE_n        | Skip file when errors reach n (>= n).
                     | Tolerates up to n-1 bad rows per file.
  ─────────────────────────────────────────────────────────────
  SKIP_FILE_n%       | Skip file when errors reach n% of rows (limit rounds down, minimum 1).
                     | Good for ratio-based quality gates.
  ─────────────────────────────────────────────────────────────

  TIP: Combine with VALIDATION_MODE = 'RETURN_ALL_ERRORS' first
       to preview errors, then choose the right ON_ERROR strategy.
*/


-- ============================================================
-- 4. PROBLEM: Loading without SKIP_HEADER pulls in all headers
-- ============================================================

-- employees_raw already created in section 3; just clear it
TRUNCATE TABLE employees_raw;

COPY INTO employees_raw
FROM @demo_stage
FILE_FORMAT = csv_raw        -- SKIP_HEADER = 0
PATTERN = '.*employees_part.*[.]csv.*';

-- See the problem: header rows from each file are loaded as data
SELECT * FROM employees_raw;
-- You'll see rows like ('Name','Age','Department') mixed with real data


-- ============================================================
-- 4. FIX #1: SKIP_HEADER = 1 (simplest approach)
-- ============================================================
-- Skips the first row of EACH file automatically.

TRUNCATE TABLE employees_raw;

COPY INTO employees_raw
FROM @demo_stage
FILE_FORMAT = csv_skip        -- SKIP_HEADER = 1
PATTERN = '.*employees_part.*[.]csv.*';

SELECT * FROM employees_raw;
-- Clean! No header rows. Only 6 data rows.


-- ============================================================
-- 5. FIX #2: METADATA$FILE_ROW_NUMBER (most reliable)
-- ============================================================
-- Works even when SKIP_HEADER isn't set. Filters row 1 from every file.

CREATE OR REPLACE TABLE employees_final (
  name       VARCHAR,
  age        INT,
  department VARCHAR
);

COPY INTO employees_final (name, age, department)
FROM (
  SELECT
    $1,              -- $1 = first column (Name)
    $2::INT,         -- $2 = second column (Age), cast to INT
    $3               -- $3 = third column (Department)
  FROM @demo_stage
  (FILE_FORMAT => 'csv_skip')   -- no skip_header
)
PATTERN = '.*employees_part.*[.]csv.*'
ON_ERROR = 'CONTINUE';
-- This will FAIL because header rows have 'Age' which can't cast to INT.
-- That proves we need to filter headers BEFORE casting.

select * from employees_final;

-- ============================================================
-- 6. FIX #3: Query stage + WHERE filter (for SELECT or views)
-- ============================================================
-- Use $N column references + METADATA$ columns to inspect and filter.

-- Preview all data with metadata
SELECT
  METADATA$FILENAME          AS source_file,
  METADATA$FILE_ROW_NUMBER   AS row_num,
  $1 AS col1,
  $2 AS col2,
  $3 AS col3
FROM @demo_stage
(FILE_FORMAT => 'csv_raw', PATTERN => '.*employees_part.*[.]csv.*');

-- Filter out row 1 from each file (the header)
SELECT
  METADATA$FILENAME          AS source_file,
  $1                         AS name,
  $2::INT                    AS age,
  $3                         AS department
FROM @demo_stage
(FILE_FORMAT => 'csv_raw')
WHERE METADATA$FILE_ROW_NUMBER > 1;

-- Or filter by matching the header value itself
SELECT
  $1 AS name,
  $2::INT AS age,
  $3 AS department
FROM @demo_stage
(FILE_FORMAT => 'csv_raw')
WHERE $1 != 'Name';


-- ============================================================
-- 7. FIX #4: Post-load cleanup (DELETE after loading)
-- ============================================================
-- When headers are already in the table, remove them afterwards.

TRUNCATE TABLE employees_raw;

COPY INTO employees_raw
FROM @demo_stage
FILE_FORMAT = csv_raw         -- SKIP_HEADER = 0, loads headers too
PATTERN = '.*employees_part.*[.]csv.*';

-- See the mess
SELECT * FROM employees_raw;

-- Delete rows where data matches the known header
DELETE FROM employees_raw
WHERE name = 'Name' AND age = 'Age';

-- Clean result
SELECT * FROM employees_raw;


-- ============================================================
-- 8. FIX #5: Load into final table using SKIP_HEADER + $N casting
-- ============================================================
-- Combines SKIP_HEADER with column extraction and type casting.

CREATE OR REPLACE TABLE employees_typed (
  name       VARCHAR,
  age        INT,
  department VARCHAR,
  source_file VARCHAR
);

COPY INTO employees_typed (name, age, department, source_file)
FROM (
  SELECT
    $1,                        -- name (VARCHAR)
    $2::INT,                   -- age  (cast to INT)
    $3,                        -- department (VARCHAR)
    METADATA$FILENAME          -- track which file each row came from
  FROM @demo_stage
  (FILE_FORMAT => 'csv_skip')  -- SKIP_HEADER = 1
)
PATTERN = '.*employees_part.*[.]csv.*';

-- Final clean, typed table with source tracking
SELECT * FROM employees_typed;


-- ============================================================
-- 9. SUMMARY
-- ============================================================
/*
  TECHNIQUE                         | WHEN TO USE
  ----------------------------------|--------------------------------------------
  SKIP_HEADER = 1                   | Each file has exactly 1 header at the top
  METADATA$FILE_ROW_NUMBER > 1      | Most reliable per-file header removal
  WHERE $1 != 'HeaderValue'         | Headers embedded mid-file or concatenated
  DELETE FROM ... WHERE col = 'Hdr' | Post-load cleanup when headers already in
  $1, $2::TYPE, METADATA$FILENAME   | Column extraction + casting + source tracking

  BEST PRACTICE:
    - Use a staging table with all VARCHAR columns
    - Apply SKIP_HEADER = 1 in the file format
    - Use COPY INTO ... FROM (SELECT $1, $2::INT ... ) for type casting
    - Add METADATA$FILENAME to track which file each row came from
*/


-- ============================================================
-- 10. CLEANUP (uncomment to run)
-- ============================================================
-- DROP DATABASE demo_headers;
-- DROP WAREHOUSE demo_wh;
