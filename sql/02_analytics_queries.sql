-- =====================================================================
-- Q2. Two queries most valuable to the XYZ analytics team
-- =====================================================================

-- ---------------------------------------------------------------------
-- Query A: Conversion by business line, month and customer type.
--
-- Why: conversion is the core health metric for a travel site. It shows
-- which business line loses the most demand, and whether registered users
-- convert better than guests (the value of getting people to register).
--
-- Each booking is credited to the search that produced it (search_id), and
-- everything is grouped by SEARCH date, so the numerator and denominator
-- cover the same set of searches. A search counts as converted once, no
-- matter how many items it led to.
-- ---------------------------------------------------------------------
WITH searches AS (
    SELECT fs.search_id, d.year, d.month, bl.business_line,
           CASE WHEN c.customer_type = 'Registered' THEN 'Registered'
                ELSE 'Guest/Anonymous' END AS customer_segment
    FROM fact_search fs
    JOIN dim_date d           ON d.date_key = fs.search_date_key
    JOIN dim_business_line bl ON bl.business_line_key = fs.business_line_key
    JOIN dim_customer c       ON c.customer_key = fs.customer_key
),
search_outcomes AS (   -- one row per search that led to a non-cancelled booking
    SELECT search_id,
           COUNT(*)              AS booked_items,
           SUM(total_amount_usd) AS booked_revenue_usd
    FROM fact_booking_item
    WHERE booking_status <> 'Cancelled'
      AND search_id IS NOT NULL
    GROUP BY search_id
)
SELECT s.year, s.month, s.business_line, s.customer_segment,
       COUNT(*)                                                    AS searches,
       COUNT(o.search_id)                                          AS converted_searches,
       ROUND(100.0 * COUNT(o.search_id) / COUNT(*), 2)             AS conversion_pct,
       COALESCE(SUM(o.booked_items), 0)                            AS booked_items,
       ROUND(COALESCE(SUM(o.booked_revenue_usd), 0) / COUNT(*), 2) AS revenue_per_search_usd
FROM searches s
LEFT JOIN search_outcomes o ON o.search_id = s.search_id
GROUP BY s.year, s.month, s.business_line, s.customer_segment
ORDER BY s.year, s.month, s.business_line, s.customer_segment;


-- ---------------------------------------------------------------------
-- Query B: Unmet demand - destinations people search for but don't book.
--
-- A destination with a lot of searches and low conversion points to a
-- possible supply or pricing gap: partnerships can see where to add hotel
-- or airline inventory, and marketing where demand already exists. It is an
-- estimate, not proof: price, sold-out dates and people booking somewhere
-- else all lower conversion too.
--
-- Conversion is search-based, like Query A: a search in the window counts
-- as converted if it led to a non-cancelled booking.
-- ---------------------------------------------------------------------
WITH window_searches AS (
    SELECT fs.search_id, fs.destination_location_key, fs.business_line_key
    FROM fact_search fs
    JOIN dim_date d ON d.date_key = fs.search_date_key
    WHERE d.full_date >= DATE '2025-01-01'   -- analysis window; a parameter in BI
),
converted AS (
    SELECT DISTINCT search_id
    FROM fact_booking_item
    WHERE booking_status <> 'Cancelled'
      AND search_id IS NOT NULL
)
SELECT COALESCE(l.airport_code, l.city)                    AS destination,
       bl.business_line,
       COUNT(*)                                            AS searches,
       COUNT(c.search_id)                                  AS converted_searches,
       ROUND(100.0 * COUNT(c.search_id) / COUNT(*), 2)     AS conversion_pct,
       COUNT(*) - COUNT(c.search_id)                       AS unconverted_searches
FROM window_searches s
JOIN dim_location l       ON l.location_key = s.destination_location_key
JOIN dim_business_line bl ON bl.business_line_key = s.business_line_key
LEFT JOIN converted c     ON c.search_id = s.search_id
GROUP BY COALESCE(l.airport_code, l.city), bl.business_line
HAVING COUNT(*) >= 50
ORDER BY unconverted_searches DESC
LIMIT 20;
