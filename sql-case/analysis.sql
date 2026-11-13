-- Polar Decision Lab | SQLite 3.x | reproducible analytical exercise
-- Synthetic voyage snapshots from the existing interactive case.
-- This dataset contains one constructed observation per voyage, NOT real booking history.
PRAGMA foreign_keys = ON;
DROP TABLE IF EXISTS commercial_metrics;
DROP TABLE IF EXISTS booking_snapshots;
DROP TABLE IF EXISTS voyages;
CREATE TABLE voyages (
  voyage_id TEXT PRIMARY KEY,
  voyage_name TEXT NOT NULL,
  region TEXT NOT NULL,
  days_out INTEGER NOT NULL
);
CREATE TABLE booking_snapshots (
  voyage_id TEXT PRIMARY KEY REFERENCES voyages(voyage_id),
  booked INTEGER NOT NULL CHECK (booked >= 0),
  pickup INTEGER NOT NULL CHECK (pickup >= 0)
);
CREATE TABLE commercial_metrics (
  voyage_id TEXT PRIMARY KEY REFERENCES voyages(voyage_id),
  capacity INTEGER NOT NULL CHECK (capacity > 0),
  target_pct REAL NOT NULL CHECK (target_pct > 0 AND target_pct <= 1),
  booked_fare REAL NOT NULL,
  future_fare REAL NOT NULL,
  ancillary REAL NOT NULL,
  variable_cost REAL NOT NULL,
  fixed_cost REAL NOT NULL,
  marketing REAL NOT NULL
);
INSERT INTO voyages VALUES ('CASE-A', 'Antarctic Discovery', 'Antarctica', 60);
INSERT INTO booking_snapshots VALUES ('CASE-A', 112, 28);
INSERT INTO commercial_metrics VALUES ('CASE-A', 180, 0.85, 12000, 13000, 1200, 4800, 650000, 45000);
INSERT INTO voyages VALUES ('CASE-B', 'Arctic Passage', 'Arctic', 95);
INSERT INTO booking_snapshots VALUES ('CASE-B', 89, 37);
INSERT INTO commercial_metrics VALUES ('CASE-B', 152, 0.86, 14200, 15000, 1600, 5700, 740000, 49000);
INSERT INTO voyages VALUES ('CASE-C', 'Greenland Explorer', 'Greenland', 35);
INSERT INTO booking_snapshots VALUES ('CASE-C', 119, 16);
INSERT INTO commercial_metrics VALUES ('CASE-C', 168, 0.87, 10800, 11600, 1250, 4200, 610000, 38000);

-- QUERY 1: Join source tables
SELECT v.voyage_name,
       v.days_out,
       b.booked,
       b.pickup,
       c.capacity,
       b.booked + b.pickup AS projected_guests,
       ROUND(100.0 * (b.booked + b.pickup) / c.capacity, 1) AS forecast_occupancy_pct,
       ROUND(100.0 * c.target_pct, 1) AS target_occupancy_pct
FROM voyages AS v
JOIN booking_snapshots AS b USING (voyage_id)
JOIN commercial_metrics AS c USING (voyage_id)
ORDER BY v.days_out;

-- QUERY 2: Aggregate KPI by departure window
WITH joined AS (
  SELECT v.voyage_id, v.days_out, b.booked + b.pickup AS projected_guests,
         c.capacity, c.booked_fare, c.future_fare, c.ancillary,
         b.booked, b.pickup, c.variable_cost, c.fixed_cost, c.marketing
  FROM voyages v
  JOIN booking_snapshots b USING (voyage_id)
  JOIN commercial_metrics c USING (voyage_id)
)
SELECT CASE WHEN days_out <= 60 THEN 'Near term (0-60d)'
            ELSE 'Later (61+d)' END AS departure_window,
       COUNT(*) AS voyages,
       SUM(projected_guests) AS projected_guests,
       SUM(capacity) AS total_capacity,
       ROUND(100.0 * SUM(projected_guests) / SUM(capacity), 1) AS weighted_occupancy_pct,
       ROUND(AVG(1.0 * (booked * booked_fare + pickup * future_fare)
                 / projected_guests), 0) AS avg_voyage_fare_per_guest_usd,
       ROUND(SUM(booked * booked_fare + pickup * future_fare
                 + projected_guests * ancillary), 0) AS forecast_revenue_usd
FROM joined
GROUP BY CASE WHEN days_out <= 60 THEN 'Near term (0-60d)'
                  ELSE 'Later (61+d)' END
ORDER BY MIN(days_out);

-- QUERY 3: Flag occupancy gaps
WITH joined AS (
  SELECT v.voyage_name, v.days_out, b.booked, b.pickup,
         c.capacity, c.target_pct,
         (CAST(c.capacity * c.target_pct AS INTEGER)
          + CASE WHEN c.capacity * c.target_pct > CAST(c.capacity * c.target_pct AS INTEGER)
                 THEN 1 ELSE 0 END) AS target_guests
  FROM voyages v
  JOIN booking_snapshots b USING (voyage_id)
  JOIN commercial_metrics c USING (voyage_id)
), risk AS (
  SELECT voyage_name, days_out, capacity, booked + pickup AS projected_guests,
         target_guests,
         MAX(0, target_guests - (booked + pickup)) AS shortfall_guests,
         ROUND(100.0 * (target_pct - 1.0 * (booked + pickup) / capacity), 1) AS gap_pp
  FROM joined
)
SELECT voyage_name, days_out, projected_guests, target_guests, shortfall_guests, gap_pp,
       CASE WHEN gap_pp >= 5 THEN 'Priority review'
            WHEN gap_pp > 0 THEN 'Monitor'
            ELSE 'At or above target' END AS risk_flag
FROM risk
ORDER BY gap_pp DESC;

-- QUERY 4: Prepare visualization extract
WITH joined AS (
  SELECT v.voyage_id, v.voyage_name, v.days_out,
         b.booked, b.pickup, c.capacity, c.target_pct,
         c.booked_fare, c.future_fare, c.ancillary,
         c.variable_cost, c.fixed_cost, c.marketing
  FROM voyages v
  JOIN booking_snapshots b USING (voyage_id)
  JOIN commercial_metrics c USING (voyage_id)
), modeled AS (
  SELECT *, booked + pickup AS projected_guests,
         booked * booked_fare + pickup * future_fare
           + (booked + pickup) * ancillary AS forecast_revenue_usd,
         fixed_cost + marketing + (booked + pickup) * variable_cost AS modeled_cost_usd
  FROM joined
)
SELECT voyage_id, voyage_name,
       ROUND(100.0 * projected_guests / capacity, 1) AS forecast_occupancy_pct,
       ROUND(100.0 * target_pct, 1) AS target_occupancy_pct,
       ROUND(forecast_revenue_usd, 0) AS forecast_revenue_usd,
       ROUND(forecast_revenue_usd - modeled_cost_usd, 0) AS contribution_proxy_usd,
       ROUND(future_fare + ancillary - variable_cost, 0) AS contribution_per_extra_guest_usd
FROM modeled
ORDER BY forecast_occupancy_pct ASC;
