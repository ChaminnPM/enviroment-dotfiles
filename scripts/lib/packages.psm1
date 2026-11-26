# packages.psm1 - capa de paquetes para Windows.
#
# Estrategia (documentada en docs/WINDOWS.md):
#   1. winget con `--scope user` cuando el paquete lo admite;
#   2. si winget no esta, no funciona o el usuario pidio "sin admin", se usan
#      los ZIPs pinnados de `fallback` en config/windows/packages.json;
#   3. NUNCA se eleva en silencio: la elevacion es explicita (-MachineScope) y
#      en bloque, para provocar una sola UAC en toda la instalacion.
#
# Los IDs se validan contra winget-pkgs en CI. Un ID mal escrito no debe
# bloquear la instalacion: el fallback portatil sigue funcionando.

Set-StrictMode -Version 2.0

# Autodependencias: los modulos se importan en el mismo proceso por el preambulo
# del panel, pero un test o un uso standalone de packages.psm1 no puede fallar
# por eso.
if (-not (Get-Command Get-DotfilesPaths -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'dotfiles.psm1') -Force -ErrorAction Stop
}
if (-not (Get-Command Invoke-DotfilesLoggedArgv -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'ui.psm1') -Force -ErrorAction Stop
}

$script:ManifestCache = $null
$script:WingetChecked = $false
$script:WingetAvailable = $false
$script:WingetPath = $null

function Get-DotfilesPackagesManifest {
    param([switch]$Reload)
    if ($script:ManifestCache -and -not $Reload) { return $script:ManifestCache }
    $paths = Get-DotfilesPaths
    $file = Join-DotfilesPath -Base $paths.RepoDir -Child 'config/windows/packages.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "falta config/windows/packages.json ($file)"
    }
    $data = Read-DotfilesJson -Path $file -AsHashtable
    if (-not $data) { throw "config/windows/packages.json no es JSON valido" }
    $script:ManifestCache = $data
    return $data
}

# Get-DotfilesFallback resuelve el ZIP pinnado de un paquete permitiendo
# sobrescribir la URL por variable de entorno (mismo patron que los *_URL del
# instalador bash: se puede repinnar sin editar el repo).
function Get-DotfilesFallback {
    param([Parameter(Mandatory)]$Package)
    if (-not (Test-DotfilesKey -Map $Package -Key 'fallback')) { return $null }
    $fb = $Package['fallback']
    $url = $fb['url']
    if ((Test-DotfilesKey -Map $fb -Key 'env') -and $fb['env']) {
        $ov = [Environment]::GetEnvironmentVariable([string]$fb['env'])
        if ($ov) { $url = $ov }
    }
    return @{
        name   = $fb['name']
        url    = $url
        inner  = if (Test-DotfilesKey -Map $fb -Key 'inner') { [string]$fb['inner'] } else { '' }
        sha256 = if (Test-DotfilesKey -Map $fb -Key 'sha256') { [string]$fb['sha256'] } else { '' }
    }
}

function Test-DotfilesWinget {
    if (-not $script:WingetChecked) {
        $script:WingetChecked = $true
        $cmd = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command 'winget' -CommandType Application -ErrorAction SilentlyContinue }
        $script:WingetAvailable = [bool]$cmd
        if ($script:WingetAvailable) {
            # Una version vieja (Win10 sin App Installer actualizado) puede no
            # conocer los flags de user-scope; se trata como no disponible.
            $ver = ''
            try { $ver = & $cmd.Source --version 2>$null | Select-Object -First 1 } catch { $ver = '' }
            if ($ver -notmatch '^\d+') { $script:WingetAvailable = $false }
            else {
                $major = [int]($ver -split '\.')[0]
                if ($major -lt 1) { $script:WingetAvailable = $false }
            }
            $script:WingetPath = if ($script:WingetAvailable) { $cmd.Source } else { $null }
        } else {
            $script:WingetPath = $null
        }
    }
    return $script:WingetAvailable
}

# Get-DotfilesPackage: entrada del manifiesto por clave.
function Get-DotfilesPackage {
    param(
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('base', 'custom', 'apps')][string]$Section = 'base'
    )
    $m = Get-DotfilesPackagesManifest
    if (-not (Test-DotfilesKey -Map $m -Key $Section)) { return $null }
    foreach ($e in @($m[$Section])) {
        if ((Test-DotfilesKey -Map $e -Key 'key') -and $e['key'] -eq $Key) { return $e }
    }
    return $null
}

function Get-DotfilesPackageList {
    param([ValidateSet('base', 'custom', 'apps')][string]$Section = 'base')
    $m = Get-DotfilesPackagesManifest
    if (-not (Test-DotfilesKey -Map $m -Key $Section)) { return @() }
    return @($m[$Section])
}

# Add-DotfilesPackage intenta winget y cae al fallback portatil.
# Devuelve [pscustomobject] con Method (winget|user-bin|none) y Detail.
function Add-DotfilesPackage {
    param(
        [Parameter(Mandatory)]$Package,
        [switch]$MachineScope,
        [switch]$DryRun
    )
    $id = $Package['id']
    $name = if (Test-DotfilesKey -Map $Package -Key 'key') { $Package['key'] } else { $id }
    $method = 'none'
    $detail = ''

    if ($DryRun) {
        return [pscustomobject]@{ ok = $true; method = 'dry-run'; detail = "dry-run: $name -> $id" }
    }

    if ($id -and (Test-DotfilesWinget) -and $script:WingetPath) {
        $wingetArgs = @('install', '--id', $id, '-e',
            '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity', '--silent')
        if (-not $MachineScope) { $wingetArgs += @('--scope', 'user') }
        # winget es MUY ruidoso: su salida va al log del paso, no al panel.
        $wgLog = New-DotfilesStepLog -Label 'winget'
        $code = Invoke-DotfilesNativeLogged -Argv (@($script:WingetPath) + $wingetArgs) -LogFile $wgLog -TimeoutSec 900
        if ($code -eq 0) {
            return [pscustomobject]@{ ok = $true; method = 'winget'; detail = "$name instalado con winget" }
        }
        # Codigo 0x8A150060 (no hay version) u otros: se reintenta sin --scope.
        if (-not $MachineScope) {
            $code2 = Invoke-DotfilesNativeLogged -Argv (@($script:WingetPath) + @(
                        'install', '--id', $id, '-e',
                        '--accept-package-agreements', '--accept-source-agreements',
                        '--disable-interactivity', '--silent')) -LogFile $wgLog -TimeoutSec 900
            if ($code2 -eq 0) {
                return [pscustomobject]@{ ok = $true; method = 'winget'; detail = "$name instalado con winget (machine)" }
            }
            $detail = "winget fallo para $id (exit $code2)"
        } else {
            $detail = "winget fallo para $id (exit $code)"
        }
    } elseif ($id) {
        $detail = "winget no disponible; se usara el fallback de $name"
    }

    if (Test-DotfilesKey -Map $Package -Key 'fallback') {
        $fb = Get-DotfilesFallback -Package $Package
        $bin = Add-DotfilesUserBin -Name $fb['name'] -Uri $fb['url'] -InnerPath $fb['inner'] -Sha256 $fb['sha256']
        if ($bin) {
            return [pscustomobject]@{ ok = $true; method = 'user-bin'; detail = "$name instalado en $bin" }
        }
        $detail += "; el fallback de $name tampoco funciono"
    }

    return [pscustomobject]@{ ok = $false; method = $method; detail = $detail }
}

# Add-DotfilesApp aplica la entrada de la seccion "apps" segun su metodo:
# npm (opencode), script oficial (herdr) o winget (fnm, oh-my-posh).
function Add-DotfilesApp {
    param(
        [Parameter(Mandatory)]$App,
        [switch]$DryRun
    )
    $name = if (Test-DotfilesKey -Map $App -Key 'key') { $App['key'] } else { $App['command'] }
    $method = if (Test-DotfilesKey -Map $App -Key 'method') { $App['method'] } else { 'winget' }

    if ($DryRun) {
        return [pscustomobject]@{ ok = $true; method = "dry-run:$method"; detail = "dry-run: $name" }
    }

    switch ($method) {
        'script' {
            return Add-DotfilesScript -Uri $App['url'] -DryRun:$DryRun
        }
        'npm' {
            if (-not (Get-Command 'npm' -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ ok = $false; method = 'npm'; detail = 'npm no esta disponible todavia' }
            }
            $code = Invoke-DotfilesLoggedArgv -Title "Instalando $name (npm)..." -Argv @('npm', 'install', '-g', $App['package'])
            if ($code -eq 0) {
                return [pscustomobject]@{ ok = $true; method = 'npm'; detail = "$name instalado con npm" }
            }
            if (Test-DotfilesKey -Map $App -Key 'fallback') {
                $fb = Get-DotfilesFallback -Package $App
                $bin = Add-DotfilesUserBin -Name $fb['name'] -Uri $fb['url'] -InnerPath $fb['inner'] -Sha256 $fb['sha256']
                if ($bin) {
                    return [pscustomobject]@{ ok = $true; method = 'user-bin'; detail = "$name instalado en $bin" }
                }
            }
            return [pscustomobject]@{ ok = $false; method = 'npm'; detail = "npm install -g fallo para $name (exit $code)" }
        }
        default {
            return Add-DotfilesPackage -Package $App -DryRun:$DryRun
        }
    }
}

# Add-DotfilesScript ejecuta un instalador oficial por URL (herdr).
function Add-DotfilesScript {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$DryRun
    )
    if ($DryRun) {
        return [pscustomobject]@{ ok = $true; detail = "dry-run: $Uri" }
    }
    $tmp = New-DotfilesTempDir -Prefix 'installer'
    try {
        $script = Join-Path $tmp 'installer.ps1'
        if (-not (Invoke-DotfilesDownload -Uri $Uri -OutFile $script -TimeoutSec 120)) {
            return [pscustomobject]@{ ok = $false; detail = "no se pudo descargar $Uri" }
        }
        # Ejecutar el instalador oficial requiere desbloquear la descarga; se
        # limita a este archivo concreto y se elimina al salir.
        $code = Invoke-DotfilesNative -Argv @(
            (Get-DotfilesSelfPwsh),
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script
        ) -TimeoutSec 600
        if ($code -ne 0) {
            return [pscustomobject]@{ ok = $false; detail = "el instalador de $Uri termino con codigo $code" }
        }
        return [pscustomobject]@{ ok = $true; detail = "instalador ejecutado: $Uri" }
    } finally {
        Remove-DotfilesTree -Path $tmp
    }
}

# Test-DotfilesPackageInstalled comprueba si la herramienta ya esta disponible
# (por comando resuelto o por winget list).
function Test-DotfilesPackageInstalled {
    param([Parameter(Mandatory)]$Package)
    $cmd = $Package['command']
    if ($cmd -and (Get-Command $cmd -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)) {
        return $true
    }
    # binario propio en ~/.config/enviroment-dotfiles/bin (fallback portatil).
    $paths = Get-DotfilesPaths
    if ($cmd) {
        $ext = if (Test-DotfilesWindows) { '.exe' } else { '' }
        foreach ($n in @(($cmd + $ext), $cmd)) {
            if (Test-Path -LiteralPath (Join-Path $paths.BinDir $n)) { return $true }
        }
    }
    return $false
}

Export-ModuleMember -Function *
