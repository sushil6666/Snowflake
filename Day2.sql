select * from SF_LEARN.DEMO_CLASS.ORDERS where order_id in (2,6);

/* 2	260	2	2026-02-28 11:32:06.038	COMPLETED	PAYPAL	14.46	0.00
   6	36	3	2025-10-03 18:42:38.038	COMPLETED	CREDIT_CARD	7.34	0.00 */

delete from SF_LEARN.DEMO_CLASS.ORDERS where order_id in (2,6);

SHOW TABLES IN SCHEMA SF_LEARN.DEMO_CLASS;

SHOW TABLES LIKE 'PROMOTIONS' IN SCHEMA SF_LEARN.DEMO_CLASS;

SELECT table_name, table_type, is_transient
FROM SF_LEARN.INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'DEMO_CLASS'
ORDER BY table_name;

--timestamp

select * from SF_LEARN.DEMO_CLASS.ORDERS AT(TIMESTAMP => dateadd (minutes, -10, current_timestamp()) );

--offset

select * from SF_LEARN.DEMO_CLASS.ORDERS AT(OFFSET => -60*12);

--query id
select * from SF_LEARN.DEMO_CLASS.ORDERS 
before(statement => '01c748dd-0204-be6a-0005-51aa000998ea');

--01c748dd-0204-be6a-0005-51aa000998ea

create temporary table orders_snapshot as
select * from SF_LEARN.DEMO_CLASS.ORDERS 
before(statement => '01c748dd-0204-be6a-0005-51aa000998ea');

select * from orders_snapshot;

delete from SF_LEARN.DEMO_CLASS.orders_snapshot where order_id in (2,6,60);


select * from SF_LEARN.DEMO_CLASS.orders_snapshot 
before(statement => '01c748f9-0204-be6a-0005-51aa00099ede');

CREATE OR REPLACE VIEW v_completed_orders AS
SELECT order_id ord_id, customer_id cust_id, order_date, total_amount
FROM orders
WHERE order_status = 'COMPLETED';

-- Use it like a table
SELECT * FROM v_completed_orders;

/*
create or replace view SF_LEARN.DEMO_CLASS.V_COMPLETED_ORDERS(
	ORDER_ID,
	CUSTOMER_ID,
	ORDER_DATE,
	TOTAL_AMOUNT
) as
SELECT order_id, customer_id, order_date, total_amount
FROM orders
WHERE order_status = 'COMPLETED';
*/


CREATE OR REPLACE SECURE VIEW v_completed_orders_secure AS
SELECT order_id ord_id, customer_id cust_id, order_date, total_amount
FROM orders
WHERE order_status = 'COMPLETED';

SELECT CURRENT_ROLE();

USE ROLE PUBLIC;
-- Try to see the definition
SHOW VIEWS LIKE 'v_completed_orders_secure' IN SCHEMA SF_LEARN.DEMO_CLASS;
-- The "text" column should be empty for secure views

SHOW GRANTS ON VIEW v_completed_orders_secure;


CREATE OR REPLACE ROLE test_viewer_role COMMENT = 'Temp role to test secure view visibility';

CREATE OR REPLACE USER test_viewer
  PASSWORD = 'TempPass123!'
  DEFAULT_ROLE = test_viewer_role
  MUST_CHANGE_PASSWORD = FALSE;

GRANT ROLE test_viewer_role TO USER test_viewer;
GRANT ROLE test_viewer_role TO USER SUSHIL;  -- so YOU can USE ROLE test_viewer_role

-- Grant just enough to query the view, but no ownership path
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE test_viewer_role;
GRANT USAGE ON DATABASE SF_LEARN TO ROLE test_viewer_role;
GRANT USAGE ON SCHEMA SF_LEARN.DEMO_CLASS TO ROLE test_viewer_role;
GRANT SELECT ON VIEW SF_LEARN.DEMO_CLASS.V_COMPLETED_ORDERS TO ROLE test_viewer_role;

-- Step 2: Switch to the test role and try to see the definition
USE ROLE test_viewer_role;
SHOW VIEWS LIKE 'V_COMPLETED_ORDERS_SECURE' IN SCHEMA SF_LEARN.DEMO_CLASS;
-- ^^^ The "text" column should be EMPTY for the test_viewer_role

-- Also try GET_DDL — should fail or hide the definition
SELECT GET_DDL('VIEW', 'SF_LEARN.DEMO_CLASS.V_COMPLETED_ORDERS_SECURE');

-- Step 3: Confirm the role CAN query the view (data access works)
SELECT * FROM SF_LEARN.DEMO_CLASS.V_COMPLETED_ORDERS_SECURE LIMIT 5;

-- Step 4: Clean up when done
USE ROLE ACCOUNTADMIN;
DROP USER IF EXISTS test_viewer;
DROP ROLE IF EXISTS test_viewer_role;

--test_viewer user
https://app.snowflake.com/azgybkv/bq93923/#/workspaces/ws/USER%24/PUBLIC/DEFAULT%24/Untitled.sql


