-- Migration 0001 — Postgres extensions.
-- Idempotent: safe to re-run.

CREATE EXTENSION IF NOT EXISTS postgis;   -- geography/geometry types + GIST spatial indexes
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- trigram indexes for fuzzy text matching (review topics)
