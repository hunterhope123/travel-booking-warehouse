"""Builds the star schema in DuckDB, loads synthetic data, and runs
every query. Proves the DDL and SQL actually execute and return sane numbers.

    python test_warehouse.py      (or: pytest)
"""
from __future__ import annotations

import random
from datetime import date, datetime, timedelta
from pathlib import Path

import duckdb

HERE = Path(__file__).parent / "sql"
LINES = {1: "Flight", 2: "Hotel", 3: "Car"}


def split_sql(text: str) -> list[str]:
    stmts, buf = [], []
    for line in text.splitlines():
        if line.strip().startswith("--"):
            continue
        buf.append(line)
        if line.rstrip().endswith(";"):
            s = "\n".join(buf).strip().rstrip(";")
            if s:
                stmts.append(s)
            buf = []
    return stmts


def build(con: duckdb.DuckDBPyConnection, seed: int = 7) -> None:
    rnd = random.Random(seed)
    for stmt in split_sql((HERE / "01_ddl.sql").read_text()):
        con.execute(stmt)

    # dim_date / dim_time (generated in SQL - fast)
    con.execute("""
        INSERT INTO dim_date
        SELECT CAST(strftime(d, '%Y%m%d') AS INTEGER), d::DATE, year(d), quarter(d), month(d),
               monthname(d), day(d), isodow(d), dayname(d), isodow(d) >= 6,
               (month(d), day(d)) IN ((1,1),(7,4),(12,25))
        FROM range(DATE '2023-01-01', DATE '2028-01-01', INTERVAL 1 DAY) t(d)""")
    con.execute("""
        INSERT INTO dim_time
        SELECT h*100+m, h, m,
               CASE WHEN h < 6 THEN 'Overnight' WHEN h < 12 THEN 'Morning'
                    WHEN h < 18 THEN 'Afternoon' ELSE 'Evening' END
        FROM range(24) t(h), range(60) u(m)""")

    con.execute("INSERT INTO dim_business_line VALUES (-1,'Unknown'),(1,'Flight'),(2,'Hotel'),(3,'Car')")
    con.execute("INSERT INTO dim_channel VALUES (-1,'Unknown','Unknown'),(1,'Web','Direct'),(2,'iOS','Paid search'),(3,'Android','Email')")
    locs = [(-1, "Unknown", None, None, None, None, None, None),
            (1, "Airport", "DCA", "Washington", "DC", "US", 38.85, -77.04),
            (2, "Airport", "JFK", "New York", "NY", "US", 40.64, -73.78),
            (3, "Airport", "MIA", "Miami", "FL", "US", 25.79, -80.29),
            (4, "Airport", "LAX", "Los Angeles", "CA", "US", 33.94, -118.41),
            (5, "City", None, "Washington", "DC", "US", 38.90, -77.03),
            (6, "City", None, "Orlando", "FL", "US", 28.54, -81.38),
            (7, "City", None, "Chicago", "IL", "US", 41.88, -87.63)]
    con.executemany("INSERT INTO dim_location VALUES (?,?,?,?,?,?,?,?)", locs)
    con.execute("INSERT INTO dim_airline VALUES (-1,NULL,'N/A'),(1,'AA','American'),(2,'DL','Delta'),(3,'UA','United')")
    con.execute("INSERT INTO dim_hotel VALUES (-1,NULL,'N/A',NULL,NULL,-1),(1,'H1','Capitol Inn','Hilton',4.0,5),(2,'H2','Lake Lodge','Marriott',3.5,6),(3,'H3','Loop Suites','Hyatt',4.5,7)")
    con.execute("INSERT INTO dim_car VALUES (-1,NULL,NULL,'N/A',NULL,NULL),(1,'Hertz','Toyota','Corolla','Economy',5),(2,'Avis','Ford','Explorer','SUV',7)")

    # customers: registered + guests + the anonymous member
    con.execute("INSERT INTO dim_customer VALUES (-1,'ANON','Anonymous',NULL,NULL,NULL,NULL,NULL,NULL,TIMESTAMP '2000-01-01',NULL,TRUE)")
    for k in range(1, 401):
        reg = k <= 250
        con.execute(
            "INSERT INTO dim_customer VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            [k, f"U{k}" if reg else f"G:hash{k}", "Registered" if reg else "Guest",
             f"U{k}" if reg else None, f"hash{k}", "Washington", "US",
             date(2022, 1, 1) if reg else None, "Silver" if reg else None,
             datetime(2022, 1, 1), None, True],
        )

    # facts: bookings grow each year, with a different rate per line
    growth = {1: 1.20, 2: 1.35, 3: 0.90}
    base = {1: 300, 2: 250, 3: 150}
    sid = bid = 0
    searches, items = [], []
    for year_idx, year in enumerate([2023, 2024, 2025, 2026]):
        for line, n0 in base.items():
            n_book = int(n0 * growth[line] ** year_idx)
            n_search = n_book * rnd.randint(8, 14)
            for i in range(n_search):
                sid += 1
                ts = datetime(year, 1, 1) + timedelta(minutes=rnd.randint(0, 364 * 24 * 60))
                cust = rnd.choice([-1, -1] + list(range(1, 401)))
                dest = rnd.choice([1, 2, 3, 4] if line == 1 else [5, 6, 7])
                start = ts.date() + timedelta(days=rnd.randint(1, 120))
                searches.append((f"S{sid}", f"SES{sid // 3}", cust, line, rnd.randint(1, 3),
                                 int(ts.strftime("%Y%m%d")), ts.hour * 100 + ts.minute, ts,
                                 rnd.choice([1, 2, 3]) if line == 1 else -1, dest,
                                 rnd.choice([1, 2]) if line == 3 else -1,
                                 int(start.strftime("%Y%m%d")), int((start + timedelta(days=4)).strftime("%Y%m%d")),
                                 None, None, rnd.randint(1, 4) if line != 2 else None,
                                 rnd.randint(1, 2) if line == 2 else None, rnd.randint(0, 200),
                                 (start - ts.date()).days))
                if i < n_book:
                    bid += 1
                    s = searches[-1]
                    amt = round(rnd.uniform(80, 900), 2)
                    status = "Cancelled" if rnd.random() < 0.08 else "Confirmed"
                    # an anonymous searcher who books checks out as a guest
                    cust_key = s[2] if s[2] > 0 else 251 + bid % 150
                    items.append((f"BI{bid}", f"B{bid}", s[0], cust_key, line, s[4], s[5], s[6], s[7],
                                  s[11], s[12], s[8], s[9],
                                  rnd.choice([1, 2, 3]) if line == 1 else -1,
                                  rnd.choice([1, 2, 3]) if line == 2 else -1,
                                  s[10], cust_key > 250, s[15], s[16], 4, amt, round(amt * 0.1, 2),
                                  round(amt * 1.1, 2), status, None, datetime.now()))
    import pandas as pd
    search_df = pd.DataFrame(searches)
    items_df = pd.DataFrame(items)
    con.register("search_df", search_df)
    con.register("items_df", items_df)
    con.execute("INSERT INTO fact_search SELECT * FROM search_df")
    con.execute("INSERT INTO fact_booking_item SELECT * FROM items_df")


def run_file(con, name):
    return [con.execute(s).fetchdf() for s in split_sql((HERE / name).read_text())]


def test_warehouse_queries():
    con = duckdb.connect()
    build(con)
    a, b = run_file(con, "02_analytics_queries.sql")
    assert len(a) > 0 and (a["search_conversion_pct"] >= 0).all() and a["booked_items"].sum() > 0
    assert len(b) > 0
    (g,) = run_file(con, "03_booking_growth_yoy.sql")
    assert set(g["business_line"]) == {"Flight", "Hotel", "Car"}
    # first year has no growth, later years do
    assert g.groupby("business_line")["booking_growth_pct"].apply(lambda s: s.isna().sum()).eq(1).all()
    # the synthetic data grows Hotel ~35%/yr, Flight ~20%/yr and shrinks Car ~10%/yr;
    # the query should recover that ordering
    avg = g.groupby("business_line")["booking_growth_pct"].mean()
    assert avg["Hotel"] > avg["Flight"] > 0 > avg["Car"]
    # no anonymous (-1) customer on a booking: anonymous searchers check out as guests
    assert con.execute("SELECT COUNT(*) FROM fact_booking_item WHERE customer_key = -1").fetchone()[0] == 0


if __name__ == "__main__":
    import pandas as pd
    pd.set_option("display.width", 200, "display.max_columns", 20)
    con = duckdb.connect()
    build(con)
    a, b = run_file(con, "02_analytics_queries.sql")
    print("Q2-A conversion funnel (first 12 rows)\n", a.head(12), "\n")
    print("Q2-B unmet demand\n", b, "\n")
    print("Q3 YoY growth\n", run_file(con, "03_booking_growth_yoy.sql")[0])
    test_warehouse_queries()
    print("\nAll warehouse checks passed.")
