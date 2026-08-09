<#
  L2 Offline Server - Control Panel (prototype)
  ---------------------------------------------
  A single-window GUI front end for the launcher. It does not reimplement any
  server logic: Start and Stop call the existing launcher.ps1 / stop.ps1, and the
  brain toggle just flips StartBrain in launcher.ini before starting. The status
  lights are live TCP probes of the real ports, so they reflect the actual stack
  whether it was started from here or from Start-Server.bat.

  Run it with Control-Panel.bat (double-click), or:
     powershell -NoProfile -ExecutionPolicy Bypass -File Control-Panel.ps1

  This is a testable prototype. The compiled C# version is a later step; nothing
  here needs a build - Windows already ships PowerShell and WPF.
#>

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---- paths -----------------------------------------------------------------
$LauncherDir = Split-Path -Parent $MyInvocation.MyCommand.Path      # dist\launcher
$DistDir     = Split-Path -Parent $LauncherDir                       # dist
$PackRoot    = Split-Path -Parent $DistDir                           # folder holding dist\ and setup_brain.bat
$IniPath     = Join-Path $LauncherDir 'launcher.ini'
$StartScript = Join-Path $LauncherDir 'launcher.ps1'
$StopScript  = Join-Path $LauncherDir 'stop.ps1'
$VersionPath = Join-Path $LauncherDir 'version.txt'
$L2AdminPath = Join-Path $DistDir 'tools\l2admin\index.html'         # best-effort, may not exist in every pack

# Public repo the update check looks at (read-only preview). Change to taste.
$UpdateRepo  = 'Teravibes/L2-Living-Worlds'

# Ports probed for the status lights.
$Ports = [ordered]@{
    'Database'     = 3306
    'Login server' = 2106
    'Game server'  = 7777
    'FPC brain'    = 5000
}

# ---- XAML ------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="L2 Offline Server - Control Panel" Height="560" Width="520"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#0B0B0B" FontFamily="Segoe UI">
  <Border Margin="0" Background="#0B0B0B">
    <Grid Margin="18">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Header -->
      <StackPanel Grid.Row="0" Margin="0,0,0,14">
        <TextBlock Text="Living World Server" Foreground="#F3E3CF" FontFamily="Georgia"
                   FontSize="24" FontWeight="SemiBold"/>
        <TextBlock x:Name="SubtitleText" Text="Control Panel" Foreground="#8F8478" FontSize="12" Margin="0,2,0,0"/>
      </StackPanel>

      <!-- Status panel -->
      <Border Grid.Row="1" Background="#121212" BorderBrush="#242424" BorderThickness="1"
              CornerRadius="6" Padding="14" Margin="0,0,0,14">
        <StackPanel x:Name="StatusStack"/>
      </Border>

      <!-- Primary controls -->
      <Grid Grid.Row="2" Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="10"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="StartButton" Grid.Column="0" Height="46" Content="Start server"
                Foreground="#F3E3CF" Background="#2A3D24" BorderBrush="#3E5A34" BorderThickness="1"
                FontFamily="Georgia" FontSize="16" Cursor="Hand"/>
        <Button x:Name="StopButton" Grid.Column="2" Height="46" Content="Stop server"
                Foreground="#F3E3CF" Background="#3D2424" BorderBrush="#5C2A2A" BorderThickness="1"
                FontFamily="Georgia" FontSize="16" Cursor="Hand"/>
      </Grid>

      <!-- Brain toggle -->
      <CheckBox x:Name="BrainCheck" Grid.Row="3" Content="Start the FPC brain with the server"
                Foreground="#CFC2B2" FontSize="13" Margin="2,0,0,12"/>

      <!-- Secondary controls -->
      <Grid Grid.Row="4" Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="UpdateButton" Grid.Column="0" Height="34" Content="Check for updates (preview)"
                Foreground="#CFC2B2" Background="#151515" BorderBrush="#2E2E2E" BorderThickness="1"
                FontSize="12" Cursor="Hand"/>
        <Button x:Name="ConfigButton" Grid.Column="2" Height="34" Content="Open config editor"
                Foreground="#CFC2B2" Background="#151515" BorderBrush="#2E2E2E" BorderThickness="1"
                FontSize="12" Cursor="Hand"/>
      </Grid>

      <!-- Log -->
      <Border Grid.Row="5" Background="#0A0A0A" BorderBrush="#1E1E1E" BorderThickness="1" CornerRadius="6">
        <TextBox x:Name="LogBox" Background="Transparent" Foreground="#9BB88A" BorderThickness="0"
                 FontFamily="Consolas" FontSize="12" Padding="10" IsReadOnly="True"
                 VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
      </Border>

      <!-- Footer -->
      <TextBlock x:Name="FooterText" Grid.Row="6" Text="" Foreground="#5A5248" FontSize="11" Margin="2,10,0,0"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

# ---- grab named controls ---------------------------------------------------
$StatusStack  = $win.FindName('StatusStack')
$StartButton  = $win.FindName('StartButton')
$StopButton   = $win.FindName('StopButton')
$BrainCheck   = $win.FindName('BrainCheck')
$UpdateButton = $win.FindName('UpdateButton')
$ConfigButton = $win.FindName('ConfigButton')
$LogBox       = $win.FindName('LogBox')
$FooterText   = $win.FindName('FooterText')
$SubtitleText = $win.FindName('SubtitleText')

# ---- helpers ---------------------------------------------------------------
function Write-Log($text) {
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $LogBox.AppendText("[$stamp] $text`r`n")
    $LogBox.ScrollToEnd()
}

function Test-Port([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(180)
        if ($ok -and $client.Connected) { $client.EndConnect($iar); return $true }
        return $false
    } catch { return $false }
    finally { $client.Close() }
}

# The database is detected by process, not by a socket probe. A bare TCP connect
# to 3306 leaves and MariaDB logs it as an unauthenticated aborted connection, so
# probing it every few seconds spams the DB console. Checking for the running
# engine process is silent and just as accurate for a status light.
function Test-DbProcess {
    return [bool](Get-Process -Name 'mysqld', 'mariadbd' -ErrorAction SilentlyContinue)
}

# Build one status row (dot + label + state) and keep a handle to its dot/state.
$statusRows = @()
foreach ($name in $Ports.Keys) {
    $row = New-Object Windows.Controls.Grid
    $row.Margin = '0,3,0,3'
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '18'
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = '*'
    $c3 = New-Object Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
    $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2); $row.ColumnDefinitions.Add($c3)

    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 10; $dot.Height = 10; $dot.VerticalAlignment = 'Center'
    $dot.Fill = [Windows.Media.Brushes]::DimGray
    [Windows.Controls.Grid]::SetColumn($dot, 0)

    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $name
    $label.Foreground = '#DCD3C7'
    $label.FontSize = 14
    $label.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($label, 1)

    $state = New-Object Windows.Controls.TextBlock
    $state.Text = 'checking...'
    $state.Foreground = '#8F8478'
    $state.FontSize = 12
    $state.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($state, 2)

    $row.Children.Add($dot) | Out-Null
    $row.Children.Add($label) | Out-Null
    $row.Children.Add($state) | Out-Null
    $StatusStack.Children.Add($row) | Out-Null

    $statusRows += [pscustomobject]@{ Name = $name; Port = $Ports[$name]; Dot = $dot; State = $state }
}

function Update-Status {
    foreach ($r in $statusRows) {
        if ($r.Name -eq 'Database') {
            $up   = Test-DbProcess
            $upTxt = 'running'; $downTxt = 'stopped'
        } else {
            $up   = Test-Port $r.Port
            $upTxt = "up  (port $($r.Port))"; $downTxt = "down (port $($r.Port))"
        }
        if ($up) {
            $r.Dot.Fill   = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x66, 0xBB, 0x55)))
            $r.State.Text = $upTxt
            $r.State.Foreground = '#8FB87A'
        } else {
            $r.Dot.Fill   = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x6E, 0x2E, 0x2E)))
            $r.State.Text = $downTxt
            $r.State.Foreground = '#7B726A'
        }
    }
}

function Set-BrainIni([bool]$enabled) {
    if (-not (Test-Path $IniPath)) { return }
    $val   = if ($enabled) { 'true' } else { 'false' }
    $lines = Get-Content $IniPath
    $found = $false
    $out   = foreach ($line in $lines) {
        if ($line -match '^\s*StartBrain\s*=') { $found = $true; "StartBrain=$val" } else { $line }
    }
    if (-not $found) { $out += "StartBrain=$val" }
    Set-Content -Path $IniPath -Value $out -Encoding ASCII
}

function Start-External([string]$scriptPath, [string[]]$extraArgs = @()) {
    # Launch the existing PowerShell script in its own console so the user sees the
    # detailed pre-flight, while this window keeps showing live status. The launcher
    # console closes itself once startup finishes; the servers and DB it spawns are
    # hidden by -Quiet.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") + $extraArgs
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList
}

# ---- wire up ---------------------------------------------------------------
$StartButton.Add_Click({
    if (-not (Test-Path $StartScript)) { Write-Log "ERROR: launcher.ps1 not found next to this panel."; return }
    Set-BrainIni ([bool]$BrainCheck.IsChecked)
    $withBrain = if ($BrainCheck.IsChecked) { ' (with FPC brain)' } else { '' }
    Write-Log "Starting server$withBrain ... the DB and server terminals stay hidden."
    Start-External $StartScript @('-Quiet')
})

$StopButton.Add_Click({
    if (-not (Test-Path $StopScript)) { Write-Log "ERROR: stop.ps1 not found next to this panel."; return }
    Write-Log "Stopping server ..."
    Start-External $StopScript
})

$ConfigButton.Add_Click({
    if (Test-Path $L2AdminPath) {
        Write-Log "Opening the config editor in your browser ..."
        Start-Process $L2AdminPath
    } else {
        Write-Log "Config editor not found in this pack (tools\l2admin\index.html)."
    }
})

$UpdateButton.Add_Click({
    $UpdateButton.IsEnabled = $false
    Write-Log "Checking $UpdateRepo for the latest release ..."
    $local = if (Test-Path $VersionPath) { (Get-Content $VersionPath -Raw).Trim() } else { '(unknown)' }
    try {
        $headers = @{ 'User-Agent' = 'L2-Control-Panel'; 'Accept' = 'application/vnd.github+json' }
        $uri = "https://api.github.com/repos/$UpdateRepo/releases/latest"
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
        $latest = $resp.tag_name
        Write-Log "Installed: $local    Latest: $latest"
        if ($local -eq $latest) {
            Write-Log "You are up to date."
        } else {
            Write-Log "An update is available. (Auto-download comes in the full version.)"
        }
    } catch {
        Write-Log "Update check failed or no releases published yet: $($_.Exception.Message)"
    } finally {
        $UpdateButton.IsEnabled = $true
    }
})

# ---- status timer ----------------------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick({ Update-Status })

# ---- init ------------------------------------------------------------------
$installed = if (Test-Path $VersionPath) { (Get-Content $VersionPath -Raw).Trim() } else { 'unknown' }
$SubtitleText.Text = "Control Panel   -   version $installed"
$FooterText.Text   = "Prototype - drives launcher.ps1 / stop.ps1. Servers open in their own windows."

# Reflect the current ini brain setting in the checkbox.
if (Test-Path $IniPath) {
    $brainLine = (Get-Content $IniPath) | Where-Object { $_ -match '^\s*StartBrain\s*=' } | Select-Object -First 1
    if ($brainLine -match '=\s*(true|1|yes|on)\s*$') { $BrainCheck.IsChecked = $true }
}

Write-Log "Control panel ready."
Update-Status
$timer.Start()

$win.Add_Closed({ $timer.Stop() })
$win.ShowDialog() | Out-Null
