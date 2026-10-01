-- ============================================================================
-- Q&A: Why Use Tags for Masking?
-- ============================================================================


-- ============================================================================
-- Q1: What is the problem with direct masking?
-- ============================================================================
-- A: With direct masking, you attach a policy to each column individually.
--    If you have 200 tables with an SSN column, you need 200 ALTER statements.
--    Every new table requires someone to remember to attach the policy manually.
--    If they forget, the column is exposed.
--
--    Example (direct — repeated for every table):
--      ALTER TABLE hr.employees    MODIFY COLUMN ssn SET MASKING POLICY ssn_mask;
--      ALTER TABLE hr.contractors  MODIFY COLUMN ssn SET MASKING POLICY ssn_mask;
--      ALTER TABLE hr.applicants   MODIFY COLUMN ssn SET MASKING POLICY ssn_mask;
--      ... 197 more ALTER statements ...


-- ============================================================================
-- Q2: What is tag-based masking?
-- ============================================================================
-- A: Instead of attaching a policy to each column, you:
--      1. Create a TAG (a label for a data category, e.g. PII)
--      2. Bind a masking policy TO the tag (once)
--      3. Tag columns — any column with that tag is automatically masked
--
--    Example (one-time setup):
--      CREATE TAG pii_tag;
--      ALTER TAG pii_tag SET MASKING POLICY pii_string_mask;
--
--    Then just tag columns:
--      ALTER TABLE hr.employees MODIFY COLUMN ssn SET TAG pii_tag = 'ssn';
--      -- Masking applies automatically. No MASKING POLICY statement needed.


-- ============================================================================
-- Q3: What happens when a new table is added?
-- ============================================================================
-- A: DIRECT  → Someone must remember to ALTER TABLE ... SET MASKING POLICY.
--              If forgotten, the column is unprotected.
--
--    TAG     → Just tag the column: SET TAG pii_tag = 'ssn'.
--              The policy bound to the tag applies automatically.


-- ============================================================================
-- Q4: What if I need to change the masking logic?
-- ============================================================================
-- A: DIRECT  → You must UNSET and SET the policy on ALL 200 tables.
--              That's 400 ALTER statements.
--
--    TAG     → Two statements, no matter how many tables:
--              ALTER TAG pii_tag UNSET MASKING POLICY old_policy;
--              ALTER TAG pii_tag SET MASKING POLICY new_policy;
--              All 200 tagged columns update instantly.


-- ============================================================================
-- Q5: Can one tag handle multiple data types (STRING, NUMBER, etc.)?
-- ============================================================================
-- A: Yes. A tag can have one masking policy PER DATA TYPE.
--    Snowflake auto-selects the correct policy based on the column's type.
--
--    Example:
--      ALTER TAG pii_tag SET MASKING POLICY pii_string_mask;  -- for VARCHAR
--      ALTER TAG pii_tag SET MASKING POLICY pii_number_mask;  -- for NUMBER
--
--    Tag a STRING column → pii_string_mask applies.
--    Tag a NUMBER column → pii_number_mask applies.


-- ============================================================================
-- Q6: What is "Separation of Concerns"?
-- ============================================================================
-- A: Tag-based masking lets two different teams work independently:
--
--    DATA STEWARD (knows the data):
--      "This column contains PII" → SET TAG pii_tag = 'ssn'
--
--    SECURITY ADMIN (knows the rules):
--      "PII should be masked like this" → ALTER TAG pii_tag SET MASKING POLICY ...
--
--    Neither person needs to coordinate with the other.
--    The steward classifies data; the admin defines protection.
--    Masking happens automatically where tags and policies meet.


-- ============================================================================
-- Q7: What if a column has BOTH a direct policy AND a tag-based policy?
-- ============================================================================
-- A: The DIRECT policy always wins (takes precedence).
--    The tag-based policy is ignored for that column.
--
--    Example:
--      Column SSN has direct policy ssn_hash_mask   → ssn_hash_mask applies
--      Column SSN also tagged with pii_tag          → tag policy is ignored
--
--    You can verify with:
--      SELECT * FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
--          REF_ENTITY_NAME => 'my_table', REF_ENTITY_DOMAIN => 'TABLE'));
--      -- TAG_NAME column is NULL for direct, populated for tag-based.


-- ============================================================================
-- Q8: How do I audit which columns are protected by a tag?
-- ============================================================================
-- A: Use TAG_REFERENCES_ALL_COLUMNS to see tagged columns per table:

SELECT OBJECT_NAME, COLUMN_NAME, TAG_NAME, TAG_VALUE
FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
        'MASKING_DEMO.DATA.CUSTOMERS', 'TABLE'
    )
)
WHERE TAG_NAME = 'PII_TAG';

--    Use POLICY_REFERENCES to see tag-based policies in effect:

SELECT POLICY_NAME, REF_ENTITY_NAME, REF_COLUMN_NAME, TAG_NAME
FROM TABLE(
    MASKING_DEMO.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME   => 'MASKING_DEMO.DATA.CUSTOMERS',
        REF_ENTITY_DOMAIN => 'TABLE'
    )
)
WHERE TAG_NAME IS NOT NULL;


-- ============================================================================
-- Q9: Does tag-based masking support conditional masking (USING clause)?
-- ============================================================================
-- A: No. Tag-based policies receive only the tagged column's value.
--    If you need to reference a SECOND column (e.g., mask email based on region),
--    you must use a DIRECT policy with the USING clause:
--
--      ALTER TABLE data.customers MODIFY COLUMN email
--          SET MASKING POLICY email_conditional_mask
--          USING (email, region);
--
--    This is the main limitation of tag-based masking.


-- ============================================================================
-- Q10: When should I use direct masking vs tag-based masking?
-- ============================================================================
-- A:
--    USE DIRECT MASKING WHEN:
--      - You have only a few tables (< 10) with sensitive columns
--      - Each column needs a unique, custom masking rule
--      - You need conditional masking with USING clause
--      - Simple setup, no need for scale
--
--    USE TAG-BASED MASKING WHEN:
--      - Many tables share the same type of sensitive data (SSN, email, phone)
--      - You want centralized, scalable governance
--      - You want to swap masking logic across all columns in one statement
--      - You want separation of duties (steward tags, admin masks)
--      - You are integrating with Snowflake's auto-classification feature


-- ============================================================================
-- SUMMARY TABLE
-- ============================================================================
--
--  Scenario                  | Direct (200 tables)           | Tag-Based (200 tables)
--  --------------------------+-------------------------------+----------------------------------
--  Initial setup             | 200 ALTER...SET MASKING POLICY| 200 ALTER...SET TAG (same effort)
--  New table added           | Must remember to ALTER        | Just tag the column
--  Change policy logic       | Unset + set on all 200 tables | ALTER TAG (1 statement, all update)
--  Add NUMBER masking        | New policy + 200 more ALTERs  | ALTER TAG SET POLICY (1 statement)
--  Audit coverage            | Check per table               | TAG_REFERENCES — one query
--  Who manages it            | DBA must know every table     | Steward tags, admin manages policy
--  Conditional masking       | Supported (USING clause)      | Not supported
--  Priority when both exist  | Direct wins                   | Tag-based is overridden
--
-- BOTTOM LINE:
-- Tags turn masking from a per-column manual task into a
-- classification-driven automatic system.
-- Tag once, mask everywhere, change in one place.
