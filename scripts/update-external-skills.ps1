#!/usr/bin/env pwsh
# update-external-skills.ps1 - consulta y actualiza skills externas
# (graphify, security-audit) desde Windows nativo.
#
# Uso:
#   pwsh -File scripts/update-external-skills.ps1            # check
#   pwsh -File scripts/update-external-skills.ps1 -Mode update
#
# El homologo bash existe; en Windows no hay python3 ni rsync, asi que el
# parseo de VERSION.json usa ConvertFrom-Json y la copia usa Copy-DotfilesTree.

[CmdletBinding()]
param(
    [ValidateSet('check', 'update')][string]$Mode = 'check',
    [string]$RepoDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $RepoDir) { $RepoDir = Split-Path -Parent $PSScriptRoot }
$env:REPO_DIR = $RepoDir
$LibDir = [IO.Path]::Combine($RepoDir, 'scripts', 'lib')
Import-Module (Join-Path $LibDir 'dotfiles.psm1') -Force
Import-Module (Join-Path $LibDir 'ui.psm1') -Force
# La resolucion de refs de upstream vive en su modulo: se puede probar contra
# un remote local (file://) sin red.
Import-Module (Join-Path $LibDir 'update-skills.psm1') -Force

$SkillsDir = Join-DotfilesPath -Base $RepoDir -Child 'config/opencode/skills'
if (-not (Test-DotfilesCommand 'git')) {
    Write-UiError 'git no esta disponible; no se puede consultar upstream'
    exit 1
}

function Read-VersionField {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Field
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $data = Read-DotfilesJson -Path $Path
    if ($null -eq $data) { return '' }
    try {
        $v = $data.$Field
        if ($null -eq $v) { return '' }
        return [string]$v
    } catch { return '' }
}

function Write-VersionRef {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Ref
    )
    $data = Read-DotfilesJson -Path $Path
    $ordered = [ordered]@{}
    foreach ($p in $data.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
    $ordered['upstream_ref'] = $Ref
    $ordered['updated_at'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    Write-DotfilesJson -Path $Path -Object $ordered -Depth 6 | Out-Null
}

function Update-Graphify {
    param([string]$Mode)
    $vf = Join-DotfilesPath -Base $SkillsDir -Child 'graphify/VERSION.json'
    $current = Read-VersionField -Path $vf -Field 'upstream_ref'
    $vendored = Read-VersionField -Path $vf -Field 'vendored_ref'
    $repo = 'https://github.com/Graphify-Labs/graphify.git'
    $latestTag = Get-DotfilesLatestTag -Url $repo
    $mainHead = Get-DotfilesRemoteHead -Url $repo

    Write-Host ''
    Write-UiOk 'graphify'
    Write-UiInfo "Upstream ref : $(if ($current) { $current } else { '?' })"
    Write-UiInfo "Vendored ref : $(if ($vendored) { $vendored } else { '?' })"
    Write-UiInfo "Ultimo tag   : $(if ($latestTag) { $latestTag } else { '?' })"
    Write-UiInfo "main HEAD    : $(if ($mainHead) { $mainHead.Substring(0, [Math]::Min(12, $mainHead.Length)) } else { '?' })"

    if ($vendored -like 'custom*') {
        Write-UiWarn 'La copia local es personalizada (references/). Revisar diff y estabilidad antes de actualizar.'
    }
    if (-not $latestTag -or $current -eq $latestTag) {
        Write-UiOk 'graphify al dia (segun tag estable).'
        return
    }
    Write-UiWarn "Hay una version nueva (tag $latestTag). Revisar estabilidad antes de actualizar."
    if ($Mode -ne 'update') { return }
    if (-not (Wait-DotfilesPanelConfirm -Id 'graphify' -Question "Actualizar graphify a $latestTag?")) { return }

    $tmp = New-DotfilesTempDir -Prefix 'graphify'
    try {
        $clone = Join-Path $tmp 'graphify'
        $code = Invoke-DotfilesNative -Argv @('git', 'clone', '--depth', '1', '--branch', $latestTag, $repo, $clone)
        if ($code -ne 0) {
            Write-UiWarn 'No se pudo clonar graphify'
            return
        }
        $src = @(Join-DotfilesPath -Base $clone -Child 'skills/graphify/skill.md', Join-DotfilesPath -Base $clone -Child 'skills/graphify/SKILL.md') |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $src) {
            Write-UiWarn 'El clon no trae skills/graphify/skill.md; revisa la estructura del upstream'
            return
        }
        $dstDir = Join-Path $SkillsDir 'graphify'
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir 'SKILL.md') -Force
        Write-VersionRef -Path $vf -Ref $latestTag
        Write-UiOk "graphify actualizado a $latestTag"
    } finally {
        Remove-DotfilesTree -Path $tmp
    }
}

function Update-SecurityAudit {
    param([string]$Mode)
    $vf = Join-DotfilesPath -Base $SkillsDir -Child 'security-audit/VERSION.json'
    $current = Read-VersionField -Path $vf -Field 'upstream_ref'
    $repo = 'https://github.com/cloudflare/security-audit-skill.git'
    $mainHead = Get-DotfilesRemoteHead -Url $repo -Branch 'main'

    Write-Host ''
    Write-UiOk 'security-audit'
    Write-UiInfo "Vendored ref : $(if ($current) { $current } else { '?' })"
    Write-UiInfo "main HEAD    : $(if ($mainHead) { $mainHead.Substring(0, [Math]::Min(12, $mainHead.Length)) } else { '?' })"

    if (-not $mainHead -or $current -eq $mainHead) {
        Write-UiOk 'security-audit al dia.'
        return
    }
    Write-UiWarn "Hay cambios en upstream (main $mainHead). Revisar estabilidad antes de actualizar."
    if ($Mode -ne 'update') { return }
    if (-not (Wait-DotfilesPanelConfirm -Id 'security-audit' -Question 'Actualizar security-audit desde main?')) { return }

    $tmp = New-DotfilesTempDir -Prefix 'secaudit'
    try {
        $clone = Join-Path $tmp 'repo'
        $code = Invoke-DotfilesNative -Argv @('git', 'clone', '--depth', '1', $repo, $clone)
        if ($code -ne 0) {
            Write-UiWarn 'No se pudo clonar security-audit'
            return
        }
        $src = Join-DotfilesPath -Base $clone -Child 'skills/security-audit'
        if (-not (Test-Path -LiteralPath $src)) {
            Write-UiWarn 'El upstream no trae skills/security-audit; revisa la estructura'
            return
        }
        $dst = Join-Path $SkillsDir 'security-audit'
        if (-not (Copy-DotfilesTree -Source $src -Destination $dst -Mirror)) {
            Write-UiWarn 'No se pudo copiar security-audit'
            return
        }
        Write-VersionRef -Path $vf -Ref $mainHead
        Write-UiOk 'security-audit actualizado desde main'
    } finally {
        Remove-DotfilesTree -Path $tmp
    }
}

Update-Graphify -Mode $Mode
Update-SecurityAudit -Mode $Mode
Write-Host ''
