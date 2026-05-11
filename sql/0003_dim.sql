-- Migration 0003 — dimensions.
-- Slow-changing reference data. Tables are created idempotently; seeds use ON CONFLICT DO NOTHING.

-- ============================================================
-- dim.date — one row per calendar day
-- ============================================================
CREATE TABLE IF NOT EXISTS dim.date (
  date_id          DATE PRIMARY KEY,
  year             SMALLINT NOT NULL,
  month            SMALLINT NOT NULL,
  day              SMALLINT NOT NULL,
  dow              SMALLINT NOT NULL,            -- 0=Mon ... 6=Sun
  is_weekend       BOOLEAN  NOT NULL,
  is_us_holiday    BOOLEAN  NOT NULL DEFAULT FALSE,
  holiday_name     TEXT,
  is_feast_day     BOOLEAN  NOT NULL DEFAULT FALSE,   -- North End feasts (St. Anthony, Fisherman's, ...)
  is_school_term   BOOLEAN  NOT NULL DEFAULT TRUE,    -- Boston-area universities in session
  tourist_season   TEXT                                -- 'peak' | 'shoulder' | 'off'
);

-- ============================================================
-- dim.hour — one row per hour 0..23
-- ============================================================
CREATE TABLE IF NOT EXISTS dim.hour (
  hour_id          SMALLINT PRIMARY KEY,
  is_lunch         BOOLEAN  NOT NULL,
  is_dinner        BOOLEAN  NOT NULL,
  is_late_night    BOOLEAN  NOT NULL
);

-- ============================================================
-- dim.restaurant — Neptune + peers + nearby competitors
-- ============================================================
CREATE TABLE IF NOT EXISTS dim.restaurant (
  restaurant_id    SERIAL PRIMARY KEY,
  name             TEXT NOT NULL,
  address          TEXT,
  neighborhood     TEXT,
  geog             GEOGRAPHY(POINT, 4326),
  category         TEXT,                            -- 'seafood', 'italian', 'bar', ...
  is_subject       BOOLEAN NOT NULL DEFAULT FALSE,  -- TRUE only for Neptune Oyster
  UNIQUE (name, address)
);
CREATE INDEX IF NOT EXISTS dim_restaurant_geog_idx ON dim.restaurant USING GIST (geog);

-- ============================================================
-- dim.menu_item — canonical item taxonomy (populated as menus are scraped)
-- ============================================================
CREATE TABLE IF NOT EXISTS dim.menu_item (
  item_id          SERIAL PRIMARY KEY,
  canonical_name   TEXT UNIQUE NOT NULL,            -- 'lobster_roll', 'wellfleet_oyster', ...
  category         TEXT,                             -- 'oyster', 'sandwich', 'crudo', ...
  origin           TEXT                              -- 'cape_cod', 'prince_edward', 'damariscotta', ...
);

-- ============================================================
-- dim.review_topic — review-text topic taxonomy
-- ============================================================
CREATE TABLE IF NOT EXISTS dim.review_topic (
  topic_id            SERIAL PRIMARY KEY,
  topic               TEXT UNIQUE NOT NULL,
  is_positive_default BOOLEAN                        -- NULL = polarity depends on context
);

-- ============================================================
-- Seed: dim.hour (24 rows)
-- ============================================================
INSERT INTO dim.hour (hour_id, is_lunch, is_dinner, is_late_night)
SELECT h,
       h BETWEEN 11 AND 13,
       h BETWEEN 17 AND 21,
       h BETWEEN 22 AND 23
FROM generate_series(0, 23) AS h
ON CONFLICT (hour_id) DO NOTHING;

-- ============================================================
-- Seed: dim.date — 2018-01-01 through 2030-12-31 (~13y)
-- Holiday / feast / school_term flags refined by a Python seed step later.
-- tourist_season is a simple month bucket; refine later if needed.
-- ============================================================
INSERT INTO dim.date (date_id, year, month, day, dow, is_weekend, tourist_season)
SELECT
  d::DATE,
  EXTRACT(YEAR  FROM d)::SMALLINT,
  EXTRACT(MONTH FROM d)::SMALLINT,
  EXTRACT(DAY   FROM d)::SMALLINT,
  (EXTRACT(ISODOW FROM d)::SMALLINT - 1),         -- ISO: 1=Mon..7=Sun -> 0..6
  EXTRACT(ISODOW FROM d) IN (6, 7),
  CASE
    WHEN EXTRACT(MONTH FROM d) IN (6, 7, 8, 9) THEN 'peak'
    WHEN EXTRACT(MONTH FROM d) IN (5, 10)      THEN 'shoulder'
    ELSE 'off'
  END
FROM generate_series('2018-01-01'::DATE, '2030-12-31'::DATE, '1 day'::INTERVAL) AS d
ON CONFLICT (date_id) DO NOTHING;

-- ============================================================
-- Seed: Neptune Oyster as the subject restaurant
-- Approx coordinates for 63 Salem St, Boston, MA 02113.
-- ST_MakePoint(lon, lat) — note the order!
-- ============================================================
INSERT INTO dim.restaurant (name, address, neighborhood, geog, category, is_subject)
VALUES (
  'Neptune Oyster',
  '63 Salem St, Boston, MA 02113',
  'North End',
  ST_SetSRID(ST_MakePoint(-71.0556, 42.3637), 4326)::GEOGRAPHY,
  'seafood',
  TRUE
)
ON CONFLICT (name, address) DO NOTHING;

-- ============================================================
-- Seed: Boston seafood peers (geog filled later via OSM/geocoding)
-- ============================================================
INSERT INTO dim.restaurant (name, address, neighborhood, category, is_subject) VALUES
  ('Island Creek Oyster Bar', '500 Commonwealth Ave, Boston, MA 02215', 'Kenmore',    'seafood', FALSE),
  ('Row 34',                  '383 Congress St, Boston, MA 02210',     'Fort Point', 'seafood', FALSE),
  ('B&G Oysters',             '550 Tremont St, Boston, MA 02116',      'South End',  'seafood', FALSE),
  ('Saltie Girl',             '281 Dartmouth St, Boston, MA 02116',    'Back Bay',   'seafood', FALSE),
  ('Eventide Oyster Co.',     '86 Middle St, Portland, ME 04101',      NULL,         'seafood', FALSE)
ON CONFLICT (name, address) DO NOTHING;

-- ============================================================
-- Seed: starter review-topic taxonomy
-- ============================================================
INSERT INTO dim.review_topic (topic, is_positive_default) VALUES
  ('wait_time',     FALSE),
  ('service',       NULL),
  ('food_quality',  TRUE),
  ('lobster_roll',  TRUE),
  ('oysters',       TRUE),
  ('bread',         TRUE),
  ('crudo',         TRUE),
  ('chowder',       TRUE),
  ('noise',         FALSE),
  ('price',         NULL),
  ('value',         NULL),
  ('crowding',      FALSE),
  ('atmosphere',    NULL),
  ('reservation',   FALSE),
  ('parking',       FALSE),
  ('tourist',       NULL),
  ('local',         NULL),
  ('freshness',     TRUE),
  ('staff',         NULL),
  ('owner_response',NULL)
ON CONFLICT (topic) DO NOTHING;
