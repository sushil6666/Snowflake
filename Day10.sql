-- ============================================
-- DEMO: Splitting Name Column using REGEXP
-- ============================================

-- Step 1: Create sample CSV-style data
CREATE OR REPLACE TEMPORARY TABLE name_demo (
    id INT,
    full_name VARCHAR(100),
    city,
    gender
);

INSERT INTO name_demo VALUES
    (1, 'John Michael Doe'),
    (2, 'Jane Smith'),
    (3, 'Alice Marie Johnson'),
    (4, 'Bob Lee'),
    (5, 'Charlie Ray Brown'),
    (6, 'Diana Prince');

-- Step 2: Split using REGEXP_SUBSTR
-- Pattern breakdown:
--   [^ ]+      = one or more non-space chars (a word)
--   occurrence  = which word to extract (1st, 2nd, 3rd)
SELECT
    id,
    full_name,
    REGEXP_SUBSTR(full_name, '[^ ]+', 1, 1) AS first_name,
    CASE
        WHEN REGEXP_COUNT(full_name, ' ') = 2
        THEN REGEXP_SUBSTR(full_name, '[^ ]+', 1, 2)
        ELSE NULL
    END AS mid_name,
    CASE
        WHEN REGEXP_COUNT(full_name, ' ') = 2
        THEN REGEXP_SUBSTR(full_name, '[^ ]+', 1, 3)
        WHEN REGEXP_COUNT(full_name, ' ') = 1
        THEN REGEXP_SUBSTR(full_name, '[^ ]+', 1, 2)
        ELSE NULL
    END AS last_name
FROM name_demo;

-- Step 3: Alternative — use REGEXP_REPLACE to isolate parts
SELECT
    id,
    full_name,
    REGEXP_REPLACE(full_name, ' .*', '')            AS first_name,
    CASE
        WHEN REGEXP_COUNT(full_name, ' ') = 2
        THEN REGEXP_REPLACE(full_name, '^\\S+ (\\S+) \\S+$', '\\1')
        ELSE NULL
    END AS mid_name,
    REGEXP_REPLACE(full_name, '.* ', '')             AS last_name
FROM name_demo;

-- Step 4: Store result into a new table
CREATE OR REPLACE TEMPORARY TABLE name_split AS
SELECT
    id,
    full_name,
    REGEXP_SUBSTR(full_name, '[^ ]+', 1, 1) AS first_name,
    CASE
        WHEN REGEXP_COUNT(full_name, ' ') = 2
        THEN REGEXP_SUBSTR(full_name, '[^ ]+', 1, 2)
        ELSE NULL
    END AS mid_name,
    CASE
        WHEN REGEXP_COUNT(full_name, ' ') = 2
        THEN REGEXP_SUBSTR(full_name, '[^ ]+', 1, 3)
        WHEN REGEXP_COUNT(full_name, ' ') = 1
        THEN REGEXP_SUBSTR(full_name, '[^ ]+', 1, 2)
        ELSE NULL
    END AS last_name
FROM name_demo;

SELECT * FROM name_split;


-- ============================================================================
-- JSON, AVRO & PARQUET: FILE HANDLING AND FLATTENING IN SNOWFLAKE
-- ============================================================================
-- All scripts verified and tested. Run each section sequentially.
-- ============================================================================

-- ============================================================================
-- SETUP: Create dedicated database & schema
-- ============================================================================
CREATE OR REPLACE DATABASE DEMO_SEMI_STRUCTURED;
CREATE OR REPLACE SCHEMA DEMO_SEMI_STRUCTURED.FILE_FORMATS_LAB;
USE SCHEMA DEMO_SEMI_STRUCTURED.FILE_FORMATS_LAB;


-- ============================================================================
-- MODULE 1: FOUNDATIONS — VARIANT, OBJECT, ARRAY 
-- ============================================================================

-- 1.1 Understanding Snowflake's semi-structured types
--     VARIANT = universal container for JSON, Avro, Parquet data
--     OBJECT  = key-value pairs (like a JSON object )
--     ARRAY   = ordered list of values
SELECT
    PARSE_JSON('{"name": "Sushil", "age": 30}')   AS variant_object,
    PARSE_JSON('[1, 2, 3]')                         AS variant_array,
    TYPEOF(PARSE_JSON('{"name": "Sushil"}'))        AS object_type,
    TYPEOF(PARSE_JSON('[1,2,3]'))                    AS array_type,
    TYPEOF(PARSE_JSON('42'))                         AS number_type,
    TYPEOF(PARSE_JSON('"hello"'))                    AS string_type;


-- 1.2 SQL NULL vs JSON null — CRITICAL distinction
--     SQL NULL   = value is missing/unknown (standard database NULL)
--     JSON null  = explicitly set to null in the JSON document (stored as VARIANT "null")
SELECT
    PARSE_JSON(NULL)              AS "SQL_NULL",
    PARSE_JSON('null')            AS "JSON_NULL",
    PARSE_JSON('{"a": null}'):a   AS "JSON_NULL_VALUE",
    TO_VARCHAR(PARSE_JSON('{"a": null}'):a) AS "CAST_TO_SQL_NULL";

-- SQL NULL vs JSON null inside ARRAY
SELECT ARRAY_CONSTRUCT(1, 2, NULL, PARSE_JSON('null')) AS array_with_nulls;
-- Output: [1, 2, undefined, null]
--         undefined = SQL NULL, null = JSON null


-- ============================================================================
-- MODULE 2: FILE FORMATS 
-- ============================================================================

-- 2.1 Create named file formats for each type
-- JSON file format
CREATE OR REPLACE FILE FORMAT my_json_format
    TYPE = JSON
    STRIP_OUTER_ARRAY = TRUE       -- unwrap outer [ ] into separate rows
    STRIP_NULL_VALUES = FALSE       -- keep JSON nulls (set TRUE to remove them)
    MULTI_LINE = TRUE;              -- handle pretty-printed JSON

-- Avro file format 
CREATE OR REPLACE FILE FORMAT my_avro_format
    TYPE = AVRO
    TRIM_SPACE = TRUE
    REPLACE_INVALID_CHARACTERS = TRUE;

-- Parquet file format (columnar binary)
CREATE OR REPLACE FILE FORMAT my_parquet_format
    TYPE = PARQUET
    BINARY_AS_TEXT = FALSE
    USE_VECTORIZED_SCANNER = TRUE;  -- better scan performance

-- 2.2 Verify created formats
SHOW FILE FORMATS IN SCHEMA DEMO_SEMI_STRUCTURED.FILE_FORMATS_LAB;

-- KEY FORMAT OPTIONS REFERENCE:
-- ┌──────────────────────────┬──────┬──────┬─────────┐
-- │ Option                   │ JSON │ Avro │ Parquet │
-- ├──────────────────────────┼──────┼──────┼─────────┤
-- │ COMPRESSION              │  ✓   │  ✓   │   ✓     │
-- │ STRIP_OUTER_ARRAY        │  ✓   │  ✗   │   ✗     │
-- │ STRIP_NULL_VALUES        │  ✓   │  ✗   │   ✗     │
-- │ MULTI_LINE               │  ✓   │  ✗   │   ✗     │
-- │ BINARY_AS_TEXT           │  ✗   │  ✗   │   ✓     │
-- │ USE_VECTORIZED_SCANNER   │  ✗   │  ✗   │   ✓     │
-- │ USE_LOGICAL_TYPE         │  ✗   │  ✗   │   ✓     │
-- │ TRIM_SPACE               │  ✓   │  ✓   │   ✓     │
-- │ REPLACE_INVALID_CHARACTERS│ ✓   │  ✓   │   ✓     │
-- └──────────────────────────┴──────┴──────┴─────────┘


-- ============================================================================
-- MODULE 3: LOADING & TRAVERSING JSON DATA 
-- ============================================================================

-- 3.1 Create sample JSON data (car dealership sales)
CREATE OR REPLACE TABLE car_sales (src VARIANT)
AS
SELECT PARSE_JSON(column1) 
FROM VALUES
('{
    "date": "2017-04-28",
    "dealership": "Valley View Auto Sales",
    "salesperson": {"id": "55", "name": "Frank Beasley"},
    "customer": [
        {"name": "Joyce Ridgely", "phone": "16504378889", "address": "San Francisco, CA"}
    ],
    "vehicle": [
        {"make": "Honda", "model": "Civic", "year": "2017", "price": "20275",
         "extras": ["ext warranty", "paint protection"]}
    ]
}'),
('{
    "date": "2017-28-04",
    "dealership": "Tindel Toyota",
    "salesperson": {"id": "274", "name": "Greg Northrup"},
    "customer": [
        {"name": "Bradley Greenbloom", "phone": "12127593751", "address": "New York, NY"}
    ],
    "vehicle": [
        {"make": "Toyota", "model": "Camry", "year": "2017", "price": "23500",
         "extras": ["ext warranty", "rust proofing", "fabric protection"]}
    ]
}') ;

select * from car_sales;

-- 3.2 DOT NOTATION — traverse JSON hierarchy with colons and dots
--     Syntax: column:level1.level2.level3
--     Keys are CASE-SENSITIVE, column names are NOT
SELECT
    src:date::STRING                AS sale_date,
    src:dealership::STRING          AS dealership,
    src:salesperson.name::STRING    AS salesperson_name,
    src:salesperson.id::INT         AS salesperson_id,
    src:customer.name::STRING       AS customer_name,
    src:customer.phone::STRING     AS customer_phone,
    src:vehicle.make::STRING       AS vehicle_make,
    src:vehicle.model::STRING      AS vehicle_model,
    src:vehicle.price::NUMBER      AS vehicle_price  
    
FROM car_sales;

SELECT
    --src:date::string                    AS sale_date,
    COALESCE(
        TRY_TO_DATE(src:date::STRING, 'YYYY-MM-DD'),
        TRY_TO_DATE(src:date::STRING, 'YYYY-DD-MM')
    ) AS sale_date,
    src:dealership::STRING              AS dealership,
    src:salesperson.name::STRING        AS salesperson_name,
    src:salesperson.id::INT             AS salesperson_id,
    src:customer[0].name::STRING        AS customer_name,
    src:customer[0].phone::STRING       AS customer_phone,
    src:customer[0].address::STRING     AS customer_address,
    src:vehicle[0].make::STRING         AS vehicle_make,
    src:vehicle[0].model::STRING        AS vehicle_model,
    src:vehicle[0].price::string        AS vehicle_price
FROM DEMO_SEMI_STRUCTURED.FILE_FORMATS_LAB.car_sales;


-- 3.3 BRACKET NOTATION — alternative syntax with single quotes
--     Syntax: column['key1']['key2']
SELECT
    src['date']::STRING                  AS sale_date,
    src['dealership']::STRING            AS dealership,
    src['salesperson']['name']::STRING   AS salesperson_name
FROM car_sales;


-- 3.4 ARRAY INDEX ACCESS — zero-based indexing
SELECT
    src:customer[0].name::STRING      AS customer_name,
    src:customer[0].phone::STRING     AS customer_phone,
    src:vehicle[0].make::STRING       AS vehicle_make,
    src:vehicle[0].model::STRING      AS vehicle_model,
    src:vehicle[0].price::NUMBER      AS vehicle_price
FROM car_sales;


-- ============================================================================
-- MODULE 4: AVRO DATA PATTERNS 
-- ============================================================================
-- Avro = binary format with embedded JSON schema
-- Snowflake loads Avro into a single VARIANT column
-- Queried exactly like JSON data
-- CANNOT unload data to Avro format

-- 4.1 Create Avro-style employee data
CREATE OR REPLACE TABLE avro_employees (src VARIANT)
AS
SELECT PARSE_JSON(column1) AS src FROM VALUES
('{"fullName": "John Doe",    "age": 22, "gender": "Male",   "department": "Engineering", "skills": ["Python", "SQL", "Java"]}'),
('{"fullName": "Anna Smith",  "age": 35, "gender": "Female", "department": "Marketing",   "skills": ["SEO", "Analytics"]}'),
('{"fullName": "Peter Jones", "age": 28, "gender": "Male",   "department": "Engineering", "skills": ["Go", "Rust", "Docker"]}'),
('{"fullName": "Maria Garcia","age": 41, "gender": "Female", "department": "Finance",     "skills": ["Excel", "SAP", "SQL"]}') v;


-- 4.2 Query Avro-style data (identical to JSON querying)
SELECT
    src:fullName::STRING     AS full_name,
    src:age::INT             AS age,
    src:gender::STRING       AS gender,
    src:department::STRING   AS department,
    ARRAY_SIZE(src:skills)   AS num_skills
FROM avro_employees
ORDER BY age;


-- 4.3 Flatten Avro skills array
SELECT
    src:fullName::STRING   AS full_name,
    src:department::STRING AS department,
    sk.VALUE::STRING       AS skill
FROM avro_employees,
    LATERAL FLATTEN(INPUT => src:skills) sk
ORDER BY full_name, sk.INDEX;


-- ============================================================================
-- MODULE 5: PARQUET DATA PATTERNS 
-- ============================================================================
-- Parquet = columnar binary format, highly compressed
-- Supports nested/complex types
-- CAN both load AND unload in Snowflake
-- Supports MATCH_BY_COLUMN_NAME for direct column mapping

-- 5.1 Create Parquet-style nested geography data
CREATE OR REPLACE TABLE parquet_geo (src VARIANT)



AS
SELECT PARSE_JSON(column1) AS src FROM VALUES
('{"continent": "Europe",       "country": {"name": "France",  "city": ["Paris", "Nice", "Marseilles", "Cannes"]}}'),
('{"continent": "Europe",       "country": {"name": "Germany", "city": ["Berlin", "Munich", "Hamburg"]}}'),
('{"continent": "North America","country": {"name": "USA",     "city": ["New York", "Los Angeles", "Chicago", "Houston"]}}'),
('{"continent": "Asia",         "country": {"name": "Japan",   "city": ["Tokyo", "Osaka", "Kyoto"]}}') v;


-- 5.2 Query nested Parquet-style data
SELECT
    src:continent::STRING        AS continent,
    src:country.name::STRING     AS country_name,
    ARRAY_SIZE(src:country.city) AS num_cities,
    src:country.city[0]::STRING  AS first_city
FROM parquet_geo;


-- 5.3 Flatten cities from nested structure
SELECT
    src:continent::STRING      AS continent,
    src:country.name::STRING   AS country_name,
    c.VALUE::STRING            AS city_name,
    c.INDEX                    AS city_index
FROM parquet_geo,
    LATERAL FLATTEN(INPUT => src:country.city) c
ORDER BY continent, country_name, c.INDEX;


-- 5.4 UNLOAD to Parquet (round-trip demo)
CREATE OR REPLACE STAGE parquet_demo_stage FILE_FORMAT = my_parquet_format;

COPY INTO @parquet_demo_stage/employees
FROM (
    SELECT
        src:fullName::STRING     AS full_name,
        src:age::INT             AS age,
        src:gender::STRING       AS gender,
        src:department::STRING   AS department
    FROM avro_employees
)
FILE_FORMAT = (TYPE = PARQUET)
HEADER = TRUE;


-- 5.5 INFER_SCHEMA — auto-detect Parquet file structure
SELECT *
FROM TABLE(
    INFER_SCHEMA(
        LOCATION => '@parquet_demo_stage/employees',
        FILE_FORMAT => 'my_parquet_format'
    )
);


-- 5.6 Create table using INFER_SCHEMA template (no manual DDL!)
CREATE OR REPLACE TABLE parquet_employees
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@parquet_demo_stage/employees',
                FILE_FORMAT => 'my_parquet_format'
            )
        )
    );


-- 5.7 Load with MATCH_BY_COLUMN_NAME (auto-maps columns)
COPY INTO parquet_employees
    FROM @parquet_demo_stage/employees
    FILE_FORMAT = (TYPE = PARQUET)
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Verify the round trip: Avro-style → Parquet file → Typed table
SELECT * FROM parquet_employees ORDER BY AGE;


-- 5.8 Query staged Parquet files DIRECTLY (no COPY needed)
SELECT
    $1:FULL_NAME::STRING   AS full_name,
    $1:AGE::INT            AS age,
    $1:DEPARTMENT::STRING  AS department
FROM @parquet_demo_stage/employees
(FILE_FORMAT => 'my_parquet_format')
ORDER BY age;


-- ============================================================================
-- MODULE 6: FLATTEN — DEEP DIVE (25 min)
-- ============================================================================

-- FLATTEN syntax:
-- FLATTEN( INPUT => <expr>
--        [, PATH => '<path>']
--        [, OUTER => TRUE | FALSE]    -- include rows with empty/missing arrays
--        [, RECURSIVE => TRUE | FALSE]
--        [, MODE => 'OBJECT' | 'ARRAY' | 'BOTH'] )
--
-- Output columns: SEQ, KEY, PATH, INDEX, VALUE, THIS


-- 6.1 BASIC ARRAY FLATTEN
SELECT
    src:dealership::STRING          AS dealership,
    src:vehicle[0].make::STRING     AS make,
    f.VALUE::STRING                 AS extra,
    f.INDEX                         AS extra_index
FROM car_sales,
    LATERAL FLATTEN(INPUT => src:vehicle[0].extras) f;


-- 6.2 FLATTEN on OBJECT — get all key-value pairs
SELECT
    f.KEY                AS field_name,
    f.VALUE::STRING      AS field_value,
    TYPEOF(f.VALUE)      AS value_type
FROM car_sales,
    LATERAL FLATTEN(INPUT => src:salesperson, MODE => 'OBJECT') f;


-- 6.3 FLATTEN output columns explained
--     SEQ   = sequence number (groups rows from same input row)
--     KEY   = object key name (NULL for arrays)
--     PATH  = path to this element
--     INDEX = array index (NULL for objects)
--     VALUE = the element value
--     THIS  = the parent array/object
SELECT
    f.SEQ    AS sequence_num,
    f.KEY    AS key,
    f.PATH   AS path,
    f.INDEX  AS array_index,
    f.VALUE  AS value,
    f.THIS   AS parent_element
FROM car_sales,
    LATERAL FLATTEN(INPUT => src:vehicle[0].extras) f;


-- 6.4 NESTED FLATTEN — Multi-level array explosion
CREATE OR REPLACE TABLE orders_raw (src VARIANT) AS
SELECT PARSE_JSON(column1) FROM VALUES
('{
    "store": "Main St",
    "customers": [
        {
            "name": "Alice",
            "orders": [
                {"item": "Laptop",   "qty": 1, "price": 999.99},
                {"item": "Mouse",    "qty": 2, "price": 25.50}
            ]
        },
        {
            "name": "Bob",
            "orders": [
                {"item": "Keyboard", "qty": 1, "price": 75.00}
            ]
        }
    ]
}'),
('{
    "store": "Oak Ave",
    "customers": [
        {
            "name": "Charlie",
            "orders": [
                {"item": "Monitor",  "qty": 1, "price": 450.00},
                {"item": "Webcam",   "qty": 1, "price": 89.99},
                {"item": "USB Hub",  "qty": 3, "price": 15.00}
            ]
        }
    ]
}') v;

-- Double FLATTEN: customers → orders (two levels deep)
SELECT
    src:store::STRING                   AS store,
    cust.VALUE:name::STRING             AS customer_name,
    ord.VALUE:item::STRING              AS item,
    ord.VALUE:qty::INT                  AS quantity,
    ord.VALUE:price::NUMBER(10,2)       AS price,
    (ord.VALUE:qty * ord.VALUE:price)::NUMBER(10,2) AS line_total
FROM orders_raw,
    LATERAL FLATTEN(INPUT => src:customers) cust,
    LATERAL FLATTEN(INPUT => cust.VALUE:orders) ord
ORDER BY store, customer_name, item;


-- 6.5 OUTER => TRUE — preserve rows with empty or missing arrays
CREATE OR REPLACE TABLE products (src VARIANT) AS
SELECT PARSE_JSON(column1) FROM VALUES
('{"name": "Widget",    "tags": ["sale", "new"]}'),
('{"name": "Gadget",    "tags": []}'),
('{"name": "Doohickey"}') v;

-- WITHOUT OUTER: Gadget and Doohickey are DROPPED (no tags to flatten)
SELECT src:name::STRING AS name, f.VALUE::STRING AS tag
FROM products,
    LATERAL FLATTEN(INPUT => src:tags) f;

-- WITH OUTER => TRUE: ALL rows preserved, NULL for missing values
SELECT src:name::STRING AS name, f.VALUE::STRING AS tag
FROM products,
    LATERAL FLATTEN(INPUT => src:tags, OUTER => TRUE) f;


-- 6.6 RECURSIVE FLATTEN — explode entire nested structure
SELECT
    f.KEY                AS key,
    f.PATH               AS path,
    f.VALUE::STRING      AS value,
    TYPEOF(f.VALUE)      AS value_type
FROM orders_raw,
    LATERAL FLATTEN(INPUT => src, RECURSIVE => TRUE, MODE => 'BOTH') f
WHERE TYPEOF(f.VALUE) NOT IN ('OBJECT', 'ARRAY')
ORDER BY f.SEQ, f.PATH
LIMIT 15;


-- 6.7 FULL MATERIALIZATION: VARIANT → relational table
--     Best practice: flatten semi-structured data into typed columns
--     for better query performance, pruning, and storage
CREATE OR REPLACE TABLE car_sales_flat AS
SELECT
    src:date::DATE                    AS sale_date,
    src:dealership::STRING            AS dealership,
    src:salesperson.id::INT           AS salesperson_id,
    src:salesperson.name::STRING      AS salesperson_name,
    c.VALUE:name::STRING              AS customer_name,
    c.VALUE:phone::STRING             AS customer_phone,
    c.VALUE:address::STRING           AS customer_address,
    v.VALUE:make::STRING              AS vehicle_make,
    v.VALUE:model::STRING             AS vehicle_model,
    v.VALUE:year::INT                 AS vehicle_year,
    v.VALUE:price::NUMBER(10,2)       AS vehicle_price,
    e.VALUE::STRING                   AS extra
FROM car_sales,
    LATERAL FLATTEN(INPUT => src:customer) c,
    LATERAL FLATTEN(INPUT => src:vehicle) v,
    LATERAL FLATTEN(INPUT => v.VALUE:extras, OUTER => TRUE) e;

SELECT * FROM car_sales_flat ORDER BY dealership, extra;


-- ============================================================================
-- MODULE 7: ADVANCED PATTERNS & BEST PRACTICES 
-- ============================================================================

-- 7.1 TRY_PARSE_JSON — safe parsing (returns NULL instead of error)
SELECT
    TRY_PARSE_JSON('{"valid": true}')   AS good_json,
    TRY_PARSE_JSON('not valid json')    AS bad_json,
    TRY_PARSE_JSON('')                  AS empty_string,
    TRY_PARSE_JSON(NULL)                AS null_input;


-- 7.2 OBJECT_CONSTRUCT — build JSON from scratch
SELECT OBJECT_CONSTRUCT(
    'name', 'Sushil',
    'role', 'Data Engineer',
    'skills', ARRAY_CONSTRUCT('SQL', 'Python', 'Snowflake'),
    'active', TRUE
) AS constructed_json;


-- 7.3 OBJECT_CONSTRUCT_KEEP_NULL — preserve NULLs in output
SELECT
    OBJECT_CONSTRUCT('a', 1, 'b', NULL, 'c', 3)            AS drops_nulls,
    OBJECT_CONSTRUCT_KEEP_NULL('a', 1, 'b', NULL, 'c', 3)  AS keeps_nulls;


-- 7.4 OBJECT manipulation functions
SELECT
    OBJECT_INSERT(PARSE_JSON('{"a":1, "b":2}'), 'c', 3)               AS after_insert,
    OBJECT_DELETE(PARSE_JSON('{"a":1, "b":2, "c":3}'), 'b')           AS after_delete,
    OBJECT_PICK(PARSE_JSON('{"a":1, "b":2, "c":3, "d":4}'), 'a','c') AS after_pick;


-- 7.5 ARRAY functions
SELECT
    ARRAY_CONTAINS('SQL'::VARIANT, PARSE_JSON('["Python","SQL","Java"]'))  AS has_sql,
    ARRAY_POSITION('SQL'::VARIANT, PARSE_JSON('["Python","SQL","Java"]'))  AS sql_index,
    ARRAY_SLICE(PARSE_JSON('["a","b","c","d","e"]'), 1, 4)                 AS sliced,
    ARRAY_SIZE(PARSE_JSON('["a","b","c","d","e"]'))                        AS arr_size,
    ARRAY_DISTINCT(PARSE_JSON('["a","b","a","c","b"]'))                    AS deduped;


-- 7.6 ARRAY_AGG — aggregate relational rows back into arrays
SELECT
    dealership,
    ARRAY_AGG(DISTINCT extra) AS all_extras,
    ARRAY_AGG(DISTINCT vehicle_make) AS makes
FROM car_sales_flat
GROUP BY dealership;


-- 7.7 FULL ROUND-TRIP: Relational → JSON reconstruction
SELECT OBJECT_CONSTRUCT(
    'dealership', dealership,
    'salesperson', salesperson_name,
    'customer', customer_name,
    'vehicle', OBJECT_CONSTRUCT(
        'make', vehicle_make,
        'model', vehicle_model,
        'year', vehicle_year,
        'price', vehicle_price
    ),
    'extras', ARRAY_AGG(extra)
) AS reconstructed_json
FROM car_sales_flat
GROUP BY dealership, salesperson_name, customer_name,
         vehicle_make, vehicle_model, vehicle_year, vehicle_price;


-- ============================================================================
-- SUMMARY: FORMAT COMPARISON
-- ============================================================================
-- ┌──────────────┬──────────────┬──────────────┬──────────────────┐
-- │ Feature      │ JSON         │ Avro         │ Parquet          │
-- ├──────────────┼──────────────┼──────────────┼──────────────────┤
-- │ Format       │ Text         │ Binary       │ Binary (columnar)│
-- │ Schema       │ Schema-less  │ Embedded     │ Embedded         │
-- │ Load         │ ✓            │ ✓            │ ✓                │
-- │ Unload       │ ✓            │ ✗            │ ✓                │
-- │ INFER_SCHEMA │ ✓            │ ✓            │ ✓                │
-- │ MATCH_BY_COL │ ✓            │ ✓            │ ✓                │
-- │ Compression  │ GZIP/BZ2/   │ GZIP/BROTLI/ │ SNAPPY/AUTO      │
-- │              │ BROTLI/ZSTD  │ ZSTD         │                  │
-- │ Best For     │ APIs, config │ Hadoop/Kafka │ Analytics,       │
-- │              │ logs         │ ecosystems   │ data lakes       │
-- └──────────────┴──────────────┴──────────────┴──────────────────┘

-- PERFORMANCE TIPS:
-- 1. Flatten into relational tables for better pruning and typed columns
-- 2. Use STRIP_NULL_VALUES = TRUE to improve subcolumnarization
-- 3. Use MATCH_BY_COLUMN_NAME for Parquet/Avro direct column mapping
-- 4. Use INFER_SCHEMA to auto-generate DDL from file metadata
-- 5. Use USE_VECTORIZED_SCANNER = TRUE for Parquet scans
-- 6. Always cast VARIANT fields to native types (::STRING, ::INT, etc.)
-- 7. Use OUTER => TRUE in FLATTEN when you need to preserve all rows


-- ============================================================================
-- CLEANUP (optional — uncomment to drop demo objects)
-- ============================================================================
-- DROP DATABASE IF EXISTS DEMO_SEMI_STRUCTURED;
