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

function Get-QtSdkPath {
    [CmdletBinding()]
    param()

    # A Qt Creator installation alone does not prove that the Qt SDK exists.
    # Detect a Qt kit (Qt binaries and/or its CMake package configuration).
    foreach ($commandName in @('qmake', 'qmake6', 'qtpaths6')) {
        $command = Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }

    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @(
        $env:WINDOWSDEVINSTALLS_QT_ROOT, $env:QT_ROOT, $env:QTDIR,
        $env:Qt6_DIR, $env:Qt5_DIR,
        (Join-Path $env:SystemDrive 'Qt'),
        (Join-Path $env:ProgramFiles 'Qt'),
        (Join-Path $env:LOCALAPPDATA 'Qt'),
        (Join-Path $env:USERPROFILE 'Qt')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($path)) { [void]$roots.Add($path) }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CMAKE_PREFIX_PATH)) {
        foreach ($path in ($env:CMAKE_PREFIX_PATH -split ';')) {
            if (-not [string]::IsNullOrWhiteSpace($path)) { [void]$roots.Add($path) }
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $roots) {
        $path = [Environment]::ExpandEnvironmentVariables($candidate.Trim('"'))
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        if (-not $seen.Add($path)) { continue }
        # Root can point directly to a kit, its CMake Qt6/Qt5 directory,
        # or the overall Qt installation (typically C:\Qt).
        $patterns = @(
            'bin\qmake.exe', 'bin\qmake6.exe', 'bin\qtpaths6.exe',
            'lib\cmake\Qt6\Qt6Config.cmake', 'lib\cmake\Qt5\Qt5Config.cmake',
            'Qt6Config.cmake', 'Qt5Config.cmake',
            '*\bin\qmake.exe', '*\bin\qmake6.exe', '*\bin\qtpaths6.exe',
            '*\lib\cmake\Qt6\Qt6Config.cmake', '*\lib\cmake\Qt5\Qt5Config.cmake',
            '*\*\bin\qmake.exe', '*\*\bin\qmake6.exe', '*\*\bin\qtpaths6.exe',
            '*\*\lib\cmake\Qt6\Qt6Config.cmake', '*\*\lib\cmake\Qt5\Qt5Config.cmake'
        )
        foreach ($relativePath in $patterns) {
            # -Path supports wildcards while -LiteralPath does not.
            $match = Get-Item -Path (Join-Path $path $relativePath) -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } | Select-Object -First 1
            if ($null -ne $match) { return $match.FullName }
        }
    }
    return $null
}

function Test-DockerDesktopKubernetes {
    [CmdletBinding()]
    param()

    $kubectl = Get-Command kubectl -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $kubectl) { return $false }

    # Inspect explicitly named context; do NOT switch the user's active context.
    # kubectl may emit errors on stderr, which PowerShell 5.1 can promote to
    # terminating errors when ErrorActionPreference is Stop.
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $contexts = @(& $kubectl.Source config get-contexts -o name 2>$null)
        if ($LASTEXITCODE -ne 0 -or ($contexts -notcontains 'docker-desktop')) { return $false }

        $raw = @(& $kubectl.Source --context docker-desktop get nodes -o json --request-timeout=8s 2>$null)
        if ($LASTEXITCODE -ne 0) { return $false }
        $data = (($raw | Out-String) | ConvertFrom-Json -ErrorAction Stop)
        foreach ($node in @($data.items)) {
            foreach ($condition in @($node.status.conditions)) {
                if ($condition.type -eq 'Ready' -and $condition.status -eq 'True') { return $true }
            }
        }
    }
    catch { return $false }
    finally { $ErrorActionPreference = $oldPreference }
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

function Invoke-ExecutableProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 10
    )

    # Bounded native process, including .cmd shims used by npm CLIs.
    # Redirect to files (not pipes) so verbose tools cannot deadlock the parent.
    $stdoutPath = [IO.Path]::GetTempFileName()
    $stderrPath = [IO.Path]::GetTempFileName()
    $process = $null
    try {
        $quotedArgs = @($Arguments | ForEach-Object {
            $arg = [string]$_
            if ($arg -match '[\s"]') { '"' + ($arg -replace '"', '\"') + '"' }
            else { $arg }
        }) -join ' '

        $file = $Executable
        $argumentsText = $quotedArgs
        if ([IO.Path]::GetExtension($Executable) -in @('.cmd', '.bat')) {
            $file = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:WINDIR 'System32\cmd.exe' }
            $argumentsText = '/d /s /c ""' + $Executable + '" ' + $quotedArgs + '"'
        }

        $options = @{
            FilePath = $file
            PassThru = $true
            WindowStyle = 'Hidden'
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($argumentsText)) {
            $options.ArgumentList = $argumentsText
        }
        $process = Start-Process @options
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Kill the exact probe process and its children, never the host UI.
            try {
                $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
                & $taskkill /PID $process.Id /T /F 2>$null | Out-Null
            }
            catch { }
            if (-not $process.HasExited) {
                try { $process.Kill() } catch { }
            }
            throw [System.TimeoutException]::new(
                "Verification timed out after $TimeoutSeconds seconds: $Executable $quotedArgs"
            )
        }
        return ($process.ExitCode -eq 0)
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-Application {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tool,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 10,
        [switch]$Functional
    )

    # Default check: installation DETECTION, not a potentially blocking launch.
    # In particular, jdtls, GUI applications and development servers do not
    # necessarily support --version, or may not exit after being launched.
    if ($Tool.Type -eq 'cluster') { return (Test-DockerDesktopKubernetes) }
    if ($Tool.Key -eq 'Qt') {
        return (-not [string]::IsNullOrWhiteSpace((Get-QtSdkPath)))
    }
    if ($Tool.Type -eq 'manual') {
        if ($Tool.Key -eq 'Scoop') {
            return ($null -ne (Get-Command scoop -ErrorAction SilentlyContinue))
        }
        return $false
    }
    if ($Tool.Key -eq 'Docker') {
        # Docker CLI can be installed without Docker Desktop. Check the app.
        foreach ($path in @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe')
        )) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
        }
        return $false
    }
    if ($Tool.Key -eq 'MySQL') {
        # A stopped MySQL service still means the server is installed.
        $service = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $service) { return $true }
    }

    $executable = Get-ApplicationExecutable -Tool $Tool
    if ([string]::IsNullOrWhiteSpace($executable)) { return $false }
    if (-not $Functional -or $Tool.Key -eq 'Jdtls') { return $true }

    # Optional deeper probe, kept separate from "Verify installed".
    return (Invoke-ExecutableProbe -Executable $executable -Arguments @($Tool.ProbeArgs) -TimeoutSeconds $TimeoutSeconds)
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

    # IMPORTANT: Preview must NEVER launch a tool's version command.
    # Only examine PATH / known paths, without modifying installations or executing tools.
    if ($DryRun) {
        $detected = $false
        if ($Tool.Type -ne 'cluster') {
            $detected = Test-Application -Tool $Tool
        }
        if ($detected) {
            Write-Host "[FOUND] $($Tool.Name) (installation detected; no apps launched)." -ForegroundColor DarkGreen
            return (New-InstallResult $Tool 'DetectedUnverified' '-' 'Installation footprint detected; not executed')
        }
        Write-Host "[PLAN] $($Tool.Name) [$($Tool.Type)]" -ForegroundColor Cyan
        return (New-InstallResult $Tool 'Planned' $Manager 'No changes made')
    }

    Update-SessionPath
    Write-Host "[CHECK] $($Tool.Name) (installation detection)..." -ForegroundColor Gray
    try {
        if (Test-Application -Tool $Tool) {
            Write-Host "[OK] $($Tool.Name) is already available." -ForegroundColor Green
            return (New-InstallResult $Tool 'AlreadyInstalled' '-' 'Installation detected (execution not tested)')
        }
    }
    catch [System.TimeoutException] {
        Write-Host "[WARNING] $($_.Exception.Message)" -ForegroundColor Yellow
        return (New-InstallResult $Tool 'VerificationPending' '-' $_.Exception.Message)
    }
    if ($VerifyOnly) {
        if ($Tool.Type -eq 'cluster') {
            return (New-InstallResult $Tool 'NotReady' '-' 'Docker Desktop Kubernetes has no Ready node, or docker-desktop context is missing')
        }
        return (New-InstallResult $Tool 'NotInstalled' '-' 'Installation not detected in PATH, services, or configured locations')
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
                return (New-InstallResult $Tool 'Installed' 'npm' 'Installer completed; installation footprint detected (execution not tested)')
            }
            return (New-InstallResult $Tool 'VerificationPending' 'npm' 'npm completed but CLI is not detected yet; open a new terminal')
        }
        catch [System.TimeoutException] {
            return (New-InstallResult $Tool 'VerificationPending' 'npm' $_.Exception.Message)
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
            try {
                if (Test-Application -Tool $Tool) {
                    return (New-InstallResult $Tool 'Installed' $candidate 'Installer completed; installation footprint detected (execution not tested)')
                }
            }
            catch [System.TimeoutException] {
                # Installer succeeded. Do not retry through a second package manager.
                return (New-InstallResult $Tool 'VerificationPending' $candidate $_.Exception.Message)
            }
            # A successful installer must not trigger another package manager.
            $note = if ($Tool.Key -eq 'MySQL') {
                'Package installed; configure/start the MySQL service and credentials, then verify again.'
            } else {
                'Installer completed but installation footprint is not detected; reopen terminal or reboot then verify.'
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
