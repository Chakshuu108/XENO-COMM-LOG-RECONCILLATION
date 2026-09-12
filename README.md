# Comm-Log Send Reconciliation — Merchant 501, Diwali Campaigns, Oct 2026

## 1. Reconciliation Bridge

Each row below is a running total — the number after applying that one adjustment to the number above it — so the table reads straight down from the naive count to Finance's 22.

| Step | Description | Result | Reason |
|---|---|---|---|
| 0 | Naive count: all `communication_log` rows for merchant 501, Oct 2026, Diwali campaigns, `communication_type = '2'` | **30** | Starting point — every send attempt, no adjustments |
| 1 | Drop rows belonging to campaign **9004** ("Diwali Cart Recovery – Retry C (pending)") | **26** (−4) | `9004.creation_status = 'approval_awaiting'`. Per the data dictionary, a campaign only counts toward reporting once its creation workflow has cleared — `approval_awaiting` hasn't, even though its `processing_status` is `'processed'` and its 4 comm_log rows already exist. The send pipeline ran ahead of approval sign-off, so these sends aren't reportable yet. |
| 2 | Collapse the retry chain `9001 → 9002 → 9003` down to distinct customers | **23** (−3) | This is one *underlying communication*, not three campaigns. Raw rows = 13 (10 under 9001, 2 under 9002, 1 under 9003), but only 10 distinct customers: `C2` was sent under 9001 then retried under 9002 (2 rows → 1 customer); `C3` was sent under 9001, retried under 9002, retried again under 9003 (3 rows → 1 customer). |
| 3 | Collapse the retry chain `9201 → 9202` down to distinct customers | **22** (−1) | Same logic, second chain. Raw rows = 6, distinct customers = 5 — `D1` failed under 9201 and was retried (and delivered) under 9202, so it's 1 customer, not 2 rows. |
| **Final** | Campaign `9101` ("Diwali Flash Sale – Standalone") needed **no adjustment**: it has no parent and nothing retries off it, so it's a standalone communication — every send is its own event, including `C20` appearing twice (Oct 10 and Oct 20 sends both count). Its 7 rows pass through untouched. | **22** | Matches Finance's `target_base` |

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

- **It overcounts the chains.** `GROUP BY communication_id` groups by *campaign*, not by *underlying communication*. So `C2` (sent under 9001, retried under 9002) gets counted once under 9001 **and** once under 9002 — the dedup only happens within a single campaign's rows, never across the parent→child relationship. Same for `C3` across 9001/9002/9003, and `D1` across 9201/9202. This is exactly what the README's "Retry chains" section warns about: a chain has to be collapsed as *one* unit, not campaign-by-campaign.
- **It simultaneously undercounts the standalone campaign.** `9101` drops from 7 raw rows to 6 distinct customers, because `COUNT(DISTINCT customer_id)` blindly collapses `C20`'s two legitimate, independent sends (Oct 10 and Oct 20) into one — even though 9101 isn't a retry chain at all. The README is explicit that this is *not* a retry, so it should **never** be deduped.

That's why a plain `GROUP BY` can't work here regardless of which column you group on: campaigns that *are* chains need cross-campaign deduping that a per-campaign `GROUP BY` can't see, while the one campaign that *isn't* a chain needs to explicitly **not** be deduped — and a single flat `COUNT(DISTINCT ...)` can't apply two different rules to two different groups. That's the actual reason the solution needs the `roots`/`chain_flag` logic: it has to first figure out *which* rows belong to the same underlying communication (via `parent_id`, potentially several levels deep) before deciding whether to dedupe that group at all.

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

A few things stood out while digging through the data. First, campaign `9004` has `processing_status = 'processed'` — meaning the send pipeline actually ran and generated 4 real `communication_log` rows — despite its `creation_status` still sitting at `approval_awaiting`. That's a live example of the send pipeline running ahead of approval bookkeeping that the data dictionary warns about, and it's easy to miss if you only filter on `processing_status`. Second, the retry chain for the cart-recovery communication goes three levels deep (`9001 → 9002 → 9003`), so a single customer (`C3`) shows up in the raw log three separate times before finally being counted once — a naive `COUNT(DISTINCT customer_id) GROUP BY communication_id` would still overcount here because it groups by campaign, not by chain. Third, `delivery_status` (delivered vs. failed) turned out not to matter at all for this particular number: `target_base` is about who was *targeted* across a chain, not who was successfully delivered to, so `D1`'s failed attempt under `9201` still contributes to the same "1" as its successful retry under `9202`. It didn't change the final count here, but it's a distinction worth flagging since it's easy to assume a "reached" metric silently means "delivered."
