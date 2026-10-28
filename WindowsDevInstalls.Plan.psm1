#requires -Version 5.1
Set-StrictMode -Version Latest

# Core is a dependency of Plan. Import into this module's scope without
# forcing a reload of the copy already visible in other scopes.
Import-Module (Join-Path $PSScriptRoot 'WindowsDevInstalls.Core.psm1') -ErrorAction Stop

function Get-TechnologyCatalog {
    [CmdletBinding()]
    param()
    $path = Join-Path $PSScriptRoot 'Config\technologies.json'
    @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Resolve-InstallPlan {
    [CmdletBinding()]
    param(
        [string[]]$Technologies = @(),
        [string[]]$Tools = @(),
        [bool]$IncludeRequired = $true
    )
    $catalog = @(Get-ToolCatalog)
    $technologyCatalog = @(Get-TechnologyCatalog)
    $toolMap = @{}
    $technologyMap = @{}
    foreach ($tool in $catalog) { $toolMap[$tool.Key] = $tool }
    foreach ($tech in $technologyCatalog) { $technologyMap[$tech.Key] = $tech }

    $keys = New-Object 'System.Collections.Generic.List[string]'
    if ($IncludeRequired) {
        foreach ($t in $catalog) {
            if ($t.Required) { [void]$keys.Add($t.Key) }
        }
    }
    foreach ($key in @($Tools)) {
        if (-not $toolMap.ContainsKey($key)) { throw "Unknown tool: $key" }
        [void]$keys.Add($key)
    }
    foreach ($key in @($Technologies)) {
        if (-not $technologyMap.ContainsKey($key)) { throw "Unknown technology: $key" }
        $tech = $technologyMap[$key]
        foreach ($dependency in @($tech.Tools)) { [void]$keys.Add($dependency) }
        switch ($tech.Category) {
            'Frontend' {
                foreach ($dependency in @('Docker', 'FirebaseCLI')) { [void]$keys.Add($dependency) }
            }
            'Backend' {
                foreach ($dependency in @('MySQL', 'Docker', 'Kubectl', 'KubernetesCluster')) {
                    [void]$keys.Add($dependency)
                }
            }
        }
    }
    if (($keys -contains 'NVM') -and ($keys -contains 'Node')) {
        throw 'NVM for Windows conflicts with standalone Node.js. Select one Node management strategy.'
    }
    $visiting = @{}
    $visited = @{}
    $ordered = New-Object 'System.Collections.Generic.List[object]'
    function Visit-Tool {
        param([string]$Key)
        if ($visited.ContainsKey($Key)) { return }
        if ($visiting.ContainsKey($Key)) { throw "Circular dependency: $Key" }
        if (-not $toolMap.ContainsKey($Key)) { throw "Unknown tool dependency: $Key" }
        $visiting[$Key] = $true
        $tool = $toolMap[$Key]
        foreach ($dependency in @($tool.DependsOn)) { Visit-Tool -Key $dependency }
        [void]$visiting.Remove($Key)
        $visited[$Key] = $true
        [void]$ordered.Add($tool)
    }
    foreach ($key in $keys) { Visit-Tool -Key $key }
    return $ordered.ToArray()
}

function Invoke-InstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [ValidateSet('Auto', 'WinGet', 'Chocolatey', 'Scoop', 'Direct')]
        [string]$Manager = 'Auto',
        [switch]$DryRun,
        [switch]$VerifyOnly
    )
    $statuses = @{}
    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($tool in $Plan) {
        $blockers = @()
        if (-not ($DryRun -or $VerifyOnly)) {
            foreach ($dep in @($tool.DependsOn)) {
                if ($statuses.ContainsKey($dep) -and $statuses[$dep] -notin @('Installed', 'AlreadyInstalled')) {
                    $blockers += $dep
                }
            }
        }
        if ($blockers.Count -gt 0) {
            $result = [pscustomobject]@{
                Key=$tool.Key; Name=$tool.Name; Status='Blocked'; Manager='-'
                Message="Dependency not ready: $($blockers -join ', ')"
            }
            Write-Host "[BLOCKED] $($tool.Name): $($result.Message)" -ForegroundColor Yellow
        }
        else {
            $result = Install-Application -Tool $tool -Manager $Manager -DryRun:$DryRun -VerifyOnly:$VerifyOnly
        }
        $statuses[$tool.Key] = $result.Status
        [void]$results.Add($result)
    }
    return $results.ToArray()
}

Export-ModuleMember -Function Get-TechnologyCatalog, Resolve-InstallPlan, Invoke-InstallPlan
