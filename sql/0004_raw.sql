-- Migration 0004 — raw layer.
-- Pattern for every source: indexable columns we'll filter/join on, plus the full
-- as-scraped payload in a JSONB `raw` column. Schema is forgiving on purpose
-- (NULLs allowed, JSONB catches surprises) — staging is where we tighten types.

-- ============================================================
-- 1. raw.reviews — Yelp / Google / TripAdvisor reviews (one row per review)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.reviews (
  review_id                TEXT PRIMARY KEY,                 -- '<vendor>:<vendor_review_id>'
  vendor                   TEXT NOT NULL,                    -- 'yelp','google','tripadvisor'
  restaurant_id            INT REFERENCES dim.restaurant,
  posted_at                TIMESTAMPTZ,
  rating                   NUMERIC(2,1),
  body                     TEXT,
  reviewer_id              TEXT,
  reviewer_total_reviews   INT,                              -- tourist / local proxy
  reviewer_boston_reviews  INT,
  reviewer_home_city       TEXT,
  raw                      JSONB,
  ingested_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS reviews_restaurant_time_idx ON raw.reviews (restaurant_id, posted_at);
CREATE INDEX IF NOT EXISTS reviews_raw_gin_idx        ON raw.reviews USING GIN (raw);

-- ============================================================
-- 2. raw.menu_snapshot — one row per item per scrape (current + Wayback)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.menu_snapshot (
  snapshot_id     BIGSERIAL PRIMARY KEY,
  restaurant_id   INT REFERENCES dim.restaurant,
  captured_at     DATE NOT NULL,
  raw_name        TEXT,
  item_id         INT REFERENCES dim.menu_item,
  description     TEXT,
  price           NUMERIC(7,2),
  source_url      TEXT,
  raw             JSONB,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (restaurant_id, captured_at, raw_name)
);
CREATE INDEX IF NOT EXISTS menu_snapshot_restaurant_time_idx ON raw.menu_snapshot (restaurant_id, captured_at);

-- ============================================================
-- 3. raw.boston_311 — service requests (filter to North End by geog later)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.boston_311 (
  case_id       TEXT PRIMARY KEY,
  opened_at     TIMESTAMPTZ,
  closed_at     TIMESTAMPTZ,
  category      TEXT,
  subject       TEXT,
  neighborhood  TEXT,
  geog          GEOGRAPHY(POINT, 4326),
  raw           JSONB,
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS boston_311_opened_at_idx ON raw.boston_311 (opened_at);
CREATE INDEX IF NOT EXISTS boston_311_geog_idx     ON raw.boston_311 USING GIST (geog);

-- ============================================================
-- 4. raw.weather_obs — Open-Meteo hourly archive at Logan Airport
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.weather_obs (
  obs_id          BIGSERIAL PRIMARY KEY,
  location        TEXT NOT NULL,                              -- 'logan_airport'
  ts              TIMESTAMPTZ NOT NULL,
  temp_c          NUMERIC,
  precip_mm       NUMERIC,
  wind_mps        NUMERIC,
  wind_dir_deg    SMALLINT,
  cloud_cover_pct SMALLINT,
  is_rain         BOOLEAN,
  is_snow         BOOLEAN,
  raw             JSONB,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (location, ts)
);
CREATE INDEX IF NOT EXISTS weather_obs_ts_idx ON raw.weather_obs (ts);

-- ============================================================
-- 5. raw.sports_events — Bruins (NHL) + Celtics (NBA) home/away schedule
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.sports_events (
  event_id      TEXT PRIMARY KEY,           -- 'nhl_<gameId>' / 'nba_<gameId>'
  league        TEXT NOT NULL,              -- 'NHL','NBA'
  team          TEXT NOT NULL,              -- 'BOS'
  is_home       BOOLEAN NOT NULL,
  is_playoff    BOOLEAN NOT NULL DEFAULT FALSE,
  opponent      TEXT,
  start_ts      TIMESTAMPTZ NOT NULL,
  venue         TEXT,
  attendance    INT,
  raw           JSONB,
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS sports_events_start_ts_idx ON raw.sports_events (start_ts);

-- ============================================================
-- 6. raw.popular_times — Google "typical week" snapshot (no historical per-date data)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.popular_times (
  snapshot_id   BIGSERIAL PRIMARY KEY,
  restaurant_id INT REFERENCES dim.restaurant,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  dow           SMALLINT NOT NULL,           -- 0=Mon..6=Sun
  hour          SMALLINT NOT NULL,           -- 0..23
  busyness      SMALLINT,                    -- 0..100
  raw           JSONB,
  UNIQUE (restaurant_id, captured_at, dow, hour)
);
CREATE INDEX IF NOT EXISTS popular_times_restaurant_idx ON raw.popular_times (restaurant_id);

-- ============================================================
-- 7. raw.reddit_mentions — submissions and comments mentioning Neptune
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.reddit_mentions (
  mention_id   TEXT PRIMARY KEY,              -- reddit fullname e.g. 't3_xxx' / 't1_xxx'
  subreddit    TEXT NOT NULL,
  kind         TEXT NOT NULL,                 -- 'submission' | 'comment'
  posted_at    TIMESTAMPTZ NOT NULL,
  author       TEXT,
  score        INT,
  title        TEXT,                          -- NULL for comments
  body         TEXT,
  url          TEXT,
  raw          JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS reddit_mentions_posted_at_idx ON raw.reddit_mentions (posted_at);

-- ============================================================
-- 8. raw.instagram_posts — @neptuneoyster and hashtag posts
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.instagram_posts (
  shortcode      TEXT PRIMARY KEY,
  account        TEXT NOT NULL,
  posted_at      TIMESTAMPTZ NOT NULL,
  caption        TEXT,
  hashtags       TEXT[],
  like_count     INT,
  comment_count  INT,
  is_video       BOOLEAN,
  raw            JSONB,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS instagram_posts_posted_at_idx ON raw.instagram_posts (posted_at);
CREATE INDEX IF NOT EXISTS instagram_posts_hashtags_idx ON raw.instagram_posts USING GIN (hashtags);

-- ============================================================
-- 9. raw.bluebike_trips — public bike-share trips near North End
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.bluebike_trips (
  trip_id        BIGSERIAL PRIMARY KEY,
  start_ts       TIMESTAMPTZ NOT NULL,
  end_ts         TIMESTAMPTZ,
  duration_sec   INT,
  start_station  TEXT,
  end_station    TEXT,
  start_geog     GEOGRAPHY(POINT, 4326),
  end_geog       GEOGRAPHY(POINT, 4326),
  user_type      TEXT,                         -- 'member','casual'
  raw            JSONB,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS bluebike_trips_start_ts_idx   ON raw.bluebike_trips (start_ts);
CREATE INDEX IF NOT EXISTS bluebike_trips_start_geog_idx ON raw.bluebike_trips USING GIST (start_geog);

-- ============================================================
-- 10. raw.boston_inspections — health inspections (competitor weakness signal)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.boston_inspections (
  inspection_id   TEXT PRIMARY KEY,
  business_name   TEXT,
  address         TEXT,
  neighborhood    TEXT,
  geog            GEOGRAPHY(POINT, 4326),
  inspected_at    TIMESTAMPTZ,
  result          TEXT,                          -- 'HE_Pass','HE_Fail',...
  violation_code  TEXT,
  violation_desc  TEXT,
  raw             JSONB,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS boston_inspections_inspected_at_idx ON raw.boston_inspections (inspected_at);
CREATE INDEX IF NOT EXISTS boston_inspections_geog_idx ON raw.boston_inspections USING GIST (geog);

-- ============================================================
-- 11. raw.boston_permits — construction permits (nearby noise/disruption proxy)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.boston_permits (
  permit_id    TEXT PRIMARY KEY,
  permit_type  TEXT,
  issued_at    TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ,
  description  TEXT,
  address      TEXT,
  neighborhood TEXT,
  geog         GEOGRAPHY(POINT, 4326),
  raw          JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS boston_permits_issued_at_idx ON raw.boston_permits (issued_at);
CREATE INDEX IF NOT EXISTS boston_permits_geog_idx ON raw.boston_permits USING GIST (geog);

-- ============================================================
-- 12. raw.boston_liquor_licenses — competitor map within walking distance
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.boston_liquor_licenses (
  license_id     TEXT PRIMARY KEY,
  business_name  TEXT,
  license_type   TEXT,
  status         TEXT,
  issued_at      DATE,
  expires_at     DATE,
  address        TEXT,
  geog           GEOGRAPHY(POINT, 4326),
  raw            JSONB,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS boston_liquor_licenses_geog_idx ON raw.boston_liquor_licenses USING GIST (geog);

-- ============================================================
-- 13. raw.mbta_ridership — MBTA V3 API (recent context only, ≤30 days)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.mbta_ridership (
  obs_id       BIGSERIAL PRIMARY KEY,
  station      TEXT NOT NULL,                  -- 'Haymarket','North Station',...
  ts           TIMESTAMPTZ NOT NULL,
  taps         INT,
  raw          JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (station, ts)
);
CREATE INDEX IF NOT EXISTS mbta_ridership_ts_idx ON raw.mbta_ridership (ts);

-- ============================================================
-- 14. raw.massport_cruise — cruise-ship arrivals at Boston cruise port
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.massport_cruise (
  arrival_id    BIGSERIAL PRIMARY KEY,
  arrival_date  DATE NOT NULL,
  ship_name     TEXT,
  passengers    INT,
  berth         TEXT,
  raw           JSONB,
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (arrival_date, ship_name)
);
CREATE INDEX IF NOT EXISTS massport_cruise_arrival_date_idx ON raw.massport_cruise (arrival_date);

-- ============================================================
-- 15. raw.noaa_landings — wholesale oyster/lobster landings (MA, ME, RI)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.noaa_landings (
  landing_id   BIGSERIAL PRIMARY KEY,
  species      TEXT NOT NULL,                   -- 'oyster','lobster',...
  state        TEXT NOT NULL,                   -- 'MA','ME','RI'
  year         SMALLINT NOT NULL,
  month        SMALLINT NOT NULL,
  pounds       BIGINT,
  value_usd    NUMERIC,
  raw          JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (species, state, year, month)
);
CREATE INDEX IF NOT EXISTS noaa_landings_temporal_idx ON raw.noaa_landings (year, month);

-- ============================================================
-- 16. raw.bls_cpi — Consumer Price Index ('food away from home' series)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.bls_cpi (
  obs_id      BIGSERIAL PRIMARY KEY,
  series_id   TEXT NOT NULL,                    -- e.g. 'CUUR0000SEFV' = food away from home
  year        SMALLINT NOT NULL,
  month       SMALLINT NOT NULL,
  value       NUMERIC,
  raw         JSONB,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (series_id, year, month)
);

-- ============================================================
-- 17. raw.census_acs — block-group ACS variables near Neptune
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.census_acs (
  block_group_id TEXT PRIMARY KEY,              -- GEOID
  geog           GEOGRAPHY(MULTIPOLYGON, 4326),
  population     INT,
  median_income  NUMERIC,
  median_age     NUMERIC,
  vintage        TEXT,                           -- e.g. '2019-2023'
  raw            JSONB,
  ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS census_acs_geog_idx ON raw.census_acs USING GIST (geog);

-- ============================================================
-- 18. raw.osm_pois — OpenStreetMap POIs within 300m of Neptune
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.osm_pois (
  osm_id       BIGINT PRIMARY KEY,
  osm_type     TEXT NOT NULL,                   -- 'node','way','relation'
  amenity      TEXT,                             -- 'restaurant','bar','cafe','hotel',...
  name         TEXT,
  cuisine      TEXT,
  geog         GEOGRAPHY(POINT, 4326),
  raw          JSONB,
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS osm_pois_amenity_idx ON raw.osm_pois (amenity);
CREATE INDEX IF NOT EXISTS osm_pois_geog_idx    ON raw.osm_pois USING GIST (geog);
