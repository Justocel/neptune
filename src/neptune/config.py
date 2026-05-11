"""Project-wide settings loaded from environment / `.env`.

Usage from anywhere in the codebase:

    from neptune.config import settings
    print(settings.postgres_host)
    print(settings.database_url)
"""

from __future__ import annotations

from urllib.parse import quote_plus

from pydantic import SecretStr, computed_field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",            # allow unknown env vars in .env without erroring
    )

    # --- Postgres -----------------------------------------------------------
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_user: str = "neptune"
    postgres_password: SecretStr
    postgres_db: str = "neptune"

    # --- External API keys (optional — None until we hit that source) -------
    bls_api_key: SecretStr | None = None
    census_api_key: SecretStr | None = None
    mbta_api_key: SecretStr | None = None
    reddit_client_id: SecretStr | None = None
    reddit_client_secret: SecretStr | None = None
    reddit_user_agent: str = "neptune-research-bot/0.1"
    google_maps_api_key: SecretStr | None = None
    instagram_username: str | None = None
    instagram_password: SecretStr | None = None

    @computed_field
    @property
    def database_url(self) -> str:
        """libpq-style URL for SQLAlchemy / alembic / log-friendly display.

        Password is URL-encoded so special chars (e.g. `/` from `openssl rand
        -base64`) don't break URI parsing. For psycopg connections prefer
        `psycopg_kwargs` below — no string parsing means no escaping bugs.
        """
        user = quote_plus(self.postgres_user)
        pw = quote_plus(self.postgres_password.get_secret_value())
        return f"postgresql://{user}:{pw}@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"

    @property
    def psycopg_kwargs(self) -> dict[str, str | int]:
        """Kwargs accepted by `psycopg.connect()` / `ConnectionPool(kwargs=...)`.

        Not a computed_field on purpose — we don't want the password leaking
        into pydantic's serialization output.
        """
        return {
            "host": self.postgres_host,
            "port": self.postgres_port,
            "user": self.postgres_user,
            "password": self.postgres_password.get_secret_value(),
            "dbname": self.postgres_db,
        }


# A single shared instance. Importing this is cheap; instantiating again would
# re-parse `.env`, so prefer `from neptune.config import settings`.
settings = Settings()  # type: ignore[call-arg]
