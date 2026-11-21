# AskTube — a RAG chatbot for YouTube videos

Paste a YouTube link, then ask questions about it. The video's own transcript is
split into timestamped chunks, embedded, and searched, so every answer is
grounded in what was actually said — and every claim links back to the exact
moment it came from.

![stack](https://img.shields.io/badge/FastAPI-009688?logo=fastapi&logoColor=white)
![stack](https://img.shields.io/badge/OpenAI-412991?logo=openai&logoColor=white)
![stack](https://img.shields.io/badge/FAISS-3B4B8B?logo=github&logoColor=white)

---

## How it works

```
  YouTube URL
      │
      ▼
  extract_video_id ─────────────► watch?v=…, youtu.be/…, /shorts/…, /embed/…, or a bare id
      │
      ▼
  fetch_transcript ────────────► youtube-transcript-api, manual captions preferred
      │                          (oEmbed supplies title / channel / thumbnail)
      ▼
  build_chunks ────────────────► ~1200-char windows, 200-char overlap, timestamps kept
      │
      ▼
  embed_texts ─────────────────► OpenAI text-embedding-3-small, L2-normalised
      │
      ▼
  FAISS IndexFlatIP ───────────► inner product == cosine similarity
      │
      ▼  user question → same embedding → top-k
  search ──────────────────────► chunks above the similarity threshold
      │
      ▼
  generate_answer ─────────────► GPT answers using ONLY those chunks, citing [1] [2]
      │
      ▼
  answer + clickable timestamped sources
```

## Project layout

```
run.bat             One-click launcher (double-click)
run.ps1             Same, for PowerShell - with extra checks
backend/
  main.py           FastAPI app: routes, error handling, static file serving
  rag_utils.py      The RAG engine (transcript → chunks → vectors → answer)
  config.py         All settings, every one overridable from .env
  static/
    index.html      Page structure
    style.css       Design system, responsive layout
    app.js          Fetch calls + markdown/citation renderer (no build step)
  test_pipeline.py  End-to-end test, runs without an OpenAI key
  requirements.txt
  .env.example      Copy to .env and add your key
```

## Setup

**1. Install dependencies** (a virtualenv is already in `venv/`):

```powershell
.\venv\Scripts\python.exe -m pip install -r backend\requirements.txt
```

**2. Add your OpenAI key:**

```powershell
copy backend\.env.example backend\.env
```

Then open `backend/.env` and set `OPENAI_API_KEY=sk-...` (get one at
<https://platform.openai.com/api-keys>).

**3. Start it — double-click `run.bat`**

That's it. It checks the virtualenv, verifies the dependencies, warns you if
the API key is still a placeholder, confirms the port is free, starts uvicorn
with hot reload, and opens your browser at <http://localhost:8000>. Press
`Ctrl+C` in that window to stop.

Prefer PowerShell, or want a different port?

```powershell
.\run.ps1                # http://localhost:8000
.\run.ps1 -Port 8080     # http://localhost:8080
.\run.ps1 -NoBrowser     # don't open a browser
```

<details>
<summary>Prefer to run uvicorn yourself?</summary>

```powershell
cd backend
..\venv\Scripts\python.exe -m uvicorn main:app --reload --port 8000
```

</details>

Paste a link with captions into the box on the left. The first video takes a few
seconds (transcript + embeddings); later ones are instant, because the FAISS
index is cached to `backend/.cache/`.

## Tests

Both suites run **without** an API key — the OpenAI calls are replaced with
deterministic local fakes, so the real code paths are still exercised.

```powershell
# Python: parsing, transcript, chunking, FAISS, retrieval, HTTP
cd backend
..\venv\Scripts\python.exe test_pipeline.py

# Frontend: 33 checks across escaping/XSS, markdown, citation chips
cd backend\static
node test_render.js
```

The Python suite needs YouTube for its transcript sections. If YouTube is
rate-limiting your IP, those sections **skip** rather than fail — you'll see
`N passed, 0 failed, 1 skipped`, which still exits `0`.

## HTTP API

| Method | Path                 | Body / query                        | Returns |
|--------|----------------------|-------------------------------------|---------|
| `GET`  | `/`                  | —                                   | The single-page UI |
| `GET`  | `/api/health`        | —                                   | Status, model names, whether a key is configured |
| `POST` | `/api/video`         | `{"url": "..."}`                    | `{ video: {...}, suggestions: [...] }` |
| `POST` | `/api/video/sample`  | —                                   | The same, for the bundled sample transcript |
| `POST` | `/api/video/transcript` | `{"url": "...", "transcript": "..."}` | Index a transcript you pasted. Works with no network. |
| `GET`  | `/api/video/{id}`    | —                                   | Same, for a video already indexed (`"cached": true`) |
| `POST` | `/api/ask`           | `{"video_id": "...", "question": "..."}` | `{ answer, sources[], retrieved }` |

Interactive docs are at <http://localhost:8000/docs>.

Errors come back as `{"error": "...", "code": "..."}`. The `code` is stable and
the UI switches on it: `youtube_blocked` opens the paste-a-transcript box,
`no_transcript` means the video has nothing to read, `invalid_video_id` means
the link was not a YouTube one.

Each entry in `sources` carries the chunk text, its similarity score, a
formatted timestamp, and a `watch_url` that deep-links to that second of the
video.

## Configuration

Everything lives in `backend/.env`; see `.env.example` for the full list.

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENAI_API_KEY` | — | Optional. Without it the app runs in local mode (hashing embeddings + extractive answers); with it, OpenAI writes the answers. |
| `LLM_MODEL` | `gpt-4o-mini` | Chat model that writes the answer. |
| `EMBEDDING_MODEL` | `text-embedding-3-small` | Embedding model. Changing it invalidates the cache. |
| `TOP_K` | `5` | Chunks retrieved per question. |
| `SIMILARITY_THRESHOLD` | `0.25` | Minimum cosine score, tuned for OpenAI embeddings. Local mode filters at a lower floor, because a hashing vectoriser's scores run lower. |
| `CHUNK_SIZE` | `1200` | Characters per chunk. Smaller = more precise retrieval, more embeddings. |
| `CHUNK_OVERLAP` | `200` | Overlap between chunks so split sentences stay retrievable. |
| `MAX_TRANSCRIPT_CHARS` | `240000` | Cost guard for long videos. |
| `YOUTUBE_PROXY` | — | Proxy for **YouTube traffic only**. The fix for an IP block. |

## Design notes

**The model is told to refuse.** The system prompt restricts it to the retrieved
chunks and requires inline `[n]` citations. When retrieval returns nothing above
the threshold, the answer says so rather than filling the gap — the usual
failure mode of a chatbot that has nothing to ground itself in.

**Timestamps survive the whole pipeline.** Chunks keep their start/end times, so
citations resolve to real `?t=` deep links instead of being decorative.

**Indexing is cached twice.** On disk (`backend/.cache/`, so a restart is free)
and in memory (an LRU of the last few videos). A per-video lock means two
simultaneous requests for the same video build the index once, not twice.

**Answers are escaped before formatting.** `app.js` HTML-escapes the model's
output and then layers on bold/italic/lists — so model output can only ever
produce an allowlisted set of tags. There is no path from a transcript (or an
injected instruction inside one) to executing script.

**Videos with no captions are rejected up front,** with a message explaining
why, rather than a confusing empty answer.

## Troubleshooting

**"OPENAI_API_KEY is not set"** — the key is missing or still the placeholder.
Set it in `backend/.env` and restart; the status pill in the header turns green
when it's picked up.

**"This video has captions turned off"** — some videos genuinely have no
transcript. Try a video with manual or auto-generated captions.

**"Cannot reach the backend"** — the server isn't running. Double-click
`run.bat`, or start it with `uvicorn main:app --reload` from `backend/`.

**"Port 8000 is already in use"** — something else holds that port. The launcher
suggests the next free one, e.g. `.\run.ps1 -Port 8001`.

**"YouTube is blocking this network's IP address"** (`youtube_blocked`, surfaces as
HTTP 502) — YouTube rate-limits by IP, so this is your network, not your link.
**Waiting usually does not clear it**, because the block is on your address
rather than on any one request. What works:

- switch network — a phone hotspot changes your IP and fixes it immediately
- or set `YOUTUBE_PROXY=http://user:pass@host:8080` in `backend/.env` (a bare
  `host:port` is fine) and restart. YouTube traffic goes through the proxy;
  OpenAI traffic deliberately stays direct, so your API key is never silently
  rerouted. Verify with `python retry_youtube.py --once`, which honours the same
  variable and masks the credentials in its output.
- **paste the transcript** — the "YouTube is blocking me" button in the sidebar.
  Keep the link in the box and paste the video's text (or the contents of an
  `.srt` / `.vtt` file) below it. Title, thumbnail and citation links still come
  from the real video, so only the captions are supplied by hand. Subtitle files
  keep their real timestamps; plain text gets estimated ones, and the video card
  is badged "Pasted transcript" so you always know which you are looking at.
- meanwhile **"Try a sample video"** indexes a bundled transcript through the
  identical pipeline, so the app stays usable while YouTube is blocked.

A blocked client is not the end of the road on its own: captions are fetched
through `youtube-transcript-api` first and then, if that single client is
refused, through YouTube's InnerTube API with several clients in rotation. So a
network that only blocks one of them still works, and only a block on the IP
itself reaches the message above.

**Answers say "the video does not cover that"** — the question may be outside the
video's subject, or `SIMILARITY_THRESHOLD` is too high for the topic. Lower it
toward `0.15` to retrieve more loosely.

**Everything is slow on the first question** — that's indexing. It happens once
per video; the cache makes later loads instant.

## Limitations

- The video must have captions. There is no speech-to-text fallback.
- Auto-generated captions are occasionally garbled, which can weaken retrieval.
- Very long videos are truncated at `MAX_TRANSCRIPT_CHARS`, so questions about
  the very end may miss.
- Indexing a video costs a small number of embedding tokens, cached per video.
