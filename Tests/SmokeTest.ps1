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

# Regression: VerifyOnly must report a detected executable without invoking it.
$markerVerify = Join-Path $env:TEMP ("windowsdevinstalls-verify-$PID.txt")
if (Test-Path -LiteralPath $markerVerify) { Remove-Item -LiteralPath $markerVerify -Force }
$fakeVerify = [pscustomobject]@{
    Key='FakeVerify'; Name='Fake verify'; Type='package'; Command='cmd.exe'
    ProbeArgs=@('/c', ('echo SHOULD_NOT_EXIST > "' + $markerVerify + '"'))
    ProbePaths=@(); DependsOn=@()
}
$verification = Install-Application -Tool $fakeVerify -VerifyOnly
if ($verification.Status -ne 'AlreadyInstalled') { throw "VerifyOnly gave unexpected status: $($verification.Status)" }
if (Test-Path -LiteralPath $markerVerify) { throw 'VerifyOnly ran an executable probe!' }
$fakeMissing = [pscustomobject]@{
    Key='FakeMissing'; Name='Fake missing'; Type='package'; Command='windowsdevinstalls-nonexistent-xyz.exe'
    ProbeArgs=@('--version'); ProbePaths=@(); DependsOn=@()
}
$missing = Install-Application -Tool $fakeMissing -VerifyOnly
if ($missing.Status -ne 'NotInstalled') { throw "Missing tool gave status $($missing.Status), expected NotInstalled." }
Write-Host 'PASS: VerifyOnly detects a known executable and reports missing tools without launching them.' -ForegroundColor Green

# Regression: locate a Qt kit outside PATH without needing an actual Qt installation.
$fakeQtRoot = Join-Path $env:TEMP ("windowsdevinstalls-qt-$PID")
$oldQtRoot = $env:WINDOWSDEVINSTALLS_QT_ROOT
try {
    $kitBin = Join-Path $fakeQtRoot '6.9.1\mingw_64\bin'
    [void](New-Item -ItemType Directory -Path $kitBin -Force)
    [void](New-Item -ItemType File -Path (Join-Path $kitBin 'qmake.exe') -Force)
    $env:WINDOWSDEVINSTALLS_QT_ROOT = $fakeQtRoot
    $qtTool = (Get-ToolCatalog | Where-Object { $_.Key -eq 'Qt' } | Select-Object -First 1)
    $qt = Install-Application -Tool $qtTool -VerifyOnly
    if ($qt.Status -ne 'AlreadyInstalled') { throw "Qt kit was not found: $($qt.Status)" }
    Write-Host 'PASS: Qt SDK detection works outside PATH with a configured installation root.' -ForegroundColor Green
}
finally {
    $env:WINDOWSDEVINSTALLS_QT_ROOT = $oldQtRoot
    Remove-Item -LiteralPath $fakeQtRoot -Recurse -Force -ErrorAction SilentlyContinue
}
