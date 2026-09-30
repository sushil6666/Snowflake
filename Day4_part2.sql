-- VIRTUAL WAREHOUSES DEEP DIVE
-- ############################################################################
/*
  KEY CONCEPTS:
  - Warehouse SIZE determines compute resources per cluster (XS → 6XL, each doubles)
  - AUTO_SUSPEND + AUTO_RESUME automate lifecycle; per-second billing (60s minimum)
  - Multi-cluster warehouses (Enterprise+) scale OUT for concurrency
  - Scaling policies: STANDARD (spin up quickly) vs ECONOMY (conserve credits)
  - Sizing strategy: match warehouse to workload
  - Separate warehouses by workload type: ETL, BI/dashboards, ad-hoc, data science
*/
-- ════════════════════════════════════════════════════════════════════════════
-- Auto-Suspend and Auto-Resume Behavior
-- ════════════════════════════════════════════════════════════════════════════
/*
  AUTO_SUSPEND (in seconds):
  - Warehouse suspends after N seconds of NO active queries
  - Suspended = no credits consumed
  - Setting too LOW: frequent suspend/resume cycles, cold cache, 60s min charge each time
  - Setting too HIGH: paying for idle compute


  AUTO_RESUME = TRUE (default):
  - Warehouse auto-starts when a query arrives
  - If FALSE, users must manually ALTER WAREHOUSE ... RESUME

  IMPORTANT: Suspending drops the cache. A resumed warehouse starts cold.
  For latency-sensitive dashboards, a longer auto-suspend keeps cache warm.
*/
-- BI / Dashboard warehouse: smaller but always warm for fast responses
CREATE OR REPLACE WAREHOUSE wh_dashboards
  WAREHOUSE_SIZE = SMALL
  AUTO_SUSPEND = 300          -- 5 minutes: dashboards need warm cache
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'BI dashboards and reporting';
-- Demo: change auto-suspend on the fly
ALTER WAREHOUSE wh_dashboards SET AUTO_SUSPEND = 600;  -- increase to 10 min

-- Check the current settings
SHOW WAREHOUSES LIKE 'WH_DASHBOARDS';
-- Look at "auto_suspend" and "auto_resume" columns

-- ════════════════════════════════════════════════════════════════════════════
-- Resizing a Warehouse (Scale UP)
-- ════════════════════════════════════════════════════════════════════════════
/*
  Resizing changes the compute power of each cluster.
  - Takes effect IMMEDIATELY (even while queries are running)
  - Running queries use existing resources until they complete
  - New queries use the new (larger or smaller) resources
  - Resizing does NOT drop the cache (unlike suspend/resume)

  Use resizing when:
  - Individual queries are too slow (need more compute per query)
  - Data loading is bottlenecked by compute power
  - NOT for concurrency problems (use multi-cluster instead)
*/

-- Resume and use the ad-hoc warehouse
ALTER WAREHOUSE wh_adhoc RESUME;
USE WAREHOUSE wh_adhoc;

-- Run a baseline query
SELECT COUNT(*), AVG(o_totalprice), MAX(o_orderdate)
FROM snowflake_sample_data.tpch_sf100.orders
WHERE o_orderstatus = 'F';
-- Note the execution time (check query history or LAST_QUERY_ID())

-- Resize UP to Medium (4x the compute)
ALTER WAREHOUSE wh_adhoc SET WAREHOUSE_SIZE = MEDIUM;

-- Run the same query again
SELECT COUNT(*), AVG(o_totalprice), MAX(o_orderdate)
FROM snowflake_sample_data.tpch_sf100.orders
WHERE o_orderstatus = 'F';
-- Compare execution time — should be notably faster on the larger warehouse

-- Resize back down when done
ALTER WAREHOUSE wh_adhoc SET WAREHOUSE_SIZE = XSMALL;
-- ════════════════════════════════════════════════════════════════════════════
--  Multi-Cluster Warehouses — Scale OUT for Concurrency
-- ════════════════════════════════════════════════════════════════════════════
/*
  Multi-cluster = multiple copies of the SAME SIZE warehouse running together.
  Enterprise Edition feature.

  Purpose: handle MORE CONCURRENT queries (not faster individual queries)

  Two modes:
  1. MAXIMIZED: all clusters always running (fixed capacity)
     - MIN_CLUSTER_COUNT = MAX_CLUSTER_COUNT
     - Use for steady, predictable concurrency

  2. AUTO-SCALE: Snowflake adds/removes clusters based on load
     - MIN_CLUSTER_COUNT < MAX_CLUSTER_COUNT
     - Use for variable concurrency (peak hours vs off-hours)

  Credit math example (Medium = 4 cr/hr):
  - 1 cluster for 1 hour  = 4 credits
  - 3 clusters for 1 hour = 12 credits
  - Auto-scale: 1 cluster for 2 hours + 2 clusters for 30 min = 12 credits
*/
-- ════════════════════════════════════════════════════════════════════════════
--   Scale UP vs Scale OUT Decision Framework
-- ════════════════════════════════════════════════════════════════════════════
/*
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ Problem                     │ Solution         │ Why                    │
  ├─────────────────────────────┼──────────────────┼────────────────────────┤
  │ Individual queries are slow │ Scale UP (resize)│ More compute per query │
  │ Queries are queueing        │ Scale OUT (multi)│ More parallel capacity │
  │ Both slow AND queueing      │ Both             │ Resize + add clusters  │
  │ Data loading is slow        │ Scale UP         │ More compute per file  │
  │                             │ (+ split files)  │ Better file parallelism│
  └─────────────────────────────┴──────────────────┴────────────────────────┘

  Multi-cluster does NOT help with:
  - A single slow query (it only gets one cluster)
  - Data loading speed (more clusters ≠ faster per-file loading)

  Resizing does NOT help with:
  - 100 users all running tiny queries that queue behind each other
*/

--   Monitoring Warehouse Performance
-- ════════════════════════════════════════════════════════════════════════════

-- Check current warehouse load and queued queries
USE WAREHOUSE demo_wh;

-- View warehouse load over time (requires ACCOUNTADMIN or MONITOR privilege)
USE ROLE ACCOUNTADMIN;

-- Credit usage by warehouse (last 7 days)
SELECT
  WAREHOUSE_NAME,
  SUM(CREDITS_USED) AS total_credits,
  SUM(CREDITS_USED_COMPUTE) AS compute_credits,
  SUM(CREDITS_USED_CLOUD_SERVICES) AS cloud_svc_credits,
  COUNT(*) AS metering_intervals
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY WAREHOUSE_NAME
ORDER BY total_credits DESC;

-- Query queuing analysis: how often are queries waiting?
SELECT
  WAREHOUSE_NAME,
  COUNT(*) AS total_queries,
  AVG(QUEUED_OVERLOAD_TIME) / 1000 AS avg_queue_sec,
  MAX(QUEUED_OVERLOAD_TIME) / 1000 AS max_queue_sec,
  COUNT(CASE WHEN QUEUED_OVERLOAD_TIME > 0 THEN 1 END) AS queued_count,
  ROUND(queued_count / total_queries * 100, 2) AS pct_queued
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND WAREHOUSE_NAME IS NOT NULL
GROUP BY WAREHOUSE_NAME
HAVING total_queries > 10
ORDER BY avg_queue_sec DESC;

-- Spilling analysis: are queries spilling to local/remote storage?
SELECT
  WAREHOUSE_NAME,
  WAREHOUSE_SIZE,
  COUNT(*) AS total_queries,
  COUNT(CASE WHEN BYTES_SPILLED_TO_LOCAL_STORAGE > 0 THEN 1 END) AS spilled_local,
  COUNT(CASE WHEN BYTES_SPILLED_TO_REMOTE_STORAGE > 0 THEN 1 END) AS spilled_remote,
  ROUND(AVG(BYTES_SPILLED_TO_LOCAL_STORAGE) / (1024*1024), 2) AS avg_spill_local_mb,
  ROUND(AVG(BYTES_SPILLED_TO_REMOTE_STORAGE) / (1024*1024), 2) AS avg_spill_remote_mb
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND WAREHOUSE_NAME IS NOT NULL
  AND EXECUTION_STATUS = 'SUCCESS'
GROUP BY WAREHOUSE_NAME, WAREHOUSE_SIZE
HAVING total_queries > 10
ORDER BY avg_spill_remote_mb DESC;
-- Resource Monitors — Cost Guardrails
-- ════════════════════════════════════════════════════════════════════════════
/*
  Resource monitors set credit limits on warehouses to prevent runaway costs.
  Actions at thresholds: NOTIFY, SUSPEND, SUSPEND_IMMEDIATE

  - NOTIFY: sends alert, warehouse keeps running
  - SUSPEND: finish running queries, then suspend
  - SUSPEND_IMMEDIATE: kill running queries and suspend right away
*/

-- Create a resource monitor: 100 credits/month, warn at 80%, suspend at 100%
CREATE OR REPLACE RESOURCE MONITOR demo_monitor
  WITH CREDIT_QUOTA = 100
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 80 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

-- Attach the monitor to a warehouse
ALTER WAREHOUSE wh_adhoc SET RESOURCE_MONITOR = demo_monitor;

-- View resource monitors
SHOW RESOURCE MONITORS;

-- Check current usage against limits
SELECT * FROM TABLE(INFORMATION_SCHEMA.RESOURCE_MONITORS());
