# How to Run AskTube (fixes "localhost refused to connect")

The browser error **`ERR_CONNECTION_REFUSED` / "localhost refused to connect"**
means the backend server is **not running**. The page at `http://localhost:8000`
only loads while the server process is alive. Start it, then open the page.

---

## Option 1 — Double-click (easiest)

1. Double-click **`run.bat`** in the project root.
2. Wait for the banner, then open **http://localhost:8000**.

Use a different port if 8000 is busy:

```bat
run.bat 8080
```

## Option 2 — PowerShell launcher

```powershell
.\run.ps1                # http://localhost:8000
.\run.ps1 -Port 8080     # different port
.\run.ps1 -NoBrowser     # don't auto-open the browser
```

## Option 3 — Manual uvicorn (what we ran)

From the project root:

```powershell
cd backend
..\venv\Scripts\python.exe -m uvicorn main:app --port 8000
```

Add `--reload` only while developing (it spawns a child process):

```powershell
..\venv\Scripts\python.exe -m uvicorn main:app --reload --port 8000
```

---

## Verify the server is actually up

Run this in another terminal:

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/api/health
```

Expected: `STATUS 200` with JSON like:

```json
{"status":"ok","api_key_configured":false,"local_mode":true,...}
```

- `api_key_configured: false` -> runs in **local mode** (extractive answers).
  For full AI answers, set `OPENAI_API_KEY=sk-...` in `backend/.env` and restart.
- `api_key_configured: true` -> OpenAI writes the answers.

### Is the port already listening?

```powershell
netstat -ano | findstr "LISTENING" | findstr /R /C:":8000 "
```

No output means **nothing is listening** -> that is exactly why the browser
refused to connect. Start the server with one of the options above.

### If the app is already running

`run.bat` / `run.ps1` detect this (via `/api/health`) and just open the browser
instead of failing.

---

## Top-of-mind checklist when you see "refused to connect"

1. Is the server window still open and running? (Don't close it.)
2. Did it print `Uvicorn running on http://127.0.0.1:8000`?
3. Is the port the same one you're opening in the browser?
4. Does `/api/health` return 200? If not, read the server window for errors.

Stop the server with **Ctrl+C** in its window.
