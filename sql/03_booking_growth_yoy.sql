-- =====================================================================
-- Q3. Percentage growth in bookings by year and business line
--
-- Definition choices (call these out - they change the answer):
--   * "Booking" = a booked item in fact_booking_item. A trip with a flight
--     and a hotel counts once for Flight and once for Hotel, which is what
--     you want for a per-line view.
--   * Year = the year the booking was MADE (booking_date), not travel year.
--   * Cancelled bookings are excluded (net bookings). Remove the WHERE
--     clause to report gross bookings.
--   * First year for each line has no prior year -> growth is NULL, and a
--     prior year of 0 also returns NULL instead of divide-by-zero.
--   * A calendar spine (years x lines) makes sure a year with zero bookings
--     still shows up, otherwise LAG() would compare against the wrong year.
-- =====================================================================
WITH bounds AS (
    SELECT MIN(d.year) AS min_year, MAX(d.year) AS max_year
    FROM fact_booking_item fb
    JOIN dim_date d ON d.date_key = fb.booking_date_key
),
line_years AS (            -- every year x every line, so gaps show as 0
    SELECT DISTINCT d.year, bl.business_line_key, bl.business_line
    FROM dim_date d
    CROSS JOIN dim_business_line bl
    CROSS JOIN bounds b
    WHERE bl.business_line_key > 0          -- skip the -1 Unknown row
      AND d.year BETWEEN b.min_year AND b.max_year
),
yearly AS (
    SELECT d.year, fb.business_line_key,
           COUNT(*)                 AS bookings,
           SUM(fb.total_amount_usd) AS booking_value_usd
    FROM fact_booking_item fb
    JOIN dim_date d ON d.date_key = fb.booking_date_key
    WHERE fb.booking_status <> 'Cancelled'
    GROUP BY d.year, fb.business_line_key
),
filled AS (
    SELECT ly.year, ly.business_line,
           COALESCE(y.bookings, 0)          AS bookings,
           COALESCE(y.booking_value_usd, 0) AS booking_value_usd
    FROM line_years ly
    LEFT JOIN yearly y
           ON y.year = ly.year
          AND y.business_line_key = ly.business_line_key
)
SELECT year, business_line, bookings,
       LAG(bookings) OVER w AS prior_year_bookings,
       ROUND(100.0 * (bookings - LAG(bookings) OVER w)
             / NULLIF(LAG(bookings) OVER w, 0), 2)                   AS booking_growth_pct,
       ROUND(100.0 * (booking_value_usd - LAG(booking_value_usd) OVER w)
             / NULLIF(LAG(booking_value_usd) OVER w, 0), 2)          AS value_growth_pct
FROM filled
WINDOW w AS (PARTITION BY business_line ORDER BY year)
ORDER BY business_line, year;
