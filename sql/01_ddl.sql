-- =====================================================================
-- XYZ Travel - Customer Intelligence Warehouse (Kimball star schema)
-- Written in ANSI-style SQL; tested on DuckDB. Maps 1:1 to Snowflake or
-- Databricks (Delta) tables. Gold-layer model in a medallion lakehouse.
--
-- Grain summary
--   fact_search        one row per search a user runs (any business line)
--   fact_booking_item  one row per item booked (a flight, a hotel stay,
--                      or a car rental). One booking (cart / confirmation)
--                      can hold several items -> booking_id is a degenerate dim.
--
-- Unknown / not-applicable members use surrogate key -1 so fact FKs are
-- never NULL (keeps joins inner and BI tools happy).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Conformed dimensions
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        INTEGER PRIMARY KEY,      -- yyyymmdd
    full_date       DATE    NOT NULL,
    year            SMALLINT NOT NULL,
    quarter         SMALLINT NOT NULL,
    month           SMALLINT NOT NULL,
    month_name      VARCHAR NOT NULL,
    day_of_month    SMALLINT NOT NULL,
    day_of_week     SMALLINT NOT NULL,        -- 1 = Monday
    day_name        VARCHAR NOT NULL,
    is_weekend      BOOLEAN NOT NULL,
    is_us_holiday   BOOLEAN NOT NULL
);

CREATE TABLE dim_time (
    time_key        INTEGER PRIMARY KEY,      -- hhmm
    hour_24         SMALLINT NOT NULL,
    minute          SMALLINT NOT NULL,
    day_part        VARCHAR NOT NULL          -- Overnight / Morning / Afternoon / Evening
);

CREATE TABLE dim_business_line (
    business_line_key  SMALLINT PRIMARY KEY,
    business_line      VARCHAR NOT NULL       -- Flight / Hotel / Car
);

-- Customers: registered users AND guest checkouts.
-- Guests have no account, so they are keyed on a hashed email/phone so the
-- same guest can be recognised across bookings and later stitched to an
-- account if they register. SCD Type 2 keeps history (e.g. guest -> registered).
CREATE TABLE dim_customer (
    customer_key        BIGINT PRIMARY KEY,   -- surrogate
    customer_nk         VARCHAR NOT NULL,     -- user_id for registered, 'G:'||email_hash for guests
    customer_type       VARCHAR NOT NULL,     -- Registered / Guest / Anonymous
    user_id             VARCHAR,              -- NULL for guests
    email_hash          VARCHAR,              -- SHA-256 of normalised email (no raw PII in the warehouse)
    home_city           VARCHAR,
    home_country        VARCHAR,
    registration_date   DATE,
    loyalty_tier        VARCHAR,
    effective_from      TIMESTAMP NOT NULL,
    effective_to        TIMESTAMP,            -- NULL = current
    is_current          BOOLEAN NOT NULL
);

-- One location dimension, role-played as origin / destination.
-- Airports for flights, cities/areas for hotels and car pick-up.
CREATE TABLE dim_location (
    location_key    INTEGER PRIMARY KEY,
    location_type   VARCHAR NOT NULL,         -- Airport / City
    airport_code    VARCHAR,                  -- IATA, NULL for cities
    city            VARCHAR,
    state_region    VARCHAR,
    country         VARCHAR,
    latitude        DOUBLE,
    longitude       DOUBLE
);

CREATE TABLE dim_airline (
    airline_key     INTEGER PRIMARY KEY,
    airline_code    VARCHAR,
    airline_name    VARCHAR
);

CREATE TABLE dim_hotel (
    hotel_key       INTEGER PRIMARY KEY,
    hotel_id        VARCHAR,
    hotel_name      VARCHAR,
    hotel_chain     VARCHAR,
    star_rating     DECIMAL(2,1),
    location_key    INTEGER REFERENCES dim_location(location_key)
);

CREATE TABLE dim_car (
    car_key         INTEGER PRIMARY KEY,
    rental_company  VARCHAR,
    make            VARCHAR,
    model           VARCHAR,
    car_class       VARCHAR,                  -- Economy / SUV / ...
    seats           SMALLINT
);

CREATE TABLE dim_channel (
    channel_key     SMALLINT PRIMARY KEY,
    channel         VARCHAR,                  -- Web / iOS / Android
    traffic_source  VARCHAR                   -- Direct / Paid search / Email / ...
);

-- ---------------------------------------------------------------------
-- Facts
-- ---------------------------------------------------------------------

-- One row per search. A single table for all three lines (instead of three
-- search tables) so funnel / conversion questions are one query. Attributes
-- that only apply to one line are nullable or point at the -1 member.
CREATE TABLE fact_search (
    search_id                 VARCHAR PRIMARY KEY,   -- from the app event
    session_id                VARCHAR NOT NULL,
    customer_key              BIGINT  NOT NULL REFERENCES dim_customer(customer_key),  -- -1 = anonymous
    business_line_key         SMALLINT NOT NULL REFERENCES dim_business_line(business_line_key),
    channel_key               SMALLINT NOT NULL REFERENCES dim_channel(channel_key),
    search_date_key           INTEGER NOT NULL REFERENCES dim_date(date_key),
    search_time_key           INTEGER NOT NULL REFERENCES dim_time(time_key),
    search_ts_utc             TIMESTAMP NOT NULL,
    origin_location_key       INTEGER NOT NULL REFERENCES dim_location(location_key),      -- flight departure airport; -1 otherwise
    destination_location_key  INTEGER NOT NULL REFERENCES dim_location(location_key),      -- arrival airport / hotel location / car pick-up
    car_key                   INTEGER NOT NULL REFERENCES dim_car(car_key),                -- car model searched; -1 otherwise
    travel_start_date_key     INTEGER REFERENCES dim_date(date_key),   -- departure / check-in / pick-up
    travel_end_date_key       INTEGER REFERENCES dim_date(date_key),   -- arrival / check-out / drop-off
    departure_ts              TIMESTAMP,                               -- flight only
    arrival_ts                TIMESTAMP,                               -- flight only
    num_passengers            SMALLINT,                                -- flight + car
    num_rooms                 SMALLINT,                                -- hotel
    results_returned          INTEGER,
    lead_time_days            INTEGER                                  -- travel start - search date
);

-- One row per booked item. booking_id groups items bought together.
-- search_id links the booking back to the search that produced it
-- (session-based attribution done upstream in silver).
CREATE TABLE fact_booking_item (
    booking_item_id           VARCHAR PRIMARY KEY,
    booking_id                VARCHAR NOT NULL,      -- degenerate dimension (confirmation number)
    search_id                 VARCHAR,               -- attributed search, NULL if none found
    customer_key              BIGINT  NOT NULL REFERENCES dim_customer(customer_key),
    business_line_key         SMALLINT NOT NULL REFERENCES dim_business_line(business_line_key),
    channel_key               SMALLINT NOT NULL REFERENCES dim_channel(channel_key),
    booking_date_key          INTEGER NOT NULL REFERENCES dim_date(date_key),
    booking_time_key          INTEGER NOT NULL REFERENCES dim_time(time_key),
    booking_ts_utc            TIMESTAMP NOT NULL,
    travel_start_date_key     INTEGER NOT NULL REFERENCES dim_date(date_key),
    travel_end_date_key       INTEGER REFERENCES dim_date(date_key),
    origin_location_key       INTEGER NOT NULL REFERENCES dim_location(location_key),
    destination_location_key  INTEGER NOT NULL REFERENCES dim_location(location_key),
    airline_key               INTEGER NOT NULL REFERENCES dim_airline(airline_key),  -- -1 unless Flight
    hotel_key                 INTEGER NOT NULL REFERENCES dim_hotel(hotel_key),      -- -1 unless Hotel
    car_key                   INTEGER NOT NULL REFERENCES dim_car(car_key),          -- -1 unless Car
    is_guest_checkout         BOOLEAN NOT NULL,
    num_passengers            SMALLINT,
    num_rooms                 SMALLINT,
    num_nights_or_days        SMALLINT,
    base_amount_usd           DECIMAL(12,2) NOT NULL,
    tax_amount_usd            DECIMAL(12,2) NOT NULL,
    total_amount_usd          DECIMAL(12,2) NOT NULL,
    booking_status            VARCHAR NOT NULL,      -- Confirmed / Cancelled / Completed
    cancelled_date_key        INTEGER REFERENCES dim_date(date_key),
    _loaded_at                TIMESTAMP NOT NULL     -- audit column for incremental loads
);

-- Raw web events stay in the bronze layer of the lake (append-only JSON),
-- which is where "last five searches" style app features are NOT served from:
-- those are OLTP/app-cache concerns. The warehouse keeps the full history.
