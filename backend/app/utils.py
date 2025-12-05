import secrets
import string

from sqlalchemy.orm import Session

from .models import ShortURL

ALPHABET = string.ascii_letters + string.digits


def generate_code(length: int = 6) -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(length))


def is_code_available(db: Session, code: str) -> bool:
    return not db.query(ShortURL).filter(ShortURL.code == code).first()
