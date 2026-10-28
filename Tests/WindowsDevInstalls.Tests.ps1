#requires -Version 5.1
# Run with: Invoke-Pester .\Tests\WindowsDevInstalls.Tests.ps1
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'WindowsDevInstalls.Plan.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'WindowsDevInstalls.Core.psm1') -ErrorAction Stop
Describe 'WindowsDevInstalls module exports' {
    It 'exposes the core catalog after both modules have loaded' {
        (Get-Command -Name Get-ToolCatalog -CommandType Function -ErrorAction Stop).ModuleName | Should -Be 'WindowsDevInstalls.Core'
        @(Get-ToolCatalog).Count | Should -BeGreaterThan 0
    }
    It 'exposes planning functions alongside Core functions' {
        Get-Command -Name Resolve-InstallPlan -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command -Name Get-TechnologyCatalog -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}

Describe 'JSON catalog enumeration on Windows PowerShell 5.1' {
    It 'emits each tool as a separate object, not one Object[]' {
        $catalog = @(Get-ToolCatalog)
        $catalog.Count | Should -Be 38
        @($catalog | Where-Object { $_ -is [array] }).Count | Should -Be 0
        $catalog[0].Key | Should -Be 'Git'
    }
    It 'emits each technology as a separate object, not one Object[]' {
        $catalog = @(Get-TechnologyCatalog)
        $catalog.Count | Should -Be 24
        @($catalog | Where-Object { $_ -is [array] }).Count | Should -Be 0
        $catalog[0].Key | Should -Be 'Ionic'
    }
    It 'produces a proper core-only dependency plan' {
        $plan = @(Resolve-InstallPlan)
        $plan.Count | Should -BeGreaterThan 8
        $plan[0].Key | Should -Be 'Git'
        @($plan | Where-Object { $_ -is [array] }).Count | Should -Be 0
    }
}

Describe 'WindowsDevInstalls install plan' {
    It 'adds Docker and Firebase CLI for frontend' {
        $plan = @(Resolve-InstallPlan -Technologies @('Angular') -IncludeRequired:$false)
        $plan.Key | Should -Contain 'Docker'
        $plan.Key | Should -Contain 'FirebaseCLI'
        $plan.Key | Should -Not -Contain 'MySQL'
    }
    It 'adds full Kubernetes + MySQL infrastructure for backend' {
        $plan = @(Resolve-InstallPlan -Technologies @('Go') -IncludeRequired:$false)
        foreach ($key in @('MySQL','Docker','Kubectl','KubernetesCluster','Go')) {
            $plan.Key | Should -Contain $key
        }
        ([array]::IndexOf($plan.Key,'KubernetesCluster') -gt [array]::IndexOf($plan.Key,'Docker')) | Should -Be $true
    }
    It 'deduplicates dependencies across frontend and backend' {
        $plan = @(Resolve-InstallPlan -Technologies @('Angular','Ionic','Go','NestJS') -IncludeRequired:$false)
        @($plan | Where-Object { $_.Key -eq 'Docker' }).Count | Should -Be 1
        @($plan | Where-Object { $_.Key -eq 'FirebaseCLI' }).Count | Should -Be 1
        @($plan | Where-Object { $_.Key -eq 'KubernetesCluster' }).Count | Should -Be 1
    }
    It 'always maps Ionic to Angular CLI' {
        $plan = @(Resolve-InstallPlan -Technologies @('Ionic') -IncludeRequired:$false)
        $plan.Key | Should -Contain 'IonicCLI'
        $plan.Key | Should -Contain 'AngularCLI'
    }
    It 'does not globally install TypeScript merely for Angular' {
        $plan = @(Resolve-InstallPlan -Technologies @('Angular') -IncludeRequired:$false)
        $plan.Key | Should -Not -Contain 'TypeScriptCLI'
    }
    It 'includes TypeScript CLI when selected explicitly' {
        $plan = @(Resolve-InstallPlan -Technologies @('TypeScript') -IncludeRequired:$false)
        $plan.Key | Should -Contain 'TypeScriptCLI'
    }
    It 'rejects unknown technologies' {
        { Resolve-InstallPlan -Technologies @('DoesNotExist') } | Should -Throw
    }
    It 'includes the declared core tools by default' {
        $plan = @(Resolve-InstallPlan)
        foreach ($key in @('Git','FFmpeg','7Zip','Neovim','VSCode','WezTerm','TreeSitter')) {
            $plan.Key | Should -Contain $key
        }
    }
}
