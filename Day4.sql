
USE ROLE SYSADMIN;

CREATE OR REPLACE DATABASE foundations_demo;
CREATE OR REPLACE SCHEMA foundations_demo.lab;
USE DATABASE foundations_demo;
USE SCHEMA lab;

SELECT CURRENT_REGION() AS my_region;

CREATE OR REPLACE WAREHOUSE demo_gen1_wh
   GENERATION = '1'
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

--RBAC

CREATE OR REPLACE WAREHOUSE demo_gen3_wh
  GENERATION = '2'
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

  CREATE OR REPLACE WAREHOUSE demo_adaptive_wh
  WAREHOUSE_TYPE = 'ADAPTIVE';

  SHOW WAREHOUSES LIKE 'DEMO_%';


  CREATE OR REPLACE ROLE FOUNDATIONS_READ;

  grant role FOUNDATIONS_READ to user test_viewer; 

  

  SHOW ROLES;

  use role FOUNDATIONS_READ; 

  -- Read role: SELECT on all current and future tables
GRANT USAGE ON DATABASE foundations_demo TO ROLE foundations_read;
GRANT USAGE ON SCHEMA foundations_demo.lab TO ROLE foundations_read;
GRANT SELECT ON ALL TABLES IN SCHEMA foundations_demo.lab TO ROLE foundations_read;
grant SELECT ON FUTURE TABLES IN SCHEMA foundations_demo.lab  to foundations_read;


create table foundations_demo.lab._test_view3 as select 1 as id;

grant usage on warehouse demo_gen1_wh to role foundations_read;



-- Write role: inherits read + INSERT, UPDATE, DELETE
GRANT USAGE ON DATABASE foundations_demo TO ROLE foundations_write;
GRANT USAGE ON SCHEMA foundations_demo.lab TO ROLE foundations_write;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA foundations_demo.lab TO ROLE foundations_write;
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA foundations_demo.lab TO ROLE foundations_write;

GRANT ALL PRIVILEGES ON DATABASE foundations_demo TO ROLE foundations_admin;
GRANT ALL PRIVILEGES ON SCHEMA foundations_demo.lab TO ROLE foundations_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA foundations_demo.lab TO ROLE foundations_admin;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA foundations_demo.lab TO ROLE foundations_admin;


