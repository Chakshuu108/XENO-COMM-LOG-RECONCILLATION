# Comm-Log Send Reconciliation — Merchant 501, Diwali Campaigns, Oct 2026

## 1. Reconciliation Bridge

Each row below is a running total — the number after applying that one adjustment to the number above it — so the table reads straight down from the naive count to Finance's 22.

| Step | Description | Result | Reason |
|---|---|---:|---|
| 0 | Count all `communication_log` rows for merchant 501, Oct 2026, Diwali campaigns, `communication_type = '2'` | **30** | Starting count before any adjustments |
| 1 | Remove rows for campaign `9004` (`approval_awaiting`) | **26 (-4)** | `9004` is not finalized, so its 4 sends do not count |
| 2 | Collapse retry chain `9001 → 9002 → 9003` to distinct customers | **23 (-3)** | The 13 sends belong to 10 customers, so retries are counted once |
| 3 | Collapse retry chain `9201 → 9202` to distinct customers | **22 (-1)** | The 6 sends belong to 5 customers, so the retry is counted once |
| Final | Keep standalone campaign `9101` unchanged | **22** | It has no retries, so every send counts, including the two sends to `C20` |

### Composition of the final 22 (for reference)

| Underlying communication | Campaigns | Raw rows | Distinct customers counted |
|---|---|---|---|
| Diwali Cart Recovery | 9001, 9002, 9003 (9004 excluded) | 13 | **10** |
| Diwali Flash Sale – Standalone | 9101 | 7 | **7** |
| Diwali Wave 2 | 9201, 9202 | 6 | **5** |
| **Total** | | **26** | **22** |

### Why a plain `GROUP BY communication_id` isn't enough

Before reaching for the recursive chain logic, the obvious next thing to try after Step 1 (26) is a normal `GROUP BY` — count distinct customers **per campaign**, and sum it up:

```sql
SELECT cl.communication_id, COUNT(DISTINCT cl.customer_id) AS distinct_customers
FROM communication_log cl
JOIN campaign c ON c.id = cl.communication_id
WHERE cl.merchant_id = 501
  AND cl.communication_type = '2'
  AND c.name LIKE 'Diwali%'
  AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
  AND c.processing_status = 'processed'
  AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
GROUP BY cl.communication_id;
```

| communication_id | raw_rows | distinct_customers |
|---|---|---|
| 9001 | 10 | 10 |
| 9002 | 2 | 2 |
| 9003 | 1 | 1 |
| 9101 | 7 | **6** |
| 9201 | 5 | 5 |
| 9202 | 1 | 1 |

Sum of `distinct_customers` = **25** — still not 22, and wrong in two opposite directions at once:

- **It overcounts retry chains.** `GROUP BY communication_id` treats each campaign separately instead of treating the parent→child campaigns as one underlying communication. So customers like `C2`, `C3`, and `D1` can be counted more than once across their retry campaigns.

- **It undercounts standalone sends.** `COUNT(DISTINCT customer_id)` changes `9101` from 7 rows to 6 customers because `C20` appears twice. However, `9101` is a standalone campaign, so those two sends are separate events and both should count.

That's why a simple `GROUP BY` or `COUNT(DISTINCT)` cannot handle both cases. Retry chains need customers deduplicated across campaigns, while standalone campaigns must keep every send. The `roots` and `chain_flag` logic identifies these two cases before applying the correct counting rule.
## 2. SQL

Works against `data/comm_log.db` as-is.

```sql
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

-- Walk parent_id links (on the full campaign table, since the retry
-- relationship is structural and independent of a campaign's own status)
-- to find the ultimate root of every campaign's retry chain.
roots (id, root_id) AS (
    SELECT id, id FROM campaign
    WHERE merchant_id = 501 AND name LIKE 'Diwali%' AND parent_id IS NULL
    UNION ALL
    SELECT c.id, r.root_id
    FROM campaign c
    JOIN roots r ON c.parent_id = r.id
    WHERE c.merchant_id = 501 AND c.name LIKE 'Diwali%'
),

-- A root represents a genuine retry chain only if some campaign actually
-- points back at it; otherwise it's a standalone communication.
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
```

*(Note: `name LIKE 'Diwali%'` is scoped defensively per the assignment's "across all Diwali campaigns" wording. In this dataset every campaign for merchant 501 happens to be Diwali-named, so it doesn't change the result — but it makes the intent explicit rather than relying on that coincidence.)*

Result:

| root_id | communication_type | qualifying_sends |
|---|---|---|
| 9001 | chain | 10 |
| 9101 | standalone | 7 |
| 9201 | chain | 5 |

Total `target_base` = 10 + 7 + 5 = **22**

A single-number version of the same query:

```sql
WITH RECURSIVE
finalized AS (
    SELECT id, parent_id FROM campaign
    WHERE merchant_id = 501 AND name LIKE 'Diwali%'
      AND creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND processing_status = 'processed'
),
roots (id, root_id) AS (
    SELECT id, id FROM campaign
    WHERE merchant_id = 501 AND name LIKE 'Diwali%' AND parent_id IS NULL
    UNION ALL
    SELECT c.id, r.root_id FROM campaign c JOIN roots r ON c.parent_id = r.id
    WHERE c.merchant_id = 501 AND c.name LIKE 'Diwali%'
),
chain_flag AS (
    SELECT c.id AS root_id,
           EXISTS (SELECT 1 FROM campaign ch WHERE ch.parent_id = c.id) AS has_retries
    FROM campaign c
    WHERE c.merchant_id = 501 AND c.name LIKE 'Diwali%' AND c.parent_id IS NULL
)
SELECT SUM(qualifying_sends) AS target_base FROM (
    SELECT
        CASE WHEN cf.has_retries = 1
             THEN COUNT(DISTINCT cl.customer_id)
             ELSE COUNT(*)
        END AS qualifying_sends
    FROM communication_log cl
    JOIN finalized f ON f.id = cl.communication_id
    JOIN roots r ON r.id = f.id
    JOIN chain_flag cf ON cf.root_id = r.root_id
    WHERE cl.merchant_id = 501
      AND cl.communication_type = '2'
      AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
    GROUP BY r.root_id
);
-- target_base = 22
```

## 3. What surprised me

- **Campaign `9004`** has `processing_status = 'processed'` but `creation_status = 'approval_awaiting'`, showing that processing can happen before approval is complete.

- **The cart-recovery retry chain** goes three levels deep (`9001 → 9002 → 9003`), with customers like `C3` appearing in multiple attempts, so retries must be deduplicated across the full chain.

- **`delivery_status` does not affect `target_base`** — failed and delivered attempts still represent the same targeted customer when they belong to the same retry chain.


## 4. Submitted by

**Chakshu Gupta**  
B.Tech CSE | Thapar University
