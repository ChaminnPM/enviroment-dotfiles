# Theme.Tests.ps1 - tema, plantillas y Windows Terminal.
#
# El parseador JSONC y la construccion del esquema se pueden ejercitar en
# cualquier SO; lo que toca el registro de fuentes se marca como Windows-only.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('th-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/theme.psm1') -Force
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
    Remove-Item env:THEME_ENV_FILE -ErrorAction SilentlyContinue
}

Describe 'Tokens del tema' {
    It 'lee config/theme/dracula.env como unica fuente de verdad' {
        $t = Read-DotfilesTheme
        $t.THEME_NAME | Should -Be 'dracula'
        $t.THEME_BG | Should -Be '#282a36'
        $t.THEME_FONT_FAMILY | Should -Be 'JetBrainsMono Nerd Font'
        $t.THEME_NERD_VERSION | Should -Match '^v\d+'
        $t['__file'] | Should -BeLike '*dracula.env'
    }

    It 'respeta THEME_ENV_FILE' {
        $alt = Join-Path $script:Sandbox 'mini.env'
        Set-Content -LiteralPath $alt -Value "THEME_NAME=otro`nTHEME_BG='#000000'"
        $env:THEME_ENV_FILE = $alt
        try {
            $t = Read-DotfilesTheme
            $t.THEME_NAME | Should -Be 'otro'
            # los demas tokens conservan el default embebido
            $t.THEME_FONT_FAMILY | Should -Be 'JetBrainsMono Nerd Font'
        } finally {
            Remove-Item env:THEME_ENV_FILE
        }
    }

    It 'Set-DotfilesThemeEnv exporta los tokens al proceso' {
        $t = Read-DotfilesTheme
        Set-DotfilesThemeEnv -Theme $t
        $env:THEME_NAME | Should -Be $t.THEME_NAME
    }
}

Describe 'Plantillas' {
    It 'sustituye {{TOKEN}} con los valores del tema' {
        $tpl = Join-Path $script:Sandbox 't.tpl'
        Set-Content -LiteralPath $tpl -Value "family = '{{THEME_FONT_FAMILY}}'`nsize = {{THEME_FONT_SIZE}}"
        $out = Get-DotfilesRenderedTemplate -TemplatePath $tpl -Values (Read-DotfilesTheme)
        $out | Should -BeLike "*'JetBrainsMono Nerd Font'*"
        $out | Should -Not -BeLike '*{{*'
    }

    It 'avisa de los tokens que no puede resolver' {
        $tpl = Join-Path $script:Sandbox 'rota.tpl'
        Set-Content -LiteralPath $tpl -Value "x = {{THEME_NOEXISTE}}"
        $out = Get-DotfilesRenderedTemplate -TemplatePath $tpl -Values @{ A = 'b' } 3>&1
        ($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count |
            Should -BeGreaterThan 0
    }

    It 'falla con una plantilla inexistente' {
        { Get-DotfilesRenderedTemplate -TemplatePath (Join-Path $script:Sandbox 'nope.tpl') -Values @{} } |
            Should -Throw
    }

    It 'escribe el archivo sin BOM' {
        $tpl = Join-Path $script:Sandbox 'a.tpl'
        $dst = Join-Path $script:Sandbox 'out.toml'
        Set-Content -LiteralPath $tpl -Value "k = '{{V}}'"
        $null = Get-DotfilesRenderedTemplate -TemplatePath $tpl -Values @{ V = 'x' } -OutFile $dst
        $b = [IO.File]::ReadAllBytes($dst)
        $b[0] | Should -Not -Be 0xEF
    }
}

Describe 'Manifiesto del tema' {
    It 'es JSON con el pin de la fuente' {
        $t = Read-DotfilesTheme
        $p = Get-DotfilesPaths
        $f = Write-DotfilesThemeManifest -Theme $t
        $f | Should -Be $p.ThemeManifest
        $m = Read-DotfilesJson -Path $f
        $m.theme | Should -Be $t.THEME_NAME
        $m.nerd_version | Should -Be $t.THEME_NERD_VERSION
        $m.applied | Should -Not -BeNullOrEmpty
    }
}

Describe 'JSONC de Windows Terminal' {
    It 'quitaba los comentarios de linea y de bloque' {
        $src = @"
{
  // comentario de linea
  "a": 1, /* bloque
     multilinea */
  "url": "https://x.example//y",
  "comilla_escaped": "no \\// este"
}
"@
        $clean = Remove-DotfilesJsonComments -Text $src
        $clean | Should -Not -BeLike '*comentario de linea*'
        $clean | Should -Not -BeLike '*multilinea*'
        # los // dentro de cadenas NO son comentarios
        $clean | Should -BeLike '*https://x.example//y*'
        { $null = ConvertFrom-Json -InputObject $clean } | Should -Not -Throw
    }

    It 'convierte un settings.json con comentarios a hashtable' {
        $src = '{ "profiles": { /* c */ "defaults": { "colorScheme": "Campbell" } } }'
        $h = ConvertFrom-DotfilesJsonC -Text $src
        $h | Should -Not -BeNullOrEmpty
    }

    It 'devuelve null con JSON roto (y el llamador no toca nada)' {
        $h = ConvertFrom-DotfilesJsonC -Text '{ esto no es json'
        $h | Should -BeNullOrEmpty
    }
}

Describe 'Esquema Dracula' {
    It 'sale del fragmento versionado, sin claves de comentario' {
        $t = Read-DotfilesTheme
        $s = Get-DotfilesWindowsTerminalScheme -Theme $t
        $s['name'] | Should -Be 'Dracula'
        $s['background'] | Should -Be $t.THEME_BG
        $s['brightGreen'] | Should -Be $t.THEME_BRIGHT_GREEN
        $s.Keys | Where-Object { $_ -like '$*' } | Should -BeNullOrEmpty
    }

    It 'trae los 16 colores ANSI (Windows Terminal rechaza el colorScheme si falta uno)' {
        # Caso real: faltaba "blue" y la terminal avisaba en cada arranque.
        $t = Read-DotfilesTheme
        $s = Get-DotfilesWindowsTerminalScheme -Theme $t
        foreach ($k in @('black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
                'brightBlack', 'brightRed', 'brightGreen', 'brightYellow',
                'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')) {
            $s[$k] | Should -Not -BeNullOrEmpty -Because "falta el color $k"
        }
        (Test-DotfilesWindowsTerminalScheme -Scheme $s) | Should -BeTrue
    }

    It 'detecta un esquema incompleto' {
        $t = Read-DotfilesTheme
        $s = Get-DotfilesWindowsTerminalScheme -Theme $t
        $s.Remove('blue')
        (Test-DotfilesWindowsTerminalScheme -Scheme $s) | Should -BeFalse
    }
}

Describe 'Set-DotfilesWindowsTerminalTheme' {
    BeforeAll {
        # Home de Windows falso: %LOCALAPPDATA%\Packages\...\LocalState.
        $script:Local = Join-Path $script:Sandbox 'AppData/Local'
        $script:Pkg = Join-Path $script:Local 'Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState'
        New-Item -ItemType Directory -Force -Path $script:Pkg | Out-Null
        $env:DOTFILES_LOCALAPPDATA = $script:Local
    }
    AfterAll {
        Remove-Item env:DOTFILES_LOCALAPPDATA -ErrorAction SilentlyContinue
    }

    It 'anade el esquema, marca el default y ajusta la fuente' {
        $settings = Join-Path $script:Pkg 'settings.json'
        $orig = @'
{
  "$help": "https://aka.ms/terminal-documentation",
  "$schema": "https://aka.ms/terminal-profiles-schema",
  // Comentario de la guia rapida
  "actions": [],
  "profiles": {
    "defaults": {
      "colorScheme": "Campbell",
      "font": { "face": "Cascadia Mono", "size": 12 }
    },
    "list": [ { "guid": "{default}", "name": "Default" } ]
  },
  "schemes": []
}
'@
        Set-Content -LiteralPath $settings -Value $orig
        $t = Read-DotfilesTheme
        $r = Set-DotfilesWindowsTerminalTheme -Theme $t
        $r.ok | Should -BeTrue

        $after = Remove-DotfilesJsonComments -Text (Get-DotfilesFileText -Path $settings)
        $d = ConvertFrom-Json -InputObject $after
        $names = @($d.schemes | ForEach-Object { $_.name })
        $names | Should -Contain 'Dracula'
        $d.profiles.defaults.colorScheme | Should -Be 'Dracula'
        $d.profiles.defaults.font.face | Should -Be $t.THEME_FONT_FAMILY
        # lo del usuario sigue ahi
        @($d.profiles.list).Count | Should -Be 1
    }

    It 'crea respaldo antes de tocar settings.json' {
        $p = Get-DotfilesPaths
        @(Get-ChildItem -LiteralPath $p.BackupDir -Filter 'settings.json.*' -File -ErrorAction SilentlyContinue).Count |
            Should -BeGreaterThan 0
    }

    It 'reaplicar no duplica el esquema (idempotente)' {
        $settings = Join-Path $script:Pkg 'settings.json'
        $t = Read-DotfilesTheme
        $null = Set-DotfilesWindowsTerminalTheme -Theme $t
        $null = Set-DotfilesWindowsTerminalTheme -Theme $t
        $after = Remove-DotfilesJsonComments -Text (Get-DotfilesFileText -Path $settings)
        $d = ConvertFrom-Json -InputObject $after
        @($d.schemes | Where-Object { $_.name -eq 'Dracula' }).Count | Should -Be 1
    }

    It 'deja el colorScheme apuntando a un esquema completo' {
        # La invariante que comprueba Windows Terminal al arrancar. El test
        # escribe su propio settings.json para no depender del orden.
        $settings = Join-Path $script:Pkg 'settings.json'
        $orig = @'
{
  "profiles": { "defaults": { "colorScheme": "Campbell" }, "list": [] },
  "schemes": []
}
'@
        Set-Content -LiteralPath $settings -Value $orig
        $t = Read-DotfilesTheme
        $r = Set-DotfilesWindowsTerminalTheme -Theme $t
        $r.ok | Should -BeTrue -Because $r.detail
        $after = Remove-DotfilesJsonComments -Text (Get-DotfilesFileText -Path $settings)
        $d = ConvertFrom-Json -InputObject $after
        $cs = $d.profiles.defaults.colorScheme
        $scheme = @($d.schemes | Where-Object { $_.name -eq $cs })
        $scheme.Count | Should -Be 1
        (Test-DotfilesWindowsTerminalScheme -Scheme $scheme[0]) | Should -BeTrue
    }

    It 'no toca un settings.json que no se puede analizar' {
        $settings = Join-Path $script:Pkg 'settings.json'
        Set-Content -LiteralPath $settings -Value '{ roto "a":'
        $before = Get-DotfilesFileText -Path $settings
        $t = Read-DotfilesTheme
        $r = Set-DotfilesWindowsTerminalTheme -Theme $t
        $r.ok | Should -BeFalse
        (Get-DotfilesFileText -Path $settings) | Should -Be $before
    }

    It 'degrada a "omitido" si Windows Terminal no esta instalado' {
        $env:DOTFILES_LOCALAPPDATA = (Join-Path $script:Sandbox 'vacio')
        try {
            $t = Read-DotfilesTheme
            $r = Set-DotfilesWindowsTerminalTheme -Theme $t
            $r.skipped | Should -BeTrue
        } finally {
            $env:DOTFILES_LOCALAPPDATA = $script:Local
        }
    }
}

Describe 'Fuente Nerd Font (fuera de Windows)' {
    It 'el runtime no-Windows no intenta tocar el registro' {
        # Test-DotfilesWindows mira el runtime REAL, no el override de prueba:
        # en un runner Linux este paso debe degradar sin ejecutar icacls/reg.
        if (Test-DotfilesWindows) { Set-ItResult -Skipped -Because 'estamos en Windows' }
        $t = Read-DotfilesTheme
        $r = Update-DotfilesNerdFont -Theme $t
        $r.skipped | Should -BeTrue
        $r.ok | Should -BeFalse
    }
}

Describe 'Bloque del tema en el perfil' {
    It 'no escribe propiedades de color invalidas de PSReadLine' {
        # Caso real: el bloque incluia `Prompt = ...`, que PSReadLine no admite,
        # y el perfil de PowerShell fallaba en cada arranque.
        $home2 = Join-Path $script:Sandbox 'perfil'
        New-Item -ItemType Directory -Force -Path $home2 | Out-Null
        $prev = $env:DOTFILES_HOME
        $env:DOTFILES_HOME = $home2
        try {
            $script = Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path 'scripts/apply-theme.ps1'
            $null = & $script *>&1
            $txt = ''
            foreach ($pf in @(Get-DotfilesProfilePaths)) {
                if (Test-Path -LiteralPath $pf) { $txt += (Get-DotfilesFileText -Path $pf) }
            }
            $txt | Should -BeLike '*Set-PSReadLineOption*'
            ($txt -match '(?m)^\s*Prompt\s*=') | Should -BeFalse
            $txt | Should -BeLike '*Command*'
            ($txt -match '(?m)^\s*try \{') | Should -BeTrue
        } finally {
            $env:DOTFILES_HOME = $prev
        }
    }
}

Describe 'Tema del prompt (oh-my-posh)' {
    It 'THEME_OMP_THEME elige un fichero que existe en el repo' {
        $t = Read-DotfilesTheme
        $t.THEME_OMP_THEME | Should -Be 'vscode'
        # La clave esta en dracula.env (fuente unica), no solo como default.
        $envFile = Join-DotfilesPath -Base (Get-DotfilesPaths).RepoDir -Child 'config/theme/dracula.env'
        (Get-DotfilesFileText -Path $envFile) | Should -BeLike "*THEME_OMP_THEME='vscode'*"
        $f = Join-DotfilesPath -Base (Get-DotfilesPaths).RepoDir -Child "config/oh-my-posh/$($t.THEME_OMP_THEME).omp.json"
        Test-Path -LiteralPath $f | Should -BeTrue
    }

    It 'el puerto de oh-my-bash conserva forma y colores ANSI' {
        # oh-my-bash vscode: "usuario -> ruta (rama) $" con ANSI 0;32, 1;34,
        # 0;36, 1;31 y 1;33. Aqui se comprueba que el de Windows usa los mismos.
        $t = Read-DotfilesTheme
        $f = Join-DotfilesPath -Base (Get-DotfilesPaths).RepoDir -Child 'config/oh-my-posh/vscode.omp.json'
        $d = Read-DotfilesJson -Path $f -AsHashtable
        @($d['blocks']).Count | Should -Be 1
        $segs = @($d['blocks'][0]['segments'])
        @($segs | ForEach-Object { $_['type'] }) |
            Should -Be @('session', 'status', 'path', 'git', 'git', 'git', 'git', 'text')
        $segs[0]['foreground'] | Should -Be $t.THEME_GREEN
        $segs[1]['foreground_templates'][0] | Should -BeLike "*$($t.THEME_BRIGHT_RED)*"
        $segs[2]['foreground'] | Should -Be $t.THEME_BRIGHT_BLUE
        $segs[2]['options']['max_depth'] | Should -Be 4
        $segs[3]['foreground'] | Should -Be $t.THEME_CYAN
        $segs[4]['foreground'] | Should -Be $t.THEME_BRIGHT_RED
        $segs[5]['foreground'] | Should -Be $t.THEME_BRIGHT_YELLOW
        $segs[7]['template'] | Should -BeLike '*$*'
        # oh-my-bash no usa powerline: ningun segmento con fondo.
        @($segs | Where-Object { Test-DotfilesKey -Map $_ -Key 'background' }).Count | Should -Be 0
    }

    It 'dracula sigue disponible como alternativa' {
        $f = Join-DotfilesPath -Base (Get-DotfilesPaths).RepoDir -Child 'config/oh-my-posh/dracula.omp.json'
        Test-Path -LiteralPath $f | Should -BeTrue
    }
}
