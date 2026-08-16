@echo off
title Coding Tools MCP - ChatGPT Connector

REM ==== Fill in ALL <placeholders> before first run. See bridge/README.md. ====
REM ==== Keep this file local. NEVER commit it or share it (it contains secrets). ====

set CODING_TOOLS_MCP_SERVER_URL=https://<your-ngrok-static-domain>.ngrok-free.dev
set CODING_TOOLS_MCP_OAUTH_PASSWORD=<your-oauth-password>
REM ==== OAuth stability trio: preregistered connector client + stable signing secret + TTL ====
REM ==== (without these three, every server restart invalidates all connector tokens) ====
set CODING_TOOLS_MCP_OAUTH_CLIENT_ID=<client-id-captured-from-connector>
set CODING_TOOLS_MCP_OAUTH_REDIRECT_URIS=<redirect-uri-captured-from-connector>
set CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET=<64-hex-chars-secrets.token_hex(32)>
set CODING_TOOLS_MCP_OAUTH_TOKEN_TTL=604800

REM ==== Check if MCP server is already running ====
netstat -ano | findstr ":8765" | findstr "LISTENING" >nul
if %errorlevel%==0 (
    echo [OK] MCP server already running on port 8765.
) else (
    echo Starting MCP server in a minimized window...
    start "MCP Server" /min "<path-to>\coding-tools-mcp.exe" --workspace "<your-project-repo-path>" --host 127.0.0.1 --port 8765 --auth-token <static-bearer-token> --oauth-mode
    echo Waiting 8 seconds for server startup...
    timeout /t 8 /nobreak >nul
)

echo.
echo ============================================
echo   PERMANENT URL (never changes):
echo   https://<your-ngrok-static-domain>.ngrok-free.dev/mcp
echo.
echo   Keep this window open while using ChatGPT.
echo   Close it to stop the tunnel.
echo ============================================
echo.

"<path-to>\ngrok.exe" http --url=<your-ngrok-static-domain> 8765

pause
