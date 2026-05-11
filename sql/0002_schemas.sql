-- Migration 0002 — schemas.
-- Four logical layers; each can carry its own permissions later.

CREATE SCHEMA IF NOT EXISTS dim;       -- canonical lookup tables (date, hour, restaurant, ...)
CREATE SCHEMA IF NOT EXISTS raw;       -- as-scraped payloads, JSONB-rich
CREATE SCHEMA IF NOT EXISTS staging;   -- typed + deduped views over raw
CREATE SCHEMA IF NOT EXISTS marts;     -- analysis-ready flat tables consumed by notebooks
