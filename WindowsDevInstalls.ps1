#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$Tools,
    [switch]$All,
    [switch]$List,
    [ValidateSet('Auto', 'WinGet', 'Chocolatey', 'Scoop', 'Direct')]
    [string]$Manager = 'Auto',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WindowsDevInstalls.Core.psm1') -Force

$catalog = @(Get-ToolCatalog)

if ($List) {
    $catalog | Select-Object Key, Name, Required, WinGetId, ChocolateyId, ScoopId |
        Format-Table -AutoSize
    return
}

if ($All -and $null -ne $Tools -and $Tools.Length -gt 0) {
    throw 'Use -All or -Tools, not both.'
}

if ($All) {
    $selected = $catalog
}
elseif ($null -ne $Tools -and $Tools.Length -gt 0) {
    $selected = @()
    foreach ($key in $Tools) {
        $match = $catalog | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if ($null -eq $match) {
            $keys = ($catalog.Key -join ', ')
            throw "Unknown tool '$key'. Valid keys: $keys"
        }
        if (@($selected | Where-Object { $_.Key -eq $match.Key }).Count -eq 0) {
            $selected += $match
        }
    }
}
else {
    $selected = @($catalog | Where-Object { $_.Required })
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and -not $DryRun) {
    throw 'WindowsDevInstalls supports installations on Windows only. Use -List or -DryRun elsewhere.'
}

$results = @()
foreach ($tool in $selected) {
    $results += Install-Application -Tool $tool -Manager $Manager -DryRun:$DryRun
}

Write-Host "`n--- Installation summary ---" -ForegroundColor Cyan
$results | Format-Table Name, Status, Manager, Message -AutoSize -Wrap

if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { exit 1 }
if (@($results | Where-Object { $_.Status -eq 'VerificationPending' }).Count -gt 0) { exit 2 }
