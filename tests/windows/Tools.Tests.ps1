# Tools.Tests.ps1 - utilidades sueltas que tambien se ejecutan en Windows:
# instalador (validacion de ref) y actualizador de skills externas.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:RepoRoot = $RepoRoot
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('tools-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME, env:REPO_REF, env:NUI_INSTALL_BASE_URL -ErrorAction SilentlyContinue
}

Describe 'install.ps1 valida el ref antes de tocar la red' {
    It 'rechaza un REPO_REF con caracteres raros (exit 2)' {
        foreach ($bad in @('main; rm -rf /', '..\..\etc', 'a b', 'main/refs')) {
            $out = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'install.ps1') -Ref $bad 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 2 -Because "ref invalido: '$bad'"
            $out | Should -BeLike '*REPO_REF*'
        }
    }

    It 'rechaza REPO_REF tambien por variable de entorno' {
        $env:REPO_REF = 'main`whoami`'
        try {
            $null = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'install.ps1') 2>&1
            $LASTEXITCODE | Should -Be 2
        } finally {
            Remove-Item env:REPO_REF
        }
    }

    It 'no deja directorios temporales del repo tras un rechazo' {
        $antes = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'enviroment-dotfiles-*' -ErrorAction SilentlyContinue).Count
        $null = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'install.ps1') -Ref 'no valido' 2>&1
        $despues = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'enviroment-dotfiles-*' -ErrorAction SilentlyContinue).Count
        $despues | Should -Be $antes
    }
}

Describe 'update-external-skills.ps1 contra un remote local' {
    BeforeAll {
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git no disponible'
        }
        # Repo bare local con tags: prueba la resolucion semver sin red.
        $src = Join-Path $script:Sandbox 'upstream'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Push-Location $src
        try {
            & git init -q .
            & git config user.email t@example.com
            & git config user.name test
            'skill' | Set-Content -LiteralPath (Join-Path $src 'skill.md')
            & git add skill.md
            & git commit -q -m v1
            & git tag v1.0.0
            'skill2' | Set-Content -LiteralPath (Join-Path $src 'skill.md')
            & git commit -aq -m v2
            & git tag v1.10.0
            'skill3' | Set-Content -LiteralPath (Join-Path $src 'skill.md')
            & git commit -aq -m v3
            & git tag v1.2.0
            & git branch -M main
        } finally {
            Pop-Location
        }
        $script:Upstream = "file://$src"
    }

    It 'ordena tags por semver, no por string (v1.10.0 supera v1.2.0)' {
        Import-Module (Join-Path $script:RepoRoot 'scripts/lib/update-skills.psm1') -Force
        $tags = Get-DotfilesRemoteTags -Url $script:Upstream
        $tags -join ',' | Should -Be 'v1.0.0,v1.2.0,v1.10.0'
        (Get-DotfilesLatestTag -Url $script:Upstream) | Should -Be 'v1.10.0'
    }

    It 'lee upstream_ref del VERSION.json vendorizado' {
        $vf = Join-Path $script:RepoRoot 'config/opencode/skills/graphify/VERSION.json'
        Test-Path -LiteralPath $vf | Should -BeTrue
        $data = Read-DotfilesJson -Path $vf
        $data.upstream_ref | Should -Not -BeNullOrEmpty
        $data.vendored_ref | Should -Not -BeNullOrEmpty
    }
}
