#!/usr/bin/env pwsh
# setup-git-identity.ps1 - configura identidad(es) git multi-cuenta en Windows
# nativo.
#
# Modelo de cuentas (identico al script bash, docs/GIT-IDENTITY.md):
#   - Cuenta personal (obligatoria): clave ~/.ssh/id_ed25519_personal y perfil
#     ~/.gitconfig-personal; actua en todo el home via includeIf "gitdir:<home>/".
#   - Hasta 3 cuentas opcionales ("espacios"): cada una vive en $HOME\<Espacio>
#     con clave id_ed25519_<slug>, perfil ~/.gitconfig-<slug> y alias SSH
#     git-<slug>. Un includeIf por carpeta cambia user.name/email y un bloque
#     url.insteadOf reescribe los remotes de su plataforma al alias.
#   - Estado: ~/.config/enviroment-dotfiles/git-accounts.json (manifiesto
#     generado; lo leen el paso 'Registrar y probar llaves SSH' y el doctor).
#   - ~/.ssh/config: solo se regenera la seccion entre los marcadores
#     dotfiles-managed; el resto se conserva. El bloque gestionado va PRIMERO
#     porque en ssh gana la primera coincidencia.
#
# Diferencias con el bash:
#   - los permisos son ACL (icacls), no chmod;
#   - las rutas de includeIf van con barras normales (C:/Users/...), que es
#     como Git for Windows normaliza los gitdir;
#   - ssh-agent es un servicio de Windows: si no esta corriendo se avisa en vez
#     de colgar el paso.
#
# Modo panel: los valores vienen de $NUI_STEP_RESULT (los pide el panel).
# Modo standalone: se preguntan por consola o via GIT_PERSONAL_* / GIT_ACC<i>_*.

[CmdletBinding()]
param(
    [string]$RepoDir,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $RepoDir) { $RepoDir = Split-Path -Parent $PSScriptRoot }
$env:REPO_DIR = $RepoDir
$LibDir = [IO.Path]::Combine($RepoDir, 'scripts', 'lib')
Import-Module (Join-Path $LibDir 'dotfiles.psm1') -Force
Import-Module (Join-Path $LibDir 'ui.psm1') -Force
Import-Module (Join-Path $LibDir 'theme.psm1') -Force

$Paths = Get-DotfilesPaths
$env:NUI_ENV_FILE = if ($env:NUI_ENV_FILE) { $env:NUI_ENV_FILE } else { $Paths.EnvFile }
if ($NonInteractive) { $env:NUI_NONINTERACTIVE = '1' }

# --- entrada: panel o standalone -------------------------------------------

$PanelMode = $false
$form = @{}
if ($env:NUI_STEP_RESULT -and (Test-Path -LiteralPath $env:NUI_STEP_RESULT -PathType Leaf)) {
    $tmpVars = @{}
    . $env:NUI_STEP_RESULT
    foreach ($n in 'p_platform', 'p_name', 'p_email', 'acc_count',
        'acc1_espacio', 'acc1_platform', 'acc1_name', 'acc1_email',
        'acc2_espacio', 'acc2_platform', 'acc2_name', 'acc2_email',
        'acc3_espacio', 'acc3_platform', 'acc3_name', 'acc3_email') {
        $v = Get-Variable -Name $n -ErrorAction SilentlyContinue
        $form[$n] = if ($v) { [string]$v.Value } else { '' }
    }
    $PanelMode = $true
}

function Say {
    param([Parameter(Mandatory)][string]$Text)
    Write-DotfilesMessage -Level info -Text $Text
}

function Ask {
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [string]$Prompt = '',
        [string]$Default = '',
        # En standalone se aceptan los nombres historicos del script bash
        # (GIT_PERSONAL_NAME, GIT_ACC1_ESPACIO, ...) ademas del nombre de
        # campo del panel (p_name, acc1_espacio).
        [string]$AltEnvName
    )
    if ($PanelMode) {
        if ($form.ContainsKey($EnvName)) { return $form[$EnvName] }
        return $Default
    }
    foreach ($name in @($AltEnvName, $EnvName)) {
        if (-not $name) { continue }
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) { return $v }
    }
    if ($env:NUI_NONINTERACTIVE -eq '1') { return $Default }
    if ([Environment]::UserInteractive -and $Prompt) {
        $ans = Read-DotfilesConsoleLine -Prompt $Prompt
        if ($ans) { return $ans }
    }
    return $Default
}

# --- validacion ------------------------------------------------------------

# Las identidades se escriben en ~/.gitconfig y se pasan a ssh-keygen como
# argumentos argv (nunca interpoladas). Aun asi se rechazan caracteres de
# control y corchetes, que podrian inyectar secciones de git config.
function Test-GitIdentityValue {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][AllowNull()][string]$Value
    )
    if ($Value -match '[\x00-\x1F\x7F]') {
        Say "$Label contiene caracteres de control; valor rechazado"
        return $false
    }
    if ($Value -match '[\[\]]') {
        Say "$Label contiene '[' o ']'; valor rechazado"
        return $false
    }
    return $true
}

function Get-NormalizedPlatform {
    param([string]$Value)
    if ($Value -eq 'bitbucket') { return 'bitbucket' }
    return 'github'
}

# Slug en minusculas, sin acentos y con guiones simples. Equivale al
# slugify() de bash (tr + iconv //TRANSLIT + sed).
function Get-GitAccountSlug {
    param([AllowEmptyString()][string]$Value)
    $s = $Value.ToLowerInvariant()
    try {
        $form1 = $s.Normalize([System.Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $form1.ToCharArray()) {
            if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne
                [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($ch)
            }
        }
        $s = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
    } catch { }
    $s = $s -replace '[^a-z0-9_-]', '-'
    $s = $s -replace '-+', '-'
    $s = $s.Trim('-')
    return $s
}

function Get-PlatformUrl {
    param([string]$Platform)
    if ($Platform -eq 'bitbucket') { return 'https://bitbucket.org/account/settings/ssh-keys/' }
    return 'https://github.com/settings/ssh/new'
}

function Get-PlatformHost {
    param([string]$Platform)
    if ($Platform -eq 'bitbucket') { return 'bitbucket.org' }
    return 'github.com'
}

# Get-GitDirPattern: el valor completo de un includeIf "gitdir:...".
#
# Git for Windows normaliza los gitdir a barras normales, asi que se escribe
# C:/Users/<u>/<Espacio>/ (nunca backslashes: se escapan en el patrond).
# El prefijo 'gitdir:' va DENTRO del valor: sin el, Git ignora el include.
function Get-GitDirPattern {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    return 'gitdir:' + ($full -replace '\\', '/') + '/'
}

function Invoke-GitCmd {
    param([Parameter(Mandatory)][string[]]$Argv)
    if ($PanelMode) {
        $code = Invoke-DotfilesNative -Argv $Argv
        return $code
    }
    return (Invoke-DotfilesNative -Argv $Argv)
}

# --- estructuras -----------------------------------------------------------

New-Item -ItemType Directory -Force -Path $Paths.SshDir | Out-Null
New-Item -ItemType Directory -Force -Path $Paths.ConfigRoot | Out-Null
[void](Set-DotfilesPrivateAcl -Path $Paths.SshDir -Kind dir)

if (-not (Test-DotfilesCommand 'ssh-keygen')) {
    Say 'No hay ssh-keygen (OpenSSH Client). Instala la caracteristica de Windows y relanza.'
    Write-UiWarn 'Identidad Git omitida: OpenSSH no esta disponible'
    exit 0
}
if (-not (Test-DotfilesCommand 'git')) {
    Say 'No hay git en el PATH; no se puede configurar la identidad.'
    exit 1
}

$PPlatform = Get-NormalizedPlatform (
    Ask -EnvName 'p_platform' -AltEnvName 'GIT_PERSONAL_PLATFORM' -Prompt 'Plataforma personal (github|bitbucket):' -Default 'github'
)
$PName = Ask -EnvName 'p_name' -AltEnvName 'GIT_PERSONAL_NAME' -Prompt 'Nombre personal:'
$PEmail = Ask -EnvName 'p_email' -AltEnvName 'GIT_PERSONAL_EMAIL' -Prompt 'Email personal:'

if (-not $PName -or -not $PEmail) {
    Say 'Identidad personal omitida (nombre/email vacios).'
    exit 0
}
if (-not (Test-GitIdentityValue -Label 'Nombre personal' -Value $PName)) { exit 1 }
if (-not (Test-GitIdentityValue -Label 'Email personal' -Value $PEmail)) { exit 1 }

# Cada espacio es un hashtable (sin clases): el manifiesto JSON se genera
# directamente de la misma estructura y no depende del parser de tipos de 5.1.
$spaces = @()

$countRaw = Ask -EnvName 'acc_count' -AltEnvName 'GIT_ACC_COUNT' -Prompt 'Cuantas cuentas adicionales (0-3)?' -Default '0'
$count = 0
if (-not [int]::TryParse("$countRaw".Trim(), [ref]$count)) { $count = 0 }
if ($count -lt 0 -or $count -gt 3) { $count = 0 }

for ($i = 1; $i -le $count; $i++) {
    $esp = Ask -EnvName "acc${i}_espacio" -AltEnvName "GIT_ACC${i}_ESPACIO" -Prompt "Espacio $i (carpeta en tu home, ej. Nuxiba):"
    if (-not $esp) { Say "Cuenta $i sin espacio; omitida"; continue }
    if ($esp -match '^[.]' -or $esp -match '[/\\]') {
        Say "Espacio invalido ($esp); cuenta omitida"
        continue
    }
    $plt = Get-NormalizedPlatform(
        Ask -EnvName "acc${i}_platform" -AltEnvName "GIT_ACC${i}_PLATFORM" -Prompt "Plataforma cuenta $i (github|bitbucket):" -Default 'github'
    )
    $nam = Ask -EnvName "acc${i}_name" -AltEnvName "GIT_ACC${i}_NAME" -Prompt "Nombre cuenta ${i}:"
    $eml = Ask -EnvName "acc${i}_email" -AltEnvName "GIT_ACC${i}_EMAIL" -Prompt "Email cuenta ${i}:"
    if (-not $nam -and -not $eml) {
        $nam = $PName; $eml = $PEmail
        Say "Cuenta $i : sin nombre/email; se usan los personales"
    }
    if (-not $nam -or -not $eml) { Say "Cuenta $i incompleta; omitida"; continue }
    if (-not (Test-GitIdentityValue -Label "Nombre de la cuenta '$esp'" -Value $nam)) { continue }
    if (-not (Test-GitIdentityValue -Label "Email de la cuenta '$esp'" -Value $eml)) { continue }

    $slug = Get-GitAccountSlug -Value $esp
    if (-not $slug) { Say "No se pudo normalizar el espacio '$esp'; cuenta omitida"; continue }
    if (@($spaces | Where-Object { $_['slug'] -eq $slug }).Count -gt 0) {
        Say "Espacio duplicado ($slug); cuenta omitida"
        continue
    }

    $folder = Join-Path $Paths.Home $esp
    $rf = Get-GitDirPattern -Path $folder
    $clash = $false
    foreach ($s in $spaces) {
        $sf = Get-GitDirPattern -Path $s['folder']
        if ($rf.StartsWith($sf) -or $sf.StartsWith($rf)) {
            Say "La carpeta '$esp' colisiona con otra cuenta; cuenta omitida"
            $clash = $true
            break
        }
    }
    if ($clash) { continue }

    if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        Say "Aviso: $folder ya existe con contenido; no se toca nada"
    } else {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }

    $spaces += @{
        espacio  = $esp
        platform = $plt
        name     = $nam
        email    = $eml
        slug     = $slug
        folder   = $folder
        key      = (Join-Path $Paths.SshDir "id_ed25519_$slug")
        pub      = (Join-Path $Paths.SshDir "id_ed25519_$slug.pub")
    }
}

# --- claves SSH ------------------------------------------------------------

# Add-SshAgentKey: en Windows ssh-agent es un SERVICIO. Si no esta corriendo,
# ssh-add falla: se avisa con la instruccion concreta en lugar de colgar.
function Add-SshAgentKey {
    param([Parameter(Mandatory)][string]$Key)
    if (-not $env:SSH_AUTH_SOCK) {
        return 'no-agent'
    }
    if (-not (Test-DotfilesCommand 'ssh-add')) { return 'no-agent' }
    $code = Invoke-DotfilesNative -Argv @('ssh-add', $Key)
    if ($code -eq 0) { return 'ok' }
    return 'fail'
}

function New-SshKey {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Comment
    )
    if (Test-Path -LiteralPath $Key -PathType Leaf) { return $true }
    # Invoke-DotfilesNativeQuoted: en PowerShell 5.1 el `-N ''` con `&` se
    # pierde y ssh-keygen se queda preguntando la passphrase por consola.
    $code = Invoke-DotfilesNativeQuoted -Argv @('ssh-keygen', '-t', 'ed25519', '-C', $Comment, '-f', $Key, '-N', '')
    if ($code -ne 0) { return $false }
    [void](Set-DotfilesPrivateAcl -Path $Key)
    [void](Set-DotfilesPrivateAcl -Path "$Key.pub")
    return $true
}

$personalKey = Join-Path $Paths.SshDir 'id_ed25519_personal'
$personalPub = "$personalKey.pub"

Say 'Generando/verificando clave personal...'
if (-not (New-SshKey -Key $personalKey -Comment $PEmail)) {
    Say 'No se pudo generar la clave personal.'
    exit 1
}
[void](Set-DotfilesPrivateAcl -Path $personalKey)
[void](Set-DotfilesPrivateAcl -Path $personalPub)
$agentPersonal = Add-SshAgentKey -Key $personalKey

$okSpaces = @()
foreach ($s in $spaces) {
    Say "Generando clave $($s['espacio'])..."
    if (-not (New-SshKey -Key $s['key'] -Comment $s['email'])) {
        Say "No se pudo generar la clave $($s['espacio']); cuenta desactivada"
        continue
    }
    [void](Set-DotfilesPrivateAcl -Path $s['key'])
    [void](Set-DotfilesPrivateAcl -Path "$($s['key']).pub")
    $null = Add-SshAgentKey -Key $s['key']
    $okSpaces += $s
}

if ($agentPersonal -ne 'ok') {
    Say 'ssh-agent no disponible: inicia el servicio "OpenSSH Authentication Agent" (Start-Service ssh-agent) y ejecuta ssh-add si quieres usar el agente.'
}

# --- migracion del esquema viejo -------------------------------------------

$legacyDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Repositorios'
$keepLegacyInclude = 0
$legacyInclude = $false
$gitConfigPath = $Paths.GitConfig
if (Test-Path -LiteralPath $gitConfigPath -PathType Leaf) {
    $gcText = Get-DotfilesFileText -Path $gitConfigPath
    if ($gcText -match 'Documents[/\\]Repositorios') { $legacyInclude = $true }
}
$legacyContent = (Test-Path -LiteralPath $legacyDir -PathType Container) -and
@(Get-ChildItem -LiteralPath $legacyDir -Force -ErrorAction SilentlyContinue).Count -gt 0

$migrateLegacy = if ($env:GIT_MIGRATE_LEGACY) { $env:GIT_MIGRATE_LEGACY } else { '0' }
if ($okSpaces.Count -eq 1 -and $legacyContent -and $migrateLegacy -ne '1') {
    if (-not $PanelMode -and $env:NUI_NONINTERACTIVE -ne '1' -and [Environment]::UserInteractive) {
        if (Wait-DotfilesPanelConfirm -Id 'migrate-legacy' -Question "Mover el contenido de $legacyDir a $($okSpaces[0]['folder'])?") {
            $migrateLegacy = '1'
        }
    }
    if ($migrateLegacy -ne '1') {
        Say "Migracion omitida: $legacyDir conserva su contenido (usa GIT_MIGRATE_LEGACY=1 para moverlo)"
    }
}

if ($okSpaces.Count -eq 1 -and $legacyContent -and $migrateLegacy -eq '1') {
    $target = $okSpaces[0]['folder']
    if ((Get-GitDirPattern -Path $target) -eq (Get-GitDirPattern -Path $legacyDir)) {
        Say "Migracion: la carpeta del espacio ya es $legacyDir; no se mueve nada"
    } else {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $moved = 0
        Get-ChildItem -LiteralPath $legacyDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Move-Item -LiteralPath $_.FullName -Destination $target -Force
                $moved++
            } catch { }
        }
        Say "Migracion: $moved elementos de $legacyDir -> $target"
        try { Remove-Item -LiteralPath $legacyDir -Force -ErrorAction Stop } catch { }
    }
} elseif ($legacyInclude -and (Test-Path -LiteralPath (Join-Path $Paths.Home '.gitconfig-nuxiba'))) {
    $keepLegacyInclude = 1
    Say 'Esquema viejo: se conserva el include de ~/Documents/Repositorios; mueve esos repos a la carpeta de un espacio y relanza'
} elseif ($legacyInclude) {
    Say 'Esquema viejo: los repos de Documents/Repositorios quedaran con identidad personal; muevelos a la carpeta del espacio que corresponda'
}

# --- ~/.ssh/config (seccion gestionada) -------------------------------------

$sshHeader = '# >>> dotfiles-managed (setup-git-identity.ps1) - no editar entre los marcadores'
$sshFooter = '# <<< dotfiles-managed'

$sb = New-Object System.Text.StringBuilder
function Append([string]$Text) { [void]$sb.AppendLine($Text) }

if ($PPlatform -eq 'bitbucket') {
    @(
        'Host bitbucket.org ssh.bitbucket.org',
        '    HostName ssh.bitbucket.org',
        '    User git',
        '    IdentityFile ~/.ssh/id_ed25519_personal',
        '    IdentitiesOnly yes'
    ) | ForEach-Object { Append $_ }
} else {
    @(
        'Host github.com',
        '    HostName github.com',
        '    User git',
        '    IdentityFile ~/.ssh/id_ed25519_personal',
        '    IdentitiesOnly yes'
    ) | ForEach-Object { Append $_ }
}

# Alias de compatibilidad: clone-repos.sh (repo privado) usa git@bitbucket-nuxiba.
$compat = $false
foreach ($s in $okSpaces) {
    if (-not $compat -and $s['platform'] -eq 'bitbucket') {
        @(
            'Host bitbucket-nuxiba',
            '    HostName ssh.bitbucket.org',
            '    User git',
            "    IdentityFile ~/.ssh/id_ed25519_$($s['slug'])",
            '    IdentitiesOnly yes'
        ) | ForEach-Object { Append $_ }
        $compat = $true
    }
}
foreach ($s in $okSpaces) {
    $hostName = if ($s['platform'] -eq 'bitbucket') { 'ssh.bitbucket.org' } else { 'github.com' }
    @(
        "Host git-$($s['slug'])",
        "    HostName $hostName",
        '    User git',
        "    IdentityFile ~/.ssh/id_ed25519_$($s['slug'])",
        '    IdentitiesOnly yes'
    ) | ForEach-Object { Append $_ }
}
$sshBody = $sb.ToString().TrimEnd("`r", "`n")

$sshConfig = Join-Path $Paths.SshDir 'config'
if (Test-Path -LiteralPath $sshConfig -PathType Leaf) {
    # Aviso (sin tocar nada): el usuario ya tiene Hosts propios que quedan
    # fuera de la seccion gestionada.
    $rest = (Get-DotfilesFileText -Path $sshConfig) -replace '(?m)^.*dotfiles-managed.*$', ''
    if ($rest -match '(?m)^Host (github\.com|bitbucket\.org|ssh\.bitbucket\.org)') {
        Say "$sshConfig : bloques previos conservados fuera de la seccion gestionada (el bloque gestionado tiene prioridad)"
    }
}
Backup-DotfilesFile -Path $sshConfig | Out-Null
$sshOk = Set-DotfilesManagedBlock -Path $sshConfig -Header $sshHeader -Footer $sshFooter -Body $sshBody -Position 'prepend'
if (-not $sshOk) {
    Say 'No se modifico ~/.ssh/config (bloque gestionado incompleto)'
}
[void](Set-DotfilesPrivateAcl -Path $sshConfig)

# --- ~/.gitconfig (includes por carpeta) ------------------------------------

$gcHeader = '# >>> dotfiles-gitconfig (setup-git-identity.ps1) - no editar'
$gcFooter = '# <<< dotfiles-gitconfig'
$themeGit = (Join-DotfilesPath -Base $Paths.ConfigRoot -Child 'git/theme.gitconfig') -replace '\\', '/'
$UnixHome = $Paths.Home -replace '\\', '/'

$gcLines = @(
    "[include]",
    "    path = $themeGit"
    ("[includeIf `"{0}`"]" -f (Get-GitDirPattern -Path $Paths.Home)),
    "    path = $UnixHome/.gitconfig-personal"
)
if ($keepLegacyInclude -eq 1) {
    $gcLines += @(
        ("[includeIf `"{0}`"]" -f (Get-GitDirPattern -Path $legacyDir)),
        "    path = $UnixHome/.gitconfig-nuxiba"
    )
}
foreach ($s in $okSpaces) {
    $gcLines += @(
        ("[includeIf `"{0}`"]" -f (Get-GitDirPattern -Path $s['folder'])),
        "    path = $UnixHome/.gitconfig-$($s['slug'])"
    )
}
$gcBody = $gcLines -join "`n"

Backup-DotfilesFile -Path $gitConfigPath | Out-Null
if (-not (Set-DotfilesManagedBlock -Path $gitConfigPath -Header $gcHeader -Footer $gcFooter -Body $gcBody -Position 'prepend')) {
    Say 'No se modifico ~/.gitconfig (bloque gestionado incompleto)'
}

# --- perfiles de identidad --------------------------------------------------

function Get-InsteadOfBlock {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Platform
    )
    if ($Platform -eq 'bitbucket') {
        return @(
            "[url `"git@git-${Slug}:`"]",
            '    insteadOf = git@bitbucket.org:',
            '    insteadOf = ssh://git@ssh.bitbucket.org/',
            '    insteadOf = ssh://git@bitbucket.org/'
        ) -join "`n"
    }
    return @(
        "[url `"git@git-${Slug}:`"]",
        '    insteadOf = git@github.com:'
    ) -join "`n"
}

# Write-UserProfile escribe user.name/user.email con `git config --file`
# (argv literal, nunca interpolado) y preserva lo que ya hubiera en el perfil.
function Write-UserProfile {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Email
    )
    Backup-DotfilesFile -Path $File | Out-Null
    if (-not (Test-Path -LiteralPath $File)) {
        New-Item -ItemType File -Force -Path $File | Out-Null
    }
    if (-not (Set-DotfilesGitConfig -File $File -Key 'user.name' -Value $Name)) { return $false }
    if (-not (Set-DotfilesGitConfig -File $File -Key 'user.email' -Value $Email)) { return $false }
    [void](Set-DotfilesPrivateAcl -Path $File)
    return $true
}

$personalProfile = Join-Path $Paths.Home '.gitconfig-personal'
if (-not (Test-Path -LiteralPath $personalProfile)) {
    if (-not (Write-UserProfile -File $personalProfile -Name $PName -Email $PEmail)) {
        Say 'No se pudo escribir ~/.gitconfig-personal'
    }
} else {
    [void](Set-DotfilesPrivateAcl -Path $personalProfile)
    Say "$personalProfile ya existe; se conserva"
}

foreach ($s in $okSpaces) {
    $pf = Join-Path $Paths.Home ".gitconfig-$($s['slug'])"
    $block = Get-InsteadOfBlock -Slug $s['slug'] -Platform $s['platform']
    if (-not (Test-Path -LiteralPath $pf)) {
        if (-not (Write-UserProfile -File $pf -Name $s['name'] -Email $s['email'])) { continue }
        $cur = Get-DotfilesFileText -Path $pf
        Write-DotfilesFile -Path $pf -Content ($cur + "`n" + $block + "`n") -Encoding 'utf8' | Out-Null
        [void](Set-DotfilesPrivateAcl -Path $pf)
    } elseif ((Get-DotfilesFileText -Path $pf) -notmatch [regex]::Escape("git-$($s['slug']):")) {
        Backup-DotfilesFile -Path $pf | Out-Null
        $cur = Get-DotfilesFileText -Path $pf
        Write-DotfilesFile -Path $pf -Content ($cur.TrimEnd() + "`n`n" + $block + "`n") -Encoding 'utf8' | Out-Null
        Say "Se agrego el enrutamiento SSH a $pf"
    } else {
        Say "$pf ya existe; se conserva"
    }
    [void](Set-DotfilesPrivateAcl -Path $pf)
}

# --- manifiesto de cuentas ---------------------------------------------------

$manifest = [ordered]@{
    generated_by = 'setup-git-identity.ps1'
    generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    personal     = [ordered]@{
        platform = $PPlatform
        name     = $PName
        email    = $PEmail
        key      = $personalKey
        pub      = $personalPub
        host     = Get-PlatformHost -Platform $PPlatform
        url      = Get-PlatformUrl -Platform $PPlatform
    }
    spaces       = @($okSpaces | ForEach-Object {
            [ordered]@{
                espacio  = $_.Espacio
                slug     = $_.Slug
                platform = $_.Platform
                name     = $_.Name
                email    = $_.Email
                folder   = $_.Folder
                gitdir   = Get-GitDirPattern -Path $_.Folder
                key      = $_.Key
                pub      = $_.Pub
                host     = Get-PlatformHost -Platform $_.Platform
                target   = "git@git-$($_.Slug)"
                url      = Get-PlatformUrl -Platform $_.Platform
            }
        })
}
Write-DotfilesJson -Path $Paths.AccountsFile -Object $manifest -Backup | Out-Null
[void](Set-DotfilesPrivateAcl -Path $Paths.AccountsFile)

# --- resumen + claves publicas ---------------------------------------------

function Get-KeyFingerprint {
    param([Parameter(Mandatory)][string]$Pub)
    if (-not (Test-Path -LiteralPath $Pub)) { return '?' }
    $out = & ssh-keygen -lf $Pub 2>$null | Select-Object -First 1
    if ($out -and ($out -split '\s+').Count -ge 2) { return ($out -split '\s+')[1] }
    return '?'
}

Say "Personal ($PPlatform): $personalPub ($(Get-KeyFingerprint -Pub $personalPub))"
foreach ($s in $okSpaces) {
    Say "$($s['espacio']) ($($s['platform'])): $($s['pub']) ($(Get-KeyFingerprint -Pub $s['pub']))"
}
Say 'Guarda las claves publicas en tus plataformas.'

# Todas las claves publicas quedan SIEMPRE en un archivo 0600/ACL privado,
# haya o no portapapeles: asi ninguna queda inaccesible si la prueba SSH falla.
$dump = New-Object System.Text.StringBuilder
function AppendDump([string]$Text) { [void]$dump.AppendLine($Text) }

AppendDump "=== Personal/$PPlatform (pegar en $(Get-PlatformUrl -Platform $PPlatform))"
if (Test-Path -LiteralPath $personalPub) { AppendDump (Get-DotfilesFileText -Path $personalPub).TrimEnd() }
foreach ($s in $okSpaces) {
    AppendDump ""
    AppendDump "=== $($s['espacio'])/$($s['platform']) (pegar en $(Get-PlatformUrl -Platform $s['platform']))"
    if (Test-Path -LiteralPath $s['pub']) { AppendDump (Get-DotfilesFileText -Path $s['pub']).TrimEnd() }
}
Backup-DotfilesFile -Path $Paths.KeysDump | Out-Null
Write-DotfilesFile -Path $Paths.KeysDump -Content $dump.ToString() -Encoding 'utf8' | Out-Null
[void](Set-DotfilesPrivateAcl -Path $Paths.KeysDump)
Say "Todas las claves publicas guardadas en $($Paths.KeysDump)"

# Host keys pinnadas: sin esto, un git/ssh posterior falla con
# "Host key verification failed" en maquina nueva.
if (Update-DotfilesKnownHosts) {
    Say 'Host keys de GitHub/Bitbucket fijadas en ~/.ssh/known_hosts'
} else {
    Say 'No se pudieron fijar las host keys en ~/.ssh/known_hosts'
}

if ($okSpaces.Count -gt 0) {
    Say 'Configura el servicio ssh-agent si quieres usar el agente: Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent'
}
Say 'Usa el paso "Registrar y probar llaves SSH" para copiar, registrar y comprobar cada llave.'
Say 'Configuracion de identidad completada.'
