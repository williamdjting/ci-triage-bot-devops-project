# syntax=docker/dockerfile:1

# ---- Stage 1: builder -------------------------------------------------------
# Dependencies are compiled into a self-contained virtualenv here so the runtime
# image never needs pip, build tools, or the wheel cache.
FROM python:3.12-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copied alone so this layer is cached until requirements.txt actually changes.
COPY requirements.txt .
RUN pip install -r requirements.txt


# ---- Stage 2: runtime -------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Non-root: the Kubernetes manifests later pin runAsUser to this same uid.
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=app:app app/ ./app/
COPY --chown=app:app static/ ./static/

USER app
EXPOSE 8000

# Probed by Docker locally; Kubernetes uses its own httpGet probes instead.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
