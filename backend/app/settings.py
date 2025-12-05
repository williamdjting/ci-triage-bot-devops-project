from functools import lru_cache

from pydantic import AnyHttpUrl, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings sourced from env vars or .env file."""

    model_config = SettingsConfigDict(env_file=".env", env_prefix="URLS_", case_sensitive=False)

    app_name: str = "URL Shortener"
    database_url: str = Field(
        default="postgresql+psycopg://postgres:postgres@localhost:5432/url_shortener",
        validation_alias="DATABASE_URL",
    )
    base_url: AnyHttpUrl = Field(default="http://localhost:8000", validation_alias="BASE_URL")
    code_length: int = Field(default=6, ge=4, le=16)


@lru_cache
def get_settings() -> Settings:
    return Settings()
