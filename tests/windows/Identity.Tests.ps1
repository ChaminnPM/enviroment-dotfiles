# Identity.Tests.ps1 - setup-git-identity.ps1 en un home desechable.
#
# Ejecuta el script REAL (no mocks) con GIT_* de entorno, en un sandbox via
# DOTFILES_HOME. Requiere ssh-keygen y git en el PATH; si faltan, se salta.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:RepoRoot = $RepoRoot
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('id-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $script:HasKeys = [bool](Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue)
    $script:HasGit = [bool](Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME, env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
    Remove-Item env:GIT_PERSONAL_PLATFORM, env:GIT_PERSONAL_NAME, env:GIT_PERSONAL_EMAIL -ErrorAction SilentlyContinue
    Remove-Item env:GIT_ACC_COUNT, env:GIT_ACC1_ESPACIO, env:GIT_ACC1_PLATFORM, env:GIT_ACC1_NAME, env:GIT_ACC1_EMAIL -ErrorAction SilentlyContinue
    Remove-Item env:GIT_ACC2_ESPACIO, env:GIT_ACC2_NAME, env:GIT_ACC2_EMAIL -ErrorAction SilentlyContinue
    Remove-Item env:GIT_MIGRATE_LEGACY, env:NUI_NONINTERACTIVE -ErrorAction SilentlyContinue
}

Describe 'setup-git-identity.ps1' {
    BeforeAll {
        if (-not $script:HasKeys -or -not $script:HasGit) {
            Set-ItResult -Skipped -Because 'faltan ssh-keygen o git'
        }
        $env:DOTFILES_HOME = $script:Sandbox
        $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
        $env:NUI_NONINTERACTIVE = '1'
        $env:GIT_MIGRATE_LEGACY = '0'
        $env:GIT_PERSONAL_PLATFORM = 'github'
        $env:GIT_PERSONAL_NAME = 'Chaminn'
        $env:GIT_PERSONAL_EMAIL = 'chaminn@example.com'
        $env:GIT_ACC_COUNT = '2'
        $env:GIT_ACC1_ESPACIO = 'Nuxiba'
        $env:GIT_ACC1_PLATFORM = 'bitbucket'
        $env:GIT_ACC1_NAME = 'Chaminn Trabajo'
        $env:GIT_ACC1_EMAIL = 'trabajo@example.com'
        $env:GIT_ACC2_ESPACIO = 'Otro Espacio'
        $env:GIT_ACC2_NAME = 'Otro'
        $env:GIT_ACC2_EMAIL = 'otro@example.com'
        $env:REPO_DIR = $script:RepoRoot

        $script:Out = & (Join-Path $script:RepoRoot 'scripts/setup-git-identity.ps1') *>&1
        $script:Text = ($script:Out | Out-String)
        $script:Rc = $LASTEXITCODE
        Import-Module (Join-Path $script:RepoRoot 'scripts/lib/dotfiles.psm1') -Force
        $script:P = Get-DotfilesPaths
    }

    It 'no falla' {
        $script:Rc | Should -Be 0 -Because $script:Text
    }

    It 'genera la clave personal y las de los espacios' {
        Test-Path -LiteralPath (Join-Path $script:P.SshDir 'id_ed25519_personal') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:P.SshDir 'id_ed25519_personal.pub') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:P.SshDir 'id_ed25519_nuxiba') | Should -BeTrue
        # el slug normaliza espacios y acentos: "Otro Espacio" -> otro-espacio
        Test-Path -LiteralPath (Join-Path $script:P.SshDir 'id_ed25519_otro-espacio') | Should -BeTrue
    }

    It 'crea la carpeta de cada espacio' {
        Test-Path -LiteralPath (Join-Path $script:P.Home 'Nuxiba') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:P.Home 'Otro Espacio') | Should -BeTrue
    }

    It 'escribe ~/.ssh/config con una seccion gestionada y prepend' {
        $cfg = Join-Path $script:P.SshDir 'config'
        Test-Path -LiteralPath $cfg | Should -BeTrue
        $first = (Get-Content -LiteralPath $cfg -TotalCount 1)
        # el bloque gestionado va PRIMERO: en ssh gana el primer Host que calce
        $first | Should -BeLike '*dotfiles-managed*'
        $txt = Get-Content -LiteralPath $cfg -Raw
        $txt | Should -BeLike '*Host github.com*'
        $txt | Should -BeLike '*Host git-nuxiba*'
        $txt | Should -BeLike '*HostName ssh.bitbucket.org*'
        $txt | Should -BeLike '*IdentitiesOnly yes*'
    }

    It 'escribe ~/.gitconfig con includeIf en barras normales' {
        $txt = Get-Content -LiteralPath $script:P.GitConfig -Raw
        $txt | Should -BeLike '*>>> dotfiles-gitconfig*'
        # los patrones gitdir usan SIEMPRE barras normales (Git for Windows
        # normaliza los gitdir a forward slashes) y terminan en '/'
        $txt | Should -Match 'includeIf "gitdir:[^"]+/"'
        $txt | Should -BeLike '*gitconfig-personal*'
        $txt | Should -BeLike '*gitconfig-nuxiba*'
        # nunca backslashes dentro del patron gitdir
        ($txt | Select-String -Pattern 'gitdir:[^"]*\\\\' -AllMatches).Matches.Count | Should -Be 0
    }

    It 'crea los perfiles por cuenta con user.name/user.email' {
        $p = Join-Path $script:P.Home '.gitconfig-personal'
        Test-Path -LiteralPath $p | Should -BeTrue
        (Get-Content -LiteralPath $p -Raw) | Should -BeLike '*Chaminn*'
        $n = Join-Path $script:P.Home '.gitconfig-nuxiba'
        Test-Path -LiteralPath $n | Should -BeTrue
        $txt = Get-Content -LiteralPath $n -Raw
        # nuxiba es bitbucket: el alias reescribe los remotes de ESA plataforma
        $txt | Should -BeLike '*git@git-nuxiba:*'
        $txt | Should -BeLike '*insteadOf = git@bitbucket.org:*'
        $txt | Should -Not -BeLike '*git@github.com:*'
    }

    It 'genera el manifiesto JSON de cuentas' {
        $m = Read-DotfilesJson -Path $script:P.AccountsFile -AsHashtable
        $m['personal']['platform'] | Should -Be 'github'
        $m['personal']['pub'] | Should -BeLike '*id_ed25519_personal.pub'
        @($m['spaces']).Count | Should -Be 2
        $m['spaces'][0]['slug'] | Should -Be 'nuxiba'
        $m['spaces'][0]['target'] | Should -Be 'git@git-nuxiba'
        $m['spaces'][0]['gitdir'] | Should -BeLike '*/Nuxiba/'
    }

    It 'vuelca todas las claves publicas en un archivo del proyecto' {
        Test-Path -LiteralPath $script:P.KeysDump | Should -BeTrue
        $txt = Get-Content -LiteralPath $script:P.KeysDump -Raw
        $txt | Should -BeLike '*Personal/github*'
        $txt | Should -BeLike '*github.com/settings/ssh/new*'
        $txt | Should -BeLike '*bitbucket.org/account/settings/ssh-keys*'
    }

    It 'instala el known_hosts pinnado del repo' {
        $kh = Join-Path $script:P.SshDir 'known_hosts'
        Test-Path -LiteralPath $kh | Should -BeTrue
        $txt = Get-Content -LiteralPath $kh -Raw
        $txt | Should -BeLike '*github.com*'
        $txt | Should -BeLike '*bitbucket.org*'
    }

    It 'es idempotente: volver a ejecutar no duplica bloques ni claves' {
        $cfg = Join-Path $script:P.SshDir 'config'
        $before = Get-Content -LiteralPath $cfg -Raw
        $null = & (Join-Path $script:RepoRoot 'scripts/setup-git-identity.ps1') 2>&1
        $after = Get-Content -LiteralPath $cfg -Raw
        # el bloque gestionado se reemplaza, no se acumula
        ([regex]::Matches($after, 'Host github\.com')).Count | Should -Be ([regex]::Matches($before, 'Host github\.com')).Count
        ([regex]::Matches($after, 'dotfiles-managed \(setup-git-identity')).Count | Should -Be 1
    }

    It 'rechaza identidades con corchetes (no puede inyectar secciones)' {
        $env:GIT_PERSONAL_NAME = 'x] [core"editor = rm -rf /'
        $env:GIT_ACC_COUNT = '0'
        $out = & (Join-Path $script:RepoRoot 'scripts/setup-git-identity.ps1') *>&1
        ($out | Out-String) | Should -BeLike '*valor rechazado*'
        $LASTEXITCODE | Should -Not -Be 0
        $env:GIT_PERSONAL_NAME = 'Chaminn'
    }
}
