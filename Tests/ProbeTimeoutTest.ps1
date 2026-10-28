#requires -Version 5.1
# Tests the bounded process probe without installing anything.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'WindowsDevInstalls.Core.psm1') -ErrorAction Stop
$slow = [pscustomobject]@{
    Key = 'SlowProbe'; Name = 'Slow test'; Type = 'package'
    Command = 'powershell.exe'
    ProbeArgs = @('-NoProfile','-Command','Start-Sleep -Seconds 5')
    ProbePaths = @(); DependsOn = @()
}
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$timedOut = $false
try { [void](Test-Application -Tool $slow -TimeoutSeconds 1 -Functional) }
catch [System.TimeoutException] { $timedOut = $true }
$watch.Stop()
if (-not $timedOut) { throw 'Expected a timeout from the slow verification probe.' }
if ($watch.Elapsed.TotalSeconds -gt 8) { throw "Probe timeout took too long: $($watch.Elapsed.TotalSeconds) s" }
Write-Host 'PASS: external tool verification respects timeout.' -ForegroundColor Green
