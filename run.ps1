<#
.SYNOPSIS
    AskTube launcher - sets up the environment and starts the dev server.

.DESCRIPTION
    Checks that the virtualenv and backend\.env exist, verifies an OpenAI key
    has been set, warns if the requested port is already taken, then starts
    uvicorn with hot reload. The browser opens automatically once the server
    has had time to bind.

.EXAMPLE
    .\run.ps1

.EXAMPLE
    .\run.ps1 -Port 8080

.EXAMPLE
    .\run.ps1 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8000,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$VenvPython = Join-Path $PSScriptRoot 'venv\Scripts\python.exe'
$EnvFile    = Join-Path $PSScriptRoot 'backend\.env'
$BackendDir = Join-Path $PSScriptRoot 'backend'
$Url        = "http://localhost:$Port"

function Write-Step  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "    $m" -ForegroundColor Red }

function Test-AskTube {
    # Is the thing already listening on this port our own app? /api/health is the
    # cheapest unambiguous test - it answers 200 with "llm_model" only for this
    # project, so a coincidence with some other server is not possible.
    param([int]$Port)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 `
            -Uri "http://127.0.0.1:$Port/api/health"
        return $response.Content -match 'llm_model'
    } catch {
        return $false
    }
}

Write-Host ""
Write-Host "  AskTube - YouTube RAG chatbot" -ForegroundColor White
Write-Host "  -----------------------------" -ForegroundColor DarkGray
Write-Host ""

# --- 1. virtualenv ----------------------------------------------------------
Write-Step "Checking the virtual environment"
if (Test-Path $VenvPython) {
    $version = & $VenvPython --version 2>&1
    Write-Ok $version
} else {
    Write-Fail "Not found: $VenvPython"
    Write-Host ""
    Write-Host "  Create it with:" -ForegroundColor Yellow
    Write-Host "      python -m venv venv" -ForegroundColor Yellow
    Write-Host "      .\venv\Scripts\python.exe -m pip install -r backend\requirements.txt" -ForegroundColor Yellow
    Write-Host ""
    if (-not $NoBrowser) { pause }
    exit 1
}

# --- 2. dependencies --------------------------------------------------------
Write-Step "Verifying dependencies"
$probe = & $VenvPython -c "import fastapi, uvicorn, openai, faiss, numpy, youtube_transcript_api" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "All required packages are installed"
} else {
    Write-Warn "A dependency is missing. Install with:"
    Write-Host "      .\venv\Scripts\python.exe -m pip install -r backend\requirements.txt" -ForegroundColor Yellow
    Write-Host "      $($probe -join ' ')" -ForegroundColor DarkGray
    Write-Host ""
    if (-not $NoBrowser) { pause }
    exit 1
}

# --- 3. .env ----------------------------------------------------------------
Write-Step "Checking configuration"
if (-not (Test-Path $EnvFile)) {
    Write-Fail "backend\.env is missing"
    Write-Host ""
    Write-Host "  Create it with:" -ForegroundColor Yellow
    Write-Host "      Copy-Item backend\.env.example backend\.env" -ForegroundColor Yellow
    Write-Host "  then add your OPENAI_API_KEY." -ForegroundColor Yellow
    Write-Host ""
    if (-not $NoBrowser) { pause }
    exit 1
}

$keyLine = Get-Content $EnvFile |
    Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=\s*(.+?)\s*$' } |
    Select-Object -First 1

$keyValue = if ($keyLine) { ($keyLine -split '=', 2)[1].Trim() } else { '' }

if (-not $keyValue -or $keyValue -eq 'your_api_key_here' -or $keyValue -like 'sk-replace*') {
    # Not a failure: with no key the app falls back to its local, key-free
    # engine (hashing embeddings + extractive answers). Say which one is live
    # so nobody mistakes it for a broken install.
    Write-Warn "No OPENAI_API_KEY set - the site will run in local mode."
    Write-Host "      Answers are extracted from the transcript by keyword match" -ForegroundColor DarkGray
    Write-Host "      instead of written by a model. Add a key in backend\.env for" -ForegroundColor DarkGray
    Write-Host "      full answers." -ForegroundColor DarkGray
} else {
    $masked = if ($keyValue.Length -gt 11) { $keyValue.Substring(0, 7) + '...' + $keyValue.Substring($keyValue.Length - 4) } else { '***' }
    Write-Ok "OPENAI_API_KEY found ($masked)"
}

# --- 4. port ----------------------------------------------------------------
# Windows makes every single probe unreliable on its own:
#   * Get-NetTCPConnection keeps stale Listen rows for dead PIDs (false busy).
#   * A plain bind succeeds against a live listener unless the holder set
#     SO_EXCLUSIVEADDRUSE (false free).
#   * SO_REUSEADDR in our own probe hides real conflicts on Windows.
# So probe in order of authority: connect (unambiguous "is a server there?"),
# then a strict bind to tell a real conflict from harmless TIME_WAIT residue.
Write-Step "Checking port $Port"
& $VenvPython -c "import socket,sys
s=socket.socket()
s.settimeout(2)
try:
    s.connect(('127.0.0.1', $Port))
except OSError:
    sys.exit(1)
finally:
    s.close()"
$occupied = ($LASTEXITCODE -eq 0)

if ($occupied) {
    # A busy port is only a problem if the listener is something else. If this
    # app is already serving there, refusing to start is an alarming non-problem:
    # the site is up, so open it and quit.
    if (Test-AskTube -Port $Port) {
        Write-Host ""
        Write-Host "  ASKTUBE IS ALREADY RUNNING on port $Port" -ForegroundColor Green
        Write-Host "  Nothing to fix. Opening it in your browser." -ForegroundColor DarkGray
        Write-Host "  For a second copy:  .\run.ps1 -Port $($Port + 1)" -ForegroundColor DarkGray
        Write-Host ""
        if (-not $NoBrowser) { Start-Process "http://localhost:$Port" }
        exit 0
    }

    # A force-killed uvicorn can leave a listening socket whose owning process
    # no longer exists ("zombie" port). That one needs a reboot, not taskkill.
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                Select-Object -First 1
    $alive = $false
    if ($listener) { $alive = [bool](Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue) }

    if (-not $alive -and $listener) {
        Write-Warn "Port $Port is held by a leftover socket from a previous run"
        Write-Host "      (its process no longer exists, so it cannot be stopped)." -ForegroundColor DarkGray
        Write-Host "      Start on another port:" -ForegroundColor DarkGray
        Write-Host "      .\run.ps1 -Port $($Port + 1)" -ForegroundColor Yellow
        Write-Host "      Or reboot Windows to reclaim port $Port." -ForegroundColor DarkGray
    } else {
        Write-Warn "Port $Port is already in use by another program."
        Write-Host "      Stop it, or start on another port:" -ForegroundColor DarkGray
        Write-Host "      .\run.ps1 -Port $($Port + 1)" -ForegroundColor Yellow
    }
    Write-Host ""
    if (-not $NoBrowser) { pause }
    exit 1
}

# Nothing is listening. A strict bind distinguishes a free port from TIME_WAIT.
& $VenvPython -c "import socket,sys
s=socket.socket()
try:
    s.bind(('', $Port))
except OSError:
    sys.exit(1)
finally:
    s.close()"
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Port $Port is free"
} else {
    Write-Warn "Port $Port is in TIME_WAIT from a recent run; starting anyway."
}

# --- 5. go ------------------------------------------------------------------
Write-Host ""
Write-Host "  Starting on $Url" -ForegroundColor White
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) {
    Start-Job -ScriptBlock {
        param($u)
        Start-Sleep -Seconds 3
        Start-Process $u
    } -ArgumentList $Url | Out-Null
}

Push-Location $BackendDir
try {
    & $VenvPython -m uvicorn main:app --reload --port $Port
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "  Server stopped (exit code $code)." -ForegroundColor DarkGray
if (-not $NoBrowser) { pause }
exit $code
