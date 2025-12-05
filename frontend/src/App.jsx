import { useMemo, useState } from 'react'

const defaultApiBase = 'http://localhost:8000'

function App() {
  const apiBase = useMemo(() => import.meta.env.VITE_API_BASE ?? defaultApiBase, [])
  const [url, setUrl] = useState('')
  const [customCode, setCustomCode] = useState('')
  const [shortUrl, setShortUrl] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState('')

  const handleSubmit = async (event) => {
    event.preventDefault()
    setIsLoading(true)
    setError('')
    setShortUrl('')

    try {
      const response = await fetch(`${apiBase}/shorten`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url, custom_code: customCode || undefined }),
      })

      if (!response.ok) {
        const data = await response.json().catch(() => ({}))
        throw new Error(data.detail || 'Failed to shorten URL')
      }

      const payload = await response.json()
      setShortUrl(payload.short_url)
    } catch (err) {
      setError(err.message)
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <main className="app-shell">
      <section className="card">
        <h1>Simple URL Shortener</h1>
        <form onSubmit={handleSubmit}>
          <label>
            Long URL
            <input
              type="url"
              placeholder="https://example.com/very/long/link"
              value={url}
              onChange={(event) => setUrl(event.target.value)}
              required
            />
          </label>

          <label>
            Custom code (optional)
            <input
              type="text"
              placeholder="my-alias"
              value={customCode}
              onChange={(event) => setCustomCode(event.target.value)}
              minLength={4}
              maxLength={16}
            />
          </label>

          <button type="submit" disabled={isLoading}>
            {isLoading ? 'Working…' : 'Shorten'}
          </button>
        </form>

        {error && <p className="error">{error}</p>}
        {shortUrl && (
          <p className="result">
            Short link: <a href={shortUrl}>{shortUrl}</a>
          </p>
        )}
      </section>
    </main>
  )
}

export default App
