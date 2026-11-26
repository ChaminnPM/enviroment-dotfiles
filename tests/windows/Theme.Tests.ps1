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
