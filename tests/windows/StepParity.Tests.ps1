# StepParity.Tests.ps1 - los pasos de bootstrap.sh y bootstrap.ps1 no drenan.
#
# Si alguien anade, quita o reordena un paso en una capa sin tocar la otra,
# este test falla. Es el unico mecanismo que mantiene creible la promesa de
# "dos runners, misma instalacion" de docs/STEPS.md.
#
# Los titulos se comparan por clave ASCII (Format-DotfilesAsciiKey): los .sh
# pueden llevar acentos, los .ps1 no pueden (CI los fuerza ASCII porque
# PowerShell 5.1 sin BOM rompe UTF-8).

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:RepoRoot = $RepoRoot
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force

    # Titulos de bootstrap.sh, en orden de definicion (pueden estar dentro de
    # un if --skip-git: se allowa sangria).
    $sh = Get-Content -LiteralPath (Join-Path $RepoRoot 'bootstrap.sh') -Raw
    $script:ShTitles = @([regex]::Matches($sh, '(?m)^\s*ui_panel_step "([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value })
    $script:ShKeys = @($script:ShTitles | ForEach-Object { Format-DotfilesAsciiKey $_ })

    # Plan de bootstrap.ps1 (dry-run: no toca el home real ni la red).
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('parity-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    $raw = & pwsh -NoProfile -File (Join-Path $RepoRoot 'bootstrap.ps1') -DryRun | Out-String
    $script:PlanJson = $raw.Substring($raw.IndexOf('{'))

    # Unicos emparejamientos permitidos: el equivalente funcional en Windows.
    # Cualquier otra diferencia de titulo u orden es un fallo.
    $script:Map = @(
        @{ sh = 'Credenciales sudo';             ps = 'Requisitos del sistema' },
        @{ sh = 'Dependencias base';             ps = 'Dependencias base' },
        @{ sh = 'Fuente (JetBrains Mono Nerd)';  ps = 'Fuente (JetBrains Mono Nerd)' },
        @{ sh = 'Identidad Git (SSH)';           ps = 'Identidad Git (SSH)' },
        @{ sh = 'Registrar y probar llaves SSH'; ps = 'Registrar y probar llaves SSH' },
        @{ sh = 'Paquetes custom';               ps = 'Paquetes custom' },
        @{ sh = 'Node + nvm';                    ps = 'Node + gestor de versiones' },
        @{ sh = 'Actualizar nvm (opcional)';     ps = 'Actualizar gestor de Node (opcional)' },
        @{ sh = 'OpenCode';                      ps = 'OpenCode' },
        @{ sh = 'Restaurar configuracion';       ps = 'Restaurar configuracion' },
        @{ sh = 'Alacritty (opcional)';          ps = 'Windows Terminal (tema)' },
        @{ sh = 'graphify';                      ps = 'graphify' },
        @{ sh = 'oh-my-bash';                    ps = 'oh-my-posh' },
        @{ sh = 'Tema (Dracula)';                ps = 'Tema (Dracula)' },
        @{ sh = 'herdr';                         ps = 'herdr' },
        @{ sh = 'Wrappers';                      ps = 'Wrappers' },
        @{ sh = 'Verificacion final';            ps = 'Verificacion final' },
        @{ sh = 'Persistencia de entorno';       ps = 'Persistencia de entorno' }
    )
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME, env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
}

Describe 'Paridad de pasos entre capas' {
    BeforeAll {
        $plan = ConvertFrom-Json -InputObject $script:PlanJson
        $script:Plan = $plan
        $script:PsKeys = @($plan.steps | ForEach-Object { Format-DotfilesAsciiKey $_.title })
    }

    It 'bootstrap.sh declara pasos y el mapa los cubre todos' {
        $script:ShKeys.Count | Should -BeGreaterThan 10
        $script:Map.Count | Should -Be $script:ShKeys.Count -Because 'el mapa necesita una fila por paso de bash'
    }

    It 'ambas capas definen el mismo numero de pasos' {
        $script:PsKeys.Count | Should -Be $script:ShKeys.Count
    }

    It 'cada paso de bash tiene su equivalente en PowerShell, en el mismo orden' {
        for ($i = 0; $i -lt $script:ShKeys.Count; $i++) {
            $row = $script:Map[$i]
            (Format-DotfilesAsciiKey $row.sh) | Should -Be $script:ShKeys[$i] -Because "posicion $($i + 1) de bootstrap.sh"
            (Format-DotfilesAsciiKey $row.ps) | Should -Be $script:PsKeys[$i] -Because "posicion $($i + 1) del plan pwsh"
        }
    }

    It 'el paso de terminal cambia de nombre a proposito (no por olvido)' {
        $row = @($script:Map | Where-Object { $_.sh -eq 'Alacritty (opcional)' })
        $row.Count | Should -Be 1
        $row[0].ps | Should -Be 'Windows Terminal (tema)'
        # y el plan de Windows no debe mencionar el terminal de Linux
        $script:PlanJson | Should -Not -BeLike '*lacritty*'
    }

    It 'los pasos obligatorios de bash siguen siendolo en Windows' {
        $obligatorios = @('Dependencias base', 'Paquetes custom', 'OpenCode',
            'Restaurar configuracion', 'graphify', 'herdr', 'Wrappers',
            'Persistencia de entorno', 'Tema (Dracula)', 'Node + gestor de versiones')
        foreach ($t in $obligatorios) {
            $key = Format-DotfilesAsciiKey $t
            $step = @($script:Plan.steps | Where-Object { (Format-DotfilesAsciiKey $_.title) -eq $key })
            $step.Count | Should -Be 1 -Because "el paso '$t' debe existir"
            $step[0].optional | Should -BeFalse -Because "el paso '$t' no puede ser opcional"
        }
    }

    It 'los pasos que pueden fallar sin red son opcionales' {
        foreach ($t in @('Fuente (JetBrains Mono Nerd)', 'Windows Terminal (tema)',
                'Verificacion final', 'Identidad Git (SSH)',
                'Registrar y probar llaves SSH', 'Actualizar gestor de Node (opcional)')) {
            $key = Format-DotfilesAsciiKey $t
            $step = @($script:Plan.steps | Where-Object { (Format-DotfilesAsciiKey $_.title) -eq $key })
            $step.Count | Should -Be 1 -Because "el paso '$t' debe existir"
            $step[0].optional | Should -BeTrue -Because "'$t' no debe abortar la instalacion"
        }
    }

    It 'cada paso tiene estimado razonable (el progreso lo necesita)' {
        foreach ($s in $script:Plan.steps) {
            $s.estimate | Should -BeGreaterThan 0 -Because "el paso '$($s.title)' necesita estimado"
            $s.estimate | Should -BeLessOrEqual 600 -Because "el paso '$($s.title)' deberia partirse"
        }
    }
}
