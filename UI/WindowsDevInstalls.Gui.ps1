#requires -Version 5.1
[CmdletBinding()]
param([switch]$DryRun)
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# These imports are also safe when opening this UI file directly.
# Do not force-reload dependencies that might already be in the caller's scope.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'WindowsDevInstalls.Plan.psm1') -ErrorAction Stop
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'WindowsDevInstalls.Core.psm1') -ErrorAction Stop
foreach ($functionName in @('Get-ToolCatalog', 'Get-TechnologyCatalog', 'Resolve-InstallPlan')) {
    if ($null -eq (Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Required GUI function '$functionName' is unavailable. Check the module imports."
    }
}
$root = Split-Path -Parent $PSScriptRoot
$script:technologyCatalog = @(Get-TechnologyCatalog)
$script:toolCatalog = @(Get-ToolCatalog)
$script:checkBoxes = New-Object 'System.Collections.Generic.List[object]'
$script:process = $null
$script:outputPath = $null
$script:errorPath = $null
$script:running = $false
$script:previewOnly = [bool]$DryRun

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WindowsDevInstalls" Width="1040" Height="770" MinWidth="760" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#101827" Foreground="#E9F2FF" FontFamily="Segoe UI" FontSize="13">
 <Window.Resources>
   <Style TargetType="Button">
     <Setter Property="Background" Value="#2762CB"/><Setter Property="Foreground" Value="White"/>
     <Setter Property="Padding" Value="16,10"/><Setter Property="Margin" Value="0,0,8,0"/>
     <Setter Property="BorderThickness" Value="0"/><Setter Property="FontWeight" Value="SemiBold"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Style.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></Style.Triggers>
   </Style>
   <Style TargetType="CheckBox">
     <Setter Property="Foreground" Value="#E9F2FF"/><Setter Property="FontSize" Value="14"/>
     <Setter Property="Padding" Value="10"/><Setter Property="Margin" Value="2,4"/>
     <Setter Property="MinWidth" Value="200"/><Setter Property="Cursor" Value="Hand"/>
   </Style>
   <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
 </Window.Resources>
 <Grid Margin="24">
   <Grid.RowDefinitions>
     <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="160"/>
   </Grid.RowDefinitions>
   <StackPanel Grid.Row="0" Margin="0,0,0,16">
     <TextBlock Text="WindowsDevInstalls" FontSize="30" FontWeight="Bold" Foreground="#F5F9FF"/>
     <TextBlock Text="Configure your Windows development environment" Foreground="#A9BDD6" Margin="0,4,0,0" FontSize="14"/>
   </StackPanel>
   <Border Grid.Row="1" Background="#1E304A" CornerRadius="9" Padding="14" Margin="0,0,0,14">
     <StackPanel>
       <TextBlock x:Name="BaseTitle" FontWeight="SemiBold" FontSize="15" Text="Core tools included"/>
       <TextBlock x:Name="BaseCaption" Foreground="#BCCCE0" Margin="0,5,0,0"/>
     </StackPanel>
   </Border>
   <TabControl x:Name="TechnologyTabs" Grid.Row="2" Background="#172338" Foreground="#E9F2FF" BorderThickness="0" Margin="0,0,0,12"/>
   <Border Grid.Row="3" Background="#1C2B42" CornerRadius="9" Padding="14" Margin="0,0,0,12">
     <StackPanel>
       <TextBlock x:Name="PlanCaption" FontWeight="SemiBold" FontSize="14"/>
       <TextBlock x:Name="PlanList" Foreground="#A9BDD6" Margin="0,5,0,8" MaxHeight="65"/>
       <StackPanel Orientation="Horizontal">
         <Button x:Name="InstallButton" Content="Install selected"/>
         <Button x:Name="DryRunButton" Content="Preview (dry run)" Background="#35506E"/>
         <Button x:Name="VerifyButton" Content="Verify installed" Background="#35506E"/>
       </StackPanel>
       <ProgressBar x:Name="Progress" Height="5" IsIndeterminate="True" Visibility="Collapsed" Margin="0,12,0,0" Foreground="#60B0FF"/>
     </StackPanel>
   </Border>
   <Border Grid.Row="4" Background="#0B1421" CornerRadius="9" Padding="12">
     <DockPanel LastChildFill="True">
       <TextBlock DockPanel.Dock="Top" Text="Installation output" FontWeight="SemiBold" Margin="0,0,0,8"/>
       <TextBox x:Name="ConsoleOutput" Background="#0B1421" Foreground="#B9DBBA" BorderThickness="0"
                FontFamily="Consolas" FontSize="12" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
     </DockPanel>
   </Border>
 </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$tabs = $window.FindName('TechnologyTabs')
$summary = $window.FindName('PlanCaption')
$planList = $window.FindName('PlanList')
$baseTitle = $window.FindName('BaseTitle')
$baseCaption = $window.FindName('BaseCaption')
$console = $window.FindName('ConsoleOutput')
$progress = $window.FindName('Progress')
$installButton = $window.FindName('InstallButton')
$dryButton = $window.FindName('DryRunButton')
$verifyButton = $window.FindName('VerifyButton')
if ($script:previewOnly) {
    $window.Title = 'WindowsDevInstalls - Preview only (no installation)'
    $installButton.IsEnabled = $false
    $installButton.ToolTip = 'Disabled because -Gui -DryRun was used.'
}
$base = @($script:toolCatalog | Where-Object { $_.Required })
$baseTitle.Text = "$($base.Count) core tools included automatically"
$baseCaption.Text = ($base.Name -join '  |  ')
foreach ($category in @('Frontend','Backend','Language','Tooling')) {
    $tab = New-Object Windows.Controls.TabItem
    $tab.Header = if ($category -eq 'Language') { 'Languages' } elseif ($category -eq 'Tooling') { 'Tools & managers' } else { $category }
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $panel = New-Object Windows.Controls.WrapPanel
    $panel.Margin = [Windows.Thickness]::new(12)
    foreach ($tech in @($script:technologyCatalog | Where-Object { $_.Category -eq $category })) {
        $checkbox = New-Object Windows.Controls.CheckBox
        $checkbox.Content = $tech.Name
        $checkbox.ToolTip = $tech.Description
        $checkbox.Tag = $tech.Key
        $checkbox.Add_Checked({ Update-Plan })
        $checkbox.Add_Unchecked({ Update-Plan })
        [void]$script:checkBoxes.Add($checkbox)
        [void]$panel.Children.Add($checkbox)
    }
    $scroll.Content = $panel
    $tab.Content = $scroll
    [void]$tabs.Items.Add($tab)
}
function Get-Selections {
    @($script:checkBoxes | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { [string]$_.Tag })
}
function Update-Plan {
    $chosen = @(Get-Selections)
    try {
        $resolved = @(Resolve-InstallPlan -Technologies $chosen)
        $summary.Text = "$($chosen.Count) technologies selected  |  $($resolved.Count) unique tools in the installation plan"
        $optional = @($resolved | Where-Object { -not $_.Required })
        $planList.Text = if ($optional.Count) { $optional.Name -join '  |  ' } else { 'Only core tools will be checked.' }
    }
    catch { $summary.Text = $_.Exception.Message }
}
function Start-Installation {
    param([string]$Mode)
    if ($script:running) { return }
    if ($script:previewOnly -and $Mode -eq 'Install') {
        $console.Text = 'Preview-only mode: installation is disabled. Use Preview (dry run) to plan without changing installed applications.'
        return
    }
    $logDir = Join-Path $root 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
    $id = "{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$PID
    $selectionFile = Join-Path $logDir "selection-$id.json"
    @{ Technologies = @(Get-Selections); Tools = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $selectionFile -Encoding UTF8
    $script:outputPath = Join-Path $logDir "UI-$id.stdout.txt"
    $script:errorPath = Join-Path $logDir "UI-$id.stderr.txt"
    $entry = Join-Path $root 'WindowsDevInstalls.ps1'
    $argLine = '-NoProfile -File "' + $entry + '" -SelectionFile "' + $selectionFile + '"'
    switch ($Mode) {
       DryRun { $argLine += ' -DryRun' }
       Verify { $argLine += ' -VerifyOnly' }
    }
    try {
        $script:process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argLine -PassThru -RedirectStandardOutput $script:outputPath -RedirectStandardError $script:errorPath -WindowStyle Hidden -ErrorAction Stop
        $script:running = $true
        $installButton.IsEnabled = $false
        $dryButton.IsEnabled = $false
        $verifyButton.IsEnabled = $false
        $progress.Visibility = 'Visible'
        $console.Text = "Started: $Mode`r`nLog folder: $logDir`r`n"
    }
    catch {
        $console.Text = "Failed to start PowerShell: $($_.Exception.Message)"
    }
}
$installButton.Add_Click({ Start-Installation -Mode Install })
$dryButton.Add_Click({ Start-Installation -Mode DryRun })
$verifyButton.Add_Click({ Start-Installation -Mode Verify })
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({
    if (-not $script:running) { return }
    try {
        $stdout = if (Test-Path -LiteralPath $script:outputPath) { Get-Content -LiteralPath $script:outputPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path -LiteralPath $script:errorPath) { Get-Content -LiteralPath $script:errorPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $text = "$stdout`r`n$stderr"
        if (-not [string]::IsNullOrWhiteSpace($text) -and $text -ne $console.Text) {
            $console.Text = $text
            $console.ScrollToEnd()
        }
        $script:process.Refresh()
        if ($script:process.HasExited) {
            $script:running = $false
            $progress.Visibility = 'Collapsed'
            $installButton.IsEnabled = (-not $script:previewOnly)
            $dryButton.IsEnabled = $true
            $verifyButton.IsEnabled = $true
            $console.AppendText("`r`nProcess finished with exit code $($script:process.ExitCode).`r`n")
            $console.ScrollToEnd()
            $script:process.Dispose()
            $script:process = $null
        }
    }
    catch { $console.AppendText("`r`nUI log warning: $($_.Exception.Message)") }
})
$window.Add_Closed({ $timer.Stop() })
Update-Plan
$timer.Start()
[void]$window.ShowDialog()
