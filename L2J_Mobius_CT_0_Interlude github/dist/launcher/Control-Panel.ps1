<#
  L2 Offline Server - Control Panel
  ---------------------------------
  A single-window GUI front end for the launcher. It does not reimplement any
  server logic: Start and Stop call the existing launcher.ps1 / stop.ps1, the
  brain toggle flips StartBrain in launcher.ini, and the client toggle flips the
  [client] keys. The status lights are live checks of the real ports/process.

  What is new here vs a plain console launcher:
    * It wears the launcher artwork (assets\background.png, assets\launcher.ico).
    * The startup steps (DB -> schema -> login -> game) stream INTO this window's
      log instead of a separate terminal. launcher.ps1 runs hidden with its output
      captured to a temp file that this window tails live.

  Run it with Control-Panel.bat (double-click), or:
     powershell -NoProfile -ExecutionPolicy Bypass -File Control-Panel.ps1

  Nothing here needs a build - Windows already ships PowerShell and WPF.
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
$AssetsDir   = Join-Path $LauncherDir 'assets'
$BgPath      = Join-Path $AssetsDir 'background.png'
$IcoPath     = Join-Path $AssetsDir 'launcher.ico'
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
        Title="Living World Server" Height="640" Width="940"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI">

  <Window.Resources>
    <Style x:Key="Rounded" TargetType="Button">
      <Setter Property="Foreground" Value="#F3E3CF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.70"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Foreground" Value="#E8E0D4"/>
      <Setter Property="Background" Value="#00000000"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#33FFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <!-- RootShell background is set in code to the launcher artwork. -->
  <Border x:Name="RootShell" CornerRadius="10" Background="#0B0B0B" ClipToBounds="True"
          BorderBrush="#1A1712" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="36"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Title bar (drag + minimize + close) -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="#66000000">
        <TextBlock Text="Living World Server" Margin="14,0,0,0" VerticalAlignment="Center"
                   Foreground="#E8E0D4" FontFamily="Georgia" FontSize="13"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Stretch">
          <Button x:Name="MinButton" Width="42" Style="{StaticResource Chrome}" FontSize="15" Content="&#8211;"/>
          <Button x:Name="CloseButton" Width="42" Style="{StaticResource Chrome}" FontSize="14" Content="&#10005;"/>
        </StackPanel>
      </Grid>

      <!-- Content: art on the left, control panel on the right -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="400"/>
        </Grid.ColumnDefinitions>

        <!-- Left: a subtle scrim over the art so the title reads -->
        <Border Grid.Column="0">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#00000000" Offset="0.0"/>
              <GradientStop Color="#66000000" Offset="1.0"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>

        <!-- Right: translucent control panel -->
        <Border Grid.Column="1" Background="#E6100C08" Padding="16">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <StackPanel Grid.Row="0" Margin="0,0,0,12">
              <TextBlock Text="Living World Server" Foreground="#F3E3CF" FontFamily="Georgia"
                         FontSize="22" FontWeight="SemiBold"/>
              <TextBlock x:Name="SubtitleText" Text="Control Panel" Foreground="#8F8478" FontSize="12" Margin="0,2,0,0"/>
            </StackPanel>

            <!-- Start / Stop -->
            <Grid Grid.Row="1" Margin="0,0,0,12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="StartButton" Grid.Column="0" Height="48" Content="Start server"
                      Style="{StaticResource Rounded}" Background="#2E4426" BorderBrush="#4A6B3B"
                      FontFamily="Georgia" FontSize="17"/>
              <Button x:Name="StopButton" Grid.Column="2" Height="48" Content="Stop server"
                      Style="{StaticResource Rounded}" Background="#432525" BorderBrush="#6A3030"
                      FontFamily="Georgia" FontSize="17"/>
            </Grid>

            <!-- Status -->
            <Border Grid.Row="2" Background="#33000000" BorderBrush="#2A241C" BorderThickness="1"
                    CornerRadius="6" Padding="12" Margin="0,0,0,12">
              <StackPanel x:Name="StatusStack"/>
            </Border>

            <!-- Extras: brain + client -->
            <StackPanel Grid.Row="3" Margin="0,0,0,10">
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="8"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <CheckBox x:Name="BrainCheck" Grid.Column="0" Content="Start FPC brain with the server"
                          Foreground="#CFC2B2" FontSize="13" VerticalAlignment="Center"/>
                <Button x:Name="BrainSetupButton" Grid.Column="2" Height="28" Content="Set up brain"
                        Style="{StaticResource Rounded}" Background="#1A1712" BorderBrush="#332B20"
                        Foreground="#CFC2B2" FontSize="12" Padding="10,0"/>
              </Grid>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="8"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <CheckBox x:Name="ClientCheck" Grid.Column="0" Content="Launch game client with the server"
                          Foreground="#CFC2B2" FontSize="13" VerticalAlignment="Center"/>
                <Button x:Name="ClientPathButton" Grid.Column="2" Height="28" Content="Set client..."
                        Style="{StaticResource Rounded}" Background="#1A1712" BorderBrush="#332B20"
                        Foreground="#CFC2B2" FontSize="12" Padding="10,0"/>
              </Grid>
            </StackPanel>

            <!-- Secondary -->
            <Grid Grid.Row="4" Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="8"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="UpdateButton" Grid.Column="0" Height="32" Content="Check for updates"
                      Style="{StaticResource Rounded}" Background="#1A1712" BorderBrush="#332B20"
                      Foreground="#CFC2B2" FontSize="12"/>
              <Button x:Name="ConfigButton" Grid.Column="2" Height="32" Content="Open config editor"
                      Style="{StaticResource Rounded}" Background="#1A1712" BorderBrush="#332B20"
                      Foreground="#CFC2B2" FontSize="12"/>
            </Grid>

            <!-- Startup log -->
            <Border Grid.Row="5" Background="#CC060606" BorderBrush="#231D16" BorderThickness="1" CornerRadius="6">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="Startup log" Foreground="#7E7568" FontSize="11"
                           Margin="10,6,0,2" FontFamily="Georgia"/>
                <TextBox x:Name="LogBox" Grid.Row="1" Background="Transparent" Foreground="#9BB88A"
                         BorderThickness="0" FontFamily="Consolas" FontSize="12" Padding="10,2,10,8"
                         IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
              </Grid>
            </Border>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

# ---- grab named controls ---------------------------------------------------
$RootShell    = $win.FindName('RootShell')
$TitleBar     = $win.FindName('TitleBar')
$MinButton    = $win.FindName('MinButton')
$CloseButton  = $win.FindName('CloseButton')
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
$SubtitleText = $win.FindName('SubtitleText')

# ---- artwork: set the background image and window icon from files -----------
function New-BitmapFromFile([string]$path) {
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = 'OnLoad'   # load fully now so the file is not left locked
    $bmp.UriSource = New-Object System.Uri $path
    $bmp.EndInit()
    return $bmp
}
if (Test-Path $BgPath) {
    $brush = New-Object Windows.Media.ImageBrush (New-BitmapFromFile $BgPath)
    $brush.Stretch = 'UniformToFill'
    $RootShell.Background = $brush
}
if (Test-Path $IcoPath) { $win.Icon = New-BitmapFromFile $IcoPath }

# ---- title-bar behavior ----------------------------------------------------
$TitleBar.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })
$MinButton.Add_Click({ $win.WindowState = 'Minimized' })
$CloseButton.Add_Click({ $win.Close() })

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

# The database is detected by process, not by a socket probe, so we do not spam
# the MariaDB log with unauthenticated aborted connections every few seconds.
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
            $up = Test-DbProcess; $upTxt = 'running'; $downTxt = 'stopped'
        } else {
            $up = Test-Port $r.Port; $upTxt = "up  (port $($r.Port))"; $downTxt = "down (port $($r.Port))"
        }
        if ($up) {
            $r.Dot.Fill = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x66,0xBB,0x55)))
            $r.State.Text = $upTxt; $r.State.Foreground = '#8FB87A'
        } else {
            $r.Dot.Fill = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x6E,0x2E,0x2E)))
            $r.State.Text = $downTxt; $r.State.Foreground = '#7B726A'
        }
    }
}

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
# key inside the section, or the whole section at the end, if either is missing.
function Set-IniValue([string]$section, [string]$key, [string]$value) {
    if (-not (Test-Path $IniPath)) { return }
    $lines = @(Get-Content $IniPath)
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false; $sectionSeen = $false; $written = $false
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') {
            if ($inSection -and -not $written) { $out.Add("$key=$value"); $written = $true }
            $inSection = ($Matches[1] -eq $section)
            if ($inSection) { $sectionSeen = $true }
            $out.Add($line); continue
        }
        if ($inSection -and ($trim -match ("^\s*" + [regex]::Escape($key) + "\s*="))) {
            if (-not $written) { $out.Add("$key=$value"); $written = $true }
            continue
        }
        $out.Add($line)
    }
    if ($inSection -and -not $written) { $out.Add("$key=$value"); $written = $true }
    if (-not $sectionSeen) { $out.Add(""); $out.Add("[$section]"); $out.Add("$key=$value") }
    Set-Content -Path $IniPath -Value $out -Encoding ASCII
}

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

# ---- in-window run capture --------------------------------------------------
# Run a PowerShell script hidden, its whole output redirected to a temp file, and
# tail that file into the log so the startup steps appear inside this window
# instead of a separate terminal. Only one capture runs at a time.
$script:RunProc   = $null
$script:RunLog    = $null
$script:RunOffset = 0
$script:RunLabel  = ''

$tailTimer = New-Object Windows.Threading.DispatcherTimer
$tailTimer.Interval = [TimeSpan]::FromMilliseconds(250)

function Read-RunTail {
    if (-not ($script:RunLog) -or -not (Test-Path $script:RunLog)) { return }
    try {
        $fs = [System.IO.File]::Open($script:RunLog, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [void]$fs.Seek($script:RunOffset, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader $fs
        $chunk = $sr.ReadToEnd()
        $script:RunOffset = $fs.Position
        $sr.Close(); $fs.Close()
        if ($chunk) { $LogBox.AppendText($chunk); $LogBox.ScrollToEnd() }
    } catch { }
}

$tailTimer.Add_Tick({
    Read-RunTail
    if ($script:RunProc -and $script:RunProc.HasExited) {
        Read-RunTail                       # final drain now that the file is complete
        $code = $script:RunProc.ExitCode
        $lbl  = $script:RunLabel
        try { Remove-Item $script:RunLog -Force -ErrorAction SilentlyContinue } catch { }
        $script:RunProc = $null; $script:RunLog = $null; $script:RunOffset = 0
        $tailTimer.Stop()
        $StartButton.IsEnabled = $true; $StopButton.IsEnabled = $true
        $verdict = if ($code -eq 0) { 'done' } else { "exited with code $code" }
        Write-Log "$lbl $verdict."
    }
})

function Start-Captured([string]$scriptPath, [string]$argString, [string]$label) {
    if ($script:RunProc -and -not $script:RunProc.HasExited) {
        Write-Log "Please wait - a $($script:RunLabel) is still running."
        return
    }
    if (-not (Test-Path $scriptPath)) { Write-Log "ERROR: $([System.IO.Path]::GetFileName($scriptPath)) not found."; return }
    $log = [System.IO.Path]::GetTempFileName()
    # The child redirects ALL its streams (*>) into the temp file. Paths are single
    # quoted so spaces are safe; the script's own Clear-Host is guarded on its side.
    $inner = "& '$scriptPath' $argString *> '$log'"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = 'powershell.exe'
    $psi.Arguments       = "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:RunProc = $proc; $script:RunLog = $log; $script:RunOffset = 0; $script:RunLabel = $label
    $StartButton.IsEnabled = $false; $StopButton.IsEnabled = $false
    $tailTimer.Start()
}

# ---- wire up ---------------------------------------------------------------
$StartButton.Add_Click({
    Set-BrainIni ([bool]$BrainCheck.IsChecked)
    $clientVal = if ($ClientCheck.IsChecked) { 'true' } else { 'false' }
    Set-IniValue 'client' 'LaunchClient' $clientVal
    if ($ClientCheck.IsChecked -and (Get-IniValue 'client' 'ClientExe') -eq '') {
        Write-Log "Note: 'launch client' is on but no client path is set - use 'Set client...' first."
    }
    $extras = @()
    if ($BrainCheck.IsChecked)  { $extras += 'FPC brain' }
    if ($ClientCheck.IsChecked) { $extras += 'game client' }
    $withExtras = if ($extras.Count) { " (with $($extras -join ' + '))" } else { '' }
    $LogBox.Clear()
    Write-Log "Starting server$withExtras ..."
    Start-Captured $StartScript '-Quiet' 'startup'
})

$StopButton.Add_Click({
    Write-Log "Stopping server ..."
    Start-Captured $StopScript '' 'shutdown'
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
    if (-not $brain) { Write-Log "Brain setup not found (brain\setup_brain.bat)."; return }
    Write-Log "Opening the brain setup in its own window (pick Ollama or DeepSeek) ..."
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
        if (-not $ClientCheck.IsChecked) { $ClientCheck.IsChecked = $true; Write-Log "'Launch game client' turned on." }
    }
})

$UpdateButton.Add_Click({
    if (-not (Test-Path $UpdateScript)) { Write-Log "ERROR: update.ps1 not found next to this panel."; return }
    Write-Log "Opening the updater in its own window (it will ask before applying anything) ..."
    # update.ps1 prompts (Read-Host) and stops the server itself, so it needs a real
    # interactive console; it is not captured into this window.
    $cmd = "& { & '$UpdateScript'; Write-Host ''; Read-Host 'Press Enter to close' }"
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
})

# ---- status timer ----------------------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick({ Update-Status; Update-Version })

# ---- init ------------------------------------------------------------------
Update-Version

# Reflect the current ini brain setting in the checkbox.
if (Test-Path $IniPath) {
    $brainLine = (Get-Content $IniPath) | Where-Object { $_ -match '^\s*StartBrain\s*=' } | Select-Object -First 1
    if ($brainLine -match '=\s*(true|1|yes|on)\s*$') { $BrainCheck.IsChecked = $true }
}
$clientLaunch = Get-IniValue 'client' 'LaunchClient'
if (@('true','1','yes','on') -contains $clientLaunch.ToLower()) { $ClientCheck.IsChecked = $true }
$clientExe = Get-IniValue 'client' 'ClientExe'
if ($clientExe -ne '') { Write-Log "Game client: $clientExe" }

Write-Log "Control panel ready."
Update-Status
$timer.Start()

$win.Add_Closed({ $timer.Stop(); $tailTimer.Stop() })
$win.ShowDialog() | Out-Null
