-- =====================================================================
-- Q2. Two queries most valuable to the XYZ analytics team
-- =====================================================================

-- ---------------------------------------------------------------------
-- Query A: Search-to-booking conversion funnel by business line and month,
-- split by registered vs. guest/anonymous customers.
--
-- Why: conversion is the core health metric for a travel site. It shows
-- which line leaks the most demand, and whether registered users convert
-- better than guests (which sizes the value of pushing registration).
-- ---------------------------------------------------------------------
WITH searches AS (
    SELECT
        d.year,
        d.month,
        bl.business_line,
        CASE WHEN c.customer_type = 'Registered' THEN 'Registered' ELSE 'Guest/Anonymous' END AS customer_segment,
        COUNT(*)                     AS searches,
        COUNT(DISTINCT fs.session_id) AS search_sessions
    FROM fact_search fs
    JOIN dim_date          d  ON d.date_key           = fs.search_date_key
    JOIN dim_business_line bl ON bl.business_line_key = fs.business_line_key
    JOIN dim_customer      c  ON c.customer_key       = fs.customer_key
    GROUP BY 1, 2, 3, 4
),
bookings AS (
    SELECT
        d.year,
        d.month,
        bl.business_line,
        CASE WHEN c.customer_type = 'Registered' THEN 'Registered' ELSE 'Guest/Anonymous' END AS customer_segment,
        COUNT(*)                                   AS booked_items,
        COUNT(fb.search_id)                        AS attributed_bookings,   -- bookings we can tie to a search
        SUM(fb.total_amount_usd)                   AS gross_bookings_usd
    FROM fact_booking_item fb
    JOIN dim_date          d  ON d.date_key           = fb.booking_date_key
    JOIN dim_business_line bl ON bl.business_line_key = fb.business_line_key
    JOIN dim_customer      c  ON c.customer_key       = fb.customer_key
    WHERE fb.booking_status <> 'Cancelled'
    GROUP BY 1, 2, 3, 4
)
SELECT
    s.year,
    s.month,
    s.business_line,
    s.customer_segment,
    s.searches,
    COALESCE(b.booked_items, 0)                                          AS booked_items,
    ROUND(100.0 * COALESCE(b.attributed_bookings, 0) / NULLIF(s.searches, 0), 2) AS search_conversion_pct,
    ROUND(COALESCE(b.gross_bookings_usd, 0), 2)                          AS gross_bookings_usd,
    ROUND(COALESCE(b.gross_bookings_usd, 0) / NULLIF(s.searches, 0), 2)  AS revenue_per_search_usd
FROM searches s
LEFT JOIN bookings b
       ON  b.year = s.year AND b.month = s.month
       AND b.business_line = s.business_line
       AND b.customer_segment = s.customer_segment
ORDER BY s.year, s.month, s.business_line, s.customer_segment;


-- ---------------------------------------------------------------------
-- Query B: Unmet demand - top destinations people search for but don't book.
--
-- Why: a destination with lots of searches and a low conversion rate is a
-- supply or pricing gap (no inventory, prices too high, bad results). This
-- tells merchandising/partnerships where to add hotel or airline inventory,
-- and marketing where demand already exists.
-- ---------------------------------------------------------------------
WITH dest_search AS (
    SELECT
        fs.destination_location_key,
        fs.business_line_key,
        COUNT(*)                              AS searches,
        COUNT(DISTINCT fs.customer_key)       AS distinct_searchers,
        AVG(fs.lead_time_days)                AS avg_search_lead_days
    FROM fact_search fs
    JOIN dim_date d ON d.date_key = fs.search_date_key
    WHERE d.full_date >= DATE '2025-01-01'           -- parameterise in BI: trailing 12 months
    GROUP BY 1, 2
),
dest_book AS (
    SELECT
        fb.destination_location_key,
        fb.business_line_key,
        COUNT(*)                   AS bookings,
        SUM(fb.total_amount_usd)   AS revenue_usd
    FROM fact_booking_item fb
    JOIN dim_date d ON d.date_key = fb.booking_date_key
    WHERE d.full_date >= DATE '2025-01-01'
      AND fb.booking_status <> 'Cancelled'
    GROUP BY 1, 2
)
SELECT
    COALESCE(l.airport_code, l.city)                                      AS destination,
    l.city,
    bl.business_line,
    s.searches,
    s.distinct_searchers,
    COALESCE(b.bookings, 0)                                               AS bookings,
    ROUND(100.0 * COALESCE(b.bookings, 0) / NULLIF(s.searches, 0), 2)     AS conversion_pct,
    ROUND(COALESCE(b.revenue_usd, 0), 2)                                  AS revenue_usd,
    ROUND(s.avg_search_lead_days, 1)                                      AS avg_search_lead_days,
    s.searches - COALESCE(b.bookings, 0)                                  AS unconverted_searches
FROM dest_search s
JOIN dim_location      l  ON l.location_key       = s.destination_location_key
JOIN dim_business_line bl ON bl.business_line_key = s.business_line_key
LEFT JOIN dest_book    b  ON b.destination_location_key = s.destination_location_key
                         AND b.business_line_key        = s.business_line_key
WHERE s.searches >= 50                                -- ignore long tail noise
ORDER BY unconverted_searches DESC
LIMIT 20;
