# Neptune Oyster — Data-to-Decisions Project Plan

A didactic data project: scrape, store, and analyze every free signal we can pull about **Neptune Oyster** (63 Salem St, North End, Boston), then turn it into four concrete business decisions: staffing/hours, pricing, marketing timing, and ops fixes.

**Scope:** historical-data demo. Forward-collection only kicks in after demo validates the approach.

---

## 1. Project layout & environment

```
neptune/
├── pyproject.toml
├── .env.example
├── docker-compose.yml          # postgres:16 + postgis
├── sql/
│   ├── 0001_extensions.sql
│   ├── 0002_schemas.sql
│   ├── 0003_dim.sql
│   ├── 0004_raw.sql
│   ├── 0005_staging.sql
│   └── 0006_marts.sql
├── src/neptune/
│   ├── config.py
│   ├── db.py                   # psycopg3 pool
│   ├── scrapers/               # one module per source
│   ├── etl/
│   ├── models/
│   ├── stats/                  # hypothesis tests
│   └── viz/
├── notebooks/                  # one per output card + demo summary
└── tests/
```

### uv setup (WSL)

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv init neptune && cd neptune
uv add psycopg[binary,pool] sqlalchemy alembic
uv add pandas numpy scipy statsmodels scikit-learn
uv add httpx requests beautifulsoup4 playwright lxml
uv add praw instaloader populartimes
uv add matplotlib seaborn plotly folium
uv add python-dotenv pydantic-settings rich tenacity
uv add jupyter ipykernel
uv run playwright install chromium
```

### Postgres locally

`docker-compose.yml` runs `postgres:16` with the `postgis/postgis:16-3.4` image, persistent volume, port 5432. `.env` holds the conninfo. `src/neptune/db.py` builds a single `psycopg_pool.ConnectionPool` reused across all scrapers and ETL jobs.

---

## 2. Postgres schema

Four logical schemas: `dim` (canonical lookups), `raw` (as-collected, JSONB-rich), `staging` (typed + deduped), `marts` (analysis-ready, flat tables — what notebooks query).

### 2.1 Extensions

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS dim;
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS marts;
```

### 2.2 Dimensions

```sql
CREATE TABLE dim.date (
  date_id           DATE PRIMARY KEY,
  year              SMALLINT,
  month             SMALLINT,
  day               SMALLINT,
  dow               SMALLINT,          -- 0=Mon, 6=Sun
  is_weekend        BOOLEAN,
  is_us_holiday     BOOLEAN,
  holiday_name      TEXT,
  is_feast_day      BOOLEAN,           -- North End: St. Anthony, Fisherman, etc.
  is_school_term    BOOLEAN,           -- BU/BC/Harvard/MIT/Northeastern in session
  tourist_season    TEXT               -- 'peak','shoulder','off'
);

CREATE TABLE dim.hour (
  hour_id           SMALLINT PRIMARY KEY,  -- 0–23
  is_lunch          BOOLEAN,               -- 11–14
  is_dinner         BOOLEAN,               -- 17–22
  is_late_night     BOOLEAN                -- 22–24
);

CREATE TABLE dim.restaurant (
  restaurant_id     SERIAL PRIMARY KEY,
  name              TEXT NOT NULL,
  address           TEXT,
  neighborhood      TEXT,
  geog              GEOGRAPHY(POINT, 4326),
  category          TEXT,                  -- 'seafood','italian','bar',...
  is_subject        BOOLEAN DEFAULT FALSE  -- TRUE only for Neptune
);

CREATE TABLE dim.menu_item (
  item_id           SERIAL PRIMARY KEY,
  canonical_name    TEXT NOT NULL,         -- 'lobster_roll','wellfleet_oyster'
  category          TEXT,                  -- 'oyster','sandwich','crudo',...
  origin            TEXT                   -- 'cape_cod','prince_edward',...
);

CREATE TABLE dim.review_topic (
  topic_id          SERIAL PRIMARY KEY,
  topic             TEXT UNIQUE,           -- 'wait_time','service','bread','noise',...
  is_positive_default BOOLEAN
);
```

### 2.3 Raw layer — selected tables

(Full DDL in `sql/0004_raw.sql`. The pattern: store the as-scraped payload in `raw JSONB`, plus indexable fields for fast filtering.)

```sql
-- Reviews from all vendors (Yelp/Google/TripAdvisor)
CREATE TABLE raw.reviews (
  review_id                TEXT PRIMARY KEY,      -- vendor + vendor_review_id
  vendor                   TEXT NOT NULL,
  restaurant_id            INT REFERENCES dim.restaurant,
  posted_at                TIMESTAMPTZ,
  rating                   NUMERIC(2,1),
  body                     TEXT,
  reviewer_id              TEXT,
  reviewer_total_reviews   INT,                   -- tourist/local proxy
  reviewer_boston_reviews  INT,
  reviewer_home_city       TEXT,
  raw                      JSONB,
  ingested_at              TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX ON raw.reviews (restaurant_id, posted_at);
CREATE INDEX ON raw.reviews USING GIN (raw);

-- Menu snapshots (one row per item per snapshot per restaurant)
CREATE TABLE raw.menu_snapshot (
  snapshot_id    BIGSERIAL PRIMARY KEY,
  restaurant_id  INT REFERENCES dim.restaurant,
  captured_at    DATE NOT NULL,
  raw_name       TEXT,
  item_id        INT REFERENCES dim.menu_item,
  description    TEXT,
  price          NUMERIC(7,2),
  source_url     TEXT,
  raw            JSONB,
  UNIQUE (restaurant_id, captured_at, raw_name)
);
CREATE INDEX ON raw.menu_snapshot (restaurant_id, captured_at);

-- Geospatial: Boston 311 complaints
CREATE TABLE raw.boston_311 (
  case_id      TEXT PRIMARY KEY,
  opened_at    TIMESTAMPTZ,
  closed_at    TIMESTAMPTZ,
  category     TEXT,
  subject      TEXT,
  neighborhood TEXT,
  geog         GEOGRAPHY(POINT, 4326),
  raw          JSONB
);
CREATE INDEX ON raw.boston_311 USING GIST (geog);
CREATE INDEX ON raw.boston_311 (opened_at);
```

Other raw tables follow the same JSONB + indexable-fields pattern: `raw.weather_obs`, `raw.sports_events`, `raw.popular_times`, `raw.reddit_mentions`, `raw.instagram_posts`, `raw.bluebike_trips`, `raw.boston_inspections`, `raw.boston_permits`, `raw.boston_liquor_licenses`, `raw.mbta_ridership`, `raw.massport_cruise`, `raw.noaa_landings`, `raw.bls_cpi`, `raw.census_acs`, `raw.osm_pois`.

### 2.4 Marts — what notebooks actually query

```sql
-- The spine: hourly busyness with all regressors
CREATE TABLE marts.demand_hourly (
  restaurant_id         INT REFERENCES dim.restaurant,
  ts                    TIMESTAMPTZ,
  dow                   SMALLINT,
  hour                  SMALLINT,
  busyness              SMALLINT,        -- 0–100 (Google typical-week) or modeled
  busyness_source       TEXT,
  temp_c                NUMERIC,
  precip_mm             NUMERIC,
  wind_mps              NUMERIC,
  is_rain               BOOLEAN,
  is_snow               BOOLEAN,
  bruins_home_today     BOOLEAN,
  celtics_home_today    BOOLEAN,
  bruins_playoff        BOOLEAN,
  cruise_ship_count     SMALLINT,
  is_feast_day          BOOLEAN,
  is_us_holiday         BOOLEAN,
  is_school_term        BOOLEAN,
  bluebike_trips_300m   INT,
  mbta_taps_haymarket   INT,
  PRIMARY KEY (restaurant_id, ts)
);

-- Daily price tracking + market position
CREATE TABLE marts.price_daily (
  restaurant_id     INT REFERENCES dim.restaurant,
  item_id           INT REFERENCES dim.menu_item,
  date              DATE,
  price             NUMERIC(7,2),
  peer_median       NUMERIC(7,2),
  market_zscore     NUMERIC(6,3),
  rank_among_peers  SMALLINT,
  PRIMARY KEY (restaurant_id, item_id, date)
);

-- Review topics over time
CREATE TABLE marts.review_topics_weekly (
  restaurant_id              INT,
  week_start                 DATE,
  topic                      TEXT,
  mention_count              INT,
  mentions_per_100_reviews   NUMERIC(6,2),
  avg_rating_when_mentioned  NUMERIC(2,1),
  PRIMARY KEY (restaurant_id, week_start, topic)
);

-- Marketing lag effects
CREATE TABLE marts.marketing_lag (
  post_id              TEXT PRIMARY KEY,
  posted_at            TIMESTAMPTZ,
  platform             TEXT,
  engagement           INT,
  busyness_t_plus_24   SMALLINT,
  busyness_t_plus_48   SMALLINT,
  busyness_baseline    NUMERIC
);
```

---

## 3. Data-source matrix

(Backfill = horizon for the historical pull. "Snapshot" = we capture current state; historical reconstruction not free.)

| Source | Method | Endpoint / Library | Auth | Backfill | → Table | Notes |
|---|---|---|---|---|---|---|
| **Open-Meteo (weather)** | HTTP | `archive-api.open-meteo.com` | none | 3y hourly | `raw.weather_obs` | Logan Airport coords |
| **NHL (Bruins)** | HTTP | `api-web.nhle.com` | none | 3y | `raw.sports_events` | home games + attendance |
| **NBA (Celtics)** | HTTP | `nba_api` lib | none | 3y | `raw.sports_events` | undocumented; polite delay |
| **Yelp reviews** | Playwright | `yelp.com/biz/neptune-oyster-boston` | none | all-time | `raw.reviews` | infinite-scroll; ~5K reviews |
| **Google reviews** | Playwright | Google Maps Place page | none | all-time | `raw.reviews` | grab reviewer profile → tourist/local |
| **TripAdvisor** | Playwright | restaurant page | none | all-time | `raw.reviews` | "From: city" field is the tourist proxy |
| **Reddit mentions** | `praw` | `r/boston`, `r/foodboston` | OAuth (free) | all-time search | `raw.reddit_mentions` | search `neptune oyster` |
| **Instagram** | `instaloader` | `@neptuneoyster` + hashtag | optional login | all posts | `raw.instagram_posts` | rate-limit aggressively, cache |
| **Google popular times** | `populartimes` lib | Place ID | API key (free quota) | snapshot only | `raw.popular_times` | **no per-date history** — see Gaps |
| **Menu — Neptune** | scrape | `neptuneoyster.com/menus` | none | snapshot + Wayback | `raw.menu_snapshot` | Wayback gives ~quarterly snapshots back to 2010 |
| **Menu — competitors** | scrape | Island Creek · Row 34 · B&G · Eventide · Saltie Girl | none | snapshot + Wayback | `raw.menu_snapshot` | one Playwright script per site |
| **NOAA Fisheries landings** | HTTP API | `foss.nmfs.noaa.gov/apexfoss` | none | monthly 5y | `raw.noaa_landings` | oyster/lobster wholesale context |
| **BLS CPI** | HTTP API | `api.bls.gov/publicAPI/v2` | free key | monthly 3y | `raw.bls_cpi` | "Food away from home" series |
| **Boston 311** | CKAN API | `data.boston.gov` | none | 3y | `raw.boston_311` | filter to North End geo |
| **Boston food inspections** | CKAN | `data.boston.gov` | none | 3y | `raw.boston_inspections` | competitor weakness signal |
| **Boston permits** | CKAN | `data.boston.gov` | none | 3y | `raw.boston_permits` | construction noise nearby |
| **Bluebike trips** | S3 CSVs | `s3.amazonaws.com/hubway-data` | none | 3y monthly | `raw.bluebike_trips` | filter to North End stations |
| **Boston liquor licenses** | CKAN | `data.boston.gov` | none | snapshot | `raw.boston_liquor_licenses` | competitor map |
| **MassGIS layers** | shapefile | `mass.gov` | none | one-shot | direct PostGIS load | parcels, sidewalks, MBTA, flood |
| **MBTA-Performance** | V3 API | `api-v3.mbta.com` | free key | ≤30d history | `raw.mbta_ridership` | recent context only |
| **Massport cruise** | scrape | `massport.com/.../cruise-schedule` | none | current + Wayback | `raw.massport_cruise` | |
| **Census ACS** | API | `api.census.gov` | free key | latest 5y release | `raw.census_acs` | North End block groups |
| **OSM Overpass** | API | `overpass-api.de/api/interpreter` | none | one-shot | `raw.osm_pois` | competitors/hotels/bars within 300m |
| **Wayback Machine** | CDX API | `web.archive.org/cdx/search` | none | full history | menu_snapshot backfill | critical for historical menus |

### Honest gaps

- **Hourly historical foot traffic.** Google Popular Times returns the *typical* week, not a per-date history. SafeGraph / Placer.ai have it, paid. For the demo: use the typical-week pattern as base curve, let weather/events explain deviations, and add Bluebike + MBTA as foot-traffic proxies. Timestamped "wait time" mentions in reviews give a weak ground-truth signal.
- **Instagram.** IG rate-limits scrapers aggressively. Plan 2–3 days of staggered fetches with backoff.
- **Yelp / Google ToS.** Personal-use scraping is gray-zone. For a class project: didactic use only, no redistribution, polite delays, low concurrency, cache so we only fetch once. Respect robots.txt where it exists.

---

## 4. Hypothesis tests — mapped to each output card

Each test states H0, the statistic, and the data slice. All via `scipy.stats` + `statsmodels`. Benjamini–Hochberg correction applied *within each card's family* to control FDR.

### Card 1 — Hours & Staffing

| # | H0 | Test | Data slice |
|---|---|---|---|
| 1.1 | Rainy Saturdays at 7–9pm have same busyness as dry Saturdays at 7–9pm | Welch's t-test | `marts.demand_hourly` filtered |
| 1.2 | Hourly busyness distribution on Bruins-home weeknights = non-Bruins weeknights | Kolmogorov–Smirnov | demand_hourly × sports_events |
| 1.3 | Day-of-week and weather are independent factors on busyness | Two-way ANOVA | demand_hourly |
| 1.4 | SARIMAX with weather + event regressors does no better than seasonal-naive baseline | Diebold–Mariano | demand_hourly train/test split |

**Model:** SARIMAX hourly with weekly seasonality (s=168), exogenous regressors = `temp_c, precip_mm, wind_mps, bruins_home_today, celtics_home_today, cruise_ship_count, is_feast_day, is_us_holiday`.

### Card 2 — Pricing

| # | H0 | Test | Data slice |
|---|---|---|---|
| 2.1 | Neptune's lobster roll price equals Boston seafood peer median | One-sample t-test | `marts.price_daily` |
| 2.2 | Cape Cod oysters priced same as non-Cape varieties | Two-sample t-test | price_daily × dim.menu_item.origin |
| 2.3 | Weekly avg oyster prices are white noise | Ljung–Box | price_daily aggregated |
| 2.4 | NOAA landings (lagged 2–4 weeks) do not predict menu price | Granger causality | landings × price |

### Card 3 — Marketing timing

| # | H0 | Test | Data slice |
|---|---|---|---|
| 3.1 | Instagram posts do not Granger-cause next-48h busyness | Granger, lags 12/24/48h | instagram_posts × demand_hourly |
| 3.2 | Tourist reviewers (1 Boston review) and locals (≥3) give same rating distribution | Mann–Whitney U | raw.reviews |
| 3.3 | Weekend IG posts have same engagement as weekday posts | Two-sample t-test (or MWU if non-normal) | raw.instagram_posts |
| 3.4 | Reddit mentions don't correlate with next-week busyness | Spearman cross-correlation | weekly aggregates |

### Card 4 — Ops fixes

| # | H0 | Test | Data slice |
|---|---|---|---|
| 4.1 | "Wait time" mention frequency in 4★ = 5★ reviews | Chi-square (Fisher exact if small) | review_topics_weekly |
| 4.2 | Avg sentiment unchanged after feast weekends | Paired t-test | reviews × dim.date.is_feast_day |
| 4.3 | Keywords in 1–2★ appear at same rate in 4–5★ | Per-topic frequency comparison + BH | reviews tokenized |
| 4.4 | Owner response rate has no effect on next-30d avg score | Lagged Pearson | reviews with response timestamps |

**Topic extraction:** start with KeyBERT for candidate keywords, hand-curate a ~20-topic taxonomy, train a simple multilabel classifier on ~2,000 hand-labeled reviews. Sufficient for a demo.

---

## 5. Demo deliverables

1. **The I/O diagram** (already done; export to PNG for slides).
2. **Hourly demand forecast** — interactive Plotly, next 7 days, weather + sports schedule as swappable scenarios ("rain Saturday + Bruins home" button).
3. **Pricing benchmark dashboard** — Neptune's lobster roll and top-5 oyster varieties vs. 5 peers over time, with z-score band.
4. **Review topic delta board** — top 5 rising + falling topics, last 30 days vs. trailing-12-month baseline; drill-down into example reviews.
5. **Geospatial context map** — Folium, 300m around 63 Salem St, layers: competitors (size = review count), 311 complaints (color = category), Bluebike stations (size = trip volume), construction permits.
6. **Hypothesis-test summary table** — one page, ~15 rows: H0, statistic, p-value, effect size (Cohen's d / Cliff's δ / r), decision, business interpretation. The rigor proof.

---

## 6. Sequencing (6 working weeks, solo)

| Wk | Focus | Key artifacts |
|---|---|---|
| 1 | Env + Postgres + dims + warmup scrapes (weather, sports) | `sql/` applied, weather + sports tables full |
| 2 | Review scraping (Yelp, Google, TripAdvisor, Reddit, IG) | `raw.reviews`, `raw.reddit_mentions`, `raw.instagram_posts` populated |
| 3 | Menu scraping + government/geo data | `raw.menu_snapshot`, Boston 311/permits/Bluebike, Census, OSM |
| 4 | ETL raw → staging → marts | All `marts.*` tables built |
| 5 | Modeling + hypothesis tests | SARIMAX trained, 15 tests run with BH correction |
| 6 | Viz + demo polish | Notebook 99 *is* the demo deck |

---

## 7. Risks & honest limitations

- No per-date historical busyness without paid data. Mitigations described above.
- Yelp/Google scraping is fragile; expect outsized time on selectors and rate-limit avoidance.
- Topic classification is the hardest qualitative step. Fallback: keyword search only if time runs short.
- Multiple-comparison correction is mandatory — 15 tests will produce ~1 false discovery without it.
- Most tests prove **association**, not causation. Avoid overclaiming in the narrative.

---

**Next concrete step:** write `sql/0001_extensions.sql` through `sql/0006_marts.sql` as ready-to-run migrations.