@echo off
rem install.cmd - launcher para el doble clic o para quien no pueda usar
rem "irm | iex" (GPO con politica de ejecucion estricta, proxies que rompen
rem Invoke-RestMethod, etc.).
rem
rem Hace exactamente lo mismo que el one-liner de PowerShell, pero pidiendo a
rem powershell.exe que se salte la politica SOLO en este proceso.
setlocal
set "REF=main"
if not "%REPO_REF%"=="" set "REF=%REPO_REF%"
set "URL=https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/%REF%/install.ps1"

echo.
echo  AGENTS ENVIRONMENT - instalador Windows nativo
echo  %URL%
echo.

where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -Command "irm %URL% | iex"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm %URL% | iex"
)
set "RC=%errorlevel%"
if not "%RC%"=="0" echo.
if not "%RC%"=="0" echo El instalador termino con codigo %RC%. Ver docs/WINDOWS.md.
endlocal & exit /b %RC%
