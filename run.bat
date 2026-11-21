@echo off
REM ===========================================================================
REM  AskTube - one-click launcher (double-click this file)
REM
REM  Usage:  run.bat                -> start on port 8000
REM          run.bat 8080           -> start on a different port
REM          run.bat 8080 reload    -> same, with hot reload (development)
REM ===========================================================================
setlocal
cd /d "%~dp0"

set "PORT=8000"
if not "%~1"=="" set "PORT=%~1"

REM Next port up, used in the "port busy" hint.
set /a PORT_INC=%PORT%+1

set "PY=%CD%\venv\Scripts\python.exe"

REM --- preflight checks -----------------------------------------------------
if not exist "%PY%" (
    echo [ERROR] Virtual environment not found.
    echo         Expected: %PY%
    echo         Create it with:  python -m venv venv
    echo.
    pause
    exit /b 1
)

if not exist "backend\.env" (
    echo [ERROR] backend\.env is missing.
    echo         Copy backend\.env.example to backend\.env first.
    echo.
    pause
    exit /b 1
)

REM A busy port is only a problem if the listener is something else. If AskTube
REM is already serving there, refusing to start is an alarming non-problem: the
REM app is fine, so open it and stop.
REM
REM The busy case is handled outside a parenthesised block on purpose. Inside
REM one, %EXISTING% would be expanded when the block is parsed - before the for
REM loop had a chance to set it - and the check would silently never match.
netstat -ano | findstr "LISTENING" | findstr /R /C:":%PORT% " >nul 2>&1
if not errorlevel 1 goto :port_busy

goto :port_free

:port_busy
set "EXISTING="
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 'http://127.0.0.1:%PORT%/api/health').Content -match 'llm_model' } catch { 'no' }"`) do set "EXISTING=%%H"
if "%EXISTING%"=="True" goto :already_running

echo [ERROR] Port %PORT% is already in use by another program.
echo         Stop it, or start on another port:   run.bat %PORT_INC%
echo.
pause
exit /b 1

:port_free

REM --- status banner --------------------------------------------------------
REM A key is optional: with none set the app runs in local mode (hashing
REM embeddings + extractive answers). So only flag the real failure - a key
REM that is present but still the placeholder. An empty value is fine.
findstr /B /C:"OPENAI_API_KEY=your_api_key_here" "backend\.env" >nul 2>&1
if errorlevel 1 (
    set "KEYSTATE=not set - the site runs in local mode"
) else (
    set "KEYSTATE=MISSING - still the placeholder"
)

echo ===========================================================================
echo   ASKTUBE   -   YouTube RAG chatbot
echo ===========================================================================
echo.
echo    OPEN THIS ADDRESS IN YOUR BROWSER:
echo.
echo        http://127.0.0.1:%PORT%
echo.
echo    API key:  %KEYSTATE%
if "%KEYSTATE%"=="MISSING - still the placeholder" (
    echo    ---------------------------------------------------------------
    echo    The page will LOAD but will NOT WORK until you add a key:
    echo.
    echo        1. Open   backend\.env
    echo        2. Set    OPENAI_API_KEY=sk-...
    echo        3. Run    run.bat %PORT%   again
    echo.
    echo    Get a key at https://platform.openai.com/api-keys
    echo    ---------------------------------------------------------------
)
echo.
echo    Press Ctrl+C in this window to stop.
echo.
echo ===========================================================================
echo.

REM --- open the browser once the server has had time to bind ---------------
start "" /b powershell -NoProfile -WindowStyle Hidden -Command ^
    "Start-Sleep 3; Start-Process 'http://127.0.0.1:%PORT%'"

REM Hot reload is opt-in. --reload makes uvicorn spawn a child process, and
REM killing the parent orphans the child - which leaves a half-alive server
REM holding the port. A single process shuts down cleanly. Use run.bat reload
REM while developing.
set "RELOAD="
if /i "%~2"=="reload" set "RELOAD=--reload"

pushd backend
"%PY%" -m uvicorn main:app %RELOAD% --port %PORT%
set "EXITCODE=%errorlevel%"
popd

echo.
echo Server stopped ^(exit code %EXITCODE%^).
pause
exit /b %EXITCODE%

REM Reached only by the goto above, which fires when the port is busy but
:already_running
echo ===========================================================================
echo   ASKTUBE is already running on port %PORT%
echo ===========================================================================
echo.
echo    Nothing to fix. Opening it in your browser.
echo    To run a second copy, use a different port:   run.bat %PORT_INC%
echo.
start "" "http://127.0.0.1:%PORT%"
exit /b 0
