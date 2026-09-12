-- Comm-Log Send Reconciliation — Merchant 501, Diwali Campaigns, Oct 2026
-- Reproduces Finance's target_base = 22

WITH RECURSIVE
-- Campaigns in scope (merchant 501, Diwali) that have cleared both the
-- creation and processing lifecycle, i.e. actually count toward reporting.
finalized AS (
    SELECT id, parent_id
    FROM campaign
    WHERE merchant_id = 501
      AND name LIKE 'Diwali%'
      AND creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND processing_status = 'processed'
),

-- Walk parent_id links to find the ultimate root of every campaign's retry chain.
roots (id, root_id) AS (
    SELECT id, id FROM campaign
    WHERE merchant_id = 501 AND name LIKE 'Diwali%' AND parent_id IS NULL
    UNION ALL
    SELECT c.id, r.root_id
    FROM campaign c
    JOIN roots r ON c.parent_id = r.id
    WHERE c.merchant_id = 501 AND c.name LIKE 'Diwali%'
),

-- A root is a genuine retry chain only if some campaign points back at it;
-- otherwise it's a standalone communication.
chain_flag AS (
    SELECT c.id AS root_id,
           EXISTS (SELECT 1 FROM campaign ch WHERE ch.parent_id = c.id) AS has_retries
    FROM campaign c
    WHERE c.merchant_id = 501 AND c.name LIKE 'Diwali%' AND c.parent_id IS NULL
)

SELECT
    r.root_id,
    CASE WHEN cf.has_retries = 1 THEN 'chain' ELSE 'standalone' END AS communication_type,
    CASE WHEN cf.has_retries = 1
         THEN COUNT(DISTINCT cl.customer_id)   -- chain: dedupe by customer across all retries
         ELSE COUNT(*)                          -- standalone: every send is its own event
    END AS qualifying_sends
FROM communication_log cl
JOIN finalized f ON f.id = cl.communication_id
JOIN roots r      ON r.id = f.id
JOIN chain_flag cf ON cf.root_id = r.root_id
WHERE cl.merchant_id = 501
  AND cl.communication_type = '2'
  AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
GROUP BY r.root_id, cf.has_retries
ORDER BY r.root_id;

-- Expected output:
-- root_id | communication_type | qualifying_sends
-- 9001    | chain              | 10
-- 9101    | standalone         | 7
-- 9201    | chain              | 5
-- Total target_base = 22

-- Single-number version:
-- SELECT SUM(qualifying_sends) AS target_base FROM ( <same query grouped by r.root_id only> );
