/*A stage is Snowflake's contract between "files in the wild" and "structured data in tables." 
It's the control point for security, format handling.
Without it, every data load would need inline credentials, format specs, and duplicate-detection logic  repeated every time.

A "stage" is a named location where data files sit before (or after)
being loaded into / unloaded from Snowflake tables.*/

-- 2A. Create a named internal stage
CREATE OR REPLACE STAGE demo_internal_stage
  COMMENT = 'Demo internal stage with server-side encryption';

  show stages;

-- 2B. List files on the stage (empty right now)
LIST @demo_internal_stage;

-- 2C. Upload files via PUT (run from SnowSQL / CLI, not Snowsight)
-- PUT file://C:\Users\isush\OneDrive\Desktop\Demo\sample_data.csv @demo_internal_stage AUTO_COMPRESS=TRUE;

-- 2D. Verify the upload
LIST @demo_internal_stage;

-- 2E. Query files directly ON the stage (before loading)
SELECT
    $1 AS col1,
    $2 AS col2,
    $3 AS col3,
    METADATA$FILENAME   AS file_name,
    METADATA$FILE_ROW_NUMBER AS row_num
FROM @demo_internal_stage 

SELECT $*
FROM @demo_internal_stage 


-- 2F. Load data using COPY INTO
CREATE OR REPLACE TABLE demo_target (
    id NUMBER,
    name STRING,
    city STRING,
    file_name STRING
);

COPY INTO demo_target(id, name, city, file_name)
FROM @demo_internal_stage
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 2)
ON_ERROR = 'CONTINUE';
-- keep files on stage after loading



-- 2G. Verify load
SELECT * FROM demo_target LIMIT 10;

-- 2H. Check COPY history
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME   => 'DEMO_TARGET',
    START_TIME   => DATEADD(HOURS, -1, CURRENT_TIMESTAMP())
));

-- 2I. Remove files from stage when done
REMOVE @demo_internal_stage;