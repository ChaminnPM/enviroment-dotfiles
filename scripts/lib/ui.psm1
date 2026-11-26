# ui.psm1 - capa de UI del instalador: nui (bubbletea), fallback textual,
# construccion del plan de pasos y reporte final.
#
# Es el equivalente PowerShell de scripts/lib/ui.sh. Respeta el contrato de
# docs/STEPS.md: mismo plan JSON, mismas directivas ##, mismos nombres de
# variables de entorno.
#
# Reglas del modulo:
#   - ningun dato del usuario se interpola en una cadena de shell: argv literal;
#   - los logs se crean 0600 dentro de un directorio 0700 (en Windows, ACL);
#   - nui se verifica con bin/SHA256SUMS antes de ejecutarse.

Set-StrictMode -Version 2.0

# Autodependencia: permite importar este modulo suelto en tests.
if (-not (Get-Command Get-DotfilesPaths -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'dotfiles.psm1') -Force -ErrorAction Stop
}

$script:ReportOk = @()
$script:ReportWarn = @()
$script:ReportErr = @()
$script:ReportInfo = @()
$script:LastLog = ''
$script:UiBinCache = $null

# --- estado basico ---------------------------------------------------------

function Initialize-DotfilesUi {
    param([hashtable]$Paths)
    foreach ($d in @($Paths.LogDir, $Paths.StateDir, $Paths.BackupDir, $Paths.BinDir)) {
        if ($d -and -not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
        if ($d) { [void](Set-DotfilesPrivateAcl -Path $d -Kind dir) }
    }
    # Autocomprobacion de ACL: si icacls no pudo quitar la herencia se avisa
    # UNA vez y con un mensaje util. Antes el sintoma eran decenas de lineas de
    # error de icacls y claves SSH que OpenSSH rechaza sin explicar por que.
    if (Test-DotfilesWindows) {
        $check = @($Paths.LogDir, $Paths.StateDir, $Paths.BackupDir, $Paths.BinDir) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if ($check) {
            $protected = $false
            try { $protected = (Get-Acl -LiteralPath $check).AreAccessRulesProtected } catch { $protected = $false }
            if (-not $protected) {
                Write-UiWarn "no se pudieron restringir los permisos de $check; las claves SSH y los logs quedan legibles por otros usuarios (revisa que icacls.exe funcione)"
            }
        }
    }
}

function Write-DotfilesReportEntry {
    param(
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'err', 'info')][string]$Kind,
        [Parameter(Mandatory)][string]$Text
    )
    switch ($Kind) {
        'ok' { $script:ReportOk += $Text }
        'warn' { $script:ReportWarn += $Text }
        'err' { $script:ReportErr += $Text }
        'info' { $script:ReportInfo += $Text }
    }
}

function Clear-DotfilesReport {
    $script:ReportOk = @(); $script:ReportWarn = @()
    $script:ReportErr = @(); $script:ReportInfo = @()
}

function Get-DotfilesReport {
    return [pscustomobject]@{
        ok   = @($script:ReportOk)
        warn = @($script:ReportWarn)
        err  = @($script:ReportErr)
        info = @($script:ReportInfo)
    }
}

# --- mensajes --------------------------------------------------------------

# Dentro de un paso (NUI_PANEL=1) los mensajes se emiten como directivas para
# que el panel los renderice; fuera, como texto ANSI.
function Write-DotfilesMessage {
    param(
        [Parameter(Mandatory)][ValidateSet('info', 'ok', 'warn', 'error', 'dim')][string]$Level,
        [Parameter(Mandatory)][string]$Text
    )
    $inPanel = ($env:NUI_PANEL -eq '1')
    switch ($Level) {
        'warn' {
            Write-DotfilesReportEntry -Kind warn -Text $Text
            if ($inPanel) { Write-Output ('##warn {0}' -f $Text) }
            else { Write-Host "[WARN] $Text" -ForegroundColor Yellow }
        }
        'error' {
            Write-DotfilesReportEntry -Kind err -Text $Text
            if ($inPanel) { Write-Output ('##warn {0}' -f $Text) }
            else { Write-Host "[ERROR] $Text" -ForegroundColor Red }
        }
        'ok' {
            if ($inPanel) { Write-Output ('##log {0}' -f $Text) }
            else { Write-Host "[OK] $Text" -ForegroundColor Green }
        }
        'dim' {
            if ($inPanel) { Write-Output ('##log {0}' -f $Text) }
            else { Write-Host $Text }
        }
        default {
            if ($inPanel) { Write-Output ('##log {0}' -f $Text) }
            else { Write-Host "[INFO] $Text" }
        }
    }
}

function Write-UiInfo { param([string]$Text) Write-DotfilesMessage -Level info -Text $Text }
function Write-UiOk { param([string]$Text) Write-DotfilesMessage -Level ok -Text $Text }
function Write-UiWarn { param([string]$Text) Write-DotfilesMessage -Level warn -Text $Text }
function Write-UiError { param([string]$Text) Write-DotfilesMessage -Level error -Text $Text }
function Write-UiDim { param([string]$Text) Write-DotfilesMessage -Level dim -Text $Text }

# Write-UiStepLog: linea limpia del paso actual (directiva ##log).
function Write-UiStepLog { param([string]$Text) Write-DotfilesMessage -Level info -Text $Text }

# --- nui -------------------------------------------------------------------

function Get-DotfilesUiArch {
    if (-not (Test-DotfilesWindows)) {
        # En POSIX el runner de bash ya elige la arquitectura; aqui solo se
        # usa para el fallback textual.
        return 'amd64'
    }
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        switch ("$arch") {
            'X64' { return 'amd64' }
            'Arm64' { return 'arm64' }
            'X86' { return 'amd64' }
        }
    } catch { }
    return 'amd64'
}

function Get-DotfilesUiBinaryName {
    param([string]$Arch)
    if (-not $Arch) { $Arch = Get-DotfilesUiArch }
    # El nombre sigue a la PLATAFORMA (incluido DOTFILES_PLATFORM_OVERRIDE), no
    # al runtime: con el override en 'windows' el arbol de rutas es el de
    # Windows y el archivo publicado es nui-windows-amd64.exe.gz. Mirar el
    # runtime daba 'nui-windows-amd64' (sin .exe), un nombre que no existe en
    # bin/: el instalador despreciaba el repo local y caia a la red con 404.
    $os = Get-DotfilesPlatform
    if ($os -eq 'wsl') { $os = 'linux' }
    if ($os -eq 'windows') { return "nui-windows-$Arch.exe" }
    return "nui-$os-$Arch"
}

# Get-DotfilesUiBin: ruta del nui utilisable, o $null.
function Get-DotfilesUiBin {
    # UI_BIN va ANTES de la cache: es un override explicito (lo usan los tests y
    # `Add-DotfilesUi`), y una cache de otra sesion de Pester no debe ganarle.
    if ($env:UI_BIN -and (Test-Path -LiteralPath $env:UI_BIN)) {
        $script:UiBinCache = $env:UI_BIN
        return $script:UiBinCache
    }
    if ($script:UiBinCache -and (Test-Path -LiteralPath $script:UiBinCache)) { return $script:UiBinCache }
    $paths = Get-DotfilesPaths
    $name = Get-DotfilesUiBinaryName
    $candidates = @(
        (Join-Path $paths.BinDir $name),
        (Join-Path $paths.BinDir 'nui'),
        (Join-Path $paths.BinDir 'nui.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            $script:UiBinCache = $c
            return $c
        }
    }
    $cmd = Get-Command 'nui', 'nui.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) {
        $script:UiBinCache = $cmd.Source
        return $script:UiBinCache
    }
    return $null
}

function Test-DotfilesUiHave { return [bool](Get-DotfilesUiBin) }

function Get-DotfilesUiVersion {
    param([string]$Bin)
    if (-not $Bin) { $Bin = Get-DotfilesUiBin }
    if (-not $Bin) { return '' }
    try {
        $out = & $Bin version 2>$null | Select-Object -First 1
        if ($out -and $out -match '(\d+\.\d+\.\d+[\w.-]*)') { return $Matches[1] }
    } catch { }
    return ''
}

# Test-DotfilesUiSupportsSteps: nui >= 0.2.0 trajo `steps run`; >= 0.3.0 es el
# primer plan con argv/shell (el formato que emite bootstrap.ps1).
function Test-DotfilesUiSupportsSteps {
    param([string]$Version)
    if (-not $Version) { $Version = Get-DotfilesUiVersion }
    if ($Version -notmatch '^(\d+)\.(\d+)') { return $false }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -gt 0) { return $true }
    return ($minor -ge 2)
}

# Add-DotfilesUi baja/actualiza nui y lo deja en ~/.config/enviroment-dotfiles/bin.
function Add-DotfilesUi {
    param([switch]$Force)

    $paths = Get-DotfilesPaths
    $bin = Join-Path $paths.BinDir (Get-DotfilesUiBinaryName)
    $want = if ($env:NUI_VERSION) { $env:NUI_VERSION } else { '' }
    if (-not $want -and $paths.RepoDir) {
        $vf = Join-DotfilesPath -Base $paths.RepoDir -Child 'bin/VERSION'
        if (Test-Path -LiteralPath $vf) { $want = (Get-Content -LiteralPath $vf -Raw).Trim() }
    }
    $have = ''
    if (Test-Path -LiteralPath $bin -PathType Leaf) { $have = Get-DotfilesUiVersion -Bin $bin }
    if (-not $Force -and $want -and $have -eq $want) { return $bin }
    if (-not $Force -and -not $want -and $have) { return $bin }

    if (-not (Test-Path -LiteralPath $paths.BinDir)) {
        New-Item -ItemType Directory -Force -Path $paths.BinDir | Out-Null
    }

    $base = if ($env:NUI_BASE_URL) { $env:NUI_BASE_URL } else { 'https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main' }
    $gzName = (Get-DotfilesUiBinaryName) + '.gz'
    $local = if ($paths.RepoDir) { Join-Path $paths.RepoDir "bin/$gzName" } else { $null }
    $localSums = if ($paths.RepoDir) { Join-DotfilesPath -Base $paths.RepoDir -Child 'bin/SHA256SUMS' } else { $null }

    $tmp = New-DotfilesTempDir -Prefix 'nui'
    try {
        $gz = Join-Path $tmp $gzName
        $sums = Join-Path $tmp 'SHA256SUMS'
        $fromRepo = $false

        if ($local -and (Test-Path -LiteralPath $local -PathType Leaf)) {
            Copy-Item -LiteralPath $local -Destination $gz -Force
            $fromRepo = $true
            if ($localSums -and (Test-Path -LiteralPath $localSums)) {
                Copy-Item -LiteralPath $localSums -Destination $sums -Force
            }
        } else {
            $suffix = if ($want) { " $want" } else { '' }
            Write-UiInfo "Instalando nui$suffix..."
            $url = "$base/bin/$gzName"
            if (-not (Invoke-DotfilesDownload -Uri $url -OutFile $gz -TimeoutSec 120)) {
                Write-UiError "No se pudo descargar nui desde $url"
                return $null
            }
            $null = Invoke-DotfilesDownload -Uri "$base/bin/SHA256SUMS" -OutFile $sums -TimeoutSec 60
        }

        $exe = Join-Path $tmp ([IO.Path]::GetFileNameWithoutExtension($gzName))
        try {
            Read-DotfilesGz -Source $gz -Destination $exe
        } catch {
            Write-UiError "No se pudo descomprimir nui: $($_.Exception.Message)"
            return $null
        }

        # Verificacion de integridad: nui se ejecuta con los privilegios del
        # usuario y el plan del instalador, asi que un binario adulterado no es
        # aceptable. Sin SHA256SUMS no se instala (mejor UI textual que nada).
        $expected = Get-DotfilesChecksumFor -SumsFile $sums -Name ([IO.Path]::GetFileName($exe))
        if ($expected) {
            if (-not (Test-DotfilesHash -Path $exe -Sha256 $expected)) {
                Write-UiError 'El checksum de nui no coincide con bin/SHA256SUMS'
                return $null
            }
        } elseif (-not $fromRepo) {
            Write-UiWarn 'Sin bin/SHA256SUMS: no se pudo verificar el binario descargado'
        }

        if (Test-DotfilesWindows) {
            try { Unblock-File -LiteralPath $exe -ErrorAction Stop } catch { }
        }
        [void](Set-DotfilesPrivateAcl -Path $exe)

        # Reemplazo: el binario puede estar en ejecucion (ETXTBSY en POSIX,
        #sharing violation en Windows). El truco universal es mover el viejo y
        # escribir el nuevo en su lugar.
        if (Test-Path -LiteralPath $bin) {
            $stale = "$bin.old-$(Get-DotfilesStamp)"
            try { Move-Item -LiteralPath $bin -Destination $stale -Force } catch { }
            Get-ChildItem -LiteralPath $paths.BinDir -Filter 'nui*.old-*' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne [IO.Path]::GetFileName($stale) } |
                ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { } }
        }
        Copy-Item -LiteralPath $exe -Destination $bin -Force
        if (-not (Test-DotfilesWindows)) {
            # En POSIX el modo ejecutable no lo da la ACL sino el bit x: sin
            # esto `& $bin version` falla y el panel se cree indisponible.
            try { & chmod 755 $bin 2>$null | Out-Null } catch { }
        }
        [void](Set-DotfilesPrivateAcl -Path $bin)
        Add-DotfilesEnvPath -Dir $paths.BinDir | Out-Null
        $script:UiBinCache = $bin
        Write-UiOk ("nui " + (Get-DotfilesUiVersion -Bin $bin) + " instalado")
        return $bin
    } finally {
        Remove-DotfilesTree -Path $tmp
    }
}

# Read-DotfilesGz descomprime un .gz (gzip sin multiple streams raros).
function Read-DotfilesGz {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $in = [System.IO.File]::OpenRead($Source)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $out = [System.IO.File]::Create($Destination)
            try { $gz.CopyTo($out) } finally { $out.Dispose() }
        } finally { $gz.Dispose() }
    } finally { $in.Dispose() }
}

function Get-DotfilesChecksumFor {
    param(
        [Parameter(Mandatory)][string]$SumsFile,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $SumsFile -PathType Leaf)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($SumsFile)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -ge 2) {
            $file = $parts[($parts.Count - 1)]
            if ($file -eq $Name -or $file -eq ("./" + $Name)) { return $parts[0].ToLowerInvariant() }
        }
    }
    return ''
}

# --- consola ---------------------------------------------------------------

function Test-DotfilesInteractive {
    if ($env:NUI_NONINTERACTIVE -eq '1') { return $false }
    if ($env:NUI_PLAIN -eq '1') { return $true }
    return [Environment]::UserInteractive
}

function Read-DotfilesConsoleLine {
    param(
        [string]$Prompt,
        [switch]$Secret
    )
    if ($env:NUI_NONINTERACTIVE -eq '1') { return '' }
    if ($Secret -and (Get-Command 'Read-Host' -ErrorAction SilentlyContinue)) {
        $sec = Read-Host -Prompt $Prompt -AsSecureString
        try {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        } catch { return '' }
    }
    return (Read-Host -Prompt $Prompt)
}

# Show-DotfilesClipboard copia stdin-like texto al portapapeles.
function Copy-DotfilesClipboard {
    param([Parameter(Mandatory)][string]$Text)
    if (-not $Text) { return $false }
    if (Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue) {
        try {
            Set-Clipboard -Value $Text
            return $true
        } catch { }
    }
    # OSC 52: el terminal copia por su cuenta (Windows Terminal lo admite).
    try {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
        $seq = [char]27 + "]52;c;$b64" + [char]7
        [Console]::Out.Write($seq)
        return $true
    } catch { }
    return $false
}

function Show-DotfilesUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        if (Test-DotfilesWindows) {
            Start-Process $Url | Out-Null
            return $true
        }
        if (Get-Command 'xdg-open' -ErrorAction SilentlyContinue) {
            Start-Process 'xdg-open' -ArgumentList $Url -WindowStyle Hidden | Out-Null
            return $true
        }
    } catch { }
    return $false
}

# --- known_hosts pinnado ---------------------------------------------------

# Update-DotfilesKnownHosts fusiona el pin del repo con el known_hosts del
# usuario. Nunca se hace ssh-keyscan en caliente: aceptaria un MITM.
function Update-DotfilesKnownHosts {
    $paths = Get-DotfilesPaths
    $src = Join-DotfilesPath -Base $paths.RepoDir -Child 'config/ssh/known_hosts'
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-UiError 'Falta el pin de host keys en config/ssh/known_hosts; no se hara ssh-keyscan'
        return $false
    }
    if (-not (Test-Path -LiteralPath $paths.SshDir)) {
        New-Item -ItemType Directory -Force -Path $paths.SshDir | Out-Null
    }
    [void](Set-DotfilesPrivateAcl -Path $paths.SshDir -Kind dir)

    $dest = Join-Path $paths.SshDir 'known_hosts'
    Backup-DotfilesFile -Path $dest | Out-Null

    # El orden importa: las claves pinnadas van primero ( StrictHostKeyChecking
    # usa la primera coincidencia), luego las propias del usuario.
    $lines = @()
    $lines += @(Get-Content -LiteralPath $src -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    if (Test-Path -LiteralPath $dest) {
        $lines += @(Get-Content -LiteralPath $dest -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    }
    $unique = @()
    $seen = @{}
    foreach ($l in $lines) {
        $k = $l.Trim()
        if (-not $k -or $seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $unique += $k
    }
    if ($unique.Count -eq 0) { return $false }
    try {
        Write-DotfilesFile -Path $dest -Content (($unique -join "`n") + "`n") -Encoding 'ascii' | Out-Null
        return $true
    } catch {
        Write-UiError "No se pudo escribir $dest"
        return $false
    }
}

# Test-DotfilesSsh ejecuta `ssh -T <target>` y decide por mensaje.
# GitHub/Bitbucket devuelven exit != 0 incluso autenticando bien.
function Test-DotfilesSsh {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Target,
        [string]$KnownHosts
    )
    $paths = Get-DotfilesPaths
    if (-not $KnownHosts) { $KnownHosts = Join-DotfilesPath -Base $paths.RepoDir -Child 'config/ssh/known_hosts' }
    if (-not (Test-Path -LiteralPath $KnownHosts)) {
        Write-UiWarn 'Falta config/ssh/known_hosts pinnado; no se aceptaran hosts nuevos'
    }
    $log = New-DotfilesStepLog -Label 'ssh'
    $code = Invoke-DotfilesNative -Argv @(
        'ssh', '-T',
        '-o', "UserKnownHostsFile=$KnownHosts",
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        $Target
    )
    $text = ''
    if ($log -and (Test-Path -LiteralPath $log)) { $text = Get-DotfilesFileText -Path $log }
    if ($text -match '(?i)successfully authenticated|authenticated via ssh key|logged in as') {
        Write-UiStepLog "$Title OK"
        return $true
    }
    Write-UiStepLog "$Title falla (revisa que la clave este agregada)"
    return $false
}

# --- ejecucion con log y spinner -------------------------------------------

$script:LogCounter = 0

# Get-DotfilesLastLog: ruta del ultimo log de Invoke-DotfilesLoggedArgv.
# Los tests y el doctor la usan en vez de adivinar por marca de tiempo.
function Get-DotfilesLastLog { return $script:LastLog }

function New-DotfilesStepLog {
    param([string]$Label = 'cmd')
    $paths = Get-DotfilesPaths
    $script:LogCounter++
    $dir = if ($env:LOG_DIR) { $env:LOG_DIR } else { $paths.LogDir }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir ("{0}-{1}-{2}-{3}.log" -f $Label, (Get-DotfilesStamp), $PID, $script:LogCounter))
}

# Invoke-DotfilesLoggedArgv: ejecuta argv capturando stdout+stderr en un log,
# con spinner de nui si esta disponible. Devuelve el codigo real.
#
# El log se limita al final (LOG_KEEP_LINES) para que un paso largo no crezca
# sin limite; LOG_KEEP_ALL=1 lo conserva entero.
function Invoke-DotfilesLoggedArgv {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][object[]]$Argv,
        [int]$TimeoutSec = 0,
        [string]$WorkingDirectory
    )
    if ($Argv.Count -lt 1) { throw 'Invoke-DotfilesLoggedArgv: falta el comando' }
    $log = New-DotfilesStepLog -Label 'argv'
    $script:LastLog = $log
    $ui = Get-DotfilesUiBin
    $code = 0

    if ($ui -and [Environment]::UserInteractive -and ($env:VERBOSE -ne '1')) {
        # El spinner de nui muestra el titulo mientras el comando corre con su
        # salida capturada en el log del paso.
        $code = Invoke-DotfilesNativeLogged -Argv (@($ui, 'spin', '--title', $Title, '--') + $Argv) `
            -LogFile $log -TimeoutSec $TimeoutSec -WorkingDirectory $WorkingDirectory
    } else {
        Write-UiDim "$Title ..."
        $code = Invoke-DotfilesNativeLogged -Argv $Argv -LogFile $log -TimeoutSec $TimeoutSec -WorkingDirectory $WorkingDirectory
        $text = ''
        if (Test-Path -LiteralPath $log) { $text = Get-DotfilesFileText -Path $log }
        if ($text) { Write-Output $text }
    }

    Write-DotfilesCapLog -Path $log
    if ($code -ne 0) {
        Write-UiError "$Title (exit $code)"
        Show-DotfilesLogTail -Path $log -Lines 15
    }
    return $code
}

# Version con redireccion interna: Invoke-DotfilesNative no la soporta, asi
# que se implementa aqui con ProcessStartInfo para capturar ambos flujos.
function Invoke-DotfilesNativeLogged {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][object[]]$Argv,
        [Parameter(Mandatory)][string]$LogFile,
        [int]$TimeoutSec = 0,
        # Directorio de trabajo del hijo. npm lo necesita: `npm install
        # --prefix <dir>` sigue leyendo el package.json del CWD, asi que desde
        # C:\Users\X falla con ENOENT (comprobado con npm 10.9.8). Se lanza npm
        # CON cwd en el proyecto y sin --prefix.
        [string]$WorkingDirectory
    )
    $Argv = Get-DotfilesExecArgv -Argv (ConvertTo-DotfilesArgv -Values $Argv)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Argv[0]
    for ($i = 1; $i -lt $Argv.Count; $i++) {
        if ($psi.Arguments) { $psi.Arguments += ' ' }
        $psi.Arguments += ('"' + ($Argv[$i] -replace '"', '\"') + '"')
    }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outT = $p.StandardOutput.ReadToEndAsync()
    $errT = $p.StandardError.ReadToEndAsync()
    $finished = $true
    if ($TimeoutSec -gt 0) {
        $finished = $p.WaitForExit($TimeoutSec * 1000)
    } else {
        $p.WaitForExit()
    }
    if (-not $finished) {
        try {
            if (Test-DotfilesWindows) {
                & taskkill.exe '/T' '/F' '/PID' $p.Id 2>$null | Out-Null
            }
            $p.Kill()
        } catch { }
        $code = 124
    } else {
        $code = $p.ExitCode
    }
    $text = @()
    try { $text += $outT.Result } catch { }
    try { $text += $errT.Result } catch { }
    [System.IO.File]::WriteAllText($LogFile, ($text -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    [void](Set-DotfilesPrivateAcl -Path $LogFile)
    try { $p.Dispose() } catch { }
    return $code
}

function Write-DotfilesCapLog {
    param([Parameter(Mandatory)][string]$Path)
    if ($env:LOG_KEEP_ALL -eq '1') { return }
    $keep = 500
    if ($env:LOG_KEEP_LINES -and $env:LOG_KEEP_LINES -match '^\d+$' -and [int]$env:LOG_KEEP_LINES -gt 0) {
        $keep = [int]$env:LOG_KEEP_LINES
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    if ($lines.Count -le $keep) { return }
    $tail = $lines[($lines.Count - $keep)..($lines.Count - 1)]
    [System.IO.File]::WriteAllText($Path, (($tail -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Show-DotfilesLogTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Lines = 15
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-UiDim "(sin log en $Path)"
        return
    }
    $all = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return }
    $take = [Math]::Min($Lines, $all.Count)
    foreach ($l in $all[-$take..-1]) { Write-UiDim "  $l" }
    Write-UiDim "  log: $Path"
}

# --- plan de pasos ----------------------------------------------------------

# New-DotfilesPanel crea el contexto. Todos los Add-* reciben y devuelven el
# mismo objeto para que bootstrap.ps1 sea un flujo lineal legible.
function New-DotfilesPanel {
    param([string]$Title = 'AGENTS ENVIRONMENT')
    return [pscustomobject]@{
        Title        = $Title
        Notes        = @()
        Steps        = @()
        PendingInput = [ordered]@{ fields = @(); text = '' }
        Dir          = $null
        StateDir     = $null
    }
}

function Add-DotfilesPanelNote {
    param(
        [Parameter(Mandatory)]$Panel,
        [Parameter(Mandatory)][string]$Text
    )
    $Panel.Notes += $Text
    return $Panel
}

# Add-DotfilesPanelInput declara un campo del formulario del SIGUIENTE paso
# (mismo modelo que ui_panel_inputs + ui_panel_step de ui.sh).
function Add-DotfilesPanelInput {
    param(
        [Parameter(Mandatory)]$Panel,
        [Parameter(Mandatory)][ValidateSet('input', 'password', 'confirm', 'select', 'key')][string]$Type,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        $Default,
        [string[]]$Options,
        [switch]$Multi,
        [string]$Path,
        [object[]]$ShowIf
    )
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "nombre de input invalido: $Name"
    }
    $def = ''
    if ($Default -is [array]) { $def = ($Default -join ' ') }
    elseif ($null -ne $Default) { $def = [string]$Default }

    $Panel.PendingInput.fields += [ordered]@{
        type    = $Type
        name    = $Name
        prompt  = $Prompt
        default = $def
        options = @($Options)
        multi   = [bool]$Multi
        path    = $Path
        show_if = @($ShowIf)
    }
    return $Panel
}

# Add-DotfilesPanelInputDsl parsea el DSL de texto del instalador bash:
#
#   input  <nombre> <prompt...>
#   select <nombre> <prompt...> [many]
#   confirm<nombre> <prompt...> [s|n]
#   key    <nombre> <ruta> <prompt...>
#   option <nombre> <valor>
#   default<nombre> <valor>
#   showif <nombre> <campo> <op> [valor]
#
# Sirve para que bootstrap.ps1 pueda reutilizar literalmente los formularios
# ya definidos en bootstrap.sh sin reescribirlos.
function Add-DotfilesPanelInputDsl {
    param(
        [Parameter(Mandatory)]$Panel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $byName = @{}

    function New-Field {
        param([string]$Type, [string]$Name, [string]$Prompt)
        return [ordered]@{
            type = $Type; name = $Name; prompt = $Prompt; default = ''
            options = @(); multi = $false; path = ''; show_if = @()
        }
    }

    foreach ($line in ($Text -split "`n")) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $kind = ($t -split '\s+', 2)[0]
        $rest = if ($t.Length -gt $kind.Length) { ($t.Substring($kind.Length)).Trim() } else { '' }

        switch ($kind) {
            { $_ -in 'input', 'password', 'confirm', 'select' } {
                $name = ($rest -split '\s+', 2)[0]
                $prompt = if ($rest.Length -gt $name.Length) { $rest.Substring($name.Length).Trim() } else { '' }
                $field = New-Field -Type $kind -Name $name -Prompt $prompt
                if ($kind -eq 'select' -and $prompt -match '\s+many$') {
                    $field['multi'] = $true
                    $field['prompt'] = ($prompt -replace '\s+many$', '')
                }
                if ($kind -eq 'confirm') {
                    $last = ($prompt -split '\s+')[-1]
                    if ($last -match '^(?i)(s|S|si|y|yes|true)$') {
                        $field['default'] = 'true'
                        $field['prompt'] = ($prompt -replace '\s+\S$', '')
                    } elseif ($last -match '^(?i)(n|no|false)$') {
                        $field['default'] = 'false'
                        $field['prompt'] = ($prompt -replace '\s+\S$', '')
                    }
                }
                $Panel.PendingInput.fields += $field
                $byName[$name] = $field
            }
            'key' {
                $name = ($rest -split '\s+', 2)[0]
                $after = if ($rest.Length -gt $name.Length) { $rest.Substring($name.Length).Trim() } else { '' }
                $path = ($after -split '\s+', 2)[0]
                $prompt = if ($after.Length -gt $path.Length) { $after.Substring($path.Length).Trim() } else { '' }
                $field = New-Field -Type 'key' -Name $name -Prompt $prompt
                $field['path'] = $path
                $Panel.PendingInput.fields += $field
                $byName[$name] = $field
            }
            'option' {
                $name = ($rest -split '\s+', 2)[0]
                $val = if ($rest.Length -gt $name.Length) { $rest.Substring($name.Length).Trim() } else { '' }
                if ($byName.ContainsKey($name)) { $byName[$name]['options'] += $val }
            }
            'default' {
                $name = ($rest -split '\s+', 2)[0]
                $val = if ($rest.Length -gt $name.Length) { $rest.Substring($name.Length).Trim() } else { '' }
                if ($byName.ContainsKey($name)) { $byName[$name]['default'] = $val }
            }
            'showif' {
                $toks = $rest -split '\s+'
                if ($toks.Count -lt 3) { throw "showif incompleto: $t" }
                $name = $toks[0]
                if (-not $byName.ContainsKey($name)) { throw "showif sin campo previo: $name" }
                $value = if ($toks.Count -gt 3) { ($toks[3..($toks.Count - 1)] -join ' ') } else { '' }
                $byName[$name]['show_if'] += [ordered]@{ field = $toks[1]; op = $toks[2]; value = $value }
            }
            default { throw "DSL de inputs no reconocido: $kind" }
        }
    }
    return $Panel
}

# Add-DotfilesPanelStep registra un paso con su cuerpo (scriptblock o texto).
#
# El cuerpo se materializa en step-NN.ps1 dentro del directorio del panel con
# un preambulo comun: estrict-mode, modulos del proyecto, env persistido y las
# variables del formulario ya declaradas. Asi el paso puede usar `$extras` sin
# tener que sourcear NUI_STEP_RESULT a mano.
function Add-DotfilesPanelStep {
    param(
        [Parameter(Mandatory)]$Panel,
        [Parameter(Mandatory)][string]$Title,
        [ScriptBlock]$Body,
        [string]$BodyText,
        [int]$Estimate = 0,
        [switch]$Optional,
        [switch]$Interactive,
        [string]$StepFile
    )
    # --only filtra por titulo sin distinguir mayusculas ni acentos.
    if ($env:NUI_ONLY -and -not (Test-DotfilesTitleMatch -Title $Title -Filter $env:NUI_ONLY)) {
        return $Panel
    }
    $text = if ($Body) { $Body.ToString() } elseif ($BodyText) { $BodyText } else { '' }
    if (-not $text.Trim() -and -not $StepFile) {
        throw "paso '$Title' sin cuerpo"
    }
    if (-not $Panel.Dir) {
        $Panel.Dir = New-DotfilesTempDir -Prefix 'nui-steps'
        $Panel.StateDir = New-DotfilesTempDir -Prefix 'nui-steps-state'
    }

    $n = $Panel.Steps.Count + 1
    $path = Join-Path $Panel.Dir ("step-{0:d2}.ps1" -f $n)
    $fields = @($Panel.PendingInput.fields)
    $Panel.PendingInput.fields = @()

    if ($StepFile) {
        Copy-Item -LiteralPath $StepFile -Destination $path -Force
        $script = Get-DotfilesFileText -Path $path
        [System.IO.File]::WriteAllText($path, (Get-DotfilesStepPreamble -Fields $fields) + $script, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        [System.IO.File]::WriteAllText($path, (Get-DotfilesStepPreamble -Fields $fields) + $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }

    $pwsh = Get-DotfilesSelfPwsh
    $argv = @($pwsh, '-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (-not $Interactive) { $argv += '-NonInteractive' }
    $argv += @('-File', $path)

    $Panel.Steps += [ordered]@{
        title       = $Title
        cmd         = "`"$pwsh`" -NoProfile -File `"$path`""
        argv        = $argv
        optional    = [bool]$Optional
        interactive = [bool]$Interactive
        estimate    = $Estimate
        inputs      = @($fields)
    }
    return $Panel
}

function Get-DotfilesStepPreamble {
    param([array]$Fields)
    $lib = if ($env:DOTFILES_LIB) { $env:DOTFILES_LIB } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'lib' }
    $lines = @(
        '# preambulo generado por el panel: no editar',
        "`$ErrorActionPreference = 'Stop'",
        'Set-StrictMode -Version 2.0',
        "`$env:NUI_PANEL = '1'",
        "`$env:DOTFILES_LIB = '$lib'",
        "Import-Module (Join-Path `$env:DOTFILES_LIB 'dotfiles.psm1') -Force",
        "Import-Module (Join-Path `$env:DOTFILES_LIB 'packages.psm1') -Force",
        "Import-Module (Join-Path `$env:DOTFILES_LIB 'theme.psm1') -Force",
        "Import-Module (Join-Path `$env:DOTFILES_LIB 'update-skills.psm1') -Force",
        "Import-Module (Join-Path `$env:DOTFILES_LIB 'ui.psm1') -Force",
        "if (`$env:NUI_ENV_FILE -and (Test-Path -LiteralPath `$env:NUI_ENV_FILE)) { . `$env:NUI_ENV_FILE }"
    )
    # Los campos del formulario se declaran antes de dot-sourcing del resultado
    # para que StrictMode no reviente cuando un paso no tiene seleccion.
    foreach ($f in $Fields) {
        $lines += ('${0} = $null' -f $f['name'])
    }
    if ($Fields.Count -gt 0) {
        $lines += "if (`$env:NUI_STEP_RESULT -and (Test-Path -LiteralPath `$env:NUI_STEP_RESULT)) { . `$env:NUI_STEP_RESULT }"
    }
    $lines += ''
    return (($lines -join "`n") + "`n")
}

# ConvertTo-DotfilesPlanJson serializa el plan en el formato de docs/STEPS.md.
function ConvertTo-DotfilesPlanJson {
    param([Parameter(Mandatory)]$Panel)
    $plan = [ordered]@{
        title = $Panel.Title
        shell = 'pwsh'
        notes = @($Panel.Notes)
        steps = @($Panel.Steps | ForEach-Object {
                $inputs = @($_['inputs'] | ForEach-Object {
                        $i = [ordered]@{
                            type    = $_['type']
                            name    = $_['name']
                            prompt  = $_['prompt']
                            default = $_['default']
                        }
                        if ($_['type'] -eq 'key') { $i['path'] = $_['path'] }
                        if ($_['type'] -eq 'select') {
                            $i['options'] = @($_['options'])
                            $i['multi'] = [bool]$_['multi']
                        }
                        $conds = @($_['show_if'] | Where-Object { $_ } | ForEach-Object {
                                $c = [ordered]@{ field = $_['field']; op = $_['op'] }
                                if ($_.value) { $c['value'] = $_['value'] }
                                $c
                            })
                        if ($conds.Count -gt 0) { $i['show_if'] = $conds }
                        $i
                    })
                [ordered]@{
                    title       = $_['title']
                    cmd         = $_['cmd']
                    argv        = @($_['argv'])
                    optional    = [bool]$_['optional']
                    interactive = [bool]$_['interactive']
                    estimate    = [int]$_['estimate']
                    inputs      = $inputs
                }
            })
    }
    return (ConvertTo-Json -InputObject $plan -Depth 12) + "`n"
}

function Get-DotfilesInputVisible {
    param(
        [Parameter(Mandatory)]$Field,
        [Parameter(Mandatory)][hashtable]$Answers
    )
    foreach ($c in @($Field['show_if'])) {
        if (-not $c) { continue }
        $cur = if ($Answers.ContainsKey($c['field'])) { [string]$Answers[$c['field']] } else { '' }
        $want = [string]$c['value']
        switch ($c['op']) {
            'eq' { if ($cur -ne $want) { return $false } }
            'ne' { if ($cur -eq $want) { return $false } }
            'nonempty' { if (-not $cur) { return $false } }
            'empty' { if ($cur) { return $false } }
            { $_ -in 'gt', 'gte', 'lt', 'lte' } {
                $cn = 0; $wn = 0
                if (-not [int]::TryParse($cur.Trim(), [ref]$cn)) { return $false }
                if (-not [int]::TryParse($want.Trim(), [ref]$wn)) { return $false }
                switch ($c['op']) {
                    'gt' { if (-not ($cn -gt $wn)) { return $false } }
                    'gte' { if (-not ($cn -ge $wn)) { return $false } }
                    'lt' { if (-not ($cn -lt $wn)) { return $false } }
                    'lte' { if (-not ($cn -le $wn)) { return $false } }
                }
            }
            default { return $false }
        }
    }
    return $true
}

function Get-DotfilesSelectAnswer {
    param(
        [Parameter(Mandatory)]$Field,
        [Parameter(Mandatory)][string]$Raw
    )
    $options = @($Field['options'])
    $picked = @()
    foreach ($tok in ($Raw -split '[\s,]+' | Where-Object { $_ })) {
        $n = 0
        if (-not [int]::TryParse($tok.Trim(), [ref]$n)) { continue }
        if ($n -ge 1 -and $n -le $options.Count) { $picked += $options[$n - 1] }
        if (-not $Field['multi']) { break }
    }
    if ($picked.Count -eq 0 -and $Field['default']) {
        foreach ($w in ($Field['default'] -split '\s+')) {
            if ($options -contains $w) { $picked += $w }
        }
    }
    return $picked
}

# Get-DotfilesResultLine serializa un campo del formulario en el formato del
# interprete del plan (docs/STEPS.md). Es la copia exacta de lo que hace nui
# (ui/plan_test.go) para que bash y PowerShell escriban lo mismo.
function Get-DotfilesResultLine {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Value,
        [ValidateSet('ps1', 'env')][string]$Ext = 'ps1'
    )
    if ($null -eq $Value) { $Value = '' }
    if ($Ext -eq 'ps1') {
        return "`$$Name = '" + ($Value.Replace("'", "''")) + "'"
    }
    return "$Name='" + ($Value.Replace("'", "'\''")) + "'"
}

# Invoke-DotfilesPanelRun ejecuta el plan.
#
# Ruta preferida: `nui steps run` (panel burbuja). Si nui no esta, la terminal
# no es interactiva o se pidio --plain/--non-interactive, se cae al runner
# textual, que comparte el mismo contrato de directivas.
function Invoke-DotfilesPanelRun {
    param(
        [Parameter(Mandatory)]$Panel,
        [switch]$Plain,
        [switch]$DryRun,
        [switch]$NonInteractive,
        [string]$LogDir
    )
    if ($Panel.Steps.Count -eq 0) {
        Write-UiError 'No hay pasos para ejecutar'
        return 1
    }
    if (-not $Panel.Dir) {
        $Panel.Dir = New-DotfilesTempDir -Prefix 'nui-steps'
        $Panel.StateDir = New-DotfilesTempDir -Prefix 'nui-steps-state'
    }
    if (-not $LogDir) { $LogDir = (Get-DotfilesPaths).LogDir }

    $json = ConvertTo-DotfilesPlanJson -Panel $Panel
    $planPath = Join-Path $Panel.Dir 'plan.json'
    [System.IO.File]::WriteAllText($planPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    $env:NUI_STATE_DIR = $Panel.StateDir
    $env:NUI_ENV_FILE = (Get-DotfilesEnvFilePath)

    try {
        if ($DryRun -or $env:NUI_DRY_RUN -eq '1') {
            Write-Host '== DRY RUN: no se ejecutara nada =='
            # Escrito a stdout sin pasar por el pipeline: quien llama hace
            # `$rc = Invoke-DotfilesPanelRun` y el JSON no puede contaminar el
            # codigo de retorno.
            [Console]::Out.Write($json)
            return 0
        }

        $ui = Get-DotfilesUiBin
        $usePanel = (-not $Plain) -and ($env:NUI_PLAIN -ne '1') -and
        (-not $NonInteractive) -and ($env:NUI_NONINTERACTIVE -ne '1') -and
        ($env:VERBOSE -ne '1') -and $ui -and
        (Test-DotfilesUiSupportsSteps -Version (Get-DotfilesUiVersion -Bin $ui)) -and
        [Environment]::UserInteractive

        if ($usePanel) {
            # La TUI necesita la consola cruda: cualquier reemision linea a
            # linea romperia los controles de alt-screen de bubbletea. Por eso
            # se lanza adjunta a la consola del padre (-AttachConsole): con
            # CreateNoWindow el hijo no ve la consola, cae al modo texto y sus
            # errores se pierden.
            $before = @(Get-ChildItem -LiteralPath $LogDir -Filter 'steps-*' -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name)
            $code = Invoke-DotfilesNativeQuoted -AttachConsole -Argv @(
                $ui, 'steps', 'run',
                '--plan', $planPath,
                '--log-dir', $LogDir,
                '--title', $Panel.Title
            )
            # Prueba de vida: nui crea un steps-<stamp>-NN.log por paso ejecutado.
            # Si no creo ninguno, el panel NO hizo nada (consola no disponible,
            # panic, plan rechazado) -- y eso incluye el codigo 0, que es el
            # sintoma real que se vio en maquina: "[OK] nui instalado" y vuelta al
            # prompt sin un solo paso. Se cae al runner de texto, que es lento pero
            # habla.
            $after = @(Get-ChildItem -LiteralPath $LogDir -Filter 'steps-*' -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name)
            $ranAny = @($after | Where-Object { $before -notcontains $_ }).Count -gt 0
            if (-not $ranAny) {
                Write-UiWarn "el panel no ejecuto ningun paso (codigo $code); se continua en modo texto"
                return (Invoke-DotfilesPanelPlain -Panel $Panel -PlanPath $planPath -LogDir $LogDir)
            }
            if ($code -ne 0) {
                # Los pasos corrieron: solo se informa del codigo, reejecutar en
                # texto duplicaria trabajo ya hecho.
                Write-UiWarn "el panel termino con codigo $code; revisa los logs en $LogDir"
            }
            return $code
        }
        return (Invoke-DotfilesPanelPlain -Panel $Panel -PlanPath $planPath -LogDir $LogDir)
    } finally {
        Remove-DotfilesTree -Path $Panel.Dir
        Remove-DotfilesTree -Path $Panel.StateDir
        $env:NUI_STATE_DIR = $null
        Clear-DotfilesRunMarker
    }
}

# Invoke-DotfilesPanelPlain es el runner de texto: same directives, same
# result files, sin bubbletea. Se usa en CI, --verbose y --non-interactive.
function Invoke-DotfilesPanelPlain {
    param(
        [Parameter(Mandatory)]$Panel,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$LogDir
    )
    Clear-DotfilesReport
    $plan = Read-DotfilesJson -Path $PlanPath -AsHashtable
    $total = @($plan['steps']).Count
    $i = 0
    $start = Get-Date

    foreach ($step in @($plan['steps'])) {
        $i++
        $title = $step['title']
        Write-Host ''
        Write-Host ("== [{0}/{1}] {2} ==" -f $i, $total, $title) -ForegroundColor White

        $inputs = @($step['inputs'])
        $resultFile = Join-Path $Panel.StateDir ("result-{0:d2}.ps1" -f $i)
        if ($inputs.Count -gt 0) {
            $answers = @{}
            $lines = @()
            foreach ($f in $inputs) {
                $visible = Get-DotfilesInputVisible -Field $f -Answers $answers
                $val = ''
                if (-not $visible) {
                    $answers[$f['name']] = ''
                } else {
                    $val = (Read-DotfilesPlainField -Field $f)
                    $answers[$f['name']] = $val
                }
                $lines += (Get-DotfilesResultLine -Name $f['name'] -Value $val -Ext 'ps1')
            }
            [System.IO.File]::WriteAllText($resultFile, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            [void](Set-DotfilesPrivateAcl -Path $resultFile)
        }
        $env:NUI_STEP_RESULT = if ($inputs.Count -gt 0) { $resultFile } else { $null }
        $env:NUI_PLAIN = '1'

        $argv = @($step['argv'])
        if ($step['interactive'] -and $env:NUI_NONINTERACTIVE -eq '1') {
            Write-DotfilesReportEntry -Kind warn -Text "$title : interactivo omitido (modo no interactivo)"
            Write-Host '[WARN] paso interactivo omitido en modo no interactivo' -ForegroundColor Yellow
            continue
        }

        $log = Join-Path $LogDir ("steps-{0}-{1:d2}.log" -f (Get-DotfilesStamp), $i)
        $warned = $false
        if ($step['interactive']) {
            # Paso interactivo: hereda la consola (la salida NO se captura).
            # -AttachConsole es imprescindible: sin el, el hijo arranca sin
            # consola y cualquier prompt o `Read-Host` falla al instante.
            $code = Invoke-DotfilesNativeQuoted -AttachConsole -Argv $argv
        } else {
            $code = Invoke-DotfilesNativeLogged -Argv $argv -LogFile $log
            $text = ''
            if (Test-Path -LiteralPath $log) { $text = Get-DotfilesFileText -Path $log }
            foreach ($line in ($text -split "`n")) {
                if (-not $line) { continue }
                if ($line -match '^##warn\s+(.*)$') {
                    $warned = $true
                    Write-Host "[WARN] $($Matches[1])" -ForegroundColor Yellow
                } elseif ($line -match '^##(log|title|progress)\s') {
                    if ($line -match '^##log\s+(.*)$') { Write-Host $Matches[1] }
                } elseif ($line -match '^##confirm\s+\S+\s+(.*)$') {
                    Write-Host "[CONFIRMAR] $($Matches[1])" -ForegroundColor Cyan
                } else {
                    Write-Host $line
                }
            }
            Write-DotfilesCapLog -Path $log
        }

        if ($code -eq 0) {
            if ($warned) { Write-DotfilesReportEntry -Kind warn -Text $title }
            else { Write-DotfilesReportEntry -Kind ok -Text $title }
            continue
        }
        if ($step['optional']) {
            Write-DotfilesReportEntry -Kind warn -Text "$title : fallo (opcional)"
            continue
        }
        Write-DotfilesReportEntry -Kind err -Text "$title : exit $code"
        break
    }

    foreach ($note in @($plan['notes'])) { Write-DotfilesReportEntry -Kind info -Text $note }
    Write-DotfilesReportEntry -Kind info -Text "Duracion: $([int]((Get-Date) - $start).TotalSeconds)s"
    Write-DotfilesReportEntry -Kind info -Text "Logs: $LogDir"
    $env:NUI_PLAIN = '0'
    Write-DotfilesFinalReport
    $r = Get-DotfilesReport
    return $(if ($r.err.Count -gt 0) { 1 } else { 0 })
}

function Read-DotfilesPlainField {
    param([Parameter(Mandatory)]$Field)
    $name = $Field['name']
    $prompt = $Field['prompt']
    $default = $Field['default']

    if ($env:NUI_NONINTERACTIVE -eq '1') { return $default }

    switch ($Field['type']) {
        'input' {
            $label = if ($default) { "$prompt [$default]" } else { $prompt }
            $v = Read-DotfilesConsoleLine -Prompt $label
            if (-not $v) { return $default }
            return $v
        }
        'password' {
            $v = Read-DotfilesConsoleLine -Prompt $prompt -Secret
            if (-not $v) { return $default }
            return $v
        }
        'confirm' {
            $yes = ($default -eq 'true')
            $hint = if ($yes) { 's/n' } else { 's/n (n)' }
            $v = (Read-DotfilesConsoleLine -Prompt "$prompt [$hint]").Trim().ToLowerInvariant()
            if (-not $v) { return $default }
            if ($v -in 's', 'si', 'y', 'yes', 'true') { return 'true' }
            return 'false'
        }
        'key' {
            Write-Host ''
            Write-Host $prompt
            if ($Field['path'] -and (Test-Path -LiteralPath $Field['path'] -PathType Leaf)) {
                Get-Content -LiteralPath $Field['path'] | ForEach-Object { Write-Host $_ }
            } else {
                Write-Host '(clave no generada todavia)'
            }
            $null = Read-DotfilesConsoleLine -Prompt 'Pulsa enter para continuar'
            return ''
        }
        'select' {
            Write-Host ''
            Write-Host $prompt
            $opts = @($Field['options'])
            for ($j = 0; $j -lt $opts.Count; $j++) {
                Write-Host ("  {0,2}) {1}" -f ($j + 1), $opts[$j])
            }
            $hint = if ($Field['multi']) { 'numeros separados por espacio' } else { 'numero' }
            $v = Read-DotfilesConsoleLine -Prompt "Seleccion ($hint)"
            return (Get-DotfilesSelectAnswer -Field $Field -Raw $v) -join "`n"
        }
    }
    return $default
}

function Write-DotfilesFinalReport {
    $r = Get-DotfilesReport
    Write-Host ''
    Write-Host '== REPORTE FINAL ==' -ForegroundColor White
    foreach ($x in $r.ok) { Write-Host "  [OK]   $x" -ForegroundColor Green }
    foreach ($x in $r.warn) { Write-Host "  [WARN] $x" -ForegroundColor Yellow }
    foreach ($x in $r.err) { Write-Host "  [ERR]  $x" -ForegroundColor Red }
    foreach ($x in $r.info) { Write-Host "  $x" }
}

# Wait-DotfilesPanelConfirm: espera la respuesta del panel a un ##confirm.
function Wait-DotfilesPanelConfirm {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Question
    )
    if ($env:NUI_NONINTERACTIVE -eq '1') { return $false }
    $safe = ($Id -replace '[^A-Za-z0-9_.-]', '')
    if (-not $safe) { $safe = 'key' }

    $stateDir = $env:NUI_STATE_DIR
    if ($env:NUI_PLAIN -eq '1' -or -not $stateDir -or -not (Test-Path -LiteralPath $stateDir)) {
        $a = Read-DotfilesConsoleLine -Prompt "$Question [s/N]"
        return ($a -match '^(?i)(s|si|y|yes)')
    }

    $answer = Join-Path $stateDir ("confirm-{0}.env" -f $safe)
    if (Test-Path -LiteralPath $answer) { Remove-Item -LiteralPath $answer -Force -ErrorAction SilentlyContinue }
    Write-Output ('##confirm {0} {1}' -f $safe, $Question)

    # 5 min max: si el panel se cancelo, el runner mata el paso; este limite
    # evita colgar el instalador ante un panel perdido.
    for ($i = 0; $i -lt 600; $i++) {
        if (Test-Path -LiteralPath $answer) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $answer)) { return $false }
    $txt = Get-DotfilesFileText -Path $answer
    return ($txt -match 'NUI_CONFIRM_ANSWER=true')
}

Export-ModuleMember -Function *
