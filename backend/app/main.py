from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from . import crud, schemas, utils
from .database import get_db
from .settings import get_settings

settings = get_settings()
app = FastAPI(title=settings.app_name)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"] ,
    allow_headers=["*"],
)


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/shorten", response_model=schemas.ShortenResponse)
def shorten_url(payload: schemas.ShortenRequest, db: Session = Depends(get_db)):
    desired_code = payload.custom_code
    if desired_code:
        if not utils.is_code_available(db, desired_code):
            raise HTTPException(status_code=400, detail="Custom code already in use")
        code = desired_code
    else:
        code = utils.generate_code(settings.code_length)
        while not utils.is_code_available(db, code):
            code = utils.generate_code(settings.code_length)

    existing = crud.get_by_target(db, str(payload.url))
    if existing:
        short = existing
    else:
        short = crud.create_short_url(db=db, code=code, target_url=str(payload.url))

    short_url = f"{settings.base_url.rstrip('/')}/{short.code}"
    return schemas.ShortenResponse(code=short.code, short_url=short_url, created_at=short.created_at)


@app.get("/{code}")
def redirect(code: str, db: Session = Depends(get_db)):
    record = crud.get_by_code(db, code)
    if not record:
        raise HTTPException(status_code=404, detail="Code not found")
    return RedirectResponse(record.target_url)
