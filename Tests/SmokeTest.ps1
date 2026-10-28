#requires -Version 5.1
# Execute in Windows PowerShell 5.1: .\Tests\SmokeTest.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'WindowsDevInstalls.Plan.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'WindowsDevInstalls.Core.psm1') -ErrorAction Stop

$tools = @(Get-ToolCatalog)
$techs = @(Get-TechnologyCatalog)
if ($tools.Count -ne 38) { throw "Get-ToolCatalog returned $($tools.Count) entries; expected 38." }
if ($techs.Count -ne 24) { throw "Get-TechnologyCatalog returned $($techs.Count) entries; expected 24." }
if ($tools[0] -is [array] -or $techs[0] -is [array]) { throw 'Catalog returned nested Object[] arrays.' }
if ($tools[0].Key -ne 'Git' -or $techs[0].Key -ne 'Ionic') { throw 'Catalog entries are malformed.' }

$plan = @(Resolve-InstallPlan -Technologies @('Angular','Go'))
$keys = @($plan | ForEach-Object { $_.Key })
foreach ($expected in @('Git','AngularCLI','Go','Docker','FirebaseCLI','MySQL','Kubectl','KubernetesCluster')) {
    if ($keys -notcontains $expected) { throw "Plan lacks $expected." }
}
if (@($keys | Select-Object -Unique).Count -ne $keys.Count) { throw 'Duplicate entries in installation plan.' }
Write-Host "PASS: $($tools.Count) tools, $($techs.Count) technologies, $($plan.Count) unique planned items." -ForegroundColor Green
Write-Host 'No installation commands were executed.' -ForegroundColor Green

# Regression: a dry run must never invoke executables, even when the tool exists.
$marker = Join-Path $env:TEMP ("windowsdevinstalls-probe-$PID.txt")
if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
$fake = [pscustomobject]@{
    Key='DryRunProbe'; Name='DryRun probe'; Type='package'; Command='cmd.exe'
    ProbeArgs=@('/c', ('echo SHOULD_NOT_EXIST > "' + $marker + '"'))
    ProbePaths=@(); DependsOn=@()
}
$previewResult = Install-Application -Tool $fake -DryRun
if (Test-Path -LiteralPath $marker) { throw 'DryRun unexpectedly executed an external command!' }
if ($previewResult.Status -ne 'DetectedUnverified') {
    throw "DryRun did not return DetectedUnverified for available command: $($previewResult.Status)"
}
Write-Host 'PASS: DryRun detects executables without executing them.' -ForegroundColor Green
