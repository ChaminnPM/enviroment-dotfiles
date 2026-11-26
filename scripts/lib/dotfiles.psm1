# dotfiles.psm1 - utilidades para modificar el entorno del usuario sin destruir
# configuracion previa. Equivalente PowerShell de scripts/lib/dotfiles.sh.
#
# Politicas del modulo:
#   - todo lo que gestiona el repo vive bajo ~/.config/enviroment-dotfiles
#     (config, binarios, logs, backups, estado): un unico arbol que se puede
#     respaldar o borrar entero;
#   - respaldar cada archivo una sola vez por ejecucion antes de tocarlo;
#   - escribir de forma atomica (temporal en el mismo directorio + mover);
#   - tocar solo el contenido entre marcadores de bloque gestionado;
#   - ningun dato del usuario se interpola en una cadena de shell: los comandos
#     se pasan como argv.
#
# Los .ps1/.psm1 de este repo son ASCII intencionalmente: Windows PowerShell
# 5.1 sin BOM interpreta UTF-8 como ANSI y los acentos se rompen.

Set-StrictMode -Version 2.0

$script:DotfilesRunId = if ($env:DOTFILES_RUN_ID) { $env:DOTFILES_RUN_ID } else { "$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$PID" }

# Test-DotfilesKey: ContainsKey() no existe en OrderedDictionary, que es lo
# que devuelven ConvertFrom-Json -Ashtable (PS7) y el conversor de 5.1. Esta
# funcion funciona con ambas.
function Test-DotfilesKey {
    param(
        [AllowNull()]$Map,
        [Parameter(Mandatory)][string]$Key
    )
    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($k in $Map.Keys) {
            if ("$k" -ceq $Key) { return $true }
        }
        return $false
    }
    return [bool]($Map.PSObject.Properties.Name -contains $Key)
}

# --- plataformas -----------------------------------------------------------

function Get-DotfilesPlatform {
    if ($env:DOTFILES_PLATFORM_OVERRIDE) { return $env:DOTFILES_PLATFORM_OVERRIDE }
    if ($env:OS -eq 'Windows_NT') { return 'windows' }
    $uname = ''
    try { $uname = (& uname -s 2>$null | Select-Object -First 1) } catch { $uname = '' }
    switch -regex ($uname.ToLower()) {
        '^linux$' {
            $osr = '/proc/sys/kernel/osrelease'
            if (Test-Path -LiteralPath $osr) {
                $txt = Get-Content -LiteralPath $osr -Raw -ErrorAction SilentlyContinue
                if ($txt -and $txt -match '(?i)microsoft') { return 'wsl' }
            }
            return 'linux'
        }
        '^darwin$' { return 'darwin' }
        '^(mingw|msys|cygwin)' { return 'windows' }
        default { return 'unknown' }
    }
}

# Test-DotfilesWindows: comprueba el RUNTIME real, no la plataforma declarada.
# Las llamadas de sistema (icacls, registro HKCU, Job Objects, CONIN$) solo
# existen en Windows; un DOTFILES_PLATFORM_OVERRIDE de prueba no debe provocar
# que se invoquen en WSL o Linux.
function Test-DotfilesWindows {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return [bool]$IsWindows }
    return $env:OS -eq 'Windows_NT'
}

# --- rutas -----------------------------------------------------------------

# Get-DotfilesPaths devuelve el mapa de rutas del proyecto.
#
# DOTFILES_HOME permite ejecutar todo el instalador contra un home falso
# (tests Pester y `bootstrap.ps1 -Sandbox`); si no esta definido se usa el home
# real del usuario.
# Join-DotfilesPath: concatenacion de rutas SIN tocar el proveedor de archivos.
# Join-Path falla cuando la base no es una ruta local valida (p. ej. un home
# falso 'C:/Users/Test' en un runner de Linux), y eso es justo lo que hacen los
# tests con DOTFILES_HOME y el modo sandbox.
function Join-DotfilesPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Base,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Child
    )
    if (-not $Child) { return $Base }
    if (-not $Base) { return $Child }
    $sep = [IO.Path]::DirectorySeparatorChar
    # La child puede traer subdirectorios con '/' (formato del repo).
    $child = $Child.Replace('/', $sep)
    if ($Base.EndsWith([IO.Path]::DirectorySeparatorChar) -or $Base.EndsWith('/')) {
        return ($Base + $child)
    }
    return ($Base + $sep + $child)
}

function Get-DotfilesPaths {
    param([hashtable]$Override)

    $home_ = if ($env:DOTFILES_HOME) { $env:DOTFILES_HOME } else { $HOME }
    $plat = Get-DotfilesPlatform
    $isWinLayout = ($plat -eq 'windows')
    $J = { param($a, $b) Join-DotfilesPath -Base $a -Child $b }
    $p = @{
        Home        = $home_
        RunId       = $script:DotfilesRunId
        # IsWindows: layout de rutas (sigue a Get-DotfilesPlatform, incluido el
        # override de pruebas). RuntimeWindows: si de verdad se pueden invocar
        # icacls/registro/CONIN$ (solo en el runtime real).
        IsWindows   = $isWinLayout
        RuntimeWindows = (Test-DotfilesWindows)
        Platform    = $plat
        ConfigRoot  = & $J $home_ '.config'
        RepoDir     = if ($env:REPO_DIR) { $env:REPO_DIR } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
        # Estado del proyecto: un solo arbol bajo ~/.config
        Project     = & $J $home_ '.config/enviroment-dotfiles'
        BinDir      = & $J $home_ '.config/enviroment-dotfiles/bin'
        LogDir      = & $J $home_ '.config/enviroment-dotfiles/logs'
        StateDir    = & $J $home_ '.config/enviroment-dotfiles/state'
        BackupDir   = & $J $home_ '.config/enviroment-dotfiles/backups'
        ThemeDir    = & $J $home_ '.config/enviroment-dotfiles/theme'
        EnvFile     = & $J $home_ '.config/enviroment-dotfiles/env.ps1'
        ThemeManifest = & $J $home_ '.config/enviroment-dotfiles/theme.json'
        AccountsFile  = & $J $home_ '.config/enviroment-dotfiles/git-accounts.json'
        KeysDump    = & $J $home_ '.config/enviroment-dotfiles/claves-ssh.txt'
        # Herramientas
        OpenCodeDir = & $J $home_ '.config/opencode'
        NvimDir     = & $J $home_ '.config/nvim'
        SshDir      = & $J $home_ '.ssh'
        GitConfig   = & $J $home_ '.gitconfig'
    }
    if ($p.IsWindows) {
        $local = if ($env:DOTFILES_LOCALAPPDATA) { $env:DOTFILES_LOCALAPPDATA } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { & $J $home_ 'AppData/Local' }
        $roam  = if ($env:DOTFILES_APPDATA) { $env:DOTFILES_APPDATA } elseif ($env:APPDATA) { $env:APPDATA } else { & $J $home_ 'AppData/Roaming' }
        # Con home de pruebas (sandbox) TODO queda bajo ese home, incluidos
        # perfiles y AppData: asi se puede ejecutar el instalador contra un
        # directorio desechable sin tocar la cuenta real.
        $docs  = if ($env:DOTFILES_HOME) { & $J $home_ 'Documents' }
        else { try { [Environment]::GetFolderPath('MyDocuments') } catch { & $J $home_ 'Documents' } }
        if (-not $docs) { $docs = & $J $home_ 'Documents' }
        $p['LocalAppData'] = $local
        $p['AppData'] = $roam
        $p['Documents'] = $docs
        # Rutas que impone Windows: no se pueden mover a ~/.config.
        $p['FontDir'] = & $J $local 'Microsoft/Windows/Fonts'
        $p['NvimDataDir'] = & $J $local 'nvim-data'
        $p['TerminalSettings'] = Get-DotfilesTerminalSettingsPath -LocalAppData $local
        $p['WingetLinks'] = & $J $local 'Microsoft/WinGet/Links'
    } else {
        $p['FontDir'] = & $J $home_ '.local/share/fonts'
        $p['TerminalSettings'] = $null
        $p['WingetLinks'] = $null
    }
    if ($Override) {
        foreach ($k in $Override.Keys) { $p[$k] = $Override[$k] }
    }
    return $p
}

# Get-DotfilesProfilePaths: $PROFILE de PowerShell 7 y de 5.1.
#
# Se escriben las dos porque la instalacion puede arrancar en 5.1 (default en
# Windows 10) y el usuario puede abrir despues PowerShell 7, o al reves.
# profile.ps1 (CurrentUserAllHosts) cubre ambos hosts sin duplicar bloques.
function Get-DotfilesProfilePaths {
    $docs = if ($env:DOTFILES_HOME) { Join-Path $env:DOTFILES_HOME 'Documents' } else { $null }
    if (-not $docs) {
        $docs = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
    }
    if (-not $docs) { $docs = Join-Path $HOME 'Documents' }
    return @(
        (Join-DotfilesPath -Base $docs -Child 'PowerShell/profile.ps1'),
        (Join-DotfilesPath -Base $docs -Child 'WindowsPowerShell/profile.ps1')
    )
}

function Get-DotfilesTerminalSettingsPath {
    param([string]$LocalAppData)

    # Version Store: %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal...\LocalState
    # Version unpackaged: %LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json
    $candidates = @()
    if ($LocalAppData) {
        $pkg = Join-DotfilesPath -Base $LocalAppData -Child 'Packages'
        # En rutas falsas (tests con un home de otro SO) Test-Path/Get-ChildItem
        # pueden fallar: aqui eso no es un error, simplemente no hay WT.
        if (Test-Path -LiteralPath $pkg -PathType Container -ErrorAction SilentlyContinue) {
            $dirs = @(Get-ChildItem -LiteralPath $pkg -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue)
            foreach ($d in $dirs) {
                $candidates += (Join-DotfilesPath -Base $d.FullName -Child 'LocalState/settings.json')
            }
        }
        $candidates += (Join-DotfilesPath -Base $LocalAppData -Child 'Microsoft/Windows Terminal/settings.json')
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

# --- temporales ------------------------------------------------------------

function New-DotfilesTempDir {
    param([string]$Prefix = 'dotfiles')
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("$Prefix-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Remove-DotfilesTree {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        # Antivirus/indexador pueden tener el archivo abierto; no abortar la
        # instalacion por un temporal que no se pudo borrar.
        Write-Warning "No se pudo eliminar $Path ($($_.Exception.Message))"
    }
}

function Get-DotfilesStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
}

# --- respaldos -------------------------------------------------------------

# Backup-DotfilesFile copia el archivo a backups/<nombre>.<stamp>[.<n>].
#
# La marca de "ya respaldado" es un archivo en TEMP, no una variable demodulo:
# cada paso del panel es un proceso PowerShell distinto y una cache in-memory
# duplicaria el respaldo en cada paso (comportamiento historico del bash:
# UN respaldo por archivo y por ejecucion).
function Backup-DotfilesFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $key = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    $marker = Join-Path (Get-DotfilesMarkerDir) ("backup-{0}-{1}" -f $script:DotfilesRunId, (Get-DotfilesKeyHash $key))
    if (Test-Path -LiteralPath $marker) {
        return (Get-Content -LiteralPath $marker -Raw).Trim()
    }

    $paths = Get-DotfilesPaths
    $dir = $paths.BackupDir
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    } catch { return $null }

    $leaf = [IO.Path]::GetFileName($Path)
    $base = Join-Path $dir ("{0}.{1}" -f $leaf, (Get-DotfilesStamp))
    $dest = $base
    $n = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = "$base.$n"
        $n++
    }
    try {
        Copy-Item -LiteralPath $Path -Destination $dest -Force
        [void](Set-DotfilesPrivateAcl -Path $dest)
    } catch {
        return $null
    }
    try {
        [System.IO.File]::WriteAllText($marker, $dest, [System.Text.Encoding]::ASCII)
    } catch { }
    return $dest
}

function Get-DotfilesMarkerDir {
    $dir = if ($env:DOTFILES_MARKER_DIR) {
        $env:DOTFILES_MARKER_DIR
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'enviroment-dotfiles-markers'
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Get-DotfilesKeyHash {
    param([Parameter(Mandatory)][string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 20).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

# --- escritura atomica y bloques gestionados -------------------------------

# Write-DotfilesFile escribe contenido nuevo de forma atomica.
# -Encoding: 'utf8' (sin BOM, el normal) | 'utf8bom' (perfiles .ps1 legacy) |
#   'ascii' (known_hosts) | 'preserve' (usa el encoding del destino).
function Write-DotfilesFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][AllowNull()][string]$Content,
        [string]$Encoding = 'utf8',
        [switch]$Backup
    )

    if ($null -eq $Content) { $Content = '' }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    if ($Backup) { Backup-DotfilesFile -Path $Path | Out-Null }

    $enc = switch ($Encoding) {
        'utf8bom' { New-Object System.Text.UTF8Encoding($true) }
        'ascii'   { [System.Text.Encoding]::ASCII }
        default   { New-Object System.Text.UTF8Encoding($false) }
    }

    $tmpBase = if ($dir) { $dir } else { (Split-Path -Parent $Path) }
    $tmp = Join-Path $tmpBase (".dotfiles-{0}-{1}.tmp" -f $PID, [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, $enc)
        # Move-Item -Force reemplaza; si el destino esta bloqueado falla sin
        # haber tocado el original.
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        Remove-DotfilesTree -Path $tmp
        throw
    }
    [void](Set-DotfilesPrivateAcl -Path $Path)
    return $Path
}

# Get-DotfilesFileText lee un archivo como texto plano preservando UTF-8.
function Get-DotfilesFileText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

# Set-DotfilesManagedBlock reemplaza el contenido entre header/footer.
#
# Comportamiento identico a dotfiles.sh:
#   - si existe el header pero no el footer, NO toca el archivo y devuelve
#     $false (asi se evita borrar configuracion del usuario por un bloque a
#     medias);
#   - lo que haya fuera de los marcadores se conserva tal cual;
#   - position 'prepend' pone el bloque al principio (necesario en
#     ~/.ssh/config, donde el primer Host gana).
function Set-DotfilesManagedBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$Footer,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [ValidateSet('append', 'prepend')][string]$Position = 'append',
        [switch]$Backup,
        [string]$Encoding = 'preserve'
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false)))
        $hasHeader = @($lines | Where-Object { $_ -eq $Header }).Count -gt 0
        $hasFooter = @($lines | Where-Object { $_ -eq $Footer }).Count -gt 0
        if ($hasHeader -and -not $hasFooter) {
            return $false
        }
    }
    $rest = @()
    $skip = $false
    foreach ($l in $lines) {
        if ($l -eq $Header) { $skip = $true; continue }
        if ($l -eq $Footer) { $skip = $false; continue }
        if (-not $skip) { $rest += $l }
    }

    # Garantizar salto de linea final para no pegar el header a la ultima linea.
    $restText = ($rest -join "`n")
    if ($restText) { $restText += "`n" }

    $block = @(($Header)) + @($Body -split "`n") + @($Footer)
    $blockText = ($block -join "`n") + "`n"

    $outText = if ($Position -eq 'prepend') { $blockText + $restText } else { $restText + $blockText }

    $enc = $Encoding
    if ($enc -eq 'preserve') {
        $enc = if ($Path -match '\.(ps1|psm1)$') { 'utf8bom' } else { 'utf8' }
    }
    Write-DotfilesFile -Path $Path -Content $outText -Encoding $enc -Backup:$Backup | Out-Null
    return $true
}

# Get-DotfilesManagedBlockBody devuelve el interior del bloque ('' si no hay).
function Get-DotfilesManagedBlockBody {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$Footer
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false)))
    $on = $false
    $body = @()
    foreach ($l in $lines) {
        if ($l -eq $Header) { $on = $true; continue }
        if ($l -eq $Footer) { $on = $false; continue }
        if ($on) { $body += $l }
    }
    return ($body -join "`n")
}

function Test-DotfilesManagedBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$Footer,
        [string]$MustContain
    )
    $body = Get-DotfilesManagedBlockBody -Path $Path -Header $Header -Footer $Footer
    if (-not $body) { return $false }
    if ($MustContain) { return $body.Contains($MustContain) }
    return $true
}

# --- entorno persistente ---------------------------------------------------

function Get-DotfilesEnvFilePath { (Get-DotfilesPaths).EnvFile }

# Add-DotfilesEnvPath persiste un directorio en env.ps1 y lo agrega al PATH
# actual. Idempotente: el marcador `$ddDir='<ruta>'` evita duplicados.
function Add-DotfilesEnvPath {
    param([Parameter(Mandatory)][string]$Dir)

    if (-not $Dir) { return $false }
    $file = Get-DotfilesEnvFilePath
    $parent = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (-not (Test-Path -LiteralPath $file)) {
        $hdr = @(
            '# Generado por enviroment-dotfiles. No editar a mano.',
            '# Cada bloque anade un directorio al PATH de forma idempotente.',
            ''
        ) -join "`n"
        [System.IO.File]::WriteAllText($file, $hdr, (New-Object System.Text.UTF8Encoding($false)))
    }
    Set-DotfilesPrivateAcl -Path $file

    $quoted = $Dir.Replace("'", "''")
    $marker = "`$ddDir='$quoted'"
    $current = Get-DotfilesFileText -Path $file
    if ($current -notmatch [regex]::Escape($marker)) {
        $snippet = @"
$marker
if (Test-Path -LiteralPath `$ddDir) {
    if ((`$env:Path -split ';') -notcontains `$ddDir) { `$env:Path = "`$ddDir;`$env:Path" }
}

"@
        [System.IO.File]::AppendAllText($file, $snippet, (New-Object System.Text.UTF8Encoding($false)))
    }

    Use-DotfilesPathEntry -Dir $Dir
    Add-DotfilesUserPath -Dir $Dir
    return $true
}

# Use-DotfilesEnv carga env.ps1 en la sesion actual.
function Use-DotfilesEnv {
    param([string]$Path)
    if (-not $Path) { $Path = Get-DotfilesEnvFilePath }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        . $Path
        return $true
    }
    return $false
}

function Use-DotfilesPathEntry {
    param([Parameter(Mandatory)][string]$Dir)
    $parts = @($env:Path -split ';' | Where-Object { $_ })
    if ($parts -notcontains $Dir) {
        $env:Path = ($Dir + ';' + ($parts -join ';'))
    }
}

# Add-DotfilesUserPath escribe en el PATH de usuario del registro, respetando
# el tipo de valor (REG_EXPAND_SZ no debe volverse REG_SZ o se rompen los
# %VARIABLES% del propio PATH).
function Add-DotfilesUserPath {
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-DotfilesWindows)) { return $false }
    if (-not $Dir) { return $false }
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if (-not $key) { return $false }
        try {
            $kind = $key.GetValueKind('Path')
            $value = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $value) { $value = '' }
            $parts = @("$value" -split ';' | Where-Object { $_ })
            $cmp = $Dir.TrimEnd('\')
            $exists = @($parts | Where-Object { $_.TrimEnd('\') -eq $cmp }).Count -gt 0
            if ($exists) { return $false }
            $newValue = (@($Dir) + $parts) -join ';'
            if (-not $kind) { $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $key.SetValue('Path', $newValue, $kind)
        } finally {
            $key.Dispose()
        }
        Use-DotfilesPathEntry -Dir $Dir
        return $true
    } catch {
        Write-Verbose "No se pudo actualizar el PATH de usuario: $($_.Exception.Message)"
        return $false
    }
}

# --- ACLs ------------------------------------------------------------------

# SIDs que pueden conservar acceso a un archivo privado: el SO y los admins los
# necesitan para tareas de mantenimiento. Se comparan por SID y no por nombre
# porque los nombres de las cuentas conocidas estan localizados
# ("BUILTIN\Administrators" es "BUILTIN\Administradores" en Windows espanol).
$script:DotfilesAllowedSids = @(
    'S-1-5-18',     # NT AUTHORITY\SYSTEM
    'S-1-5-32-544', # BUILTIN\Administrators
    'S-1-3-0'       # CREATOR OWNER
)

# Get-DotfilesUserSid: SID del usuario que ejecuta el instalador.
#
# Las ACL se conceden por SID, no por "MAQUINA\usuario": icacls resuelve el
# nombre contra el dominio local y devuelve ERROR_NONE_MAPPED (1332) si el
# equipo se renombro, la cuenta es de Microsoft o el nombre no coincide. El
# SID es estable y no depende del idioma ni del nombre visible.
function Get-DotfilesUserSid {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    } catch {
        return ''
    }
}

# Set-DotfilesPrivateAcl restringe un archivo o directorio al usuario actual.
#
# Sustituto de `chmod 600`: quita la herencia y concede acceso total solo al
# usuario, a SYSTEM y a Administradores. Es obligatorio para claves SSH (el
# OpenSSH de Windows rechaza claves legibles por otros) y para los resultados
# de formulario.
# En no-Windows es un no-op (ahi manda el chmod real del runner).
function Set-DotfilesPrivateAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('file', 'dir')][string]$Kind = 'file'
    )
    if (-not (Test-DotfilesWindows)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $sid = Get-DotfilesUserSid
    if (-not $sid) { return $false }
    $inherit = if ($Kind -eq 'dir') { '(OI)(CI)(F)' } else { '(F)' }
    # Un solo /grant:r con los tres principals: es la forma documentada de
    # icacls (reemplaza las concesiones previas y deja ACL = 3 lineas).
    $icaclsArgs = @($Path, '/inheritance:r', '/grant:r')
    foreach ($principal in @("*$sid", '*S-1-5-18', '*S-1-5-32-544')) {
        $icaclsArgs += "$principal$inherit"
    }
    try {
        # El mensaje de icacls (localizado) se guarda para Write-Verbose: si la
        # ACL falla, quien llama decide si avisar (Initialize-DotfilesUi lo
        # hace una sola vez, doctor por archivo).
        $out = & icacls.exe @icaclsArgs 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        $first = @($out | Where-Object { $_ } | Select-Object -First 1)
        Write-Verbose "icacls fallo en ${Path}: $($first -join ' ')"
        return $false
    } catch {
        Write-Verbose "icacls fallo en ${Path}: $($_.Exception.Message)"
        return $false
    }
}

# Get-DotfilesAclSids lista los SIDs con acceso explicito a la ruta.
#
# Devuelve SIDs (S-1-5-...) y no nombres para que la comprobacion funcione en
# cualquier idioma. Un principal que no se pueda traducir se devuelve tal cual,
# y entonces no coincide con la lista permitida: mejor un falso negativo (que
# doctor avise) que un falso positivo.
function Get-DotfilesAclSids {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $acl = Get-Acl -LiteralPath $Path
        return @($acl.Access | ForEach-Object {
                try {
                    $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
                } catch {
                    $_.IdentityReference.ToString()
                }
            })
    } catch {
        return @()
    }
}

# Test-DotfilesPrivateAcl: solo el usuario (y SYSTEM/Administradores, que el
# propio SO necesita) pueden tener acceso.
function Test-DotfilesPrivateAcl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-DotfilesWindows)) { return $true }
    $sids = @(Get-DotfilesAclSids -Path $Path)
    if ($sids.Count -eq 0) { return $false }
    $sid = Get-DotfilesUserSid
    if (-not $sid) { return $false }
    $allowed = @($sid) + $script:DotfilesAllowedSids
    foreach ($s in $sids) {
        if ($allowed -notcontains $s) { return $false }
    }
    return $true
}

# --- ejecucion de comandos -------------------------------------------------

function Test-DotfilesCommand {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)
}

# ConvertTo-DotfilesArgv aplana argv: si un elemento es en si un array, se
# queda con el primero.
#
# Caso real: `@((Get-Command 'curl.exe').Source, '-fsSL', ...)` cuando hay dos
# copias de curl en el PATH. El parametro [string[]] coercionaria el array a
# "C:\system32\curl.exe C:\scoop\curl.exe" y CreateProcess buscaria un
# ejecutable con ese nombre: el instalador muere con un error ilegible (o, peor,
# en silencio). Aplanar aqui convierte ese fallo en "usa la primera coincidencia"
# que es exactamente lo que haria el shell.
function ConvertTo-DotfilesArgv {
    param([object[]]$Values)
    $out = @()
    foreach ($v in @($Values)) {
        if ($v -is [array]) {
            if ($v.Count -eq 0) { continue }
            Write-Verbose "argv: elemento con $($v.Count) valores, se usa '$($v[0])'"
            $v = $v[0]
        }
        if ($null -eq $v) { continue }
        $out += [string]$v
    }
    return ,$out
}

# Invoke-DotfilesNative ejecuta argv literal (nunca una cadena de shell) y
# devuelve el codigo de salida. La salida va directo al panel, que la loguea.
function Invoke-DotfilesNative {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][object[]]$Argv,
        [int]$TimeoutSec = 0,
        [string]$WorkingDirectory
    )
    $Argv = ConvertTo-DotfilesArgv -Values $Argv
    if ($Argv.Count -lt 1 -or -not $Argv[0]) { throw 'Invoke-DotfilesNative: falta el comando' }
    $exe = $Argv[0]
    $tail = @()
    if ($Argv.Count -gt 1) { $tail = @($Argv[1..($Argv.Count - 1)]) }

    if ($TimeoutSec -le 0) {
        # La salida del hijo se re-emite directo a stdout del proceso: si se
        # dejara en el pipeline de PowerShell, el llamador capturaria la
        # salida en el variable de retorno y se mezclaria con el code.
        if ($WorkingDirectory) {
            Push-Location -LiteralPath $WorkingDirectory
            try {
                & $exe @tail | ForEach-Object { [Console]::Out.WriteLine($_) }
                return $LASTEXITCODE
            } finally { Pop-Location }
        }
        & $exe @tail | ForEach-Object { [Console]::Out.WriteLine($_) }
        return $LASTEXITCODE
    }

    # Con timeout se usa un proceso aparte: WaitForExit puede matarlo si el
    # hijo se cuelga (los pipes del panel no pueden quedar abiertos).
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        foreach ($a in $tail) {
            if ($psi.Arguments) { $psi.Arguments += ' ' }
            $psi.Arguments += ('"' + ($a -replace '"', '\"') + '"')
        }
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # Leer en async ANTES de esperar: un hijo con mucha salida llenaria el
        # buffer del pipe y se colgaria WaitForExit.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $finished = $p.WaitForExit($TimeoutSec * 1000)
        if (-not $finished) {
            try {
                if (Test-DotfilesWindows) {
                    & taskkill.exe '/T' '/F' '/PID' $p.Id 2>$null | Out-Null
                }
                $p.Kill()
            } catch { }
            Write-Warning "el comando $exe supero $TimeoutSec s y fue terminado"
            return 124
        }
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        $code = $p.ExitCode
        $p.Dispose()
        if ($stdout) { [Console]::Out.WriteLine($stdout.TrimEnd("`r", "`n")) }
        if ($stderr) { [Console]::Error.WriteLine($stderr.TrimEnd("`r", "`n")) }
        return $code
    } catch {
        Write-Warning "fallo al ejecutar $exe : $($_.Exception.Message)"
        return 127
    }
}

# Get-DotfilesQuotedArgs aplica las reglas de citado de la linea de comandos de
# Windows (CreateProcess). Se necesita porque Windows PowerShell 5.1 DESCARTA los
# argumentos vacios al invocar nativos con `&`, y ssh-keygen -N '' exige que el
# vacio llegue.
function Get-DotfilesQuotedArgs {
    param([AllowEmptyString()][AllowNull()][string[]]$Values)
    $out = @()
    foreach ($v in @($Values)) {
        if ($null -eq $v) { $v = '' }
        if ($v -eq '') { $out += '""'; continue }
        if ($v -notmatch '[\s"]') { $out += $v; continue }
        # Backslashes delante de una comilla se duplican; el resto pasa tal cual.
        # Los Append() van con [void]: StringBuilder devuelve si mismo y sin eso
        # el objeto se colaria en la salida de la funcion.
        $sb = New-Object System.Text.StringBuilder
        $backslash = 0
        foreach ($ch in $v.ToCharArray()) {
            if ($ch -eq '\') { $backslash++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append('\', ($backslash * 2 + 1))
                [void]$sb.Append('"')
            } else {
                if ($backslash -gt 0) { [void]$sb.Append('\', $backslash) }
                [void]$sb.Append($ch)
            }
            $backslash = 0
        }
        if ($backslash -gt 0) { [void]$sb.Append('\', ($backslash * 2)) }
        $out += ('"' + $sb.ToString() + '"')
    }
    return ($out -join ' ')
}

# Invoke-DotfilesNativeQuoted ejecuta argv con citado explicito de CreateProcess
# y hereda la consola del padre (la salida la consume el panel/log).
# Deterministico entre PowerShell 5.1 y 7, que es lo que exige ssh-keygen.
function Invoke-DotfilesNativeQuoted {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][object[]]$Argv,
        [string]$WorkingDirectory,
        # AttachConsole: el hijo comparte la consola del padre. Es obligatorio
        # para las TUI (nui steps run): con CreateNoWindow el proceso queda sin
        # la consola del padre, no detecta TTY y sus mensajes de error se
        # pierden, asi que el panel "no hace nada" sin explicacion.
        [switch]$AttachConsole
    )
    $Argv = ConvertTo-DotfilesArgv -Values $Argv
    if ($Argv.Count -lt 1 -or -not $Argv[0]) { throw 'Invoke-DotfilesNativeQuoted: falta el comando' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Argv[0]
    if ($Argv.Count -gt 1) {
        $psi.Arguments = Get-DotfilesQuotedArgs -Values @($Argv[1..($Argv.Count - 1)])
    }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = -not $AttachConsole
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $code = $p.ExitCode
        $p.Dispose()
        return $code
    } catch {
        Write-Warning "fallo al ejecutar $($Argv[0]): $($_.Exception.Message)"
        return 127
    }
}

# Get-DotfilesSelfPwsh: el pwsh que levanto esta sesion, con fallbacks.
# Fijar la ruta completa de pwsh.exe evita que un `powershell` heredado por el
# PATH acabe ejecutando pasos que asumen PowerShell 7.
function Get-DotfilesSelfPwsh {
    if ($env:NUI_PWSH) { return $env:NUI_PWSH }
    $mine = (Get-Process -Id $PID -ErrorAction SilentlyContinue)
    if ($mine -and $mine.Path -and $mine.Path -match 'pwsh(\.exe)?$') { return $mine.Path }
    # Select-Object -First 1: Get-Command devuelve TODAS las coincidencias del
    # PATH y `.Source` sobre un array produce un array. Ese array acaba como
    # FileName de ProcessStartInfo (unido con espacios) y el proceso no arranca:
    # "no se reconoce el termino 'C:\...\pwsh.exe C:\...\pwsh.exe'".
    foreach ($cand in @('pwsh', 'pwsh.exe')) {
        $cmd = Get-Command $cand -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    $ps = Get-Command 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ps) { return $ps.Source }
    return 'powershell.exe'
}

# Resolve-DotfilesExe: ruta del ejecutable para Start-Process/ProcessStartInfo.
function Resolve-DotfilesExe {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $Name
}

# --- descargas -------------------------------------------------------------

function Invoke-DotfilesDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutSec = 300,
        [int]$Retries = 3,
        [string]$Sha256
    )
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    # TLS 1.2: Windows PowerShell 5.1 no lo negocia por defecto.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }

    $ok = $false
    $curl = Get-Command 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curl) {
        for ($i = 0; $i -lt $Retries -and -not $ok; $i++) {
            $code = Invoke-DotfilesNative -Argv @($curl.Source, '-fsSL', '--retry', '2', '--max-time', "$TimeoutSec", '-o', $OutFile, $Uri)
            $ok = ($code -eq 0) -and (Test-Path -LiteralPath $OutFile -PathType Leaf)
        }
    }
    if (-not $ok) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            $ok = Test-Path -LiteralPath $OutFile -PathType Leaf
        } catch {
            Write-Warning "no se pudo descargar $Uri : $($_.Exception.Message)"
        }
    }
    if (-not $ok) { return $false }

    # Unblock-File existe como cmdlet tambien en PowerShell Linux/macOS, pero
    # SOLO funciona en Windows (falla con "does not support Linux"). Se gating
    # por runtime real, no por disponibilidad del cmdlet.
    if (Test-DotfilesWindows) {
        try { Unblock-File -LiteralPath $OutFile -ErrorAction Stop } catch { }
    }
    if ($Sha256) {
        if (-not (Test-DotfilesHash -Path $OutFile -Sha256 $Sha256)) { return $false }
    }
    return $true
}

function Get-DotfilesFileHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-DotfilesHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sha256
    )
    $want = $Sha256.Trim().ToLowerInvariant()
    $have = Get-DotfilesFileHash -Path $Path
    if ($have -eq $want) { return $true }
    $shown = if ($have) { $have } else { 'desconocido' }
    Write-Warning "checksum no coincide para $Path (esperado $want, obtenido $shown)"
    return $false
}

# --- archivos de datos -----------------------------------------------------

# Read-DotfilesEnvFile parsea KEY=valor (el formato de config/theme/dracula.env
# y de cualquier *.env del repo). Sin dependencias externas.
function Read-DotfilesEnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $map }
    foreach ($raw in [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) { continue }
        $i = $line.IndexOf('=')
        $key = $line.Substring(0, $i).Trim()
        $val = $line.Substring($i + 1).Trim()
        if ($val.Length -ge 2) {
            $q = $val[0]
            if (($q -eq '"' -or $q -eq "'") -and $val[$val.Length - 1] -eq $q) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $map[$key] = $val
    }
    return $map
}

function Write-DotfilesJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$Object,
        [int]$Depth = 20,
        [switch]$Backup
    )
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
    # ConvertTo-Json escapa <, > y & como \u003C etc. para HTML. En TOML/JSON
    # de config eso ilegible y rompe diffs; se revierten solo esas secuencias.
    $json = $json -replace '\\u003C', '<' -replace '\\u003E', '>' -replace '\\u0026', '&' -replace '\\u0027', "'"
    Write-DotfilesFile -Path $Path -Content ($json + "`n") -Encoding 'utf8' -Backup:$Backup | Out-Null
    return $Path
}

function Read-DotfilesJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AsHashtable
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $txt = Get-DotfilesFileText -Path $Path
    if (-not $txt.Trim()) { return $null }
    $obj = $null
    try {
        $obj = ConvertFrom-Json -InputObject $txt
    } catch {
        Write-Warning "JSON invalido en $Path : $($_.Exception.Message)"
        return $null
    }
    if ($AsHashtable) {
        # ConvertFrom-Json -AsHashtable existe desde PowerShell 6; en 5.1 hay
        # que convertir a mano (los planes y manifiestos se indexan como hash).
        if ((Get-Command ConvertFrom-Json).Parameters.Keys -contains 'AsHashtable') {
            return ConvertFrom-Json -InputObject $txt -AsHashtable
        }
        return ConvertTo-DotfilesHashtableDeep -InputObject $obj
    }
    return $obj
}

# ConvertTo-DotfilesHashtableDeep: PSCustomObject -> ordered hashtable,
# arrays -> array de valores convertidos. Clave: case-insensitive NO, asi que
# las claves se copian tal cual del JSON.
function ConvertTo-DotfilesHashtableDeep {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $arr = @()
            foreach ($i in $InputObject) { $arr += (ConvertTo-DotfilesHashtableDeep -InputObject $i) }
            return , $arr
        }
        if ($InputObject -is [psobject]) {
            $ht = [ordered]@{}
            foreach ($p in $InputObject.PSObject.Properties) {
                $ht[$p.Name] = ConvertTo-DotfilesHashtableDeep -InputObject $p.Value
            }
            return $ht
        }
        return $InputObject
    }
}

# --- red de archivos -------------------------------------------------------

# Copy-DotfilesTree copia el CONTENIDO de Source dentro de Destination.
#
# Semantica elegida a proposito (y replicada en scripts/sync.sh): "los
# assets acaban en esta carpeta", no "la carpeta se mete dentro". Con
# `rsync -a src dst` de Unix, si dst ya existe el resultado es
# dst/src_basename: duplicar el instalador acababa con
# ~/.config/enviroment-dotfiles/theme/theme/dracula.env y theme.sh dejaba de
# encontrar el tema.
function Copy-DotfilesTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Mirror
    )
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $Source -PathType Container) {
        $target = $Destination.TrimEnd('\', '/')
        # Un nivel de 'x/y/' no cambia el destino: se normaliza.
        $target = [System.IO.Path]::GetFullPath($target)
        if ($Mirror -and (Test-Path -LiteralPath $target)) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        }
        Get-ChildItem -LiteralPath $Source -Force -Recurse | ForEach-Object {
            $rel = $_.FullName.Substring($Source.TrimEnd('\', '/').Length).TrimStart('\', '/')
            $dest = Join-Path $target $rel
            if ($_.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $dest)) {
                    New-Item -ItemType Directory -Force -Path $dest | Out-Null
                }
            } else {
                $d = Split-Path -Parent $dest
                if ($d -and -not (Test-Path -LiteralPath $d)) {
                    New-Item -ItemType Directory -Force -Path $d | Out-Null
                }
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
        return $true
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $true
}

# Expand-DotfilesZip descomprime con proteccion zip-slip: una entrada con
# `..\` o ruta absoluta nunca escribe fuera de $Destination.
function Expand-DotfilesZip {
    param(
        [Parameter(Mandatory)][string]$Zip,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExtensionFilter,
        [switch]$Flat
    )
    if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { return @() }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    } catch { }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    $written = @()
    try {
        $rootFull = [System.IO.Path]::GetFullPath($Destination)
        if (-not (Test-Path -LiteralPath $rootFull)) { New-Item -ItemType Directory -Force -Path $rootFull | Out-Null }
        foreach ($entry in $archive.Entries) {
            if (-not $entry.FullName) { continue }
            if ($entry.FullName -match '(^|/)__MACOSX(/|$)') { continue }
            if ($entry.FullName.EndsWith('/')) { continue }
            $name = [IO.Path]::GetFileName($entry.FullName)
            if (-not $name) { continue }
            if ($ExtensionFilter) {
                $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
                if ($ExtensionFilter -notcontains $ext) { continue }
            }
            $rel = if ($Flat) { $name } else { ($entry.FullName -replace '/', [IO.Path]::DirectorySeparatorChar) }
            $dest = [System.IO.Path]::GetFullPath((Join-Path $rootFull $rel))
            if (-not $dest.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar) -and $dest -ne $rootFull) {
                throw "entrada de zip ilegal (zip-slip): $($entry.FullName)"
            }
            $d = Split-Path -Parent $dest
            if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            $src = $entry.Open()
            try {
                $dstStream = [System.IO.File]::Create($dest)
                try { $src.CopyTo($dstStream) } finally { $dstStream.Dispose() }
            } finally { $src.Dispose() }
            $written += $dest
        }
    } finally {
        $archive.Dispose()
    }
    return $written
}

# Add-DotfilesUserBin coloca un binario suelto en ~/.config/enviroment-dotfiles/bin.
# Es el fallback sin winget/admin: mismo rol que dotfiles_user_bin del bash.
function Add-DotfilesUserBin {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [string]$InnerPath,
        [string]$Sha256
    )
    $paths = Get-DotfilesPaths
    $binDir = $paths.BinDir
    if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Force -Path $binDir | Out-Null }
    $ext = if (Test-DotfilesWindows) { '.exe' } else { '' }
    $dest = Join-Path $binDir ($Name + $ext)
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        Add-DotfilesEnvPath -Dir $binDir | Out-Null
        return $dest
    }

    $tmp = New-DotfilesTempDir -Prefix 'userbin'
    try {
        $arc = Join-Path $tmp ([IO.Path]::GetFileName(([Uri]$Uri).LocalPath))
        if (-not (Invoke-DotfilesDownload -Uri $Uri -OutFile $arc -TimeoutSec 300 -Sha256 $Sha256)) { return $null }

        $x = Join-Path $tmp 'x'
        New-Item -ItemType Directory -Force -Path $x | Out-Null
        if ($arc -match '\.zip$') {
            $null = Expand-DotfilesZip -Zip $arc -Destination $x
        } elseif ($arc -match '\.tar\.gz$' -or $arc -match '\.tgz$') {
            if ((Invoke-DotfilesNative -Argv @('tar', '-xzf', $arc, '-C', $x)) -ne 0) { return $null }
        } else {
            # Archivo suelto (binario o script): no hay nada que descomprimir.
            $arc | Out-File -FilePath (Join-Path $x 'marker.txt') -Encoding ascii -ErrorAction SilentlyContinue
            $found = $arc
        }

        if (-not $found) { $found = Find-DotfilesPayload -Root $x -Name $Name -InnerPath $InnerPath -Extension $ext }
        if (-not $found) { return $null }

        Copy-Item -LiteralPath $found -Destination $dest -Force
        [void](Set-DotfilesPrivateAcl -Path $dest)
        Add-DotfilesEnvPath -Dir $binDir | Out-Null
        return $dest
    } finally {
        Remove-DotfilesTree -Path $tmp
    }
}

# Find-DotfilesPayload localiza el binario dentro de un arbol descomprimido:
# primero la ruta interna pinnada y luego el nombre esperado ($Name, con o sin
# extension). Devuelve ruta de archivo o $null.
function Find-DotfilesPayload {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [string]$InnerPath,
        [string]$Extension = ''
    )
    if ($InnerPath) {
        $cand = Join-Path $Root ($InnerPath -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    }
    $names = @(($Name + $Extension), $Name)
    $hit = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $names -contains $_.Name } |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

# --- utilidades de sistema -------------------------------------------------

function Test-DotfilesAdmin {
    if (-not (Test-DotfilesWindows)) { return ([int](& id -u 2>$null)) -eq 0 }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# Update-DotfilesSessionPath reconstruye $env:Path desde el registro.
# Necesario porque los instaladores oficiales (herdr, winget) actualizan el
# PATH de usuario y ESTE proceso no lo vuelve a leer solo.
function Update-DotfilesSessionPath {
    if (-not (Test-DotfilesWindows)) { return $env:Path }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $combined = (@($machine, $user) | Where-Object { $_ }) -join ';'
    if ($combined) { $env:Path = $combined }
    return $env:Path
}

# Get-DotfilesSemverParts -> @(major, minor, patch) tolerando prefijos v y
# sufijos -rc.1 / +build.
function Get-DotfilesSemverParts {
    param([Parameter(Mandatory)][string]$Version)
    $v = $Version.Trim() -replace '^[vV]', ''
    $v = $v -replace '[^\d.].*$', ''
    $parts = @($v.Split('.') | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
        })
    while ($parts.Count -lt 3) { $parts += 0 }
    return @($parts[0], $parts[1], $parts[2])
}

function Test-DotfilesSemverGt {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Minimum
    )
    $a = Get-DotfilesSemverParts -Version $Version
    $b = Get-DotfilesSemverParts -Version $Minimum
    for ($i = 0; $i -lt 3; $i++) {
        if ($a[$i] -gt $b[$i]) { return $true }
        if ($a[$i] -lt $b[$i]) { return $false }
    }
    return $false
}

function Get-DotfilesNvimVersion {
    $cmd = Get-Command 'nvim' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $cmd) { return '' }
    $out = ''
    try { $out = & nvim --version 2>$null | Select-Object -First 1 } catch { return '' }
    if ($out -match 'NVIM v([0-9][0-9.]*)') { return $Matches[1] }
    return ''
}

# Get-DotfilesCC: compilador C para nvim-treesitter/LazyVim.
function Get-DotfilesCC {
    foreach ($c in @('gcc', 'clang', 'cl')) {
        $cmd = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Get-DotfilesFnmNodeDir: directorio del Node activo gestionado por fnm.
function Get-DotfilesFnmNodeDir {
    param([string]$FnmDir)
    if (-not $FnmDir) {
        $FnmDir = if ($env:FNM_DIR) { $env:FNM_DIR } else { (Join-Path $env:LOCALAPPDATA 'fnm') }
    }
    if (-not (Test-Path -LiteralPath $FnmDir)) { return $null }
    $multishell = Join-Path $FnmDir 'multishell'
    if (Test-Path -LiteralPath $multishell) {
        $current = Get-ChildItem -LiteralPath $multishell -Directory -Filter 'current\*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($current) { return $current.FullName }
    }
    $alias = Get-ChildItem -LiteralPath $FnmDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\node.exe') } |
        Select-Object -First 1
    if ($alias) { return (Join-Path $alias.FullName 'bin') }
    return $null
}

# Install-DotfilesSyncWrapper escribe el wrapper publico sync-dotfiles.
# No usa `curl | bash`: clona el repo en un temporal, ejecuta el script desde
# ese clon y limpia siempre (mismo diseno que el wrapper de bash).
function Install-DotfilesSyncWrapper {
    param([hashtable]$Paths)
    if (-not $Paths) { $Paths = Get-DotfilesPaths }
    $bin = $Paths.BinDir
    if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Force -Path $bin | Out-Null }

    $repoUrl = if ($env:SYNC_REPO_URL) { $env:SYNC_REPO_URL } else { 'https://github.com/ChaminnPM/enviroment-dotfiles.git' }
    $ref = $env:SYNC_REF
    $sha = $env:SYNC_SHA
    if ($ref -and $ref -notmatch '^[A-Za-z0-9._/-]+$') {
        Write-UiWarn 'SYNC_REF invalido; se ignora'
        $ref = ''
    }
    if ($sha -and $sha -notmatch '^[0-9a-fA-F]{7,40}$') {
        Write-UiWarn 'SYNC_SHA invalido; se ignora'
        $sha = ''
    }

    $ps1 = Join-Path $bin 'sync-dotfiles.ps1'
    $body = @'
# generado por bootstrap.ps1 - no editar
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$SyncArgs)
$ErrorActionPreference = 'Stop'
$RepoUrl = '__REPO_URL__'
$Ref = '__REF__'
$Sha = '__SHA__'
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Error 'git no esta instalado. Ejecuta bootstrap.ps1 o instala Git for Windows.'
    exit 1
}
$pwsh = 'pwsh'
$alt = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)) {
    if ($alt) { $pwsh = $alt.Source } else { Write-Error 'PowerShell no disponible'; exit 1 }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sync-dotfiles-' + [guid]::NewGuid().ToString('N'))
try {
    $clone = @('clone', '--depth', '1')
    if ($Ref -and $Ref -ne 'main') { $clone += @('--branch', $Ref) }
    $clone += @($RepoUrl, (Join-Path $tmp 'repo'))
    & git @clone 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error 'No se pudo clonar el repo publico'; exit 1 }
    $repo = Join-Path $tmp 'repo'
    if ($Sha) {
        $head = (& git -C $repo rev-parse HEAD 2>$null)
        if ("$head".Trim() -ne $Sha) {
            Write-Error "HEAD del repo no coincide con SYNC_SHA ($head != $Sha)"
            exit 1
        }
    }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-DotfilesPath -Base $repo -Child 'scripts/sync.ps1') @SyncArgs
    exit $LASTEXITCODE
} finally {
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
'@
    $body = $body.Replace('__REPO_URL__', $repoUrl).Replace('__REF__', $ref).Replace('__SHA__', $sha)
    Write-DotfilesFile -Path $ps1 -Content ($body + "`n") -Encoding 'utf8bom' | Out-Null

    # .cmd para que `sync-dotfiles` funcione tambien desde cmd.exe.
    $cmd = Join-Path $bin 'sync-dotfiles.cmd'
    $cmdBody = @(
        '@echo off',
        'setlocal',
        'set "SYNC_PS1=%~dp0sync-dotfiles.ps1"',
        'where pwsh >nul 2>nul',
        'if %errorlevel%==0 (',
        '  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SYNC_PS1%" %*',
        ') else (',
        '  powershell -NoProfile -ExecutionPolicy Bypass -File "%SYNC_PS1%" %*',
        ')',
        'exit /b %errorlevel%'
    ) -join "`r`n"
    Write-DotfilesFile -Path $cmd -Content ($cmdBody + "`r`n") -Encoding 'ascii' | Out-Null

    $null = Add-DotfilesEnvPath -Dir $bin
    return [pscustomobject]@{ ps1 = $ps1; cmd = $cmd }
}

# Test-DotfilesTitleMatch: `--only` compara sin distinguir mayusculas NI
# acentos. Los titulos de los pasos son ASCII en el codigo (ver el chequeo
# "scripts ASCII-only" de CI) porque PowerShell 5.1 sin BOM rompe los
# non-ASCII, pero el usuario puede escribir "Verificacion final" o
# "Verificacion final" (el codigo de los scripts es ASCII).
# Format-DotfilesAsciiKey: minusculas y sin diacriticos. Es la forma canonica
# para comparar titulos de paso entre capas: el codigo fuente de los .ps1 es
# ASCII (ver CI) mientras que bootstrap.sh si lleva acentos.
function Format-DotfilesAsciiKey {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if (-not $Value) { return '' }
    $d = $Value.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne
            [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC).ToLowerInvariant()
}

function Test-DotfilesTitleMatch {
    param(
        [AllowEmptyString()][AllowNull()][string]$Title,
        [AllowEmptyString()][AllowNull()][string]$Filter
    )
    if (-not $Filter) { return $true }
    if (-not $Title) { return $false }
    return (Format-DotfilesAsciiKey $Title).Contains((Format-DotfilesAsciiKey $Filter))
}

# --- git -------------------------------------------------------------------

function Set-DotfilesGitConfig {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if (-not (Test-DotfilesCommand 'git')) { return $false }
    # `git config --file` recibe el valor como argv: nunca se interpola.
    $code = Invoke-DotfilesNative -Argv @('git', 'config', '--file', $File, '--replace-all', $Key, $Value)
    return ($code -eq 0)
}

# --- limpieza de la ejecucion ----------------------------------------------

# Clear-DotfilesRunMarker borra las marcas de respaldo de esta ejecucion.
function Clear-DotfilesRunMarker {
    param([string]$Dir)
    if (-not $Dir) { $Dir = Get-DotfilesMarkerDir }
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    Get-ChildItem -LiteralPath $Dir -Filter "*-$script:DotfilesRunId*" -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }
        }
}

# --- perfiles de PowerShell ------------------------------------------------

# Marcadores de los bloques gestionados. Son LOS MISMOS que usan los scripts
# bash (docs/STEPS.md): asi un archivo tocado por ambos instaladores mantiene
# la misma senal y `doctor` puede buscar una unica cabecera.
$script:BlockEnvHeader = '# >>> dotfiles-env (no editar)'
$script:BlockEnvFooter = '# <<< dotfiles-env'
$script:BlockThemeHeader = '# >>> dotfiles-theme (apply-theme.ps1) - no editar'
$script:BlockThemeFooter = '# <<< dotfiles-theme'
$script:BlockPoshHeader = '# >>> dotfiles-oh-my-posh (no editar)'
$script:BlockPoshFooter = '# <<< dotfiles-oh-my-posh'

function Get-DotfilesBlockHeader {
    param([ValidateSet('env', 'theme', 'posh')][string]$Kind)
    switch ($Kind) {
        'env' { return $script:BlockEnvHeader }
        'theme' { return $script:BlockThemeHeader }
        'posh' { return $script:BlockPoshHeader }
    }
}

function Get-DotfilesBlockFooter {
    param([ValidateSet('env', 'theme', 'posh')][string]$Kind)
    switch ($Kind) {
        'env' { return $script:BlockEnvFooter }
        'theme' { return $script:BlockThemeFooter }
        'posh' { return $script:BlockPoshFooter }
    }
}

# Set-DotfilesProfileBlock escribe un bloque gestionado en TODOS los perfiles
# (PS7 y 5.1). Crea Documents\PowerShell si no existe.
function Set-DotfilesProfileBlock {
    param(
        [Parameter(Mandatory)][ValidateSet('env', 'theme', 'posh')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [ValidateSet('append', 'prepend')][string]$Position = 'append',
        [string[]]$Profiles
    )
    $header = Get-DotfilesBlockHeader -Kind $Kind
    $footer = Get-DotfilesBlockFooter -Kind $Kind
    if (-not $Profiles) { $Profiles = Get-DotfilesProfilePaths }
    $done = @()
    $failed = @()
    foreach ($pf in $Profiles) {
        $dir = Split-Path -Parent $pf
        try {
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
            if (-not (Test-Path -LiteralPath $pf -PathType Leaf)) {
                Write-DotfilesFile -Path $pf -Content "# perfil de PowerShell gestionado por enviroment-dotfiles`n" -Encoding 'utf8bom' | Out-Null
            }
            Backup-DotfilesFile -Path $pf | Out-Null
            $ok = Set-DotfilesManagedBlock -Path $pf -Header $header -Footer $footer -Body $Body -Position $Position
            if ($ok) { $done += $pf } else { $failed += $pf }
        } catch {
            $failed += $pf
        }
    }
    return [pscustomobject]@{ done = $done; failed = $failed }
}

# Install-DotfilesProfileEnv: hace que una terminal nueva cargue env.ps1.
# Equivale a dotfiles_env_install_bashrc + dotfiles_shell_startup_install +
# dotfiles_bash_profile_install del flujo bash.
function Install-DotfilesProfileEnv {
    param([string[]]$Profiles)
    $file = Get-DotfilesEnvFilePath
    $q = $file.Replace("'", "''")
    $body = "if (Test-Path -LiteralPath '$q') { . '$q' }"
    $r = Set-DotfilesProfileBlock -Kind 'env' -Body $body -Profiles $Profiles
    return $r
}

function Test-DotfilesProfileEnv {
    param([string[]]$Profiles)
    if (-not $Profiles) { $Profiles = Get-DotfilesProfilePaths }
    $header = Get-DotfilesBlockHeader -Kind 'env'
    $footer = Get-DotfilesBlockFooter -Kind 'env'
    $envfile = Get-DotfilesEnvFilePath
    foreach ($pf in $Profiles) {
        if (-not (Test-DotfilesManagedBlock -Path $pf -Header $header -Footer $footer -MustContain $envfile)) {
            return $false
        }
    }
    return $true
}

# --- assets publicos -------------------------------------------------------

# Get-DotfilesPublicPathList: UNICA lista de assets publicos, compartida por
# el paso "Restaurar configuracion" y por sync.ps1. En Windows las rutas se
# escriben con barras normales y se resuelven contra config/opencode.
#
# DEBE coincidir exactamente con PUBLIC_PATHS de scripts/sync.sh; CI lo
# comprueba (tests/windows/Manifest.Tests.ps1) para que no drenen.
function Get-DotfilesPublicPathList {
    return @(
        'AGENTS.md',
        'cli.json',
        'opencode.jsonc',
        'tui.jsonc',
        'package.json',
        'package-lock.json',
        'service.json.example',
        'agents/lua-qa.md',
        'agents/net-qa.md',
        'agents/react-qa.md',
        'plugins/',
        'skills/generate-test-cases/',
        'skills/generate-tests/',
        'skills/graphify/',
        'skills/security-audit/',
        'memory/skills-best-practices.md'
    )
}

# Get-DotfilesShimPath crea el shim `python3` para las skills que lo invocan
# (graphify y update-external-skills usan python3 en las instrucciones).
function Install-DotfilesCommandShim {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Target
    )
    $paths = Get-DotfilesPaths
    if (-not (Test-Path -LiteralPath $paths.BinDir)) {
        New-Item -ItemType Directory -Force -Path $paths.BinDir | Out-Null
    }
    if (-not (Test-DotfilesWindows)) { return $null }
    $cmd = Join-Path $paths.BinDir "$Alias.cmd"
    $body = "@echo off`r`n`"$Target`" %*`r`n"
    Write-DotfilesFile -Path $cmd -Content $body -Encoding 'ascii' | Out-Null
    Add-DotfilesEnvPath -Dir $paths.BinDir | Out-Null
    return $cmd
}

Export-ModuleMember -Function *
