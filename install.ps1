#!/usr/bin/env pwsh
# install.ps1 - instalador one-liner para Windows NATIVO (sin WSL, sin Git Bash).
#
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.ps1 | iex"
#
# Equivalente de install.sh: baja el repo como ZIP a un temporal, ejecuta
# bootstrap.ps1 desde ahi y NO deja el clon en el disco del usuario.
#
# Opciones por bandera o por variable de entorno (necesario con `irm | iex`,
# donde no se pueden pasar banderas):
#   -Ref / $env:REPO_REF                 rama o tag (default main)
#   -DryRun / $env:NUI_DRY_RUN=1         imprime el plan y no ejecuta
#   -NonInteractive / $env:NUI_NONINTERACTIVE=1
#   -NoColor / $env:NUI_NO_COLOR=1
#   -SkipGit / $env:SKIP_GIT_IDENTITY=1
#   -Only <texto> / $env:NUI_ONLY
#   -MachineScope / $env:DOTFILES_MACHINE_SCOPE=1
#   -WithPowerShell7 / $env:DOTFILES_WITH_PS7=1
#   -NodeManager fnm|node / $env:DOTFILES_NODE_MANAGER
#
# Seguridad:
#   - el ZIP se descarga por HTTPS con TLS 1.2 forzado;
#   - se desbloquean (Unblock-File) SOLO los scripts recien bajados antes de
#     ejecutarlos, y el arbol temporal se elimina al terminar;
#   - REPO_REF validado con whitelisting de caracteres: nunca acaba en una URL
#     sin comprobar;
#   - no se usa Invoke-Expression sobre contenido remoto mas alla de este
#     bootstrap, que ejecuta bootstrap.ps1 desde archivo con -File.

[CmdletBinding()]
param(
    [string]$Ref,
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$NoColor,
    [switch]$SkipGit,
    [switch]$MachineScope,
    [switch]$WithPowerShell7,
    [string]$NodeManager,
    [string]$Only,
    [string]$BaseUrl
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- modo one-liner --------------------------------------------------------

$OneLiner = -not $PSScriptRoot
if ($MyInvocation.Line -and $MyInvocation.Line.Trim().StartsWith('iex')) { $OneLiner = $true }

# --- config ----------------------------------------------------------------

$RepoRef = if ($Ref) { $Ref } elseif ($env:REPO_REF) { $env:REPO_REF } else { 'main' }
# REPO_REF va en una URL y en un nombre de archivo: solo caracteres seguros.
if ($RepoRef -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Host "[ERROR] REPO_REF invalido: $RepoRef (solo se permiten [A-Za-z0-9._-])" -ForegroundColor Red
    exit 2
}

$base = if ($BaseUrl) { $BaseUrl } elseif ($env:NUI_INSTALL_BASE_URL) { $env:NUI_INSTALL_BASE_URL } else { 'https://github.com/ChaminnPM/enviroment-dotfiles' }
$zipUrl = "$base/archive/refs/heads/$RepoRef.zip"
if ($env:REPO_ZIP_URL) { $zipUrl = $env:REPO_ZIP_URL }

if (-not $NodeManager) { $NodeManager = if ($env:DOTFILES_NODE_MANAGER) { $env:DOTFILES_NODE_MANAGER } else { 'fnm' } }
$onlyVal = if ($Only) { $Only } else { $env:NUI_ONLY }

# --- gate de plataforma ----------------------------------------------------

if ($env:OS -ne 'Windows_NT') {
    Write-Host '[ERROR] install.ps1 es el instalador de Windows nativo. En Linux/WSL usa install.sh (ver docs/PLATFORMS.md).' -ForegroundColor Red
    exit 1
}
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Host '[ERROR] Hace falta Windows de 64 bits (x64 o ARM64).' -ForegroundColor Red
    exit 1
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "[ERROR] PowerShell $($PSVersionTable.PSVersion) no soportado; se requiere 5.1+." -ForegroundColor Red
    exit 1
}

# --- entorno ---------------------------------------------------------------

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }
$ProgressPreference = 'SilentlyContinue'

$logDir = if ($env:LOG_DIR) { $env:LOG_DIR } else { [IO.Path]::Combine($HOME, '.config', 'enviroment-dotfiles', 'logs') }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$env:LOG_DIR = $logDir

if ($DryRun) { $env:NUI_DRY_RUN = '1' }
if ($NonInteractive) { $env:NUI_NONINTERACTIVE = '1' }
if ($NoColor) { $env:NUI_NO_COLOR = '1'; $env:NO_COLOR = '1' }
if ($SkipGit) { $env:SKIP_GIT_IDENTITY = '1' }
if ($MachineScope) { $env:DOTFILES_MACHINE_SCOPE = '1' }
if ($WithPowerShell7) { $env:DOTFILES_WITH_PS7 = '1' }
if ($env:SKIP_GIT_IDENTITY -eq '1') { $SkipGit = $true }
if ($Only) { $env:NUI_ONLY = $Only }

Write-Host ''
Write-Host '  AGENTS ENVIRONMENT - instalador Windows nativo' -ForegroundColor Magenta
Write-Host "  repo: $RepoRef | config: $logDir" -ForegroundColor DarkGray
Write-Host ''

# --- descarga y ejecucion ---------------------------------------------------

# Write-Step: mensajito de progreso del bootstrap (el panel todavia no existe;
# aqui solo se necesita texto plano y que un fallo aborte).
function Write-Step {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    Write-Host ">> $Title" -NoNewline -ForegroundColor DarkGray
    try {
        & $Body
        Write-Host ' [OK]' -ForegroundColor Green
    } catch {
        Write-Host ' [ERROR]' -ForegroundColor Red
        throw
    }
}

# Invoke-DotfilesInstallChild lanza el bootstrap en un proceso hijo con
# citado explicito de CreateProcess. install.ps1 NO importa modulos: tiene que
# funcionar tal cual desde `irm | iex` en una maquina sin nada instalado.
function Invoke-DotfilesInstallChild {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$ChildArgs
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $quoted = @()
    foreach ($a in $ChildArgs) {
        if ($null -eq $a) { $a = '' }
        if ($a -eq '') { $quoted += '""'; continue }
        if ($a -match '[\s"]') { $quoted += ('"' + ($a -replace '"', '\"') + '"') }
        else { $quoted += $a }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    $code = $p.ExitCode
    $p.Dispose()
    return $code
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("enviroment-dotfiles-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$rc = 1
try {
    $zip = Join-Path $tmp 'repo.zip'
    Write-Step -Title 'Descargando repositorio (ZIP)...' -Body {
        $curl = Get-Command 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue
        if ($curl) {
            # curl.exe viene con Windows 10 1803+ y maneja mejor proxies y
            # redirecciones largas que Invoke-WebRequest en 5.1.
            & $curl.Source '-fsSL' '--retry' '3' '--max-time' '600' '-o' $zip $zipUrl
            if ($LASTEXITCODE -ne 0) { throw "curl fallo con codigo $LASTEXITCODE descargando $zipUrl" }
        } else {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        }
    }

    $repo = Join-Path $tmp 'repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    Write-Step -Title 'Extrayendo repositorio...' -Body {
        Expand-Archive -LiteralPath $zip -DestinationPath $repo -Force -ErrorAction Stop
    }

    # Expand-Archive mete todo bajo <repo>/enviroment-dotfiles-<ref>/
    $inner = Get-ChildItem -LiteralPath $repo -Directory | Select-Object -First 1
    if ($inner) { $repo = $inner.FullName }

    $bootstrap = Join-Path $repo 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrap)) {
        throw "no se encontro bootstrap.ps1 en el ZIP descargado ($bootstrap)"
    }

    # Mark-of-the-Web: sin desbloquear, PowerShell 5.1 con politica restrictiva
    # se niega a ejecutar los scripts.
    Write-Step -Title 'Desbloqueando scripts del repositorio...' -Body {
        # install.ps1 solo corre en Windows (hay gate arriba), pero Unblock-File
        # se envuelve en try por si el proveedor no soporta ADS.
        Get-ChildItem -LiteralPath $repo -Recurse -Include *.ps1, *.psm1, *.cmd, *.gz -File -ErrorAction SilentlyContinue |
            ForEach-Object { try { Unblock-File -LiteralPath $_.FullName -ErrorAction Stop } catch { } }
    }

    Write-Host '>> Ejecutando bootstrap.ps1' -ForegroundColor DarkGray
    $self = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    $bootArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrap, '-RepoDir', $repo)
    if ($DryRun) { $bootArgs += '-DryRun' }
    if ($NonInteractive) { $bootArgs += '-NonInteractive' }
    if ($NoColor) { $bootArgs += '-NoColor' }
    if ($SkipGit) { $bootArgs += '-SkipGit' }
    if ($MachineScope) { $bootArgs += '-MachineScope' }
    if ($WithPowerShell7) { $bootArgs += '-WithPowerShell7' }
    if ($NodeManager) { $bootArgs += @('-NodeManager', $NodeManager) }
    if ($onlyVal) { $bootArgs += @('-Only', $onlyVal) }

    if ($self -and $self -match 'pwsh(\.exe)?$') {
        & $self @bootArgs
        $rc = $LASTEXITCODE
    } else {
        $code = Invoke-DotfilesInstallChild -Exe 'powershell.exe' -ChildArgs $bootArgs
        $rc = $code
    }
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        Log: $logDir" -ForegroundColor DarkGray
    $rc = 1
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($rc -eq 0) {
    Write-Host ''
    Write-Host 'Instalacion terminada. Abre una terminal nueva para cargar el PATH.' -ForegroundColor Green
    Write-Host 'Comandos: sync-dotfiles pull | sync-dotfiles push | sync-dotfiles doctor' -ForegroundColor DarkGray
    if ($OneLiner) {
        Write-Host 'Esta ventana puede cerrarse: no queda repositorio local en el disco.' -ForegroundColor DarkGray
    }
}
exit $rc
