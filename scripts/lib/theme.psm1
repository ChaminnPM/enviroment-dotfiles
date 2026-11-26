# theme.psm1 - tema canonico (Dracula + JetBrainsMono Nerd Font) en Windows.
#
# Fuente unica de verdad: config/theme/dracula.env. Este modulo solo sabe leer
# ese archivo, instalar la fuente en el sitio que impone Windows y renderizar
# plantillas; no duplica colores.
#
# Diferencias frente a theme.sh (Linux/WSL):
#   - no existe fontconfig: la deteccion es registro HKCU + carpeta de fuentes
#     de usuario;
#   - el terminal objetivo es Windows Terminal (no Alacritty);
#   - el perfil de shell es PowerShell, no ~/.bashrc.

Set-StrictMode -Version 2.0

# Autodependencia: permite importar este modulo suelto en tests.
if (-not (Get-Command Get-DotfilesPaths -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'dotfiles.psm1') -Force -ErrorAction Stop
}

# --- tokens ----------------------------------------------------------------

function Get-DotfilesThemeEnvFile {
    $paths = Get-DotfilesPaths
    $candidates = @(
        $env:THEME_ENV_FILE,
        (Join-DotfilesPath -Base $paths.RepoDir -Child 'config/theme/dracula.env'),
        (Join-DotfilesPath -Base $paths.OpenCodeDir -Child 'theme/dracula.env'),
        (Join-Path $paths.ThemeDir 'dracula.env')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

# Read-DotfilesTheme devuelve una tabla hash con los tokens, con defaults
# embebidos para que un fallo de lectura no deje variables sin definir.
function Read-DotfilesTheme {
    $defaults = [ordered]@{
        THEME_NAME           = 'dracula'
        THEME_BG             = '#282a36'
        THEME_BLACK_DARKER   = '#21222c'
        THEME_CURRENT        = '#44475a'
        THEME_FG             = '#f8f8f2'
        THEME_COMMENT        = '#6272a4'
        THEME_RED            = '#ff5555'
        THEME_GREEN          = '#50fa7b'
        THEME_ORANGE         = '#ffb86c'
        THEME_YELLOW         = '#f1fa8c'
        THEME_PURPLE         = '#bd93f9'
        THEME_PINK           = '#ff79c6'
        THEME_CYAN           = '#8be9fd'
        THEME_BRIGHT_BLACK   = '#6272a4'
        THEME_BRIGHT_RED     = '#ff6e6e'
        THEME_BRIGHT_GREEN   = '#69ff94'
        THEME_BRIGHT_YELLOW  = '#ffffa5'
        THEME_BRIGHT_BLUE    = '#d6acff'
        THEME_BRIGHT_MAGENTA = '#ff92df'
        THEME_BRIGHT_CYAN    = '#a4ffff'
        THEME_BRIGHT_WHITE   = '#ffffff'
        THEME_FONT_FAMILY    = 'JetBrainsMono Nerd Font'
        THEME_FONT_SIZE      = '10.0'
        THEME_NERD_VERSION   = 'v3.4.0'
        THEME_NERD_REPO_URL  = 'https://github.com/ryanoasis/nerd-fonts'
        THEME_NERD_ASSET     = 'JetBrainsMono.zip'
        THEME_OMB_THEME      = 'vscode'
        THEME_EZA_COLORS     = ''
        THEME_FZF_OPTS       = ''
    }
    $t = @{}
    foreach ($k in $defaults.Keys) { $t[$k] = $defaults[$k] }

    $file = Get-DotfilesThemeEnvFile
    if ($file) {
        $parsed = Read-DotfilesEnvFile -Path $file
        foreach ($k in $parsed.Keys) { $t[$k] = $parsed[$k] }
    }
    $t['__file'] = $file
    return $t
}

function Set-DotfilesThemeEnv {
    param([hashtable]$Theme)
    foreach ($k in $Theme.Keys) {
        if ($k -eq '__file') { continue }
        Set-Item -Path ("env:" + $k) -Value $Theme[$k]
    }
}

# --- manifiesto ------------------------------------------------------------

function Write-DotfilesThemeManifest {
    param([hashtable]$Theme)
    $paths = Get-DotfilesPaths
    $obj = [ordered]@{
        theme        = $Theme.THEME_NAME
        font         = $Theme.THEME_FONT_FAMILY
        nerd_version = $Theme.THEME_NERD_VERSION
        applied      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Write-DotfilesJson -Path $paths.ThemeManifest -Object $obj | Out-Null
    return $paths.ThemeManifest
}

# --- fuente Nerd -----------------------------------------------------------

# Get-DotfilesFontRegistry: nombres registrados por el usuario (HKCU).
# Es el equivalente Windows de `fc-match`: no hay cache que refrescar, pero si
# hay que mirar el registro, porque el directorio de fuentes de usuario no es
# suficiente por si solo.
function Get-DotfilesFontRegistry {
    $out = @()
    try {
        $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (Test-Path -LiteralPath $key) {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            $out = @($props.PSObject.Properties | ForEach-Object { $_.Name })
        }
    } catch { }
    return $out
}

function Test-DotfilesNerdFontInstalled {
    param([hashtable]$Theme)
    $paths = Get-DotfilesPaths
    $family = $Theme.THEME_FONT_FAMILY
    $dir = $paths.FontDir

    # 1) archivos en el directorio de fuentes de usuario
    $onDisk = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'JetBrainsMono.*NerdFont.*\.(ttf|otf)$' })
    # 2) registro HKCU (lo que realmente ve la mayoria de apps)
    $reg = Get-DotfilesFontRegistry
    $registered = @($reg | Where-Object { $_ -match [regex]::Escape($family) }).Count -gt 0

    if ($onDisk.Count -gt 0 -and $registered) { return $true }
    # Solo en disco: todavia no visible para las apps; se trata como "no".
    return $false
}

function Test-DotfilesNerdFontFilesPresent {
    param([hashtable]$Theme)
    $paths = Get-DotfilesPaths
    # La familia del tema decide que se busca: cambiar dracula.env cambia la
    # comprobacion (unica fuente de verdad).
    $family = ([regex]::Escape(($Theme.THEME_FONT_FAMILY -replace '\s+', '')))
    $onDisk = @(Get-ChildItem -LiteralPath $paths.FontDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "$family.*NerdFont.*\.(ttf|otf)$" })
    return ($onDisk.Count -gt 0)
}

# Update-DotfilesNerdFont descarga y registra la JetBrainsMono Nerd Font.
#
# Sin admin: se copia a %LOCALAPPDATA%\Microsoft\Windows\Fonts y se registra en
# HKCU. Se emite WM_FONTCHANGE para que las apps ya abiertas la vean.
# Es el paso cosmetico del instalador: cualquier fallo se reporta como aviso.
function Update-DotfilesNerdFont {
    param([hashtable]$Theme)

    if (-not (Test-DotfilesWindows)) {
        return [pscustomobject]@{ ok = $false; installed = $false; skipped = $true; detail = 'fuente: la instalacion nativa es de Windows' }
    }
    $paths = Get-DotfilesPaths
    $family = $Theme.THEME_FONT_FAMILY

    if (Test-DotfilesNerdFontInstalled -Theme $Theme) {
        return [pscustomobject]@{ ok = $true; installed = $true; skipped = $false; detail = "Fuente $family ya instalada" }
    }

    $url = '{0}/releases/download/{1}/{2}' -f $Theme.THEME_NERD_REPO_URL, $Theme.THEME_NERD_VERSION, $Theme.THEME_NERD_ASSET
    $tmp = New-DotfilesTempDir -Prefix 'nerdfont'
    try {
        $zip = Join-Path $tmp 'font.zip'
        Write-Output '##log Descargando fuente'
        Write-Output "##log $url"
        if (-not (Invoke-DotfilesDownload -Uri $url -OutFile $zip -TimeoutSec 300)) {
            return [pscustomobject]@{ ok = $false; installed = $false; skipped = $false; detail = "no se pudo descargar $url" }
        }

        $x = Join-Path $tmp 'x'
        $files = @(Expand-DotfilesZip -Zip $zip -Destination $x -ExtensionFilter @('.ttf', '.otf'))
        if ($files.Count -eq 0) {
            return [pscustomobject]@{ ok = $false; installed = $false; skipped = $false; detail = 'el zip de la fuente no traia TTF/OTF' }
        }

        if (-not (Test-Path -LiteralPath $paths.FontDir)) {
            New-Item -ItemType Directory -Force -Path $paths.FontDir | Out-Null
        }
        $copied = 0
        $names = @()
        foreach ($f in $files) {
            $dest = Join-Path $paths.FontDir ([IO.Path]::GetFileName($f))
            try {
                Copy-Item -LiteralPath $f -Destination $dest -Force
                $copied++
                $names += [IO.Path]::GetFileName($dest)
            } catch { }
        }
        if ($copied -eq 0) {
            return [pscustomobject]@{ ok = $false; installed = $false; skipped = $false; detail = "no se pudo copiar ninguna fuente a $($paths.FontDir)" }
        }
        Write-Output "##log $copied archivos copiados a $($paths.FontDir)"

        $registered = Register-DotfilesUserFonts -FileNames $names -FontDir $paths.FontDir
        $ok = Test-DotfilesNerdFontInstalled -Theme $Theme
        Write-DotfilesThemeManifest -Theme $Theme | Out-Null

        if ($ok) {
            return [pscustomobject]@{ ok = $true; installed = $true; skipped = $false; detail = "Fuente $family instalada ($($Theme.THEME_NERD_VERSION))" }
        }
        return [pscustomobject]@{
            ok        = $true
            installed = $false
            skipped   = $false
            detail    = "la fuente esta en disco pero no figura en el registro ($registered registros); las apps la veran al reiniciar la sesion"
        }
    } finally {
        Remove-DotfilesTree -Path $tmp
    }
}

# Register-DotfilesUserFonts escribe HKCU\...\Fonts y avisa a las ventanas.
function Register-DotfilesUserFonts {
    param(
        [Parameter(Mandatory)][string[]]$FileNames,
        [Parameter(Mandatory)][string]$FontDir
    )
    $count = 0
    try {
        $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (-not (Test-Path -LiteralPath $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        foreach ($n in $FileNames) {
            $full = Join-Path $FontDir $n
            if (-not (Test-Path -LiteralPath $full)) { continue }
            # Nombre de clave: descripcion leible + "(TrueType)"; coincide con
            # lo que hace el panel de fuentes de Windows al instalar por usuario.
            $label = (([IO.Path]::GetFileNameWithoutExtension($n) -replace '-', ' ') + ' (TrueType)')
            try {
                New-ItemProperty -Path $key -Name $label -PropertyType String -Value $full -Force | Out-Null
                $count++
            } catch { }
        }
    } catch {
        Write-Warning "no se pudo escribir el registro de fuentes: $($_.Exception.Message)"
    }
    Publish-DotfilesFontChange
    return $count
}

# Publish-DotfilesFontChange emite WM_FONTCHANGE (HWND_BROADCAST).
function Publish-DotfilesFontChange {
    if (-not (Test-DotfilesWindows)) { return }
    try {
        if (-not ('Dotfiles.Native' -as [type])) {
            Add-Type -Namespace Dotfiles -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam, uint flags, uint timeout, out System.IntPtr result);
'@ -ErrorAction Stop
        }
        $hwndBroadcast = [System.IntPtr]0xffff
        $WM_FONTCHANGE = 0x001D
        $res = [System.IntPtr]::Zero
        # SMTO_ABORTIFHUNG (0x0002), 1000 ms
        $null = [Dotfiles.Native]::SendMessageTimeout($hwndBroadcast, $WM_FONTCHANGE, [System.IntPtr]::Zero, [System.IntPtr]::Zero, 2, 1000, [ref]$res)
    } catch { }
}

# --- plantillas ------------------------------------------------------------

# Get-DotfilesRenderedTemplate sustituye {{TOKEN}} por el valor del tema.
# Deja sin resolver los tokens desconocidos y los reporta: un TOML con
# {{THEME_BG}} literal nunca es config valida.
function Get-DotfilesRenderedTemplate {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [hashtable]$Values,
        [string]$OutFile
    )
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "plantilla no encontrada: $TemplatePath"
    }
    $src = Get-DotfilesFileText -Path $TemplatePath
    if (-not $Values) { $Values = @{} }

    # Reemplazo explicito (sin MatchEvaluator): el analizador estatico no ve
    # el uso de $Values dentro de un scriptblock, y ese ambito con closures es
    # justo el tipo de codigo que rompe en PowerShell 5.1.
    $sb = New-Object System.Text.StringBuilder
    $last = 0
    foreach ($m in [regex]::Matches($src, '\{\{([A-Z0-9_]+)\}\}')) {
        $key = $m.Groups[1].Value
        if ($Values.ContainsKey($key)) {
            [void]$sb.Append($src.Substring($last, $m.Index - $last))
            [void]$sb.Append([string]$Values[$key])
        } else {
            [void]$sb.Append($src.Substring($last, $m.Index + $m.Length - $last))
        }
        $last = $m.Index + $m.Length
    }
    if ($last -lt $src.Length) { [void]$sb.Append($src.Substring($last)) }
    $out = $sb.ToString()

    $left = @([regex]::Matches($out, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object { $_.Value })
    if ($left.Count -gt 0) {
        Write-Warning "plantilla con tokens sin resolver: $(($left | Select-Object -Unique) -join ', ')"
    }
    if ($OutFile) {
        Write-DotfilesFile -Path $OutFile -Content $out -Encoding 'utf8' | Out-Null
        return $OutFile
    }
    return $out
}

# --- Windows Terminal ------------------------------------------------------

function Get-DotfilesWindowsTerminalScheme {
    param([hashtable]$Theme)
    $paths = Get-DotfilesPaths
    $frag = Join-DotfilesPath -Base $paths.RepoDir -Child 'config/windows-terminal/dracula.json'
    if (Test-Path -LiteralPath $frag -PathType Leaf) {
        $data = Read-DotfilesJson -Path $frag -AsHashtable
        $scheme = [ordered]@{}
        foreach ($k in $data.Keys) {
            # Las claves "$comment"/"$schema" del fragmento no van en settings.json.
            if ($k -like '$*') { continue }
            $scheme[$k] = $data[$k]
        }
        if (Test-DotfilesKey -Map $scheme -Key 'name') { return $scheme }
    }
    # Fallback: se construye desde dracula.env si el fragmento no esta.
    # Se respeta la paleta oficial de Dracula para terminal: el slot ANSI "blue"
    # es el violeta (#bd93f9) y "purple" el rosa (#ff79c6). Antes faltaba "blue"
    # y Windows Terminal rechazaba el colorScheme del perfil.
    return [ordered]@{
        name         = 'Dracula'
        background   = $Theme.THEME_BG
        foreground   = $Theme.THEME_FG
        cursorColor  = $Theme.THEME_FG
        selectionBackground = $Theme.THEME_CURRENT
        black        = $Theme.THEME_BLACK_DARKER
        red          = $Theme.THEME_RED
        green        = $Theme.THEME_GREEN
        yellow       = $Theme.THEME_YELLOW
        blue         = $Theme.THEME_PURPLE
        purple       = $Theme.THEME_PINK
        cyan         = $Theme.THEME_CYAN
        white        = $Theme.THEME_FG
        brightBlack  = $Theme.THEME_BRIGHT_BLACK
        brightRed    = $Theme.THEME_BRIGHT_RED
        brightGreen  = $Theme.THEME_BRIGHT_GREEN
        brightYellow = $Theme.THEME_BRIGHT_YELLOW
        brightBlue   = $Theme.THEME_BRIGHT_BLUE
        brightPurple = $Theme.THEME_BRIGHT_MAGENTA
        brightCyan   = $Theme.THEME_BRIGHT_CYAN
        brightWhite  = $Theme.THEME_BRIGHT_WHITE
    }
}

# Test-DotfilesWindowsTerminalScheme: el esquema trae TODO lo que Windows
# Terminal exige?
#
# WT marca como invalido el colorScheme de un perfil si al esquema le falta
# cualquiera de los 16 colores ANSI. Caso real: faltaba "blue" y al abrir la
# terminal salia "Se encontraron errores al cargar la configuracion de usuario
# ... 'colorScheme' no valido".
function Test-DotfilesWindowsTerminalScheme {
    param([Parameter(Mandatory)][AllowNull()]$Scheme)
    $required = @(
        'name', 'background', 'foreground', 'cursorColor', 'selectionBackground',
        'black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
        'brightBlack', 'brightRed', 'brightGreen', 'brightYellow',
        'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite'
    )
    foreach ($k in $required) {
        if (-not (Test-DotfilesKey -Map $Scheme -Key $k)) { return $false }
        # El esquema puede llegar como hashtable (fragmento) o como PSObject
        # (ConvertFrom-Json del settings.json): no se puede indexar igual.
        $v = if ($Scheme -is [System.Collections.IDictionary]) { $Scheme[$k] } else { $Scheme.PSObject.Properties[$k].Value }
        if (-not "$v".Trim()) { return $false }
    }
    return $true
}

# Set-DotfilesWindowsTerminalTheme aplica esquema + fuente Nerd en los perfiles
# por defecto, con respaldo previo y sin tocar el resto de la configuracion.
function Set-DotfilesWindowsTerminalTheme {
    param(
        [Parameter(Mandatory)][hashtable]$Theme,
        [switch]$DryRun
    )
    $paths = Get-DotfilesPaths
    $settings = $paths.TerminalSettings
    if (-not $settings -or -not (Test-Path -LiteralPath $settings -PathType Leaf)) {
        return [pscustomobject]@{ ok = $false; skipped = $true; detail = 'Windows Terminal no esta instalado o no hay settings.json' }
    }

    $raw = Get-DotfilesFileText -Path $settings
    $data = ConvertFrom-DotfilesJsonC -Text $raw
    if ($null -eq $data) {
        return [pscustomobject]@{ ok = $false; skipped = $false; detail = "no se pudo analizar $settings; aplica manualmente el fragmento config/windows-terminal/dracula.json" }
    }

    $scheme = Get-DotfilesWindowsTerminalScheme -Theme $Theme
    if (-not (Test-DotfilesWindowsTerminalScheme -Scheme $scheme)) {
        # Mejor no tocar nada que dejar la terminal avisando en cada arranque.
        return [pscustomobject]@{ ok = $false; skipped = $false; detail = 'el esquema Dracula esta incompleto (faltan colores ANSI); se deja settings.json sin tocar' }
    }
    # Se reemplaza el esquema Dracula existente en vez de duplicarlo: relanzar
    # el instalador no debe acumular esquemas con el mismo nombre.
    $schemes = @()
    if (Test-DotfilesKey -Map $data -Key 'schemes') {
        $schemes = @($data['schemes'] | Where-Object {
                -not ((Test-DotfilesKey -Map $_ -Key 'name') -and $_['name'] -eq $scheme['name'])
            })
    }
    $schemes += $scheme
    $data['schemes'] = $schemes

    if (-not (Test-DotfilesKey -Map $data -Key 'profiles')) { $data['profiles'] = @{} }
    $profiles = $data['profiles']
    if (-not (Test-DotfilesKey -Map $profiles -Key 'defaults')) { $profiles['defaults'] = @{} }
    $defaults = $profiles['defaults']
    $defaults['colorScheme'] = $scheme['name']
    $defaults['font'] = [ordered]@{ face = $Theme.THEME_FONT_FAMILY; size = [double]$Theme.THEME_FONT_SIZE }

    if ($DryRun) {
        return [pscustomobject]@{ ok = $true; skipped = $false; detail = "dry-run: se escribira $settings" }
    }

    Backup-DotfilesFile -Path $settings | Out-Null
    $json = ConvertTo-DotfilesJsonC -Data $data
    Write-DotfilesFile -Path $settings -Content $json -Encoding 'utf8' | Out-Null

    # Verificacion de ida y vuelta: un settings.json que WT no puede interpretar
    # deja al usuario con un dialogo de error en cada arranque. Se relee y, si el
    # esquema o el colorScheme no cuadran, se restaura el respaldo.
    $check = ConvertFrom-DotfilesJsonC -Text (Get-DotfilesFileText -Path $settings)
    $okCheck = $false
    if ($check -and (Test-DotfilesKey -Map $check -Key 'schemes') -and (Test-DotfilesKey -Map $check -Key 'profiles')) {
        $profiles = $check['profiles']
        $mine = @(@($check['schemes']) | Where-Object {
                (Test-DotfilesKey -Map $_ -Key 'name') -and $_['name'] -eq $scheme['name']
            })
        $cs = ''
        if ((Test-DotfilesKey -Map $profiles -Key 'defaults')) {
            $cs = $profiles['defaults']['colorScheme']
        }
        $okCheck = ($mine.Count -eq 1) -and ($cs -eq $scheme['name'])
    }
    if (-not $okCheck) {
        $backup = Backup-DotfilesFile -Path $settings
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $backup -Destination $settings -Force
        }
        return [pscustomobject]@{
            ok      = $false
            skipped = $false
            detail  = "no se pudo dejar $settings valido para Windows Terminal; se restauro el respaldo"
        }
    }
    return [pscustomobject]@{ ok = $true; skipped = $false; detail = "Windows Terminal: esquema Dracula y fuente $($Theme.THEME_FONT_FAMILY) aplicados" }
}

# ConvertFrom-DotfilesJsonC: settings.json de Windows Terminal admite
# comentarios (JSONC). ConvertFrom-Json puro falla, asi que se quitan primero
# los comentarios de linea y de bloque, respetando las cadenas.
function ConvertFrom-DotfilesJsonC {
    param([Parameter(Mandatory)][string]$Text)
    if (-not $Text.Trim()) { return $null }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            return (ConvertFrom-Json -InputObject $Text -AsHashtable)
        }
        return (ConvertFrom-Json -InputObject $Text) | ConvertTo-DotfilesHashtable
    } catch {
        $clean = Remove-DotfilesJsonComments -Text $Text
        try {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                return (ConvertFrom-Json -InputObject $clean -AsHashtable)
            }
            return (ConvertFrom-Json -InputObject $clean) | ConvertTo-DotfilesHashtable
        } catch {
            return $null
        }
    }
}

# ConvertTo-DotfilesJsonC: 5.1 no tiene -AsHashtable ni ConvertTo-Json con
# orden estable; se normaliza siempre a hashtable ordenada primero.
function ConvertTo-DotfilesJsonC {
    param([Parameter(Mandatory)]$Data, [int]$Depth = 20)
    $obj = $Data
    if ($obj -isnot [System.Collections.IDictionary]) {
        $obj = $obj | ConvertTo-DotfilesHashtable
    }
    $json = ConvertTo-Json -InputObject $obj -Depth $Depth
    $json = $json -replace '\\u003C', '<' -replace '\\u003E', '>' -replace '\\u0026', '&'
    return $json + "`n"
}

function ConvertTo-DotfilesHashtable {
    # Alias del conversor PROFUNDO de dotfiles.psm1. La version anterior solo
    # convertia el primer nivel, asi que en PowerShell 5.1 (sin -AsHashtable) el
    # JSON anidado quedaba mezclado: los elementos de "schemes" seguian siendo
    # PSObject y `$_['name']` reventaba con "No se puede indizar en un objeto del
    # tipo PSObject" al aplicar el tema de Windows Terminal.
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return (ConvertTo-DotfilesHashtableDeep -InputObject $InputObject) }
}

function Remove-DotfilesJsonComments {
    param([Parameter(Mandatory)][string]$Text)
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false
    $esc = $false
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            $i++
            continue
        }
        if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and $next -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and $next -eq '*') {
            $i += 2
            while ($i + 1 -lt $Text.Length -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
            $i += 2
            continue
        }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

Export-ModuleMember -Function *
