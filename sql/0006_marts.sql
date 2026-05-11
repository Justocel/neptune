-- Migration 0006 — marts (analysis-ready, flat tables for notebooks).
-- These are the tables the four demo cards in plan.md §5 actually query.

-- ============================================================
-- marts.demand_hourly — the spine: hourly busyness with all regressors
-- One row per (restaurant, hour).
-- ============================================================
CREATE TABLE IF NOT EXISTS marts.demand_hourly (
  restaurant_id        INT NOT NULL REFERENCES dim.restaurant,
  ts                   TIMESTAMPTZ NOT NULL,
  dow                  SMALLINT,
  hour                 SMALLINT,
  busyness             SMALLINT,          -- 0–100 (Google typical-week-baseline or modeled)
  busyness_source      TEXT,              -- 'google_typical','model','blended'
  temp_c               NUMERIC,
  precip_mm            NUMERIC,
  wind_mps             NUMERIC,
  is_rain              BOOLEAN,
  is_snow              BOOLEAN,
  bruins_home_today    BOOLEAN,
  celtics_home_today   BOOLEAN,
  bruins_playoff       BOOLEAN,
  cruise_ship_count    SMALLINT,
  is_feast_day         BOOLEAN,
  is_us_holiday        BOOLEAN,
  is_school_term       BOOLEAN,
  bluebike_trips_300m  INT,                -- trips starting within 300m of restaurant, ±30min
  mbta_taps_haymarket  INT,
  PRIMARY KEY (restaurant_id, ts)
);
CREATE INDEX IF NOT EXISTS demand_hourly_ts_idx ON marts.demand_hourly (ts);

-- ============================================================
-- marts.price_daily — daily price tracking with peer benchmark
-- ============================================================
CREATE TABLE IF NOT EXISTS marts.price_daily (
  restaurant_id    INT  NOT NULL REFERENCES dim.restaurant,
  item_id          INT  NOT NULL REFERENCES dim.menu_item,
  date             DATE NOT NULL,
  price            NUMERIC(7,2),
  peer_median      NUMERIC(7,2),
  market_zscore    NUMERIC(6,3),
  rank_among_peers SMALLINT,
  PRIMARY KEY (restaurant_id, item_id, date)
);
CREATE INDEX IF NOT EXISTS price_daily_date_idx ON marts.price_daily (date);

-- ============================================================
-- marts.review_topics_weekly — topic mention counts per week (rising/falling card)
-- ============================================================
CREATE TABLE IF NOT EXISTS marts.review_topics_weekly (
  restaurant_id              INT  NOT NULL REFERENCES dim.restaurant,
  week_start                 DATE NOT NULL,
  topic                      TEXT NOT NULL,
  mention_count              INT,
  mentions_per_100_reviews   NUMERIC(6,2),
  avg_rating_when_mentioned  NUMERIC(2,1),
  PRIMARY KEY (restaurant_id, week_start, topic)
);

-- ============================================================
-- marts.marketing_lag — IG/Reddit posts paired with subsequent busyness
-- ============================================================
CREATE TABLE IF NOT EXISTS marts.marketing_lag (
  post_id              TEXT PRIMARY KEY,
  posted_at            TIMESTAMPTZ,
  platform             TEXT,              -- 'instagram','reddit'
  engagement           INT,
  busyness_t_plus_24   SMALLINT,
  busyness_t_plus_48   SMALLINT,
  busyness_baseline    NUMERIC
);
CREATE INDEX IF NOT EXISTS marketing_lag_posted_at_idx ON marts.marketing_lag (posted_at);
