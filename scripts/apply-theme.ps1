#!/usr/bin/env pwsh
# apply-theme.ps1 - aplica el tema canonico (Dracula + JetBrainsMono Nerd) a
# las herramientas de Windows nativo.
#
# Uso:
#   pwsh -File scripts/apply-theme.ps1              # todo
#   pwsh -File scripts/apply-theme.ps1 -Terminal    # solo Windows Terminal
#   pwsh -File scripts/apply-theme.ps1 -ProfileOnly # solo el perfil de PS
#
# Equivalente de scripts/apply-theme.sh. NUNCA sobrescribe configuracion de
# usuario que no este dentro de un bloque gestionado; en Windows Terminal se
# respeta la regla adicional de no tocar un settings.json que no se pueda
# analizar.
#
# Diferencia frente al bash: no existe Alacritty nativo aqui. El terminal
# objetivo es Windows Terminal (docs/WINDOWS.md).

[CmdletBinding()]
param(
    [switch]$Terminal,
    [switch]$ProfileOnly,
    [switch]$GitOnly,
    [string]$RepoDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $RepoDir) { $RepoDir = Split-Path -Parent $PSScriptRoot }
$env:REPO_DIR = $RepoDir
$LibDir = [IO.Path]::Combine($RepoDir, 'scripts', 'lib')
Import-Module (Join-Path $LibDir 'dotfiles.psm1') -Force
Import-Module (Join-Path $LibDir 'theme.psm1') -Force
Import-Module (Join-Path $LibDir 'ui.psm1') -Force

$Paths = Get-DotfilesPaths
$env:NUI_ENV_FILE = if ($env:NUI_ENV_FILE) { $env:NUI_ENV_FILE } else { $Paths.EnvFile }
$theme = Read-DotfilesTheme
if (-not $theme['__file']) {
    Write-UiError 'No se encontro config/theme/dracula.env'
    exit 1
}
Set-DotfilesThemeEnv -Theme $theme

$onlyOne = $Terminal -or $ProfileOnly -or $GitOnly

# --- Windows Terminal ------------------------------------------------------

function Invoke-TerminalTheme {
    param([hashtable]$Theme)
    $r = Set-DotfilesWindowsTerminalTheme -Theme $Theme
    if (Test-DotfilesResultSkipped -Result $r) {
        Write-UiDim "Windows Terminal: $($r.detail)"
        return
    }
    if ($r.ok) { Write-UiOk $r.detail } else { Write-UiWarn $r.detail }
}

# --- perfil de PowerShell ---------------------------------------------------

function Invoke-ProfileTheme {
    param([hashtable]$Theme)

    # El cuerpo va dentro del bloque gestionado: lo de fuera del usuario se
    # conserva intacto.
    $body = @(
        "# Paleta y utilidades del tema $($Theme.THEME_NAME)",
        "`$env:THEME_NAME = '$($Theme.THEME_NAME.Replace("'", "''"))'",
        "`$env:THEME_BG = '$($Theme.THEME_BG)'",
        "`$env:THEME_FG = '$($Theme.THEME_FG)'",
        "`$env:THEME_GREEN = '$($Theme.THEME_GREEN)'",
        "`$env:THEME_ORANGE = '$($Theme.THEME_ORANGE)'",
        "`$env:THEME_YELLOW = '$($Theme.THEME_YELLOW)'",
        "`$env:THEME_PURPLE = '$($Theme.THEME_PURPLE)'",
        "`$env:THEME_COMMENT = '$($Theme.THEME_COMMENT)'",
        "`$env:BAT_THEME = 'Dracula'",
        "`$env:EZA_COLORS = '$($Theme.THEME_EZA_COLORS.Replace("'", "''"))'",
        "`$env:EXA_COLORS = '$($Theme.THEME_EZA_COLORS.Replace("'", "''"))'",
        "`$env:FZF_DEFAULT_OPTS = '$($Theme.THEME_FZF_OPTS.Replace("'", "''"))'",
        'if (Get-Module -ListAvailable PSReadLine) {',
        '    Set-PSReadLineOption -Colors @{',
        "        Command   = '$($Theme.THEME_GREEN)'",
        "        Parameter = '$($Theme.THEME_ORANGE)'",
        "        String    = '$($Theme.THEME_YELLOW)'",
        "        Comment   = '$($Theme.THEME_COMMENT)'",
        "        Prompt    = '$($Theme.THEME_PURPLE)'",
        '    } 2>$null',
        '}',
        '# El perfil legacy de PowerShell 5.1 no carga modulos de PS7: se',
        '# protege con try para no romper la shell.',
        'try { if (Get-Module -ListAvailable Terminal-Icons) { Import-Module Terminal-Icons -ErrorAction Stop } } catch { }'
    ) -join "`n"

    $r = Set-DotfilesProfileBlock -Kind 'theme' -Body $body
    if ($r.done.Count -gt 0) {
        Write-UiStepLog "Paleta aplicada al perfil de PowerShell ($($r.done.Count) archivo(s))"
    }
    if ($r.failed.Count -gt 0) {
        Write-UiWarn ("perfiles sin bloque de tema (o bloque incompleto): " + ($r.failed -join ', '))
        return $false
    }
    return $true
}

# --- git --------------------------------------------------------------------

function Invoke-GitTheme {
    param([hashtable]$Theme, [hashtable]$Paths)
    $dir = Join-Path $Paths.ConfigRoot 'git'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $out = Join-Path $dir 'theme.gitconfig'
    # No hay plantilla: el gitconfig de colores se genera desde dracula.env,
    # igual que hace apply-theme.sh (unica fuente de verdad).
    $body = @"
# Generado por scripts/apply-theme.ps1 - tema $($Theme.THEME_NAME). No editar a mano.
[color]
    ui = true
[color "branch"]
    current = $($Theme.THEME_GREEN) bold
    local = $($Theme.THEME_PURPLE)
    remote = $($Theme.THEME_PINK)
[color "diff"]
    meta = $($Theme.THEME_PURPLE) bold
    frag = $($Theme.THEME_CYAN)
    old = $($Theme.THEME_RED)
    new = $($Theme.THEME_GREEN)
    commit = $($Theme.THEME_YELLOW)
[color "status"]
    added = $($Theme.THEME_GREEN)
    changed = $($Theme.THEME_YELLOW)
    untracked = $($Theme.THEME_PINK)
"@
    Backup-DotfilesFile -Path $out | Out-Null
    Write-DotfilesFile -Path $out -Content ($body + "`n") -Encoding 'utf8' | Out-Null
    Write-UiStepLog "Colores de git en $out"
    # El include del tema lo escribe setup-git-identity.ps1 dentro de su propio
    # bloque gestionado de ~/.gitconfig ([include] path = ...theme.gitconfig):
    # apply-theme no toca nunca ~/.gitconfig para no pelearse con ese script.
    return $true
}

# --- OpenCode: solo verificar ----------------------------------------------

function Test-OpenCodeTheme {
    param([hashtable]$Theme, [hashtable]$Paths)
    $cli = Join-Path $Paths.OpenCodeDir 'cli.json'
    if (-not (Test-Path -LiteralPath $cli)) { return $true }
    $data = Read-DotfilesJson -Path $cli
    if ($null -eq $data) { return $true }
    $have = $null
    try { $have = $data.theme.name } catch { $have = $null }
    if ($have -ne $Theme.THEME_NAME) {
        Write-UiWarn "OpenCode usa theme=$have, esperado $($Theme.THEME_NAME) (sync-dotfiles pull)"
        return $false
    }
    return $true
}

# --- ejecucion --------------------------------------------------------------

$rc = 0
if (-not $onlyOne -or $Terminal) { Invoke-TerminalTheme -Theme $theme }
if (-not $onlyOne -or $ProfileOnly) { if (-not (Invoke-ProfileTheme -Theme $theme)) { $rc = 1 } }
if (-not $onlyOne -or $GitOnly) { $null = Invoke-GitTheme -Theme $theme -Paths $Paths }
if (-not $onlyOne) {
    $null = Test-OpenCodeTheme -Theme $theme -Paths $Paths
    $null = Write-DotfilesThemeManifest -Theme $theme
    Write-UiStepLog "Tema $($theme.THEME_NAME) aplicado (fuente $($theme.THEME_FONT_FAMILY))"
}
exit $rc
