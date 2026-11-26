#!/usr/bin/env pwsh
# sync.ps1 - sincroniza solo los assets PUBLICOS entre el repo y
# ~/.config/opencode en Windows nativo.
#
# Uso:
#   pwsh -File scripts/sync.ps1 pull|push|doctor [-DryRun] [-Delete] [-Verbose]
#   sync-dotfiles pull | sync-dotfiles push | sync-dotfiles doctor
#
# Equivalente de scripts/sync.sh:
#   - pull usa HTTPS (no requiere llaves SSH configuradas);
#   - push requiere SSH de GitHub validada contra el known_hosts pinnado;
#   - doctor no modifica nada.
#
# -Delete espeja los directorios (borra en el destino lo que no hay en el
# origen). Sin bandera, solo copia: nunca se borra configuracion del usuario.

[CmdletBinding()]
param(
    [ValidateSet('pull', 'push', 'doctor')][string]$Mode = 'pull',
    [switch]$DryRun,
    [switch]$Delete,
    [string]$RepoDir,
    [string]$OpenCodeDir,
    # -SkipPull actualiza los assets desde un repo YA descargado sin tocar el
    # remoto. Lo usan los tests y "Restaurar configuracion"; en un pull normal
    # el repo SI se refresca (es un clon temporal del wrapper).
    [switch]$SkipPull
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $RepoDir) { $RepoDir = Split-Path -Parent $PSScriptRoot }
$env:REPO_DIR = $RepoDir
$LibDir = [IO.Path]::Combine($RepoDir, 'scripts', 'lib')
Import-Module (Join-Path $LibDir 'dotfiles.psm1') -Force
Import-Module (Join-Path $LibDir 'ui.psm1') -Force
Import-Module (Join-Path $LibDir 'theme.psm1') -Force
Import-Module (Join-Path $LibDir 'packages.psm1') -Force
Import-Module (Join-Path $LibDir 'doctor.psm1') -Force

if ($DryRun) { $env:NUI_DRY_RUN = '1' }
if ($Delete) { $env:SYNC_DELETE = '1' }
$Paths = Get-DotfilesPaths
if (-not $OpenCodeDir) { $OpenCodeDir = $Paths.OpenCodeDir }
$env:OPENCODE_DIR = $OpenCodeDir
$env:LOG_DIR = $Paths.LogDir
$env:NUI_ENV_FILE = $Paths.EnvFile
$repoUrl = if ($env:REPO_URL) { $env:REPO_URL } else { 'https://github.com/ChaminnPM/enviroment-dotfiles.git' }
$theme = Read-DotfilesTheme

# Un clon temporal NO es un repo persistente: se limpia al salir.
$Ephemeral = $false
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir '.git'))) {
    $cloneDir = New-DotfilesTempDir -Prefix 'sync-clone'
    $repoArg = Join-Path $cloneDir 'repo'
    $code = Invoke-DotfilesNative -Argv @('git', 'clone', '--depth', '50', $repoUrl, $repoArg)
    if ($code -ne 0) {
        Write-UiError "No se pudo clonar $repoUrl"
        Remove-DotfilesTree -Path $cloneDir
        exit 1
    }
    $RepoDir = $repoArg
    $env:REPO_DIR = $RepoDir
    $Ephemeral = $true
}

try {
    # --- doctor -------------------------------------------------------------
    if ($Mode -eq 'doctor') {
        exit (Invoke-DotfilesDoctor -Paths $Paths -RepoDir $RepoDir -OpenCodeDir $OpenCodeDir -Theme $theme)
    }

    Write-Host ''
    if ($DryRun) { Write-UiWarn 'Modo dry-run: no se modifica nada' }

    $publicPaths = Get-DotfilesPublicPathList

    if ($Mode -eq 'pull') {
        if (-not $Ephemeral -and -not $SkipPull) {
            if ($DryRun) {
                Write-UiDim "[dry-run] git -C $RepoDir pull --rebase --autostash"
            } else {
                $code = Invoke-DotfilesLoggedArgv -Title 'Actualizando repo publico...' -Argv @('git', '-C', $RepoDir, 'pull', '--rebase', '--autostash')
                if ($code -ne 0) { Write-UiWarn 'git pull fallo; revisa estado local o conflictos' }
            }
        }
        foreach ($rel in $publicPaths) {
            $src = Join-Path (Join-DotfilesPath -Base $RepoDir -Child 'config/opencode') $rel
            $dst = Join-Path $OpenCodeDir $rel
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if ($DryRun) {
                Write-UiDim "[dry-run] copy $src -> $dst"
                continue
            }
            if (-not (Copy-DotfilesTree -Source $src -Destination $dst -Mirror:$Delete)) {
                Write-UiWarn "No se pudo sincronizar: $rel"
            }
        }
        $themeSrc = Join-DotfilesPath -Base $RepoDir -Child 'config/theme'
        if ($DryRun) {
            Write-UiDim "[dry-run] copy $themeSrc -> $($Paths.ThemeDir)"
        } elseif (-not (Copy-DotfilesTree -Source $themeSrc -Destination $Paths.ThemeDir)) {
            Write-UiWarn 'No se pudo sincronizar: config/theme'
        }

        if (Test-DotfilesCommand 'npm') {
            if ($DryRun) {
                Write-UiDim "[dry-run] npm install --prefix $OpenCodeDir"
            } else {
                $code = Invoke-DotfilesLoggedArgv -Title 'npm install' -Argv @('npm', '--prefix', $OpenCodeDir, 'install')
                if ($code -ne 0) { Write-UiWarn 'npm install fallo; revisa node_modules manualmente' }
            }
        } else {
            Write-UiWarn 'npm no disponible; se omite la instalacion de dependencias'
        }
        Write-UiOk 'Sincronizado (pull publico): assets publicos aplicados'
    }

    if ($Mode -eq 'push') {
        if (-not (Test-DotfilesSsh -Title 'Validando GitHub SSH...' -Target 'git@github.com')) {
            Write-UiError 'SSH GitHub falla. Ejecuta scripts/setup-git-identity.ps1'
            exit 1
        }
        foreach ($rel in $publicPaths) {
            $src = Join-Path $OpenCodeDir $rel
            $dst = Join-Path (Join-DotfilesPath -Base $RepoDir -Child 'config/opencode') $rel
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if (-not (Copy-DotfilesTree -Source $src -Destination $dst -Mirror:$Delete)) {
                Write-UiWarn "No se pudo preparar: $rel"
            }
        }
        $themeDst = Join-DotfilesPath -Base $RepoDir -Child 'config/theme'
        if (Test-Path -LiteralPath $Paths.ThemeDir) {
            $null = Copy-DotfilesTree -Source $Paths.ThemeDir -Destination $themeDst
        }
        # Nunca se sube config privada ni dependencias.
        foreach ($bad in @('service.json', 'node_modules')) {
            $p = Join-Path $RepoDir "config/opencode/$bad"
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        }

        if ($DryRun) {
            Write-UiDim '[dry-run] git add (solo rutas publicas) + commit + push'
            Write-UiOk 'Dry-run (push publico): nada se subio'
            exit 0
        }

        $addPaths = @()
        foreach ($rel in $publicPaths) { $addPaths += "config/opencode/$($rel.TrimEnd('/'))" }
        $addPaths += 'config/theme'
        $null = Invoke-DotfilesNative -Argv (@('git', '-C', $RepoDir, 'add', '--') + $addPaths)
        $dirty = Invoke-DotfilesNative -Argv @('git', '-C', $RepoDir, 'diff', '--cached', '--quiet')
        if ($dirty -ne 0) {
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $code = Invoke-DotfilesLoggedArgv -Title 'Commit publico...' -Argv @('git', '-C', $RepoDir, 'commit', '-m', "sync: $stamp")
            if ($code -ne 0) { Write-UiDim 'Nada que commitear' }
        } else {
            Write-UiDim 'Nada que commitear'
        }
        $code = Invoke-DotfilesLoggedArgv -Title 'Push publico...' -Argv @('git', '-C', $RepoDir, 'push')
        if ($code -ne 0) {
            Write-UiError 'No se pudo subir al repo publico'
            exit 1
        }
        Write-UiOk 'Sincronizado (push publico): repo publico actualizado'
    }
} finally {
    if ($Ephemeral -and $cloneDir) { Remove-DotfilesTree -Path $cloneDir }
    if ($Mode -ne 'doctor') { Clear-DotfilesRunMarker }
}
