# Contract.Tests.ps1 - el contrato de docs/STEPS.md, probado en el runner.
#
# Estos tests son los que evitan que bootstrap.ps1 y nui se separen: formato
# del plan, escapado de resultados, filtrado por --only y shape del wrapper.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('dfc-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/ui.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/theme.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/packages.psm1') -Force
    $script:RepoRoot = $RepoRoot
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
}

Describe 'Plan JSON' {
    It 'declara shell=pwsh y argv literal por paso' {
        $p = New-DotfilesPanel -Title 'T'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Paso' -Estimate 7 -Body { Write-Output '##log hola' }
        $plan = (ConvertTo-DotfilesPlanJson -Panel $p) | ConvertFrom-Json
        $plan.shell | Should -Be 'pwsh'
        $plan.steps.Count | Should -Be 1
        $plan.steps[0].argv.Count | Should -BeGreaterThan 3
        [IO.Path]::GetFileName($plan.steps[0].argv[-1]) | Should -BeLike 'step-*.ps1'
        $plan.steps[0].estimate | Should -Be 7
    }

    It 'notas y titulos viajan al panel' {
        $p = New-DotfilesPanel -Title 'AGENTS ENVIRONMENT'
        $p = Add-DotfilesPanelNote -Panel $p -Text 'Comandos: sync-dotfiles pull/push'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Uno' -Body { 'x' }
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Dos' -Optional -Interactive -Body { 'y' }
        $plan = (ConvertTo-DotfilesPlanJson -Panel $p) | ConvertFrom-Json
        $plan.title | Should -Be 'AGENTS ENVIRONMENT'
        $plan.notes[0] | Should -Be 'Comandos: sync-dotfiles pull/push'
        $plan.steps[1].optional | Should -BeTrue
        $plan.steps[1].interactive | Should -BeTrue
    }

    It 'los inputs llevan type/name/prompt/default y show_if' {
        $p = New-DotfilesPanel -Title 'T'
        $p = Add-DotfilesPanelInput -Panel $p -Type 'select' -Name 'acc_count' -Prompt 'Cuentas' -Options @('0', '1') -Default '0'
        $p = Add-DotfilesPanelInput -Panel $p -Type 'input' -Name 'acc1_espacio' -Prompt 'Espacio' `
            -ShowIf @(@{ field = 'acc_count'; op = 'gte'; value = '1' })
        $p = Add-DotfilesPanelInput -Panel $p -Type 'select' -Name 'extras' -Prompt 'Paquetes' `
            -Options @('bat', 'eza') -Multi -Default @('bat')
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Con formulario' -Body { 'x' }
        $plan = (ConvertTo-DotfilesPlanJson -Panel $p) | ConvertFrom-Json
        $in = $plan.steps[0].inputs
        $in.Count | Should -Be 3
        $in[1].show_if[0].field | Should -Be 'acc_count'
        $in[1].show_if[0].op | Should -Be 'gte'
        $in[2].multi | Should -BeTrue
        ($in[2].options -join ',') | Should -Be 'bat,eza'
    }

    It 'un paso consume los inputs pendientes y el siguiente empieza limpio' {
        $p = New-DotfilesPanel -Title 'T'
        $p = Add-DotfilesPanelInput -Panel $p -Type 'input' -Name 'uno' -Prompt 'Uno'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'A' -Body { 'a' }
        $p = Add-DotfilesPanelStep -Panel $p -Title 'B' -Body { 'b' }
        $plan = (ConvertTo-DotfilesPlanJson -Panel $p) | ConvertFrom-Json
        @($plan.steps[0].inputs).Count | Should -Be 1
        @($plan.steps[1].inputs).Count | Should -Be 0
    }
}

Describe 'DSL de inputs (compatibilidad con bootstrap.sh)' {
    It 'parsea input/select/option/default/showif/key' {
        $p = New-DotfilesPanel -Title 'T'
        $text = @(
            'input p_platform Plataforma personal (github|bitbucket):',
            'default p_platform github',
            'select acc_count Cuantas cuentas? (0-3): many',
            'option acc_count 0',
            'option acc_count 3',
            'default acc_count 0',
            'input acc1_espacio Espacio 1:',
            'showif acc1_espacio acc_count gte 1',
            'confirm enviar Enviar las claves? n',
            'key clave1 ~/.ssh/id_ed25519_personal.pub Clave personal'
        ) -join "`n"
        $p = Add-DotfilesPanelInputDsl -Panel $p -Text $text
        $f = $p.PendingInput.fields
        $f.Count | Should -Be 5
        $f[0]['default'] | Should -Be 'github'
        $f[1]['multi'] | Should -BeTrue
        $f[1]['prompt'] | Should -Be 'Cuantas cuentas? (0-3):'
        $f[3]['default'] | Should -Be 'false'
        $f[4]['path'] | Should -Be '~/.ssh/id_ed25519_personal.pub'
        @($f[2]['show_if'])[0]['op'] | Should -Be 'gte'
    }

    It 'rechaza un showif sin campo previo' {
        $p = New-DotfilesPanel -Title 'T'
        { Add-DotfilesPanelInputDsl -Panel $p -Text 'showif fantasma acc_count gte 1' } | Should -Throw
    }

    It 'rechaza nombres de campo que no son identificadores' {
        $p = New-DotfilesPanel -Title 'T'
        { Add-DotfilesPanelInput -Panel $p -Type 'input' -Name 'con espacio' -Prompt 'x' } | Should -Throw
    }
}

Describe 'Resultados de formulario' {
    It 'formato ps1: $KEY = ''valor'' con comillas duplicadas' {
        $r = Get-DotfilesResultLine -Name 'p_name' -Value "O'Brien"
        $r | Should -Be "`$p_name = 'O''Brien'"
    }

    It 'formato ps1: valores multilineales (select many) sobreviven' {
        $r = Get-DotfilesResultLine -Name 'extras' -Value "bat`neza"
        $r | Should -Be "`$extras = 'bat`neza'"
    }

    It 'el archivo de resultado se puede dot-source' {
        $dir = New-DotfilesTempDir -Prefix 'res'
        try {
            $f = Join-Path $dir 'result-03.ps1'
            $body = @(
                (Get-DotfilesResultLine -Name 'extras' -Value "bat`neza"),
                (Get-DotfilesResultLine -Name 'p_name' -Value "O'Brien")
            ) -join "`n"
            [IO.File]::WriteAllText($f, $body, (New-Object System.Text.UTF8Encoding($false)))
            . $f
            $extras | Should -Be "bat`neza"
            $p_name | Should -Be "O'Brien"
        } finally {
            Remove-DotfilesTree -Path $dir
        }
    }
}

Describe '--only' {
    It 'filtra por titulo sin distinguir mayusculas' {
        Test-DotfilesTitleMatch -Title 'Dependencias base' -Filter 'dependencias' | Should -BeTrue
    }
    It 'tolera acentos escritos por el usuario' {
        # Los .ps1 de este repo son ASCII a proposito (PowerShell 5.1 sin BOM
        # rompe UTF-8), asi que el acento se construye con su codigo.
        $o = [char]0x00F3   # 'o' con agudo: el codigo exacto evita acentos en el .ps1
        $f1 = 'Restaurar configuraci' + $o + 'n'
        $f2 = 'Verificaci' + $o + 'n final'
        Test-DotfilesTitleMatch -Title 'Restaurar configuracion' -Filter $f1 | Should -BeTrue
        Test-DotfilesTitleMatch -Title 'Verificacion final' -Filter $f2 | Should -BeTrue
        Test-DotfilesTitleMatch -Title 'Verificacion final' -Filter $f2.ToUpperInvariant() | Should -BeTrue
    }
    It 'no coincide con otro paso' {
        Test-DotfilesTitleMatch -Title 'herdr' -Filter 'OpenCode' | Should -BeFalse
    }
    It 'Add-DotfilesPanelStep descarta los pasos que no coinciden' {
        $env:NUI_ONLY = 'SoloEste'
        $p = New-DotfilesPanel -Title 'T'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Otro paso' -Body { 'x' }
        $p = Add-DotfilesPanelStep -Panel $p -Title 'SoloEste paso' -Body { 'y' }
        @($p.Steps).Count | Should -Be 1
        $p.Steps[0]['title'] | Should -Be 'SoloEste paso'
        Remove-Item env:NUI_ONLY
    }
}

Describe 'Visibilidad condicional (show_if)' {
    $cases = @(
        @{ op = 'eq'; val = 'github'; answer = 'github'; visible = $true },
        @{ op = 'eq'; val = 'github'; answer = 'bitbucket'; visible = $false },
        @{ op = 'gte'; val = '1'; answer = '2'; visible = $true },
        @{ op = 'gte'; val = '1'; answer = '0'; visible = $false },
        @{ op = 'gte'; val = '1'; answer = ''; visible = $false },
        @{ op = 'nonempty'; val = ''; answer = 'Nuxiba'; visible = $true },
        @{ op = 'empty'; val = ''; answer = ''; visible = $true }
    )
    It 'op=$op con respuesta $answer visible=$visible' -TestCases $cases {
        param($op, $val, $answer, $visible)
        $field = [ordered]@{ show_if = @(@{ field = 'x'; op = $op; value = $val }) }
        Get-DotfilesInputVisible -Field $field -Answers @{ x = $answer } | Should -Be $visible
    }
}

Describe 'Preambulo de paso' {
    It 'importa los modulos y declara los campos del formulario' {
        $p = New-DotfilesPanel -Title 'T'
        $p = Add-DotfilesPanelInput -Panel $p -Type 'input' -Name 'p_name' -Prompt 'Nombre'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'P' -Body { Write-Output $p_name }
        $txt = Get-Content -LiteralPath $p.Steps[0]['argv'][-1] -Raw
        $txt | Should -BeLike "*Import-Module*dotfiles.psm1*"
        $txt | Should -BeLike '*$p_name = $null*'
        $txt | Should -BeLike '*NUI_STEP_RESULT*'
        $txt | Should -BeLike '*Write-Output $p_name*'
    }
}

Describe 'Manifiesto de paquetes' {
    It 'es JSON valido y completo' {
        $m = Get-DotfilesPackagesManifest -Reload
        $m.base.Count | Should -BeGreaterThan 0
        $m.custom.Count | Should -BeGreaterThan 5
        $m.apps.Count | Should -BeGreaterThan 0
    }

    It 'cada entrada base tiene key y command' {
        foreach ($e in Get-DotfilesPackageList -Section 'base') {
            $e['key'] | Should -Not -BeNullOrEmpty
            $e['command'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'los custom declaran el comando real que busca el instalador' {
        $fd = Get-DotfilesPackage -Key 'fd-find' -Section 'custom'
        $fd['command'] | Should -Be 'fd'
        $rg = Get-DotfilesPackage -Key 'ripgrep' -Section 'custom'
        $rg['command'] | Should -Be 'rg'
    }

    It 'un fallback con env se puede repinnar por variable' {
        $env:FZF_FALLBACK_URL = 'https://example.com/fzf-custom.zip'
        try {
            $fb = Get-DotfilesFallback -Package (Get-DotfilesPackage -Key 'fzf' -Section 'custom')
            $fb['url'] | Should -Be 'https://example.com/fzf-custom.zip'
        } finally {
            Remove-Item env:FZF_FALLBACK_URL
        }
    }

    It 'Get-DotfilesFallback devuelve inner vacio cuando no hay' {
        $fb = Get-DotfilesFallback -Package (Get-DotfilesPackage -Key 'fzf' -Section 'custom')
        $fb['inner'] | Should -BeNullOrEmpty
    }
}

Describe 'Lista de assets publicos' {
    It 'coincide con PUBLIC_PATHS de scripts/sync.sh' {
        $sh = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/sync.sh') -Raw
        $block = [regex]::Match($sh, 'PUBLIC_PATHS=\(([\s\S]*?)\)').Groups[1].Value
        $fromBash = @([regex]::Matches($block, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $fromPs = Get-DotfilesPublicPathList
        $fromPs | Should -Be $fromBash
    }
}

Describe 'Wrapper sync-dotfiles' {
    It 'escribe .ps1 y .cmd y nunca usa curl | bash' {
        $p = Get-DotfilesPaths
        $r = Install-DotfilesSyncWrapper -Paths $p
        (Test-Path -LiteralPath $r.ps1) | Should -BeTrue
        (Test-Path -LiteralPath $r.cmd) | Should -BeTrue
        $ps1 = Get-Content -LiteralPath $r.ps1 -Raw
        $ps1 | Should -Not -BeLike '*Invoke-Expression*'
        # el wrapper compone argv (no interpola en una cadena de shell)
        $ps1 | Should -BeLike "*'clone', '--depth'*"
        $ps1 | Should -BeLike '*& git @clone*'
        $ps1 | Should -BeLike '*Remove-Item*'
        $ps1 | Should -BeLike '*sync-dotfiles-*'
    }

    It 'rechaza SYNC_REF y SYNC_SHA invalidos' {
        $p = Get-DotfilesPaths
        $env:SYNC_REF = 'main; rm -rf /'
        $env:SYNC_SHA = 'ZZZZ'
        try {
            $r = Install-DotfilesSyncWrapper -Paths $p
            $ps1 = Get-Content -LiteralPath $r.ps1 -Raw
            $ps1 | Should -Not -BeLike '*rm -rf /*'
            $ps1 | Should -Not -BeLike '*ZZZZ*'
        } finally {
            Remove-Item env:SYNC_REF, env:SYNC_SHA
        }
    }
}

Describe 'Semver' {
    It 'compara versiones de neovim' {
        Test-DotfilesSemverGt -Version '0.11.4' -Minimum '0.11.2' | Should -BeTrue
        Test-DotfilesSemverGt -Version '0.10.4' -Minimum '0.11.2' | Should -BeFalse
        Test-DotfilesSemverGt -Version '0.11.2' -Minimum '0.11.2' | Should -BeFalse
        Test-DotfilesSemverGt -Version 'v0.12.0' -Minimum '0.11.2' | Should -BeTrue
        Test-DotfilesSemverGt -Version '0.11.3-rc1' -Minimum '0.11.2' | Should -BeTrue
    }
}
