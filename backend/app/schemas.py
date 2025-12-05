from datetime import datetime

from pydantic import AnyHttpUrl, BaseModel, Field


class ShortenRequest(BaseModel):
    url: AnyHttpUrl = Field(..., description="The destination URL to shorten")
    custom_code: str | None = Field(default=None, min_length=4, max_length=16)


class ShortenResponse(BaseModel):
    code: str
    short_url: AnyHttpUrl
    created_at: datetime


class ShortURLRecord(BaseModel):
    id: int
    code: str
    target_url: AnyHttpUrl
    created_at: datetime

    class Config:
        from_attributes = True
