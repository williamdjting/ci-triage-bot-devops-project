from sqlalchemy.orm import Session

from . import schemas
from .models import ShortURL


def get_by_code(db: Session, code: str) -> ShortURL | None:
    return db.query(ShortURL).filter(ShortURL.code == code).first()


def get_by_target(db: Session, target_url: str) -> ShortURL | None:
    return db.query(ShortURL).filter(ShortURL.target_url == target_url).first()


def create_short_url(db: Session, *, code: str, target_url: str) -> ShortURL:
    short = ShortURL(code=code, target_url=target_url)
    db.add(short)
    db.commit()
    db.refresh(short)
    return short
