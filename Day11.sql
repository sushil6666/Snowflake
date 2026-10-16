/* =====================================================================
   Connect Snowflake to AWS S3 (load + unload) - full step-by-step guide
   ---------------------------------------------------------------------
   Bucket : sushil-snowflake-data   (region ap-southeast-2, Sydney)
   Folder : data/
   AWS account       : 988573432872
   Snowflake account : ZM84520 (region AWS_AP_NORTHEAST_1, Tokyo)
   Run as role ACCOUNTADMIN on warehouse COMPUTE_WH
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
ALTER WAREHOUSE COMPUTE_WH RESUME IF SUSPENDED;


/* ---------------------------------------------------------------------
   STEP 1 (AWS console): Create the S3 bucket
   ---------------------------------------------------------------------
   1. AWS Console -> S3 -> Create bucket
   2. Bucket name : sushil-snowflake-data
   3. Region      : Asia Pacific (Sydney) ap-southeast-2
   4. Keep "Block all public access" ON, leave other defaults
   5. Create bucket, then open it -> Create folder -> data/
   --------------------------------------------------------------------- */


/* ---------------------------------------------------------------------
   STEP 2 (AWS console): Create IAM policy "snowflake_s3_access"
   ---------------------------------------------------------------------
   IAM -> Policies -> Create policy -> JSON tab -> paste:

   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:GetObject",
           "s3:GetObjectVersion",
           "s3:DeleteObject",
           "s3:DeleteObjectVersion"
         ],
         "Resource": "arn:aws:s3:::sushil-snowflake-data/data/*"
       },
       {
         "Effect": "Allow",
         "Action": [
           "s3:ListBucket",
           "s3:GetBucketLocation"
         ],
         "Resource": "arn:aws:s3:::sushil-snowflake-data",
         "Condition": {
           "StringLike": {
             "s3:prefix": ["data/*"]
           }
         }
       }
     ]
   }

   Next -> Policy name: snowflake_s3_access -> Create policy
   --------------------------------------------------------------------- */


/* ---------------------------------------------------------------------
   STEP 3 (AWS console): Create IAM role "snowflake_s3_role"
   ---------------------------------------------------------------------
   1. IAM -> Roles -> Create role
   2. Trusted entity: AWS account -> Another AWS account
      Account ID: 988573432872 (temporary - replaced in Step 5)
   3. Tick "Require external ID", enter 0000 (temporary)
   4. Attach policy: snowflake_s3_access
   5. Role name: snowflake_s3_role -> Create role
   6. Copy the Role ARN: arn:aws:iam::988573432872:role/snowflake_s3_role
   --------------------------------------------------------------------- */


/* ---------------------------------------------------------------------
   STEP 4 (Snowflake): Create the storage integration
   --------------------------------------------------------------------- */
CREATE OR REPLACE STORAGE INTEGRATION s3_integration
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::988573432872:role/snowflake_s3_role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://sushil-snowflake-data/data/');

-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from the output
-- NOTE: re-running CREATE OR REPLACE above generates a NEW external ID,
--       so the trust policy in Step 5 would need updating again.
DESC INTEGRATION s3_integration;


/* ---------------------------------------------------------------------
   STEP 5 (AWS console): Update the trust policy on snowflake_s3_role
   ---------------------------------------------------------------------
   IAM -> Roles -> snowflake_s3_role -> Trust relationships
   -> Edit trust policy -> replace everything with:

   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "AWS": "arn:aws:iam::687622360952:user/fpr72000-s"
         },
         "Action": "sts:AssumeRole",
         "Condition": {
           "StringEquals": {
             "sts:ExternalId": "ZM84520_SFCRole=3_l0Yxc7sknolK+JuvANc1T3VBoHc="
           }
         }
       }
     ]
   }

   -> Update policy
   Also check: IAM -> Account settings -> STS Endpoints ->
   Asia Pacific (Tokyo) ap-northeast-1 must be Active.
   --------------------------------------------------------------------- */


/* ---------------------------------------------------------------------
   STEP 6 (Snowflake): Create database, stage, and test
   --------------------------------------------------------------------- */
CREATE DATABASE IF NOT EXISTS S3_DATA_DB;

-- Option A: role-based stage (most secure, no keys stored)
-- This failed with "not authorized to perform: sts:AssumeRole" because
-- the AWS account is on the limited/free plan.
CREATE OR REPLACE STAGE S3_DATA_DB.PUBLIC.s3_stage
  URL = 's3://sushil-snowflake-data/data/'
  STORAGE_INTEGRATION = s3_integration;

LIST @S3_DATA_DB.PUBLIC.s3_stage;


/* ---------------------------------------------------------------------
   STEP 6b: Option B - access-key based stage (what is currently in use)
   ---------------------------------------------------------------------
   AWS console first:
   1. IAM -> Users -> Create user -> name: snowflake_s3_user
      (no console access)
   2. Attach policies directly -> snowflake_s3_access -> Create user
   3. Open user -> Security credentials -> Create access key
      -> Third-party service -> copy Access key ID + Secret access key

   Then replace the placeholders below, run it, and put the
   placeholders back. Never save or share real keys in this file.
   --------------------------------------------------------------------- */
CREATE OR REPLACE STAGE S3_DATA_DB.PUBLIC.s3_stage
  URL = 's3://sushil-snowflake-data/data/'
  CREDENTIALS = (AWS_KEY_ID = '<your_access_key_id>' AWS_SECRET_KEY = '<your_secret_access_key>');

-- Test the connection (0 rows = connected, empty folder)
LIST @S3_DATA_DB.PUBLIC.s3_stage;


/* ---------------------------------------------------------------------
   STEP 7 (Snowflake): Load employees.csv into a table
   ---------------------------------------------------------------------
   Upload employees.csv to s3://sushil-snowflake-data/data/ first.
   --------------------------------------------------------------------- */

-- SKIP_HEADER = 2 because the file starts with a "--employees.csv" line, then the column header
CREATE OR REPLACE FILE FORMAT S3_DATA_DB.PUBLIC.csv_format
  TYPE = CSV
  SKIP_HEADER = 2
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE;

-- Helper format to inspect raw lines of a file
CREATE OR REPLACE FILE FORMAT S3_DATA_DB.PUBLIC.raw_line_format
  TYPE = CSV
  FIELD_DELIMITER = NONE
  SKIP_HEADER = 0;

-- See exactly what is in the file, line by line
SELECT METADATA$FILE_ROW_NUMBER AS line_no, $1 AS raw_line
FROM @S3_DATA_DB.PUBLIC.s3_stage/employees.csv
  (FILE_FORMAT => 'S3_DATA_DB.PUBLIC.raw_line_format');

CREATE OR REPLACE TABLE S3_DATA_DB.PUBLIC.employees (
  id   INTEGER,
  name VARCHAR,
  city VARCHAR
);

COPY INTO S3_DATA_DB.PUBLIC.employees
FROM @S3_DATA_DB.PUBLIC.s3_stage/employees.csv
FILE_FORMAT = (FORMAT_NAME = 'S3_DATA_DB.PUBLIC.csv_format');

SELECT * FROM S3_DATA_DB.PUBLIC.employees ORDER BY id;


/* ---------------------------------------------------------------------
   STEP 8 (Snowflake): Unload the table back to S3 (data/export/)
   --------------------------------------------------------------------- */
COPY INTO @S3_DATA_DB.PUBLIC.s3_stage/export/employees_
FROM S3_DATA_DB.PUBLIC.employees
FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE)
HEADER = TRUE
OVERWRITE = TRUE;

LIST @S3_DATA_DB.PUBLIC.s3_stage/export/;
