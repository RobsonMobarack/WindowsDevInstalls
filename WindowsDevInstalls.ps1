#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$Technologies = @(),
    [string[]]$Tools = @(),
    [string]$SelectionFile,
    [switch]$All,
    [switch]$List,
    [switch]$Gui,
    [switch]$NoRequired,
    [switch]$VerifyOnly,
    [ValidateSet('Auto', 'WinGet', 'Chocolatey', 'Scoop', 'Direct')]
    [string]$Manager = 'Auto',
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Load the dependency-aware module first, then explicitly expose Core in this scope.
# Never use -Force here: Plan also depends on Core and forced reimports can
# invalidate functions that have already been exported into another scope.
Import-Module (Join-Path $PSScriptRoot 'WindowsDevInstalls.Plan.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsDevInstalls.Core.psm1') -ErrorAction Stop
foreach ($functionName in @('Get-ToolCatalog', 'Get-TechnologyCatalog', 'Resolve-InstallPlan', 'Invoke-InstallPlan')) {
    if ($null -eq (Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Required WindowsDevInstalls function '$functionName' is unavailable. Check the .psm1 files next to WindowsDevInstalls.ps1."
    }
}

if ($Gui) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The WPF interface is only available on Windows.'
    }
    & (Join-Path $PSScriptRoot 'UI\WindowsDevInstalls.Gui.ps1') -DryRun:$DryRun
    return
}
if ($List) {
    Write-Host '=== Tools ===' -ForegroundColor Cyan
    Get-ToolCatalog | Select-Object Key, Name, Required, Type, WinGetId | Format-Table -AutoSize
    Write-Host '=== Technologies ===' -ForegroundColor Cyan
    Get-TechnologyCatalog | Select-Object Key, Name, Category, Description | Format-Table -Wrap -AutoSize
    return
}
if (-not [string]::IsNullOrWhiteSpace($SelectionFile)) {
    $selection = (Get-Content -LiteralPath $SelectionFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    $Technologies = @($selection.Technologies)
    $Tools = @($selection.Tools)
}
if ($DryRun -and $VerifyOnly) { throw 'DryRun and VerifyOnly cannot be combined.' }
if ($All -and @($Technologies).Count -gt 0) { throw 'Choose -All or -Technologies.' }
if ($All) { $Technologies = @((Get-TechnologyCatalog) | Where-Object { $_.Category -ne 'Tooling' } | ForEach-Object { $_.Key }) }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and -not ($DryRun -or $VerifyOnly)) {
    throw 'Installing tools is supported on Windows only. Use -DryRun to preview the plan.'
}

$logDir = $PSScriptRoot
if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
$log = Join-Path $logDir ("log{0}-{1}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$PID)
$exitCode = 0
$transcriptStarted = $false
try {
    Start-Transcript -Path $log -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
    $plan = @(Resolve-InstallPlan -Technologies $Technologies -Tools $Tools -IncludeRequired:(-not $NoRequired))
    Write-Host "WindowsDevInstalls | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "Selected technologies: $($Technologies -join ', ')"
    Write-Host "Plan: $($plan.Count) unique tools | Manager: $Manager | DryRun: $DryRun | VerifyOnly: $VerifyOnly"
    $results = @(Invoke-InstallPlan -Plan $plan -Manager $Manager -DryRun:$DryRun -VerifyOnly:$VerifyOnly)
    Write-Host "`n=== Installation summary ===" -ForegroundColor Cyan
    $results | Format-Table Name, Status, Manager, Message -AutoSize -Wrap | Out-Host
    if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $exitCode = 1 }
    elseif (@($results | Where-Object { $_.Status -in @('VerificationPending','ActionRequired','Blocked') }).Count -gt 0) { $exitCode = 2 }
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    Write-Host "Log file: $log" -ForegroundColor Cyan
}
exit $exitCode
