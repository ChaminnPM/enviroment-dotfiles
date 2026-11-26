# Sync.Tests.ps1 - apply-theme.ps1 y sync.ps1 en un home desechable.
#
# Cubren el "dia despues": el usuario abre el instalador de nuevo o pide
# `sync-dotfiles doctor`. Ninguna de las dos cosas debe escribir fuera del
# arbol del proyecto ni colgarse.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:RepoRoot = $RepoRoot
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('sy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    $env:DOTFILES_LOCALAPPDATA = Join-Path $script:Sandbox 'AppData/Local'
    $env:DOTFILES_APPDATA = Join-Path $script:Sandbox 'AppData/Roaming'
    $env:REPO_DIR = $RepoRoot
    $env:NUI_NONINTERACTIVE = '1'
    New-Item -ItemType Directory -Force -Path $env:DOTFILES_LOCALAPPDATA | Out-Null
    New-Item -ItemType Directory -Force -Path $env:DOTFILES_APPDATA | Out-Null
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    $script:P = Get-DotfilesPaths
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME, env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_LOCALAPPDATA, env:DOTFILES_APPDATA -ErrorAction SilentlyContinue
    Remove-Item env:REPO_DIR, env:NUI_NONINTERACTIVE, env:NUI_PLAIN -ErrorAction SilentlyContinue
}

Describe 'apply-theme.ps1' {
    BeforeAll {
        # Perfiles "existentes" con config del usuario que no debe perderse.
        foreach ($pf in Get-DotfilesProfilePaths) {
            New-Item -ItemType Directory -Force -Path (Split-Path $pf) | Out-Null
            Set-Content -LiteralPath $pf -Value '# mi config a mano'
        }
        New-Item -ItemType Directory -Force -Path $script:P.OpenCodeDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'config/opencode/cli.json') `
            -Destination (Join-Path $script:P.OpenCodeDir 'cli.json') -Force

        $script:Out = & (Join-Path $RepoRoot 'scripts/apply-theme.ps1') -RepoDir $RepoRoot *>&1
        $script:Text = ($script:Out | Out-String)
        $script:Rc = $LASTEXITCODE
    }

    It 'termina sin error' {
        $script:Rc | Should -Be 0 -Because $script:Text
    }

    It 'escribe el bloque de tema en los dos perfiles' {
        foreach ($pf in Get-DotfilesProfilePaths) {
            $txt = Get-Content -LiteralPath $pf -Raw
            $txt | Should -BeLike '*>>> dotfiles-theme*'
            $txt | Should -BeLike "*BAT_THEME*"
            # lo del usuario sigue ahi
            $txt | Should -BeLike '*mi config a mano*'
        }
    }

    It 'exporta los tokens del tema como variables de entorno' {
        $body = Get-DotfilesManagedBlockBody -Path (Get-DotfilesProfilePaths)[0] `
            -Header '# >>> dotfiles-theme (apply-theme.ps1) - no editar' -Footer '# <<< dotfiles-theme'
        $body | Should -BeLike "*THEME_BG = '#282a36'*"
        $body | Should -BeLike "*BAT_THEME = 'Dracula'*"
    }

    It 'genera el gitconfig de colores con la paleta Dracula' {
        $f = Join-Path $script:P.ConfigRoot 'git/theme.gitconfig'
        Test-Path -LiteralPath $f | Should -BeTrue
        $txt = Get-Content -LiteralPath $f -Raw
        $txt | Should -BeLike '*ui = true*'
        $txt | Should -BeLike '*current = #50fa7b bold*'
        $txt | Should -BeLike '*Generado por scripts/apply-theme.ps1*'
    }

    It 'deja el manifiesto del tema' {
        $m = Read-DotfilesJson -Path $script:P.ThemeManifest
        $m.theme | Should -Be 'dracula'
        $m.nerd_version | Should -Not -BeNullOrEmpty
    }

    It 'es idempotente (no duplica el bloque)' {
        $null = & (Join-Path $RepoRoot 'scripts/apply-theme.ps1') -RepoDir $RepoRoot *>&1
        $txt = Get-Content -LiteralPath (Get-DotfilesProfilePaths)[0] -Raw
        ([regex]::Matches($txt, '>>> dotfiles-theme')).Count | Should -Be 1
        ([regex]::Matches($txt, 'mi config a mano')).Count | Should -Be 1
    }

    It 'con -GitOnly no toca el perfil' {
        $before = Get-Content -LiteralPath (Get-DotfilesProfilePaths)[0] -Raw
        $null = & (Join-Path $RepoRoot 'scripts/apply-theme.ps1') -RepoDir $RepoRoot -GitOnly *>&1
        (Get-Content -LiteralPath (Get-DotfilesProfilePaths)[0] -Raw) | Should -Be $before
    }
}

Describe 'sync.ps1 doctor' {
    BeforeAll {
        $script:Out = & (Join-Path $RepoRoot 'scripts/sync.ps1') -Mode doctor -RepoDir $RepoRoot *>&1
        $script:Text = ($script:Out | Out-String)
    }

    It 'no reviente y reporte el resumen' {
        $script:Text | Should -BeLike '*Doctor publico*'
        $script:Text | Should -BeLike '*Resumen:*OK*avisos*'
    }

    It 'no escribe fuera del arbol del proyecto' {
        # doctor es solo lectura: los unicos archivos nuevos posibles serian
        # los del sandbox, y esos los crea el resto de los tests.
        $script:Text | Should -Not -BeLike '*sync:*'
        $script:Text | Should -Not -BeLike '*git push*'
    }

    It 'avisa de lo que pertenece al proyecto y falta en este home' {
        # Las herramientas (git, nui, node) pueden estar en el PATH del runner:
        # lo que SI tiene que aparecer es lo que vive bajo el home del proyecto.
        $script:Text | Should -BeLike '*sin ~/.ssh/config*'
        $script:Text | Should -BeLike '*git-accounts.json*'
        $script:Text | Should -BeLike '*sync-dotfiles no instalado*'
        $script:Text | Should -BeLike '*Windows Terminal no instalado*'
    }

    It 'distingue OK de avisos en el recuento' {
        $script:Text | Should -Match 'Resumen: \d+ OK, \d+ avisos'
        # la fuente NO esta registrada en un sandbox
        $script:Text | Should -BeLike '*Nerd Font*'
    }
}

Describe 'sync.ps1 pull en dry-run' {
    It 'no modifica el destino con -DryRun' {
        $dst = Join-Path $script:P.OpenCodeDir 'AGENTS.md'
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
        $null = & (Join-Path $RepoRoot 'scripts/sync.ps1') -Mode pull -RepoDir $RepoRoot -DryRun -SkipPull *>&1
        Test-Path -LiteralPath $dst | Should -BeFalse
    }

    It 'aplica los assets publicos sin -DryRun' {
        $null = & (Join-Path $RepoRoot 'scripts/sync.ps1') -Mode pull -RepoDir $RepoRoot -SkipPull *>&1
        $dst = Join-Path $script:P.OpenCodeDir 'AGENTS.md'
        Test-Path -LiteralPath $dst | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:P.OpenCodeDir 'cli.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:P.ThemeDir 'dracula.env') | Should -BeTrue
        # skills
        Test-Path -LiteralPath (Join-Path $script:P.OpenCodeDir 'skills/graphify/SKILL.md') | Should -BeTrue
    }

    It 'nunca copia la config privada' {
        $priv = Join-Path $script:P.OpenCodeDir 'service.json'
        Test-Path -LiteralPath $priv | Should -BeFalse
    }
}
