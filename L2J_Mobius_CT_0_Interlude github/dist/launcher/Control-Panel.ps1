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
$UpdateScript= Join-Path $LauncherDir 'update.ps1'
$VersionPath = Join-Path $LauncherDir 'version.txt'
$L2AdminPath = Join-Path $DistDir 'tools\l2admin\index.html'         # best-effort, may not exist in every pack

# Interactive brain setup lives in the pack at <root>\brain\setup_brain.bat; a raw
# source checkout keeps setup_brain.bat one level above dist\. Try both.
function Resolve-BrainSetup {
    $c = Join-Path $DistDir 'brain\setup_brain.bat'
    if (Test-Path $c) { return $c }
    $c = Join-Path $PackRoot 'setup_brain.bat'
    if (Test-Path $c) { return $c }
    return $null
}

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

      <!-- Optional extras: brain + game client -->
      <StackPanel Grid.Row="3" Margin="0,0,0,12">
        <!-- Brain toggle + one-time setup -->
        <Grid Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="8"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <CheckBox x:Name="BrainCheck" Grid.Column="0" Content="Start the FPC brain with the server"
                    Foreground="#CFC2B2" FontSize="13" VerticalAlignment="Center" Margin="2,0,0,0"/>
          <Button x:Name="BrainSetupButton" Grid.Column="2" Height="30" Content="Set up / configure brain"
                  Foreground="#CFC2B2" Background="#151515" BorderBrush="#2E2E2E" BorderThickness="1"
                  FontSize="12" Padding="10,0" Cursor="Hand"/>
        </Grid>
        <!-- Game client toggle + path picker -->
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="8"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <CheckBox x:Name="ClientCheck" Grid.Column="0" Content="Launch the game client with the server"
                    Foreground="#CFC2B2" FontSize="13" VerticalAlignment="Center" Margin="2,0,0,0"/>
          <Button x:Name="ClientPathButton" Grid.Column="2" Height="30" Content="Set game client..."
                  Foreground="#CFC2B2" Background="#151515" BorderBrush="#2E2E2E" BorderThickness="1"
                  FontSize="12" Padding="10,0" Cursor="Hand"/>
        </Grid>
      </StackPanel>

      <!-- Secondary controls -->
      <Grid Grid.Row="4" Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="UpdateButton" Grid.Column="0" Height="34" Content="Check for updates"
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
$BrainSetupButton = $win.FindName('BrainSetupButton')
$ClientCheck  = $win.FindName('ClientCheck')
$ClientPathButton = $win.FindName('ClientPathButton')
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

# Re-read launcher\version.txt and reflect it in the subtitle. Called on the same
# timer as the status lights so that after an update rewrites version.txt, the
# open panel shows the new version live - no need to close and reopen it.
function Update-Version {
    $v = if (Test-Path $VersionPath) { (Get-Content $VersionPath -Raw).Trim() } else { 'unknown' }
    $SubtitleText.Text = "Control Panel   -   version $v"
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

# Set a key under a named section, replacing it in place if present. Creates the
# key inside the section, or the whole section at the end, if either is missing -
# needed because an existing tester's launcher.ini predates the [client] section
# (it is not shipped in patches, so it can be absent on upgraded installs).
function Set-IniValue([string]$section, [string]$key, [string]$value) {
    if (-not (Test-Path $IniPath)) { return }
    $lines = @(Get-Content $IniPath)
    $out = New-Object System.Collections.Generic.List[string]
    $inSection   = $false
    $sectionSeen = $false
    $written     = $false
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') {
            if ($inSection -and -not $written) { $out.Add("$key=$value"); $written = $true }
            $inSection = ($Matches[1] -eq $section)
            if ($inSection) { $sectionSeen = $true }
            $out.Add($line)
            continue
        }
        if ($inSection -and ($trim -match ("^\s*" + [regex]::Escape($key) + "\s*="))) {
            if (-not $written) { $out.Add("$key=$value"); $written = $true }
            continue   # drop the old line; replaced above
        }
        $out.Add($line)
    }
    if ($inSection -and -not $written) { $out.Add("$key=$value"); $written = $true }
    if (-not $sectionSeen) {
        $out.Add("")
        $out.Add("[$section]")
        $out.Add("$key=$value")
    }
    Set-Content -Path $IniPath -Value $out -Encoding ASCII
}

# Read a single key's raw value from the ini (empty string if absent).
function Get-IniValue([string]$section, [string]$key) {
    if (-not (Test-Path $IniPath)) { return '' }
    $cur = ''
    foreach ($line in (Get-Content $IniPath)) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') { $cur = $Matches[1]; continue }
        if ($cur -eq $section -and ($trim -match ("^\s*" + [regex]::Escape($key) + "\s*=\s*(.*)$"))) {
            return $Matches[1].Trim()
        }
    }
    return ''
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
    $clientVal = if ($ClientCheck.IsChecked) { 'true' } else { 'false' }
    Set-IniValue 'client' 'LaunchClient' $clientVal
    if ($ClientCheck.IsChecked -and (Get-IniValue 'client' 'ClientExe') -eq '') {
        Write-Log "Note: 'launch client' is ticked but no client path is set - use 'Set game client...' first."
    }
    $extras = @()
    if ($BrainCheck.IsChecked)  { $extras += 'FPC brain' }
    if ($ClientCheck.IsChecked) { $extras += 'game client' }
    $withExtras = if ($extras.Count) { " (with $($extras -join ' + '))" } else { '' }
    Write-Log "Starting server$withExtras ... the DB and server terminals stay hidden."
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

$BrainSetupButton.Add_Click({
    $brain = Resolve-BrainSetup
    if (-not $brain) {
        Write-Log "Brain setup not found (brain\setup_brain.bat). This pack may have been built without it."
        return
    }
    Write-Log "Opening the brain setup in its own window (pick Ollama or DeepSeek) ..."
    # Its own console so the interactive prompts and the running brain are visible.
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/k `"$brain`""
})

$ClientPathButton.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title  = 'Select your L2 game client (e.g. system\L2.exe)'
    $dlg.Filter = 'Programs (*.exe)|*.exe|All files (*.*)|*.*'
    $current = Get-IniValue 'client' 'ClientExe'
    if ($current -ne '' -and (Test-Path $current)) {
        $dlg.InitialDirectory = (Split-Path -Parent $current)
        $dlg.FileName = (Split-Path -Leaf $current)
    }
    if ($dlg.ShowDialog()) {
        Set-IniValue 'client' 'ClientExe' $dlg.FileName
        Write-Log "Game client set to: $($dlg.FileName)"
        if (-not $ClientCheck.IsChecked) {
            $ClientCheck.IsChecked = $true
            Write-Log "'Launch the game client with the server' turned on."
        }
    }
})

$UpdateButton.Add_Click({
    if (-not (Test-Path $UpdateScript)) { Write-Log "ERROR: update.ps1 not found next to this panel."; return }
    Write-Log "Opening the updater in its own window (it will ask before applying anything) ..."
    # update.ps1 prompts (Read-Host) and downloads, so give it a real console that
    # stays open after it finishes. It stops the server itself before overwriting files.
    $cmd = "& { & '$UpdateScript'; Write-Host ''; Read-Host 'Press Enter to close' }"
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
})

# ---- status timer ----------------------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick({ Update-Status; Update-Version })

# ---- init ------------------------------------------------------------------
Update-Version   # sets the subtitle now; the status timer keeps it current after updates
$FooterText.Text   = "Prototype - drives launcher.ps1 / stop.ps1. Servers open in their own windows."

# Reflect the current ini brain setting in the checkbox.
if (Test-Path $IniPath) {
    $brainLine = (Get-Content $IniPath) | Where-Object { $_ -match '^\s*StartBrain\s*=' } | Select-Object -First 1
    if ($brainLine -match '=\s*(true|1|yes|on)\s*$') { $BrainCheck.IsChecked = $true }
}

# Reflect the current ini game-client settings.
$clientLaunch = Get-IniValue 'client' 'LaunchClient'
if (@('true','1','yes','on') -contains $clientLaunch.ToLower()) { $ClientCheck.IsChecked = $true }
$clientExe = Get-IniValue 'client' 'ClientExe'
if ($clientExe -ne '') { Write-Log "Game client: $clientExe" }

Write-Log "Control panel ready."
Update-Status
$timer.Start()

$win.Add_Closed({ $timer.Stop() })
$win.ShowDialog() | Out-Null
