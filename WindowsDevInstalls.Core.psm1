#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-ToolCatalog {
    [CmdletBinding()]
    param()

    $file = Join-Path $PSScriptRoot 'Config\tools.json'
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Tool catalog not found: $file"
    }

    # Windows PowerShell 5.1 passes a JSON root array as ONE pipeline object.
    # Parentheses force PowerShell to enumerate its individual entries.
    (Get-Content -LiteralPath $file -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop) | ForEach-Object {
        if ($_ -isnot [pscustomobject] -or
            $null -eq $_.PSObject.Properties['Key'] -or
            [string]::IsNullOrWhiteSpace([string]$_.Key)) {
            throw 'Invalid tools.json: expected individual tool objects with Key. Check JSON array enumeration.'
        }
        $_
    }
}

function Test-DockerDesktopKubernetes {
    [CmdletBinding()]
    param()
    if ($null -eq (Get-Command kubectl -CommandType Application -ErrorAction SilentlyContinue)) {
        # Prefer Docker Desktop's bundled kubectl when absent from PATH.
        $candidates = @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'),
            (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin')
        )
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath (Join-Path $candidate 'kubectl.exe')) {
                $env:Path = "$candidate;$env:Path"
                break
            }
        }
    }
    if ($null -eq (Get-Command kubectl -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
    try {
        # Explicit context: never mutate the user's selected Kubernetes context.
        $raw = & kubectl --context docker-desktop get nodes -o json --request-timeout=8s 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $data = (($raw | Out-String) | ConvertFrom-Json -ErrorAction Stop)
        foreach ($node in @($data.items)) {
            foreach ($condition in @($node.status.conditions)) {
                if ($condition.type -eq 'Ready' -and $condition.status -eq 'True') { return $true }
            }
        }
    }
    catch { return $false }
    return $false
}

function Test-DockerWSL {
    [CmdletBinding()]
    param()
    if ($null -eq (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) { return $false }
    try {
        & wsl.exe --version *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

function Get-ApplicationExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tool)

    $command = Get-Command -Name $Tool.Command -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }

    foreach ($candidate in $Tool.ProbePaths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        $item = Get-Item -Path $expanded -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } | Select-Object -First 1
        if ($null -ne $item) { return $item.FullName }
    }

    return $null
}

function Test-Application {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tool)
    if ($Tool.Type -eq 'cluster') { return (Test-DockerDesktopKubernetes) }
    if ($Tool.Type -eq 'manual') {
        if ($Tool.Key -eq 'Scoop') {
            return ($null -ne (Get-Command scoop -ErrorAction SilentlyContinue))
        }
        return ($false)
    }
    if ($Tool.Key -eq 'Docker') {
        # The docker CLI alone is not proof that Docker Desktop is installed.
        $desktopLocations = @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe')
        )
        $desktopPresent = $false
        foreach ($location in $desktopLocations) {
            if (Test-Path -LiteralPath $location) { $desktopPresent = $true; break }
        }
        if (-not $desktopPresent) { return $false }
    }
    if ($Tool.Key -eq 'MySQL') {
        # Installed MySQL client binaries do not prove that a server is running.
        $service = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1
        return ($null -ne $service)
    }
    $executable = Get-ApplicationExecutable -Tool $Tool
    if ([string]::IsNullOrWhiteSpace($executable)) { return $false }
    try {
        $probeArgs = @($Tool.ProbeArgs)
        & $executable @probeArgs *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

function Update-SessionPath {
    [CmdletBinding()]
    param()

    $extraPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:ProgramFiles 'WinGet\Links'),
        (Join-Path $env:USERPROFILE 'scoop\shims'),
        (Join-Path $env:ProgramData 'chocolatey\bin'),
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:USERPROFILE '.cargo\bin'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin')
    )

    $sources = @(
        $env:Path,
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $outputPaths = New-Object 'System.Collections.Generic.List[string]'

    foreach ($source in @($sources + $extraPaths)) {
        foreach ($entry in ($source -split ';')) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $path = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if ($path -notmatch '^[a-zA-Z]:\\$') { $path = $path.TrimEnd('\') }
            if ($seen.Add($path)) { [void]$outputPaths.Add($path) }
        }
    }
    $env:Path = $outputPaths -join ';'
}

function Test-PackageManager {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('WinGet', 'Chocolatey', 'Scoop')] [string]$Manager)
    $commandName = switch ($Manager) {
        WinGet { 'winget' }
        Chocolatey { 'choco' }
        Scoop { 'scoop' }
    }
    return ($null -ne (Get-Command $commandName -ErrorAction SilentlyContinue))
}

function Invoke-NativeInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    # Native tools may write progress/warnings to stderr even on success.
    # Rely on their exit code, not PowerShell 5.1's redirection behavior.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1 | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { throw "$Command exited with code $exitCode." }
}

function Invoke-WinGetInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tool)
    Invoke-NativeInstaller -Command 'winget' -Arguments @(
        'install', '--id', $Tool.WinGetId, '--exact', '--source', 'winget',
        '--silent', '--accept-package-agreements', '--accept-source-agreements'
    )
}

function Invoke-ChocolateyInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tool)
    Invoke-NativeInstaller -Command 'choco' -Arguments @(
        'install', $Tool.ChocolateyId, '--yes', '--no-progress'
    )
}

function Invoke-ScoopInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tool)

    if ($Tool.ScoopBucket -and $Tool.ScoopBucket -ne 'main') {
        $buckets = & scoop bucket list 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { throw 'Unable to list Scoop buckets.' }
        $bucketName = [regex]::Escape($Tool.ScoopBucket)
        if ($buckets -notmatch "(?im)^\s*$bucketName(?:\s|$)") {
            Invoke-NativeInstaller -Command 'scoop' -Arguments @('bucket', 'add', $Tool.ScoopBucket)
        }
    }

    $package = if ($Tool.ScoopBucket) { "$($Tool.ScoopBucket)/$($Tool.ScoopId)" } else { $Tool.ScoopId }
    Invoke-NativeInstaller -Command 'scoop' -Arguments @('install', $package)
}

function Invoke-DirectInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tool)

    $direct = $Tool.Direct
    if ($null -eq $direct) { throw 'No direct installer is configured.' }
    if ($direct.Url -notmatch '^https://') { throw 'Direct URL must use HTTPS.' }
    if ($direct.Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'A valid SHA-256 is mandatory.' }
    if ($direct.Type -notin @('msi', 'exe')) { throw 'Direct installer must be type msi or exe.' }
    if ($direct.Type -eq 'exe' -and -not $direct.SilentArgs) {
        throw 'An EXE installer requires explicit silent arguments.'
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('WindowsDevInstalls-' + [guid]::NewGuid().ToString('N') + '.' + $direct.Type)
    try {
        Invoke-WebRequest -Uri $direct.Url -OutFile $temp -UseBasicParsing -ErrorAction Stop
        $actualHash = (Get-FileHash -Path $temp -Algorithm SHA256).Hash
        if ($actualHash -ne $direct.Sha256) {
            throw "SHA-256 mismatch. Expected $($direct.Sha256); got $actualHash."
        }

        if ($direct.Type -eq 'msi') {
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$temp`" /qn /norestart" -Wait -PassThru
        }
        else {
            $process = Start-Process -FilePath $temp -ArgumentList $direct.SilentArgs -Wait -PassThru
        }

        if ($process.ExitCode -eq 3010) { throw 'Installer requires a restart (exit code 3010). Re-run verification after reboot.' }
        if ($process.ExitCode -ne 0) { throw "Direct installer exited with code $($process.ExitCode)." }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NpmInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tool)
    if ([string]::IsNullOrWhiteSpace($Tool.NpmPackage)) { throw 'Missing npm package.' }
    # npm.cmd avoids npm.ps1 execution-policy failures on Windows PowerShell.
    $npm = Get-Command 'npm.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $npm) { throw 'npm.cmd is missing. Install Node.js first, then retry.' }
    Invoke-NativeInstaller -Command $npm.Source -Arguments @('install', '--global', $Tool.NpmPackage, '--no-audit', '--no-fund')
}

function Initialize-DockerDesktopKubernetes {
    [CmdletBinding()]
    param($Tool)
    if (Test-DockerDesktopKubernetes) {
        return (New-InstallResult $Tool 'AlreadyInstalled' '-' 'Docker Desktop Kubernetes has a Ready node')
    }
    if (-not (Test-DockerWSL)) {
        return (New-InstallResult $Tool 'ActionRequired' '-' 'WSL 2 is missing or outdated. Run wsl --install or wsl --update in elevated PowerShell; reboot if requested.')
    }
    try {
        if ($null -ne (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
            # Official CLI can start Docker Desktop, but it has no supported create-cluster command.
            & docker desktop start *> $null
        }
    }
    catch { }
    $instructions = 'In Docker Desktop: Kubernetes > Create cluster > kind > 1 node > Create. Keep Linux containers mode. Then run -VerifyOnly (or Refresh in the UI).'
    Write-Host "[ACTION REQUIRED] $instructions" -ForegroundColor Yellow
    return (New-InstallResult $Tool 'ActionRequired' 'Docker Desktop UI' $instructions)
}

function New-InstallResult {
    param($Tool, [string]$Status, [string]$Manager, [string]$Message)
    [pscustomobject]@{
        Key = $Tool.Key
        Name = $Tool.Name
        Status = $Status
        Manager = $Manager
        Message = $Message
    }
}

function Install-Application {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tool,
        [ValidateSet('Auto', 'WinGet', 'Chocolatey', 'Scoop', 'Direct')]
        [string]$Manager = 'Auto',
        [switch]$DryRun,
        [switch]$VerifyOnly
    )

    Update-SessionPath
    if (Test-Application -Tool $Tool) {
        Write-Host "[OK] $($Tool.Name) is already available." -ForegroundColor Green
        return (New-InstallResult $Tool 'AlreadyInstalled' '-' 'Verification succeeded')
    }
    if ($VerifyOnly) {
        return (New-InstallResult $Tool 'VerificationPending' '-' 'Not detected or not yet ready')
    }
    if ($DryRun) {
        Write-Host "[PLAN] $($Tool.Name) [$($Tool.Type)]" -ForegroundColor Cyan
        return (New-InstallResult $Tool 'Planned' $Manager 'No changes made')
    }
    if ($Tool.Type -eq 'cluster') { return (Initialize-DockerDesktopKubernetes -Tool $Tool) }
    if ($Tool.Type -eq 'manual') {
        $guide = if ($Tool.Key -eq 'Scoop') {
            'Scoop bootstrap is guided for security. Review https://scoop.sh/ and follow its official installation instructions.'
        } else { 'Manual installation/configuration required. See README.' }
        return (New-InstallResult $Tool 'ActionRequired' 'Manual' $guide)
    }
    if ($Tool.Type -eq 'npm') {
        try {
            Write-Host "[INSTALL] $($Tool.Name) via npm..." -ForegroundColor Gray
            Invoke-NpmInstall -Tool $Tool
            Update-SessionPath
            if (Test-Application -Tool $Tool) {
                return (New-InstallResult $Tool 'Installed' 'npm' 'Installation and verification succeeded')
            }
            return (New-InstallResult $Tool 'VerificationPending' 'npm' 'npm succeeded but CLI not yet visible; open a new terminal')
        }
        catch { return (New-InstallResult $Tool 'Failed' 'npm' $_.Exception.Message) }
    }
    if ($Tool.Key -eq 'NVM' -and $null -ne (Get-Command node -ErrorAction SilentlyContinue)) {
        return (New-InstallResult $Tool 'ActionRequired' '-' 'Standalone Node.js is already on PATH. Resolve Node/NVM conflict before proceeding.')
    }
    if ($Tool.Key -eq 'Docker' -and -not (Test-DockerWSL)) {
        return (New-InstallResult $Tool 'ActionRequired' '-' 'Set up WSL 2 first with wsl --install / wsl --update as administrator; reboot if necessary.')
    }

    $managers = if ($Manager -eq 'Auto') { @('WinGet', 'Chocolatey', 'Scoop', 'Direct') } else { @($Manager) }
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $managers) {
        if ($candidate -eq 'Direct') {
            if ($null -eq $Tool.Direct) { continue }
        }
        else {
            $id = switch ($candidate) {
                WinGet { $Tool.WinGetId }
                Chocolatey { $Tool.ChocolateyId }
                Scoop { $Tool.ScoopId }
            }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if (-not (Test-PackageManager -Manager $candidate)) {
                [void]$errors.Add("$candidate is not available")
                continue
            }
        }
        try {
            Write-Host "[INSTALL] $($Tool.Name) via $candidate..." -ForegroundColor Gray
            switch ($candidate) {
                WinGet { Invoke-WinGetInstall -Tool $Tool }
                Chocolatey { Invoke-ChocolateyInstall -Tool $Tool }
                Scoop { Invoke-ScoopInstall -Tool $Tool }
                Direct { Invoke-DirectInstall -Tool $Tool }
            }
            Update-SessionPath
            if (Test-Application -Tool $Tool) {
                return (New-InstallResult $Tool 'Installed' $candidate 'Installation and verification succeeded')
            }
            # A successful installer must not trigger another package manager.
            $note = if ($Tool.Key -eq 'MySQL') {
                'Package installed; configure/start the MySQL service and credentials, then verify again.'
            } else {
                'Installer succeeded but command is not available yet; reopen the terminal or reboot and verify again.'
            }
            Write-Host "[WARNING] $($Tool.Name): $note" -ForegroundColor Yellow
            return (New-InstallResult $Tool 'VerificationPending' $candidate $note)
        }
        catch {
            $message = $_.Exception.Message
            Write-Host "[ERROR] $candidate failed for $($Tool.Name): $message" -ForegroundColor Red
            [void]$errors.Add("${candidate}: $message")
            if ($message -like '*requires a restart*') {
                return (New-InstallResult $Tool 'VerificationPending' $candidate $message)
            }
        }
    }
    $detail = if ($errors.Count) { $errors -join ' | ' } else { 'No configured installation method is available.' }
    return (New-InstallResult $Tool 'Failed' '-' $detail)
}

Export-ModuleMember -Function Get-ToolCatalog, Test-Application, Test-DockerDesktopKubernetes, Test-DockerWSL, Update-SessionPath, Install-Application
