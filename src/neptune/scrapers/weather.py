"""Open-Meteo historical-weather scraper for Boston Logan (KBOS).

Run as a module:

    uv run python -m neptune.scrapers.weather                     # default range
    uv run python -m neptune.scrapers.weather \\
        --start 2024-01-01 --end 2024-01-31                       # explicit range

Writes hourly observations to `raw.weather_obs` with an upsert,
so re-runs are idempotent.
"""

from __future__ import annotations

import argparse
import json
import logging
from collections.abc import Iterator
from datetime import date, timedelta

import httpx
from rich.logging import RichHandler
from tenacity import retry, stop_after_attempt, wait_exponential

from neptune.db import get_conn

# --- constants ---------------------------------------------------------------

OPEN_METEO_ARCHIVE = "https://archive-api.open-meteo.com/v1/archive"
LOGAN_LAT = 42.3656
LOGAN_LON = -71.0096
LOCATION_NAME = "logan_airport"

HOURLY_VARS = [
    "temperature_2m",
    "precipitation",
    "rain",
    "snowfall",
    "wind_speed_10m",
    "wind_direction_10m",
    "cloud_cover",
    "weather_code",
]

# We chunk the date range so a single HTTP failure doesn't lose all of history.
CHUNK_DAYS = 365

logger = logging.getLogger("neptune.weather")


# --- HTTP --------------------------------------------------------------------

@retry(
    stop=stop_after_attempt(4),
    wait=wait_exponential(multiplier=1, min=2, max=30),
    reraise=True,
)
def fetch_window(start: date, end: date) -> dict:
    """One HTTP GET to Open-Meteo for the inclusive date range [start, end]."""
    params = {
        "latitude": LOGAN_LAT,
        "longitude": LOGAN_LON,
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "hourly": ",".join(HOURLY_VARS),
        "wind_speed_unit": "ms",
        "timezone": "America/New_York",
    }
    logger.info(f"GET archive  [bold]{start.isoformat()} → {end.isoformat()}[/bold]")
    with httpx.Client(timeout=120) as client:
        resp = client.get(OPEN_METEO_ARCHIVE, params=params)
        resp.raise_for_status()
        return resp.json()


# --- transform ---------------------------------------------------------------

def to_rows(payload: dict) -> list[tuple]:
    """Pivot Open-Meteo's parallel arrays into one tuple per hour, ready for upsert."""
    h = payload["hourly"]
    times = h["time"]
    rows: list[tuple] = []
    for i, ts in enumerate(times):
        rows.append(
            (
                LOCATION_NAME,
                ts,                                           # ISO 8601 str → psycopg → TIMESTAMPTZ
                h["temperature_2m"][i],
                h["precipitation"][i],
                h["wind_speed_10m"][i],
                _to_int(h["wind_direction_10m"][i]),
                _to_int(h["cloud_cover"][i]),
                _gt_zero(h["rain"][i]),
                _gt_zero(h["snowfall"][i]),
                json.dumps(
                    {
                        "weather_code": h["weather_code"][i],
                        "rain_mm": h["rain"][i],
                        "snowfall_cm": h["snowfall"][i],
                    }
                ),
            )
        )
    return rows


def _to_int(v: float | int | None) -> int | None:
    return None if v is None else int(v)


def _gt_zero(v: float | int | None) -> bool | None:
    return None if v is None else (v > 0)


# --- write -------------------------------------------------------------------

UPSERT_SQL = """
INSERT INTO raw.weather_obs
  (location, ts, temp_c, precip_mm, wind_mps, wind_dir_deg, cloud_cover_pct,
   is_rain, is_snow, raw)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb)
ON CONFLICT (location, ts) DO UPDATE SET
  temp_c          = EXCLUDED.temp_c,
  precip_mm       = EXCLUDED.precip_mm,
  wind_mps        = EXCLUDED.wind_mps,
  wind_dir_deg    = EXCLUDED.wind_dir_deg,
  cloud_cover_pct = EXCLUDED.cloud_cover_pct,
  is_rain         = EXCLUDED.is_rain,
  is_snow         = EXCLUDED.is_snow,
  raw             = EXCLUDED.raw,
  ingested_at     = NOW()
"""


def upsert(rows: list[tuple]) -> int:
    with get_conn() as conn, conn.cursor() as cur:
        cur.executemany(UPSERT_SQL, rows)
        conn.commit()
    return len(rows)


# --- main loop ---------------------------------------------------------------

def chunk_dates(start: date, end: date, chunk_days: int) -> Iterator[tuple[date, date]]:
    cur = start
    while cur <= end:
        nxt = min(cur + timedelta(days=chunk_days - 1), end)
        yield cur, nxt
        cur = nxt + timedelta(days=1)


def run(start: date, end: date) -> None:
    total = 0
    for w_start, w_end in chunk_dates(start, end, CHUNK_DAYS):
        payload = fetch_window(w_start, w_end)
        rows = to_rows(payload)
        n = upsert(rows)
        total += n
        logger.info(f"upserted [green]{n:6d}[/green] rows  cumulative=[bold]{total}[/bold]")
    logger.info(f"[bold green]DONE[/bold green] — {total} hourly rows in raw.weather_obs")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    today = date.today()
    p.add_argument(
        "--start",
        type=date.fromisoformat,
        default=today - timedelta(days=365 * 3),
        help="ISO date, inclusive (default: 3 years ago)",
    )
    p.add_argument(
        "--end",
        type=date.fromisoformat,
        default=today - timedelta(days=1),
        help="ISO date, inclusive (default: yesterday)",
    )
    return p.parse_args()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(message)s",
        handlers=[RichHandler(show_path=False, show_time=False, markup=True)],
    )
    args = parse_args()
    run(args.start, args.end)
