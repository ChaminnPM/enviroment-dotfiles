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
$script:WingetVersion = ''

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

# Test-DotfilesWingetVersion: la version de winget es utilizable (>= 1)?
#
# winget moderno imprime "v1.29.380" CON la 'v' (1.29); versiones antiguas
# "1.6.3482", y hay previews "1.29.380-preview". Un `-match '^\d+'` rechazaba
# todas las que empiezan por 'v': el instalador se creia sin winget, pasaba a
# los ZIP y dejaba python/node en aviso (fallo real en Windows 11 en espanol con
# winget v1.29.380 perfectamente funcional).
function Test-DotfilesWingetVersion {
    param([AllowEmptyString()][AllowNull()][string]$Version)
    if (-not $Version) { return $false }
    if ($Version -notmatch '(\d+)\.(\d+)') { return $false }
    return ([int]$Matches[1] -ge 1)
}

# Get-DotfilesWingetVersion: version cruda detectada ("v1.29.380"), para
# mostrarla en 'Requisitos del sistema' y en doctor.
function Get-DotfilesWingetVersion {
    $null = Test-DotfilesWinget
    return $script:WingetVersion
}

# Test-DotfilesWinget: hay un winget utilizable? cachea el resultado.
#
# WINGET_BIN permite forzar el binario (tests y CI), mismo patron que UI_BIN.
function Test-DotfilesWinget {
    param([switch]$Force)
    if ($script:WingetChecked -and -not $Force) { return $script:WingetAvailable }
    $script:WingetChecked = $true
    $script:WingetVersion = ''
    $script:WingetAvailable = $false
    $script:WingetPath = $null

    $cmd = $null
    if ($env:WINGET_BIN -and (Test-Path -LiteralPath $env:WINGET_BIN)) {
        $cmd = [pscustomobject]@{ Source = (Resolve-Path -LiteralPath $env:WINGET_BIN).Path }
    }
    if (-not $cmd) {
        # -First 1: puede haber dos winget (App Execution Alias de WindowsApps y
        # el de Program Files); .Source sobre el array devuelve un array y la
        # invocacion posterior se rompe.
        $cmd = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $cmd) { $cmd = Get-Command 'winget' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $cmd -or -not $cmd.Source) { return $false }

    $ver = ''
    try { $ver = "$(& $cmd.Source --version 2>$null | Select-Object -First 1)".Trim() } catch { $ver = '' }
    $script:WingetVersion = $ver
    if (-not $ver) {
        # Existe pero no dice su version (salida vacia o localizada rara). Se
        # intenta igualmente: si es demasiado viejo fallara al instalar y se usa
        # el fallback. Descartarlo aqui repetiria el falso negativo que dejo a
        # python/node sin instalar.
        Write-Verbose 'winget presente pero sin version legible; se intenta igualmente'
        $script:WingetAvailable = $true
    } elseif (Test-DotfilesWingetVersion -Version $ver) {
        $script:WingetAvailable = $true
    } else {
        Write-Verbose "winget $ver es anterior a 1.0; se usan los fallbacks pinnados"
    }
    $script:WingetPath = if ($script:WingetAvailable) { $cmd.Source } else { $null }
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
