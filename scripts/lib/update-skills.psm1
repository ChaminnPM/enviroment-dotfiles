# update-skills.psm1 - resolucion de refs de upstream para skills externas.
#
# Separado del script por dos motivos:
#   - se puede probar contra un remote local (file://) sin red;
#   - el orden semver es logica con bugs silenciosos (v1.10.0 < v1.2.0 en
#     orden alfabetico) y merece su propio test.

Set-StrictMode -Version 2.0

if (-not (Get-Command Get-DotfilesSemverParts -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'dotfiles.psm1') -Force -ErrorAction Stop
}

# Get-DotfilesSemverKey: clave ordenable tipo '000001000002000000000000'.
function Get-DotfilesSemverKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $v = $Value -replace '^[vV]', ''
    $nums = @($v -split '[.:-]' | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
        })
    while ($nums.Count -lt 4) { $nums += 0 }
    return ('{0:d6}{1:d6}{2:d6}{3:d6}' -f $nums[0], $nums[1], $nums[2], $nums[3])
}

# Get-DotfilesRemoteTags: tags de un remote, sin los puneros ^{}.
function Get-DotfilesRemoteTags {
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$Descending
    )
    $out = @()
    try {
        $out = @(& git ls-remote --tags $Url 2>$null)
    } catch {
        return @()
    }
    if ($LASTEXITCODE -ne 0) { return @() }
    $tags = @($out | ForEach-Object {
            $parts = $_ -split "`t"
            if ($parts.Count -lt 2) { return }
            $ref = "$($parts[1])".Trim()
            if ($ref -match '\^\{\}$') { return }
            if ($ref -notmatch '^refs/tags/') { return }
            $ref -replace '^refs/tags/', ''
        } | Where-Object { $_ })
    if ($tags.Count -eq 0) { return @() }
    # Se devuelve el array EXPANDIDO: los callers lo vuelven a envolver con
    # @(). Devolver ', $sorted' hacia que @(...) viera un unico elemento
    # (el array dentro del array) y [-1] sacara la lista entera.
    $sorted = @($tags | Sort-Object { Get-DotfilesSemverKey $_ } -Descending:$Descending)
    return @($sorted)
}

function Get-DotfilesLatestTag {
    param([Parameter(Mandatory)][string]$Url)
    $tags = @(Get-DotfilesRemoteTags -Url $Url -Descending)
    if ($tags.Count -eq 0) { return '' }
    return "$($tags[0])"
}

# Get-DotfilesRemoteHead: SHA de una rama (default main).
function Get-DotfilesRemoteHead {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Branch = 'main'
    )
    try {
        $out = @(& git ls-remote $Url "refs/heads/$Branch" 2>$null)
    } catch { return '' }
    if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) { return '' }
    return (("$($out[0])" -split "`t")[0]).Trim()
}

Export-ModuleMember -Function *
