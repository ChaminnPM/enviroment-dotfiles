# gen-theme-go.ps1 - genera ui/theme_generated.go desde config/theme/dracula.env.
#
# Version PowerShell de scripts/gen-theme-go.sh: mismo algoritmo y mismo
# resultado byte a byte, para que `nui` se pueda compilar en Windows sin bash.
#
# Uso: pwsh -File scripts/gen-theme-go.ps1 [-Out <archivo>]
[CmdletBinding()]
param(
    [string]$Out
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = if ($env:THEME_ENV_FILE) { $env:THEME_ENV_FILE } else { [IO.Path]::Combine($RepoRoot, 'config', 'theme', 'dracula.env') }
if (-not $Out) { $Out = [IO.Path]::Combine($RepoRoot, 'ui', 'theme_generated.go') }

if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
    throw "no existe el archivo de tema: $EnvFile"
}

# --- parseo KEY=valor (comillas envolventes opcionales) -------------------
$tokens = @{}
foreach ($raw in [System.IO.File]::ReadAllLines($EnvFile, [System.Text.UTF8Encoding]::new($false))) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) { continue }
    $idx = $line.IndexOf('=')
    $key = $line.Substring(0, $idx).Trim()
    $val = $line.Substring($idx + 1).Trim()
    if ($val.Length -ge 2) {
        $first = $val[0]
        if (($first -eq '"' -or $first -eq "'") -and $val[$val.Length - 1] -eq $first) {
            $val = $val.Substring(1, $val.Length - 2)
        }
    }
    $tokens[$key] = $val
}

$keys = @(
    'THEME_BG', 'THEME_CURRENT', 'THEME_FG', 'THEME_COMMENT',
    'THEME_RED', 'THEME_GREEN', 'THEME_ORANGE', 'THEME_YELLOW',
    'THEME_PURPLE', 'THEME_PINK', 'THEME_CYAN'
)
$missing = @($keys | Where-Object { -not $tokens[$_] })
if ($missing.Count -gt 0) {
    throw "faltan tokens en el tema: $($missing -join ', ')"
}

# THEME_FOO_BAR -> themeFooBar
function ConvertTo-GoName([string]$Key) {
    $parts = $Key.Substring(6).Split('_') | Where-Object { $_ }
    $joined = ($parts | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower() }) -join ''
    return "theme$joined"
}

$lines = @(
    '// Code generated from config/theme/dracula.env by scripts/gen-theme-go.sh. DO NOT EDIT.',
    '',
    'package main',
    '',
    'const ('
)
foreach ($k in $keys) {
    $lines += "`t$(ConvertTo-GoName $k) = `"$($tokens[$k])`""
}
$lines += ')'
$body = ($lines -join "`n") + "`n"

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
# El generador de bash escribe LF sin BOM; aqui se replica exacto para que el
# diff de CI entre ambas implementaciones sea vacio.
[System.IO.File]::WriteAllText($Out, $body, [System.Text.UTF8Encoding]::new($false))

# gofmt alinea las constantes; sin esto `gofmt -l` fallaria en CI.
$gofmt = $null
foreach ($cand in @('gofmt', "$env:LOCALAPPDATA\Programs\Go\bin\gofmt.exe", 'C:\Program Files\Go\bin\gofmt.exe')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $gofmt = $cmd.Source; break }
    if (Test-Path -LiteralPath $cand -ErrorAction SilentlyContinue) { $gofmt = $cand; break }
}
if ($gofmt) {
    & $gofmt -w $Out
} else {
    Write-Warning 'gofmt no disponible: el archivo puede necesitar gofmt -w'
}

Write-Output "Generado $Out desde $EnvFile"
