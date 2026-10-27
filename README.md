# WindowsDevInstalls

A PowerShell 5.1+ Windows development-tool installer. CLI today, reusable module for a future graphical interface.

## Files

- `WindowsDevInstalls.ps1`: command-line entry point and final summary.
- `WindowsDevInstalls.Core.psm1`: catalog, installation engine, verification, and package-manager fallbacks.

## Quick start

Run from PowerShell inside this folder:

```powershell
.\WindowsDevInstalls.ps1 -List
.\WindowsDevInstalls.ps1 -DryRun -All
.\WindowsDevInstalls.ps1                     # Git and FFmpeg only
.\WindowsDevInstalls.ps1 -All                # All 8 tools
.\WindowsDevInstalls.ps1 -Tools Git,Neovim,7Zip
.\WindowsDevInstalls.ps1 -Tools Alacritty,WezTerm -Manager Scoop
```

Available keys: `Git`, `FFmpeg`, `7Zip`, `Alacritty`, `ImageMagick`, `Neovim`, `VSCode`, `WezTerm`.

`-Manager Auto` (default): WinGet -> Chocolatey -> Scoop -> trusted direct installer. Existing package managers are reused, **never installed automatically**. Scoop may add its official `extras` bucket when required.

`-Manager WinGet`, `Chocolatey`, `Scoop`, or `Direct` forces a specific backend without other fallbacks.

A successful package-manager command is followed by a current-session PATH refresh and a runnable-program check. If the command succeeded but the executable is not yet accessible, the state is **VerificationPending** rather than installing another copy with a different package manager.

For 7-Zip and selected GUI programs, the engine also checks well-known installation paths because `7z.exe` and other executables may not be in the PATH. PATH access is not guaranteed for those GUI apps.

## Adding a package

In `Get-ToolCatalog` in the module, add an object following the existing entries. Set these fields:

- `Key`, `Name`, `Required`, `Command`, `ProbeArgs` and `ProbePaths`.
- `WinGetId`, `ChocolateyId`, `ScoopId`, `ScoopBucket` (set unknown IDs to `$null`).
- `Direct = $null` unless a trusted pinned installer is explicitly configured.

Example direct installer **schema** (placeholder values are not a working installer):

```powershell
Direct = @{
    Url        = 'https://vendor.example/releases/1.2.3/setup.exe'
    Sha256     = '<REPLACE WITH ACTUAL 64-HEX SHA-256 FOR THIS FILE>'
    Type       = 'exe'             # exe or msi
    SilentArgs = @('/VERYSILENT', '/NORESTART')
}
```

For MSI, use `Type = 'msi'` and `SilentArgs = @()` (the engine uses `msiexec /qn /norestart`).
For EXE installers, **silent arguments differ by vendor**; verify the vendor's documentation. Only a pinned HTTPS URL with a matching SHA-256 is accepted. Never use a checksum from the same untrusted place as the installer.

The fallback to direct download is inactive until the manifest specifies an installer and checksum; none of the eight current tools needs this fallback.

## Return status

Each call to `Install-Application` returns a PowerShell object with `Key`, `Name`, `Status`, `Manager`, `Message`:

- `AlreadyInstalled`
- `Installed`
- `Planned` (`-DryRun`)
- `VerificationPending` (check after opening a new terminal / reboot)
- `Failed`

CLI exit codes: `0` success or planned; `1` one or more failures; `2` at least one verification pending (unless another tool failed, in which case `1`).

## Notes

- Requires PowerShell 5.1+ on Windows 10/11, and the selected package manager installed.
- Some installers require Windows administrator rights / UAC approval. Scoop normally runs unelevated.
- `--silent` requests unattended installation but UAC, installers, network, policy and licensing requirements may still need action.
- `-DryRun` does not install or modify anything.
- The module functions can be called directly later by a GUI with `Import-Module .\WindowsDevInstalls.Core.psm1`.
- Tool detection is based on a working executable, not a complete inventory of Windows installed applications.
- The code has been statically reviewed but not executed on Windows in this environment; test in a VM or a fresh machine before wide deployment.
