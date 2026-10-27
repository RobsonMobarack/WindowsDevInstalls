#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-ToolCatalog {
    <#
      Catalog used by the CLI today and available to a future UI.
      Direct installers are deliberately unset: add a trusted pinned HTTPS URL,
      the exact file's SHA-256, installer type and silent arguments before using.
    #>
    @(
        [pscustomobject]@{
            Key = 'Git'; Name = 'Git'; Required = $true
            Command = 'git'; ProbeArgs = @('--version')
            ProbePaths = @('%ProgramFiles%\Git\cmd\git.exe', '%ProgramFiles%\Git\bin\git.exe')
            WinGetId = 'Git.Git'; ChocolateyId = 'git'; ScoopId = 'git'; ScoopBucket = 'main'; Direct = $null
        }
        [pscustomobject]@{
            Key = 'FFmpeg'; Name = 'FFmpeg'; Required = $true
            Command = 'ffmpeg'; ProbeArgs = @('-version')
            ProbePaths = @()
            WinGetId = 'Gyan.FFmpeg'; ChocolateyId = 'ffmpeg'; ScoopId = 'ffmpeg'; ScoopBucket = 'main'; Direct = $null
        }
        [pscustomobject]@{
            Key = '7Zip'; Name = '7-Zip'; Required = $false
            Command = '7z'; ProbeArgs = @('i')
            ProbePaths = @('%ProgramFiles%\7-Zip\7z.exe', '%ProgramFiles(x86)%\7-Zip\7z.exe')
            WinGetId = '7zip.7zip'; ChocolateyId = '7zip'; ScoopId = '7zip'; ScoopBucket = 'main'; Direct = $null
        }
        [pscustomobject]@{
            Key = 'Alacritty'; Name = 'Alacritty'; Required = $false
            Command = 'alacritty'; ProbeArgs = @('--version')
            ProbePaths = @('%ProgramFiles%\Alacritty\alacritty.exe', '%LOCALAPPDATA%\Programs\Alacritty\alacritty.exe')
            WinGetId = 'Alacritty.Alacritty'; ChocolateyId = 'alacritty'; ScoopId = 'alacritty'; ScoopBucket = 'extras'; Direct = $null
        }
        [pscustomobject]@{
            Key = 'ImageMagick'; Name = 'ImageMagick'; Required = $false
            Command = 'magick'; ProbeArgs = @('-version')
            ProbePaths = @('%ProgramFiles%\ImageMagick-*\magick.exe')
            WinGetId = 'ImageMagick.Q16-HDRI'; ChocolateyId = 'imagemagick'; ScoopId = 'imagemagick'; ScoopBucket = 'main'; Direct = $null
        }
        [pscustomobject]@{
            Key = 'Neovim'; Name = 'Neovim'; Required = $false
            Command = 'nvim'; ProbeArgs = @('--version')
            ProbePaths = @('%ProgramFiles%\Neovim\bin\nvim.exe', '%LOCALAPPDATA%\Programs\Neovim\bin\nvim.exe')
            WinGetId = 'Neovim.Neovim'; ChocolateyId = 'neovim'; ScoopId = 'neovim'; ScoopBucket = 'main'; Direct = $null
        }
        [pscustomobject]@{
            Key = 'VSCode'; Name = 'Visual Studio Code'; Required = $false
            Command = 'code'; ProbeArgs = @('--version')
            ProbePaths = @('%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd', '%ProgramFiles%\Microsoft VS Code\bin\code.cmd')
            WinGetId = 'Microsoft.VisualStudioCode'; ChocolateyId = 'vscode'; ScoopId = 'vscode'; ScoopBucket = 'extras'; Direct = $null
        }
        [pscustomobject]@{
            Key = 'WezTerm'; Name = 'WezTerm'; Required = $false
            Command = 'wezterm'; ProbeArgs = @('--version')
            ProbePaths = @('%ProgramFiles%\WezTerm\wezterm.exe', '%LOCALAPPDATA%\Programs\WezTerm\wezterm.exe')
            WinGetId = 'wez.wezterm'; ChocolateyId = 'wezterm'; ScoopId = 'wezterm'; ScoopBucket = 'extras'; Direct = $null
        }
    )
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

    $executable = Get-ApplicationExecutable -Tool $Tool
    if ([string]::IsNullOrWhiteSpace($executable)) { return $false }

    try {
        # Both existence AND successful execution matter.
        & $executable @($Tool.ProbeArgs) *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Update-SessionPath {
    [CmdletBinding()]
    param()

    $extraPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:ProgramFiles 'WinGet\Links'),
        (Join-Path $env:USERPROFILE 'scoop\shims'),
        (Join-Path $env:ProgramData 'chocolatey\bin')
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
        [switch]$DryRun
    )

    if (Test-Application -Tool $Tool) {
        Write-Host "[OK] $($Tool.Name) is already installed." -ForegroundColor Green
        return New-InstallResult $Tool 'AlreadyInstalled' '-' 'Already working'
    }

    if ($DryRun) {
        Write-Host "[PLAN] Would install $($Tool.Name) using $Manager." -ForegroundColor Cyan
        return New-InstallResult $Tool 'Planned' $Manager 'No changes made'
    }

    Write-Host "[MISSING] $($Tool.Name) is not available." -ForegroundColor Yellow
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
                [void]$errors.Add("$candidate is not installed")
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
                Write-Host "[OK] $($Tool.Name) installed successfully via $candidate." -ForegroundColor Green
                return New-InstallResult $Tool 'Installed' $candidate 'Installation and verification succeeded'
            }

            $message = 'Installer reported success, but the application is not executable in this session. Restart the terminal and verify again.'
            Write-Host "[WARNING] $($Tool.Name): $message" -ForegroundColor Yellow
            return New-InstallResult $Tool 'VerificationPending' $candidate $message
        }
        catch {
            $message = $_.Exception.Message
            Write-Host "[ERROR] $candidate failed for $($Tool.Name): $message" -ForegroundColor Red
            [void]$errors.Add("$candidate`: $message")
            # Do not install another copy if a direct MSI reports that reboot is needed.
            if ($candidate -eq 'Direct' -and $message -like '*requires a restart*') {
                return New-InstallResult $Tool 'VerificationPending' $candidate $message
            }
        }
    }

    $detail = if ($errors.Count -gt 0) { $errors -join ' | ' } else { 'No usable installation method was configured.' }
    Write-Host "[ERROR] Unable to install $($Tool.Name). $detail" -ForegroundColor Red
    return New-InstallResult $Tool 'Failed' '-' $detail
}

Export-ModuleMember -Function Get-ToolCatalog, Test-Application, Update-SessionPath, Install-Application
