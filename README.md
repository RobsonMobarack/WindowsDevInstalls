# WindowsDevInstalls

Windows-oriented developer environment bootstrapper (PowerShell 5.1+, WPF checklist UI + CLI). Personal opinionated defaults that others can adapt. **Experimental: start with a virtual machine and a dry run.** It has not been executed on a Windows machine as part of its creation.

## Project layout

```
WindowsDevInstalls.ps1              # CLI entry, dry runs, verification and transcript
WindowsDevInstalls.Core.psm1         # installer engine: WinGet, Chocolatey, Scoop, npm, URL
WindowsDevInstalls.Plan.psm1         # technology profiles, dependency order and dedup
Config/tools.json                   # tools catalog (change package IDs here)
Config/technologies.json            # selectable profiles
UI/WindowsDevInstalls.Gui.ps1       # WPF dark theme checklist; runs CLI in separate process
Tests/WindowsDevInstalls.Tests.ps1  # Pester smoke tests of dependency resolution
Logs/                               # GUI output captures / temporary selection files
```

## Start

Open **Windows PowerShell 5.1** (standard Windows; `powershell.exe`) in the extracted folder:

```powershell
.\WindowsDevInstalls.ps1 -Gui                        # graphical checklist
.\WindowsDevInstalls.ps1 -List                       # show available keys
.\WindowsDevInstalls.ps1 -Technologies Go,Angular -DryRun
.\WindowsDevInstalls.ps1 -Technologies Go,Angular
.\WindowsDevInstalls.ps1 -Technologies Ionic,Vue
.\WindowsDevInstalls.ps1 -Technologies TypeScript -NoRequired
.\WindowsDevInstalls.ps1 -Tools Git,Neovim -NoRequired
.\WindowsDevInstalls.ps1 -Technologies Go -VerifyOnly # after setup/reboot
```

Without `-Technologies` or `-Tools`, the CLI checks/installs the core tools. `-All` selects all programming profiles (excluding package-manager/tooling choices) (large installation; use `-DryRun` first). `-NoRequired` omits the mandatory base when targeting a particular set. For first execution, run a dry run to review the complete plan. All textual console feedback is in English. Installation logs are written next to the entry script as `logyyyyMMdd-HHmmss-PID.txt`; GUI process output captures are stored in `Logs/`.

The WPF window contains Frontend, Backend, Languages and Tools & managers tabs, checkboxes, a dynamic plan summary, install button, dry-run and verification buttons, and a scrolling log. It starts a separate PowerShell process so that installers do **not block the UI**. Closing the window while installation is active doesn't automatically kill the child process; see logs for progress.

## Rules

- **All frontend profiles** -> Docker Desktop and Firebase CLI (npm). Profiles: Ionic + Angular (always Angular), Angular, React, Vue.js and Vite.
- **All backend profiles** -> MySQL Community Server, Docker Desktop, `kubectl` and a **Ready local Kubernetes cluster** managed by Docker Desktop. Profiles: NestJS, Express.js, Go, Java, Python backend, Rust backend.
- **Standalone languages** (Python, Rust, TypeScript, Lua, C, C++) do not automatically install backend services.
- Angular and Ionic use the Angular CLI; NestJS uses the NestJS CLI. React uses `npm create vite@latest`, Vue uses `npm create vue@latest` **per project**. They do not install deprecated/global scaffolding CLIs. Explicitly selecting Vite installs the `vite` CLI globally, but pin it as a project dependency for real projects.
- TypeScript global CLI is installed **only when TypeScript standalone is selected**. Other frameworks use TypeScript from project dependencies.
- GUI selection stays fully available; dependency deduplication happens in the planner, not by disabling options.
- Additional base tools: fd, fzf, ripgrep and Tree-sitter CLI (as per the original notes). The default includes the original eight programs plus these four.
- Java includes JDK, Maven, and JDTLS; JDTLS currently requires Scoop and Python. See package-manager limitations below.
- C/C++ includes LLVM/Clang, CMake, Ninja and make. On Windows you may still need a suitable **linker, headers, Windows SDK or MinGW toolchain**. Qt installation is a guided/manual step because the Qt SDK requires selecting license, components, kit and version.

## Kubernetes and Docker Desktop — important limitation

Docker's official Desktop CLI supports starting Desktop and checking Kubernetes state, but **does not expose a supported command to create Docker Desktop's built-in Kubernetes cluster**. This project does not edit Docker Desktop internal settings JSON or claim a cluster was created. For a backend profile:

1. Verify WSL 2: `wsl --version`. If missing, run `wsl --install` or `wsl --update` in an elevated terminal, and reboot if requested. The installer doesn't silently change Windows features or reboot the machine.
2. Install Docker Desktop (from WinGet by default); sign in/accept Docker terms if prompted, start Docker Desktop and ensure **Linux container mode**.
3. **Open Docker Desktop > Kubernetes > Create cluster > kind**, select **one node**, then **Create**. If `kind` is unavailable, check the containerd image store requirement in Docker Desktop. Docker may download container images. This is an explicit guided step.
4. Re-run `-Technologies Go -VerifyOnly` (or click **Verify installed** in the GUI with a backend profile selected). It executes `kubectl --context docker-desktop get nodes -o json --request-timeout=8s` and requires at least one condition `Ready=True`.

The installer returns `ActionRequired` until you finish this stage. No `kubectl config use-context` is performed, and no other contexts or Kubernetes resources are removed. `kubectl` is installed only if absent; Docker Desktop bundles its own copy on current Windows versions. Docker Desktop has system requirements (WSL, virtualization and supported Windows releases) and licensing conditions; see [official installation docs](https://docs.docker.com/desktop/setup/install/windows-install/) and [Kubernetes instructions](https://docs.docker.com/desktop/use-desktop/kubernetes/).

## MySQL

`Oracle.MySQL` is the WinGet package. A package installation alone does not guarantee a configured or running server. This app verifies **a running MySQL service**; if it is not ready, reports `VerificationPending`, so configure the service and credentials following MySQL documentation. The script does **not** generate or log a database root password.

## Install engines and direct downloads

For a package type, `-Manager Auto` checks installed managers in this order: WinGet -> Chocolatey -> Scoop -> configured pinned HTTPS direct installer. It does not bootstrap Scoop or Chocolatey without your explicit selection. Chocolatey can be selected separately (installed using WinGet). Scoop is guided/manual due to its script bootstrap. NVM for Windows is also optional, but the planner blocks selecting NVM together with standalone Node.js to avoid PATH conflicts. Native `npm` CLI packages use `npm` regardless of `-Manager`. Package managers must already exist; use `winget --version`, `choco --version`, or `scoop --version`. Scoop may add its `extras` bucket if a package needs it.

If an installer returns success but verification is not yet possible, the result is `VerificationPending` **without installing a second copy using another manager**. Reboot or open a new terminal and use `-VerifyOnly`. If a dependency fails or requires action, its dependents are `Blocked` rather than installed out of order.

A direct EXE/MSI can be configured in `Config/tools.json` for any package:

```json
"Direct": {
  "Url": "https://official.example.org/releases/1.2.3/installer.exe",
  "Sha256": "REPLACE_WITH_REAL_64_HEX_SHA256",
  "Type": "exe",
  "SilentArgs": ["/VERYSILENT", "/NORESTART"]
}
```

The placeholders are **not** functional. Pin the vendor URL to a specific version and use a trustworthy SHA-256 obtained from a trusted channel. The engine requires both HTTPS and a valid matching SHA-256 before execution. MSI uses `msiexec /qn /norestart`.

## Exit codes and result states

`Installed`, `AlreadyInstalled`, `Planned`, `VerificationPending`, `ActionRequired`, `Blocked`, `Failed`.

- `0`: all completed or planned.
- `1`: one or more failures.
- `2`: outstanding action, blocked dependency or verification pending, without an explicit failure.

`-DryRun` never installs or changes system software (it **does** write a log). `-VerifyOnly` performs read-only checks (except logs) and never configures software. The WPF app supports both operations.

## Tests

```powershell
Install-Module Pester -Scope CurrentUser  # only if you need Pester and trust PSGallery
Invoke-Pester .\Tests\WindowsDevInstalls.Tests.ps1
```

For a first real installation, test in a disposable Windows 11 VM. No Windows, Docker, WinGet or WPF runtime was available where this project was generated; the catalog/dependency configuration has undergone static checks, **not a real end-to-end Windows test**.


## v2.1 module-import and GUI preview fix

The previous v2 release repeatedly used `Import-Module -Force` while both the plan and GUI depended on `WindowsDevInstalls.Core.psm1`. This could make public functions such as `Get-ToolCatalog` unavailable in a subsequent scope. The new build loads Plan and Core without forced reloads and checks public exports before opening the UI.

- `./WindowsDevInstalls.ps1 -Gui` starts the interface with installation enabled.
- `./WindowsDevInstalls.ps1 -Gui -DryRun` starts the interface with **Install selected** disabled; **Preview (dry run)** remains enabled.
- `./WindowsDevInstalls.ps1 -List` checks both catalogs.
- `Invoke-Pester ./Tests/WindowsDevInstalls.Tests.ps1` exercises exports and dependency rules (requires Pester).

This build was statically reviewed but could not be executed on Windows in the build environment. Run the dry-run first before any installation.
