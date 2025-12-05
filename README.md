# URL Shortener (FastAPI + React)

A tiny two-endpoint FastAPI backend with a lightweight React UI. The backend persists short codes in PostgreSQL and the frontend lets you create short links.

## Requirements

- Python 3.11+
- Node.js 18+
- PostgreSQL 14+

## Database setup

### One-time setup

**Install PostgreSQL:**

**macOS:**
```bash
brew install postgresql@14
brew services start postgresql@14
```

**Other platforms:** Download from [postgresql.org](https://www.postgresql.org/download/)

**Create the database:**
```bash
# Connect to PostgreSQL
psql postgres

# Create the database
CREATE DATABASE url_shortener;

# Exit psql
\q
```

**Configure database connection:**

Create a `.env` file in the `backend/` directory:

```bash
cd /Users/williamting/Desktop/url-devops-project/backend
cp ../.env.example .env
```

Edit `backend/.env` and set your `DATABASE_URL`:

```
DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/url_shortener
```

Replace `postgres:postgres` with your PostgreSQL username and password if different.

### Running the database

**macOS:**
```bash
brew services start postgresql@14
```

**Other platforms:** Start PostgreSQL using your system's service manager.

## Backend setup

### One-time setup

```bash
cd /Users/williamting/Desktop/url-devops-project/backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m app.init_db    # creates the short_urls table
```

### Running the backend

```bash
cd /Users/williamting/Desktop/url-devops-project/backend
source .venv/bin/activate
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### API quick reference

- `POST /shorten` → body `{ "url": "https://example.com", "custom_code": "alias"? }`
- `GET /{code}` → HTTP 307 redirect to the stored URL

## Frontend setup

### One-time setup

```bash
cd /Users/williamting/Desktop/url-devops-project/frontend
npm install
```

### Running the frontend

```bash
cd /Users/williamting/Desktop/url-devops-project/frontend
npm run dev
```

Set `VITE_API_BASE` in a `.env` file inside `frontend/` if the backend runs on a different host/port.

## Database schema

`backend/app/models.py` defines a single `short_urls` table containing `code`, `target_url`, and timestamps. Running `python -m app.init_db` will create the table in the configured database, so no additional migration tooling is required for this minimal app.
