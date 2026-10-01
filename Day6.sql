-- DYNAMIC DATA MASKING & COLUMN-LEVEL SECURITY
-- ############################################################################

-- ============================================================================
-- 1.1 SETUP: Database, Schemas, Sample Data, Roles
-- ============================================================================

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE DATABASE masking_demo;
USE DATABASE masking_demo;

CREATE SCHEMA security;
CREATE SCHEMA data;

-- Sample customer data with sensitive columns
CREATE OR REPLACE TABLE data.customers (
    id        INT,
    name      VARCHAR,
    email     VARCHAR,
    ssn       VARCHAR,
    phone     VARCHAR,
    region    VARCHAR
);

INSERT INTO data.customers VALUES
    (1, 'Alice Smith',  'alice@acme.com',   '123-45-6789', '555-100-2000', 'NA'),
    (2, 'Bob Jones',    'bob@acme.com',     '987-65-4321', '555-200-3000', 'EU'),
    (3, 'Carol Lee',    'carol@acme.com',   '456-78-9012', '555-300-4000', 'APAC'),
    (4, 'Dave Kim',     'dave@globex.com',  '321-54-9876', '555-400-5000', 'NA'),
    (5, 'Eve Brown',    'eve@initech.com',  '654-32-1098', '555-500-6000', 'EU');

-- Create functional roles
CREATE ROLE IF NOT EXISTS analyst_role;
CREATE ROLE IF NOT EXISTS support_role;
CREATE ROLE IF NOT EXISTS masking_admin;

-- Grant base access to roles
GRANT USAGE ON DATABASE masking_demo TO ROLE analyst_role;
GRANT USAGE ON DATABASE masking_demo TO ROLE support_role;
GRANT USAGE ON SCHEMA data TO ROLE analyst_role;
GRANT USAGE ON SCHEMA data TO ROLE support_role;
GRANT SELECT ON TABLE data.customers TO ROLE analyst_role;
GRANT SELECT ON TABLE data.customers TO ROLE support_role;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE analyst_role;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE support_role;

-- Masking admin privileges (Separation of Duties)
GRANT CREATE MASKING POLICY ON SCHEMA security TO ROLE masking_admin;
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE masking_admin;
GRANT USAGE ON DATABASE masking_demo TO ROLE masking_admin;
GRANT USAGE ON SCHEMA security TO ROLE masking_admin;

-- Assign roles to your user
GRANT ROLE masking_admin TO USER SUSHIL;
GRANT ROLE analyst_role TO USER SUSHIL;
GRANT ROLE support_role TO USER SUSHIL;


-- ============================================================================
-- 1.2 BASIC MASKING POLICIES
-- ============================================================================

USE ROLE masking_admin;
USE DATABASE masking_demo;

-- POLICY 1: Full mask for SSN — only analyst sees real values
CREATE OR REPLACE MASKING POLICY security.ssn_mask
AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN val
        ELSE '***-**-****'
    END;

-- POLICY 2: Partial mask for email — support sees domain only
CREATE OR REPLACE MASKING POLICY security.email_mask
AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN val
        WHEN CURRENT_ROLE() IN ('SUPPORT_ROLE') THEN REGEXP_REPLACE(val, '.+@', '****@')
        ELSE '********'
    END;

-- POLICY 3: NULL mask — returns NULL for unauthorized users
CREATE OR REPLACE MASKING POLICY security.phone_mask
AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN val
        WHEN CURRENT_ROLE() IN ('SUPPORT_ROLE') THEN val
        ELSE NULL
    END;

-- Apply policies to columns
ALTER TABLE data.customers MODIFY COLUMN ssn   SET MASKING POLICY security.ssn_mask;
ALTER TABLE data.customers MODIFY COLUMN email SET MASKING POLICY security.email_mask;
ALTER TABLE data.customers MODIFY COLUMN phone SET MASKING POLICY security.phone_mask;


-- ============================================================================
-- 1.3 TEST: Query as Different Roles
-- ============================================================================

-- ANALYST: sees all data unmasked
USE ROLE analyst_role;
SELECT * FROM masking_demo.data.customers;

-- SUPPORT: partial email, full phone, masked SSN
USE ROLE support_role;
SELECT * FROM masking_demo.data.customers;

-- PUBLIC: fully masked email/SSN, NULL phone
USE ROLE PUBLIC;
-- (This will fail with insufficient privileges — PUBLIC has no SELECT grant)
-- that masking + RBAC work together

-- Back to accountadmin for next section
USE ROLE ACCOUNTADMIN;
GRANT SELECT ON TABLE masking_demo.data.customers TO ROLE PUBLIC;
GRANT USAGE ON DATABASE masking_demo TO ROLE PUBLIC;
GRANT USAGE ON SCHEMA masking_demo.data TO ROLE PUBLIC;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE PUBLIC;

USE ROLE PUBLIC;
SELECT * FROM masking_demo.data.customers;
-- All sensitive columns are masked/NULL

-- ============================================================================
-- 1.4 ADVANCED: Hash-Based Masking (preserves referential integrity)
-- ============================================================================

USE ROLE masking_admin;

-- SHA2 mask: unauthorized users see a hash instead of a fixed string
-- This allows JOINs across masked datasets to still work

-- Detach any existing policy on SSN before replacing (safe to run even on first run)
ALTER TABLE masking_demo.data.customers MODIFY COLUMN ssn UNSET MASKING POLICY;

CREATE OR REPLACE MASKING POLICY security.ssn_hash_mask
AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN val
        ELSE md5(val)
    END;

-- Apply the hash-based policy
ALTER TABLE masking_demo.data.customers MODIFY COLUMN ssn SET MASKING POLICY security.ssn_hash_mask;

-- Verify: same SSN always produces the same hash
USE ROLE support_role;
SELECT id, name, ssn FROM masking_demo.data.customers;


-- ============================================================================
-- 1.5 ADVANCED: Conditional Masking (uses a second column)
-- ============================================================================

USE ROLE masking_admin;

-- The "region" column decides whether email is visible
-- NA region emails are public; others are masked
CREATE OR REPLACE MASKING POLICY security.email_conditional_mask
AS (email VARCHAR, region VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN email
        WHEN region = 'NA' THEN email                       -- public for NA
        ELSE REGEXP_REPLACE(email, '.+@', '****@')          -- masked for others
    END;

-- Swap email policy to conditional version
ALTER TABLE masking_demo.data.customers MODIFY COLUMN email UNSET MASKING POLICY;
ALTER TABLE masking_demo.data.customers MODIFY COLUMN email
    SET MASKING POLICY security.email_conditional_mask
    USING (email, region);

-- Test
USE ROLE support_role;
SELECT id, name, email, region FROM masking_demo.data.customers;
-- NA rows show full email; EU/APAC rows show masked email


-- ============================================================================
-- 1.6 ADVANCED: Tag-Based Masking (scale to 1000s of columns)
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- Create a PII tag
CREATE OR REPLACE TAG masking_demo.security.pii_tag;

-- Generic masking policy per data type (attach to the tag, not columns)
USE ROLE masking_admin;

-- NOTE: Using CURRENT_ROLE() here (not IS_ROLE_IN_SESSION) because
-- IS_ROLE_IN_SESSION returns TRUE for ALL roles granted to the user
-- (secondary roles are activated by default). In a demo where one user
-- has multiple roles, CURRENT_ROLE() gives strict per-role behavior.
CREATE OR REPLACE MASKING POLICY security.pii_string_mask
AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN val
        ELSE '** PII REDACTED **'
    END;

-- Bind the masking policy to the tag (for STRING type)
USE ROLE ACCOUNTADMIN;
ALTER TAG masking_demo.security.pii_tag SET MASKING POLICY security.pii_string_mask;

-- Now tag any column — the masking policy applies automatically
-- (first unset existing direct policies on name column if any)
ALTER TABLE masking_demo.data.customers MODIFY COLUMN name
    SET TAG masking_demo.security.pii_tag = 'customer_name';

-- Test: name column is now masked via tag
USE ROLE support_role;
SELECT id, name, region FROM masking_demo.data.customers;

USE ROLE analyst_role;
SELECT id, name, region FROM masking_demo.data.customers;


-- ============================================================================
-- 1.7 AUDITING: Where are policies applied?
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- List all masking policies in the account
SHOW MASKING POLICIES IN DATABASE masking_demo;

-- See which columns have policies attached
SELECT *
FROM TABLE(
    masking_demo.INFORMATION_SCHEMA.POLICY_REFERENCES(
        POLICY_NAME => 'masking_demo.security.ssn_hash_mask'
    )
);

-- All policy references for a specific table
SELECT *
FROM TABLE(
    masking_demo.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME   => 'masking_demo.data.customers',
        REF_ENTITY_DOMAIN => 'TABLE'
    )
);


-- See which policies are bound to a tag
SELECT * FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.TAG_REFERENCES(
        'MASKING_DEMO.SECURITY.PII_TAG', 'TAG'
    )
);

-- See which columns carry a specific tag
SELECT * FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
        'MASKING_DEMO.DATA.CUSTOMERS', 'TABLE'
    )
);


-- ============================================================================
-- 1.8 DEMO: Tag-Based Masking at Scale (Multiple Tables)
-- ============================================================================
-- Show how one tag + one policy automatically protects columns across tables

USE ROLE ACCOUNTADMIN;

-- Create a second table with PII columns
CREATE OR REPLACE TABLE masking_demo.data.employees (
    emp_id    INT,
    full_name VARCHAR,
    email     VARCHAR,
    salary    NUMBER(10,2),
    dept      VARCHAR
);

INSERT INTO masking_demo.data.employees VALUES
    (101, 'Frank Wilson',  'frank@acme.com',   95000.00, 'Engineering'),
    (102, 'Grace Hopper',  'grace@acme.com',  120000.00, 'Engineering'),
    (103, 'Hank Adams',    'hank@acme.com',    78000.00, 'Sales'),
    (104, 'Ivy Chen',      'ivy@acme.com',    105000.00, 'Finance');

GRANT SELECT ON TABLE masking_demo.data.employees TO ROLE analyst_role;
GRANT SELECT ON TABLE masking_demo.data.employees TO ROLE support_role;

-- Tag columns across BOTH tables with the same PII tag — no new policies needed
USE ROLE ACCOUNTADMIN;

ALTER TABLE masking_demo.data.employees MODIFY COLUMN full_name
    SET TAG masking_demo.security.pii_tag = 'employee_name';

ALTER TABLE masking_demo.data.employees MODIFY COLUMN email
    SET TAG masking_demo.security.pii_tag = 'employee_email';

-- Verify: both tables are now masked via the SAME tag
USE ROLE support_role;

SELECT 'CUSTOMERS' AS source, id AS id, name, region
FROM masking_demo.data.customers
UNION ALL
SELECT 'EMPLOYEES', emp_id, full_name, dept
FROM masking_demo.data.employees;
-- NAME and FULL_NAME are both masked via PII_TAG

USE ROLE analyst_role;

SELECT 'CUSTOMERS' AS source, id AS id, name, region
FROM masking_demo.data.customers
UNION ALL
SELECT 'EMPLOYEES', emp_id, full_name, dept
FROM masking_demo.data.employees;
-- ANALYST sees everything unmasked


-- ============================================================================
-- 1.9 DEMO: Multi-Type Tag Masking (STRING + NUMBER on one tag)
-- ============================================================================
-- One tag can carry different policies per data type

USE ROLE masking_admin;

-- Number masking policy: hide salary from non-analysts
CREATE OR REPLACE MASKING POLICY security.pii_number_mask
AS (val NUMBER) RETURNS NUMBER ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN val
        ELSE 0
    END;

-- Bind the NUMBER policy to the same PII tag
USE ROLE ACCOUNTADMIN;
ALTER TAG masking_demo.security.pii_tag SET MASKING POLICY security.pii_number_mask;

-- Tag the salary column — Snowflake auto-picks pii_number_mask (NUMBER type)
ALTER TABLE masking_demo.data.employees MODIFY COLUMN salary
    SET TAG masking_demo.security.pii_tag = 'compensation';

-- Test: support_role sees 0 for salary, redacted for name
USE ROLE support_role;
SELECT emp_id, full_name, email, salary, dept FROM masking_demo.data.employees;

-- Test: analyst_role sees everything
USE ROLE analyst_role;
SELECT emp_id, full_name, email, salary, dept FROM masking_demo.data.employees;


-- ============================================================================
-- 1.10 DEMO: Swap a Tag-Based Policy in One Statement
-- ============================================================================
-- Change masking behavior across ALL tagged columns at once

USE ROLE masking_admin;

-- New policy: show first initial + "***" instead of full redaction
CREATE OR REPLACE MASKING POLICY security.pii_string_partial_mask
AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ANALYST_ROLE') THEN val
        ELSE LEFT(val, 1) || '***'
    END;

-- Swap: unbind old policy, bind new one — ALL tagged STRING columns update instantly
USE ROLE ACCOUNTADMIN;
ALTER TAG masking_demo.security.pii_tag UNSET MASKING POLICY security.pii_string_mask;
ALTER TAG masking_demo.security.pii_tag SET MASKING POLICY security.pii_string_partial_mask;

-- Verify: support_role now sees "F***" instead of "** PII REDACTED **"
USE ROLE support_role;
SELECT emp_id, full_name, salary, dept FROM masking_demo.data.employees;
SELECT id, name, region FROM masking_demo.data.customers;

-- Revert back to full redaction
USE ROLE ACCOUNTADMIN;
ALTER TAG masking_demo.security.pii_tag UNSET MASKING POLICY security.pii_string_partial_mask;
ALTER TAG masking_demo.security.pii_tag SET MASKING POLICY security.pii_string_mask;


-- ============================================================================
-- 1.11 AUDIT: Full Tag-Based Masking Inventory
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- Which columns are tagged with PII_TAG, and which policies apply via that tag?
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME, TAG_NAME
FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME   => 'MASKING_DEMO.DATA.CUSTOMERS',
        REF_ENTITY_DOMAIN => 'TABLE'
    )
)
WHERE TAG_NAME IS NOT NULL
UNION ALL
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME, TAG_NAME
FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME   => 'MASKING_DEMO.DATA.EMPLOYEES',
        REF_ENTITY_DOMAIN => 'TABLE'
    )
)
WHERE TAG_NAME IS NOT NULL
ORDER BY REF_ENTITY_NAME, REF_COLUMN_NAME;

-- All columns tagged with PII_TAG across the database
SELECT
    OBJECT_DATABASE, OBJECT_SCHEMA, OBJECT_NAME, COLUMN_NAME,
    TAG_VALUE, DOMAIN
FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
        'MASKING_DEMO.DATA.EMPLOYEES', 'TABLE'
    )
)
WHERE TAG_NAME = 'PII_TAG'
UNION ALL
SELECT
    OBJECT_DATABASE, OBJECT_SCHEMA, OBJECT_NAME, COLUMN_NAME,
    TAG_VALUE, DOMAIN
FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
        'MASKING_DEMO.DATA.CUSTOMERS', 'TABLE'
    )
)
WHERE TAG_NAME = 'PII_TAG'
ORDER BY OBJECT_NAME, COLUMN_NAME;


-- ============================================================================
-- CLEANUP (run when done with all demos)
-- ============================================================================
-- DROP DATABASE MASKING_DEMO;