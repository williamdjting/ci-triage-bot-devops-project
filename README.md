# CI Failure Triage Bot

A simple web app that triages CI failures using an LLM. Paste raw CI logs from **GitHub Actions** or **Jenkins**; the app does not run builds or connect to any CI system—logs are the source of truth.

## User flow

1. Open the UI in the browser.
2. Paste CI log output into the text box.
3. Optionally select the CI provider (GitHub Actions or Jenkins).
4. Click **Analyze**.
5. View the result on the same page.

## What you get

- **Failure classification** — test failure, lint failure, infra failure, config failure, or unknown.
- **Failing step** — where the failure likely occurred.
- **Key error line** — the most important error line from the log.
- **Explanation** — why the failure happened.
- **Suggested action** — next step for the developer.

## Setup

### 1. Backend (Python)

```bash
cd backend
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### 2. Environment

Copy `.env.example` to `.env` and set your OpenRouter API key:

```bash
cp .env.example .env
Edit .env and set OPENROUTER_API_KEY=sk-or-...
```

### 3. Run

```bash
cd backend
uvicorn app.main:app --reload
```

Open [http://127.0.0.1:8000](http://127.0.0.1:8000) in your browser.

### 4. Use the APP
- take the text from sample_jenkins.txt or sample_github_actions.txt and paste into the form field, the LLM will have a structured output
- please note you must spend $5 on OpenRouter api key credit to use this app, set it up in your .env file

## API

- **POST /api/analyze** — body: `{ "log_content": "...", "ci_provider": "github_actions" | "jenkins" | null }`. Returns the structured analysis (classification, failing_step, key_error_line, explanation, suggested_action).

## Tech

- **Backend:** FastAPI, OpenRouter API (structured output; supports many models).
- **Frontend:** Single HTML page (no build step).
- **Logs:** Treated as raw text; no regex-heavy parsing—the LLM extracts meaning from unstructured log output.
