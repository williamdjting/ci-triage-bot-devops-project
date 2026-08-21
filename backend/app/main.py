"""FastAPI application for CI Failure Triage Bot."""

from pathlib import Path

from dotenv import load_dotenv

from fastapi import FastAPI, HTTPException

# Load .env from project root so OPENROUTER_API_KEY and OPENROUTER_MODEL are set
_env_path = Path(__file__).resolve().parent.parent.parent / ".env"
load_dotenv(_env_path)
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

from .schemas import AnalyzeRequest, AnalyzeResponse, CIProvider
from .llm import analyze_log

app = FastAPI(
    title="CI Failure Triage Bot",
    description="Paste CI logs, get structured failure analysis from an LLM.",
    version="1.0.0",
)

# Mount static files (single-page UI)
static_dir = Path(__file__).resolve().parent.parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


@app.get("/")
async def root():
    """Serve the single-page UI."""
    index_path = static_dir / "index.html"
    if index_path.exists():
        return FileResponse(index_path)
    return {"message": "CI Failure Triage Bot API. Open /static/index.html for the UI."}


@app.get("/healthz")
async def healthz():
    """Liveness/readiness probe.

    Deliberately does no I/O and does not touch the LLM provider: this answers
    "is the process up and serving?", not "is OpenRouter reachable?". Wiring an
    upstream dependency into a liveness probe makes Kubernetes restart healthy
    pods during someone else's outage.
    """
    return {"status": "ok"}


@app.post("/api/analyze", response_model=AnalyzeResponse)
async def analyze(request: AnalyzeRequest) -> AnalyzeResponse:
    """
    Analyze pasted CI log with an LLM and return structured triage result.
    """
    if not request.log_content or not request.log_content.strip():
        raise HTTPException(status_code=400, detail="Log content is required")
    try:
        return analyze_log(request)
    except ValueError as e:
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Analysis failed: {str(e)}",
        )
