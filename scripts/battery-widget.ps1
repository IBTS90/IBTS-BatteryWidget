Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

# ------------------------------------------------------------------
# Impostazioni widget (persistenti su file JSON)
# ------------------------------------------------------------------
# Percorso base: file .ps1 in esecuzione; se vuoto (host ps2exe) usa il percorso dell'exe
$entryPath = $PSCommandPath
if (-not $entryPath) {
    $entryPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
$scriptDir = Split-Path $entryPath
$configDir = Join-Path $scriptDir "config"
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
$configFile = Join-Path $configDir "settings.json"

# Impostazioni predefinite
$defaultSettings = @{
    "TempUnit" = "C"            # C = Celsius, F = Fahrenheit
    "ShowBattery" = $true       # Mostra la carica batteria (true=laptop, false=desktop)
    "AlwaysOnTop" = $true
    "RefreshRateSec" = 4        # Intervallo aggiornamento in secondi
}

# Carica o crea le impostazioni (hashtable uniforme per poter usare ContainsKey)
if (Test-Path $configFile) {
    try {
        $loaded = Get-Content $configFile -Raw | ConvertFrom-Json
        $settings = @{}
        foreach ($prop in $loaded.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
        foreach ($key in $defaultSettings.Keys) {
            if (-not $settings.ContainsKey($key)) {
                $settings[$key] = $defaultSettings[$key]
            }
        }
    } catch {
        $settings = $defaultSettings.Clone()
    }
} else {
    $settings = $defaultSettings.Clone()
}

# Esponi le impostazioni come variabili globali per l'uso nello script
$TempUnit       = $settings["TempUnit"]
$ShowBattery    = [bool]$settings["ShowBattery"]
$AlwaysOnTop    = [bool]$settings["AlwaysOnTop"]
$RefreshRateSec = [int]$settings["RefreshRateSec"]

function Save-Settings {
    # Assicura che la directory esista
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    @{
        TempUnit       = $TempUnit
        ShowBattery    = $ShowBattery
        AlwaysOnTop    = $AlwaysOnTop
        RefreshRateSec = $RefreshRateSec
    } | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8
}

# Salva subito le impostazioni predefinite se il file non esisteva
if (-not (Test-Path $configFile)) { Save-Settings }

# Cache per temperature hardware (evita re-query lente su cambio unità)
$script:lastHwTemps = @{
    Cpu   = $null
    Gpu   = $null
    Ram   = $null
    Disk  = $null
    DiskD = $null
}

# ------------------------------------------------------------------
# Hardware monitoring (LibreHardwareMonitorLib da ..\dll)
# ------------------------------------------------------------------
$hwMonAvailable = $false
$computer = $null
$hwErrorMsg = $null

try {
    # dll accanto al file di avvio (exe nella root) oppure in ..\dll (ps1 in scripts\)
    $dllDir = Join-Path $scriptDir "dll"
    if (-not (Test-Path (Join-Path $dllDir "LibreHardwareMonitorLib.dll"))) {
        $dllDir = Join-Path $scriptDir "..\dll"
    }
    $hwDll  = Join-Path $dllDir "LibreHardwareMonitorLib.dll"
    $hidDll = Join-Path $dllDir "HidSharp.dll"
    if ((Test-Path $hwDll) -and (Test-Path $hidDll)) {
        [void][System.Reflection.Assembly]::LoadFrom($hidDll)
        [void][System.Reflection.Assembly]::LoadFrom($hwDll)
        $computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $computer.IsCpuEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMemoryEnabled = $true
        $computer.IsStorageEnabled = $true
        $computer.Open()
        $hwMonAvailable = $true
    } else {
        $hwErrorMsg = "DLL not found in dll folder"
    }
} catch {
    $hwErrorMsg = $_.Exception.Message
}

function Get-HwTemp {
    param([string]$typePattern, [string]$cacheKey)
    if (-not $hwMonAvailable) { return $null }
    $result = $null
    foreach ($hw in $computer.Hardware) {
        if ($hw.HardwareType.ToString() -like $typePattern) {
            $hw.Update()
            foreach ($s in $hw.Sensors) {
                if ($s.SensorType.ToString() -eq "Temperature" -and $null -ne $s.Value) {
                    if ($null -eq $result -or $s.Value -gt $result) { $result = $s.Value }
                }
            }
        }
    }
    if ($null -ne $result) { 
        $rounded = [math]::Round($result,0)
        if ($cacheKey) { $script:lastHwTemps[$cacheKey] = $rounded }
        return $rounded
    }
    return $null
}

# Leggero: riformatta le temperature già in cache senza ri-interrogare l'hardware
# Ri-legge solo i % di utilizzo (veloci via WMI) e combina con temperature in cache
function Update-TempDisplayOnly {
    # CPU
    try {
        $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $cpuText.Text = "{0}% - {1}" -f [int]$cpuLoad, (Format-Temp $script:lastHwTemps.Cpu)
        $cpuText.Foreground = Get-TempColor $script:lastHwTemps.Cpu
    } catch { $cpuText.Text = "N/D"; $cpuText.Foreground = [System.Windows.Media.Brushes]::White }

    # GPU
    try {
        $gpuSamples = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop
        $gpuLoad = ($gpuSamples | Where-Object { $_.Name -like "*engtype_3D*" } | Measure-Object -Property UtilizationPercentage -Sum).Sum
        if (-not $gpuLoad) { $gpuLoad = 0 }
        if ($gpuLoad -gt 100) { $gpuLoad = 100 }
        $gpuText.Text = "{0}% - {1}" -f [int]$gpuLoad, (Format-Temp $script:lastHwTemps.Gpu)
        $gpuText.Foreground = Get-TempColor $script:lastHwTemps.Gpu
    } catch { $gpuText.Text = "N/D"; $gpuText.Foreground = [System.Windows.Media.Brushes]::White }

    # RAM
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $usedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        $ramPct  = [int](($usedGB / $totalGB) * 100)
        $ramInfo = "$ramPct% ($usedGB/$totalGB GB)"
        if ($script:lastHwTemps.Ram) { $ramInfo += " - $(Format-Temp $script:lastHwTemps.Ram)" }
        $ramText.Text = $ramInfo
        $ramText.Foreground = Get-TempColor $script:lastHwTemps.Ram
    } catch { $ramText.Text = "N/D"; $ramText.Foreground = [System.Windows.Media.Brushes]::White }

    # Disk C:
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $diskPct = [int]((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100)
        $diskFreeGB = [math]::Round($disk.FreeSpace / 1GB, 0)
        $diskInfo = "{0}% ({1} GB free)" -f $diskPct, $diskFreeGB
        if ($script:lastHwTemps.Disk) { $diskInfo += " - $(Format-Temp $script:lastHwTemps.Disk)" }
        $diskText.Text = $diskInfo
        $diskText.Foreground = Get-TempColor $script:lastHwTemps.Disk
    } catch { $diskText.Text = "N/D"; $diskText.Foreground = [System.Windows.Media.Brushes]::White }

    # Disk D:
    try {
        $diskD = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" -ErrorAction Stop
        if ($diskD) {
            $diskDPct = [int]((($diskD.Size - $diskD.FreeSpace) / $diskD.Size) * 100)
            $diskDFreeGB = [math]::Round($diskD.FreeSpace / 1GB, 0)
            $diskDInfo = "{0}% ({1} GB free)" -f $diskDPct, $diskDFreeGB
            if ($script:lastHwTemps.DiskD) { $diskDInfo += " - $(Format-Temp $script:lastHwTemps.DiskD)" }
            $diskDText.Text = $diskDInfo
            $diskDText.Foreground = Get-TempColor $script:lastHwTemps.DiskD
        } else {
            $diskDText.Text = "Not present"
            $diskDText.Foreground = [System.Windows.Media.Brushes]::White
        }
    } catch { $diskDText.Text = "Not present"; $diskDText.Foreground = [System.Windows.Media.Brushes]::White }
}

$deg = [string][char]0x00B0

function Format-Temp {
    param($celsius)
    if ($null -eq $celsius) { return "N/D" }
    if ($TempUnit -eq "F") {
        return "$([math]::Round($celsius * 9 / 5 + 32, 0))$($deg)F"
    }
    return "$celsius$($deg)C"
}

# ------------------------------------------------------------------
# Funzioni colore per temperatura e batteria
# ------------------------------------------------------------------
function Convert-HslToRgb {
    param(
        [double]$h,   # 0-360
        [double]$s,   # 0-1
        [double]$l    # 0-1
    )
    $c = (1 - [math]::Abs(2 * $l - 1)) * $s
    $hp = ($h / 60) % 6
    $x = $c * (1 - [math]::Abs(($hp % 2) - 1))
    $r = 0.0; $g = 0.0; $b = 0.0
    switch ([math]::Floor($hp)) {
        0 { $r = $c; $g = $x }
        1 { $r = $x; $g = $c }
        2 { $g = $c; $b = $x }
        3 { $g = $x; $b = $c }
        4 { $r = $x; $b = $c }
        default { $r = $c; $b = $x }
    }
    $m = $l - $c / 2
    $r = [math]::Round(($r + $m) * 255)
    $g = [math]::Round(($g + $m) * 255)
    $b = [math]::Round(($b + $m) * 255)
    return [System.Windows.Media.Color]::FromRgb($r, $g, $b)
}

function Get-TempColor {
    param($temp)
    if ($null -eq $temp) { return [System.Windows.Media.Brushes]::White }
    $t = [double]$temp
    if ($t -ge 85) { return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 107, 107))) }   # Rosso #FF6B6B
    if ($t -ge 50) { return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 210, 74))) }   # Giallo #FFD24A
    return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(110, 193, 255)))                    # Blu #6EC1FF
}

function Get-BatteryColor {
    param([int]$percent)
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }
    # Verde (hue 120) a 100%, Rosso (hue 0) a 0%
    $hue = $percent * 1.2
    $color = Convert-HslToRgb -h $hue -s 0.78 -l 0.52
    return (New-Object System.Windows.Media.SolidColorBrush $color)
}

function Get-StatusColor {
    param([string]$status)
    if ($status -like "*Discharging*") { return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 179, 92))) }   # Orange
    if ($status -like "*Charging*" -or $status -like "*Plugged in*")  { return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(124, 252, 155))) }  # Light green
    if ($status -like "*Fully charged*") { return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(124, 252, 155))) }  # Light green
    if ($status -like "*Low*" -or $status -like "*Critical*") { return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 107, 107))) } # Red
    return [System.Windows.Media.Brushes]::White
}

# ------------------------------------------------------------------
# Finestra principale
# ------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="System Widget" Width="250"
        SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual">
    <Window.Resources>
        <Style x:Key="FlatButton" TargetType="Button">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="6" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.6"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border CornerRadius="14" Background="#DD1A1A1A" BorderBrush="#33FFFFFF" BorderThickness="1">
        <Grid Margin="14,8,12,10">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header: ingranaggio a sinistra, batteria centrata, chiudi a destra -->
            <Grid Grid.Row="0" Margin="0,0,0,6">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Settings gear button (angolo sinistro) -->
                <Button x:Name="SettingsBtn" Grid.Column="0" Content="&#x2699;" Width="28" Height="28" Background="#383838" BorderThickness="0" Foreground="#FFFFFF" Style="{StaticResource FlatButton}" FontFamily="Segoe UI Symbol" FontSize="17" Cursor="Hand" HorizontalAlignment="Left" VerticalAlignment="Top">
                    <Button.ToolTip>
                        <ToolTip Content="Settings"/>
                    </Button.ToolTip>
                </Button>

                <!-- Battery/Percentage area (centrata) -->
                <StackPanel Grid.Column="1">
                    <TextBlock x:Name="PercText" FontSize="26" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center"/>
                    <TextBlock x:Name="StatusText" FontSize="11" Foreground="#BBBBBB" HorizontalAlignment="Center" Margin="0,1,0,0"/>
                    <TextBlock x:Name="WattText" FontSize="10" Foreground="#BBBBBB" HorizontalAlignment="Center" Visibility="Collapsed"/>
                    <TextBlock x:Name="TimeText" FontSize="10" Foreground="#BBBBBB" HorizontalAlignment="Center" Visibility="Collapsed"/>
                </StackPanel>

                <!-- Close button -->
                <Button x:Name="CloseBtn" Grid.Column="2" Content="&#x2715;" Width="28" Height="28" Background="#E53935" BorderThickness="0" Foreground="#FFFFFF" Style="{StaticResource FlatButton}" FontFamily="Segoe UI Symbol" FontSize="14" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Button.ToolTip>
                        <ToolTip Content="Close"/>
                    </Button.ToolTip>
                </Button>
            </Grid>

            <!-- Hardware warning (nascosto di default) -->
            <TextBlock x:Name="HwWarnText" Grid.Row="1" FontSize="10" Foreground="#FFD24A" TextWrapping="Wrap" Margin="0,0,0,6" Visibility="Collapsed"/>

            <!-- Main content area (verticale) -->
            <Border Grid.Row="2" CornerRadius="10" Background="#22FFFFFF" Padding="10,8">
                <ContentPresenter x:Name="MainContent"/>
            </Border>

            <!-- Footer con link credit -->
            <TextBlock x:Name="FooterText" Grid.Row="3" FontSize="10" Foreground="#999999" HorizontalAlignment="Center" Margin="0,8,0,0">
                <Run Text="Made with "/><Run Text="&#x2764;" Foreground="#FF6B6B"/><Run Text=" by "/><Hyperlink x:Name="FooterLink" NavigateUri="https://www.ibtechsupport.com" Foreground="#6EC1FF" TextDecorations="None" BaselineAlignment="Center">IBTechSupport.com</Hyperlink>
            </TextBlock>
        </Grid>
    </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$percText   = $window.FindName("PercText")
$statusText = $window.FindName("StatusText")
$wattText   = $window.FindName("WattText")
$timeText   = $window.FindName("TimeText")
$cpuText    = $window.FindName("CpuText")
$gpuText    = $window.FindName("GpuText")
$ramText    = $window.FindName("RamText")
$diskText   = $window.FindName("DiskText")
$diskDText  = $window.FindName("DiskDText")
$hwWarnText = $window.FindName("HwWarnText")
$closeBtn   = $window.FindName("CloseBtn")
$settingsBtn = $window.FindName("SettingsBtn")
$mainContent = $window.FindName("MainContent")

# Avvisi hardware (solo se il sensore non e' disponibile o manca l'elevazione)
if (-not $hwMonAvailable) {
    if ($hwErrorMsg) {
        $hwWarnText.Text = "Temperatures unavailable: $hwErrorMsg"
    } else {
        $hwWarnText.Text = "Temperatures unavailable: no sensors read (try running as Administrator)"
    }
    $hwWarnText.Visibility = "Visible"
} elseif (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $hwWarnText.Text = "DLL loaded but not running as Administrator: temperatures may remain N/A"
    $hwWarnText.Visibility = "Visible"
}

# Posiziona in alto a destra dello schermo
$screen = [System.Windows.SystemParameters]::WorkArea
$window.Left = $screen.Width - $window.Width - 20
$window.Top = 20

# Trascina la finestra col click sinistro tenuto premuto, ma non quando si
# clicca su un pulsante (altrimenti confligge col loro Click e puo' causare
# una chiusura brusca dello script)
function Test-IsDescendantOfButton {
    param($source)
    $el = $source
    while ($null -ne $el) {
        if ($el -is [System.Windows.Controls.Button]) { return $true }
        if ($el -is [System.Windows.Media.Visual] -or $el -is [System.Windows.Media.Media3D.Visual3D]) {
            $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
        } else {
            $el = $null
        }
    }
    return $false
}

$window.Add_MouseLeftButtonDown({
    param($sender, $e)
    if (Test-IsDescendantOfButton $e.OriginalSource) { return }
    try { $window.DragMove() } catch {}
})

$exitApp = {
    if ($hwMonAvailable -and $computer) { try { $computer.Close() } catch {} }
    try { $window.Close() } catch {}
    try { [System.Windows.Application]::Current.Shutdown() } catch {}
    [Environment]::Exit(0)
}

# "X" button: closes the widget permanently
$closeBtn.Add_Click($exitApp)

# Impostazioni: handler per il tasto a forma di ingranaggio
$settingsBtn.Add_Click({ Open-SettingsWindow })

# Footer: link cliccabile a IBTechSupport.com
$footerText = $window.FindName("FooterText")
$footerLink = $window.FindName("FooterLink")
if (-not $footerLink -and $footerText) {
    foreach ($inl in $footerText.Inlines) {
        if ($inl -is [System.Windows.Documents.Hyperlink]) { $footerLink = $inl; break }
    }
}
if ($footerLink) {
    $footerLink.Add_RequestNavigate({
        param($sender, $e)
        try { Start-Process $e.Uri.AbsoluteUri } catch {}
        $e.Handled = $true
    })
}

# ------------------------------------------------------------------
# Contenuto principale (layout verticale)
# ------------------------------------------------------------------
function New-HwRow {
    param([string]$label)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = "Horizontal"
    $row.Margin = "0,2"
    $lab = New-Object System.Windows.Controls.TextBlock
    $lab.Text = $label
    $lab.Width = 58
    $lab.FontSize = 12
    $lab.Foreground = [System.Windows.Media.Brushes]::Gray
    $val = New-Object System.Windows.Controls.TextBlock
    $val.FontSize = 12
    $val.Foreground = [System.Windows.Media.Brushes]::White
    [void]$row.Children.Add($lab)
    [void]$row.Children.Add($val)
    return $val
}

# Crea una sola volta i textblock dei valori
$cpuText   = New-HwRow "CPU:"
$gpuText   = New-HwRow "GPU:"
$ramText   = New-HwRow "RAM:"
$diskText  = New-HwRow "Disk C:"
$diskDText = New-HwRow "Disk D:"

$cpuRow   = $cpuText.Parent
$gpuRow   = $gpuText.Parent
$ramRow   = $ramText.Parent
$diskRow  = $diskText.Parent
$diskDRow = $diskDText.Parent

function Build-MainContent {
    $host_panel = New-Object System.Windows.Controls.StackPanel
    foreach ($r in @($cpuRow, $gpuRow, $ramRow, $diskRow, $diskDRow)) {
        # Re-add is illegal while the row is still child of a previous panel
        $prev = $r.Parent
        if ($prev) { $prev.Children.Remove($r) }
        $host_panel.Children.Add($r) | Out-Null
    }
    $mainContent.Content = $host_panel
}

Build-MainContent

function Set-OptionalText {
    param($tb, [string]$text)
    if ([string]::IsNullOrEmpty($text)) {
        $tb.Visibility = "Collapsed"
    } else {
        $tb.Visibility = "Visible"
        $tb.Text = $text
    }
}

# ------------------------------------------------------------------
# Finestra impostazioni
# ------------------------------------------------------------------
function Open-SettingsWindow {
    [xml]$sxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="240" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Topmost="True">
    <StackPanel Margin="14">
        <TextBlock Text="Temperature unit" FontSize="12" Margin="0,0,0,2"/>
        <ComboBox x:Name="UnitBox" SelectedIndex="0">
            <ComboBoxItem Content="Celsius ($($deg)C)" Tag="C"/>
            <ComboBoxItem Content="Fahrenheit ($($deg)F)" Tag="F"/>
        </ComboBox>
        <TextBlock Text="Refresh rate (seconds)" FontSize="12" Margin="0,10,0,2"/>
        <ComboBox x:Name="RateBox" SelectedIndex="1">
            <ComboBoxItem Content="1 second" Tag="1"/>
            <ComboBoxItem Content="2 seconds" Tag="2"/>
            <ComboBoxItem Content="4 seconds" Tag="4"/>
            <ComboBoxItem Content="10 seconds" Tag="10"/>
            <ComboBoxItem Content="30 seconds" Tag="30"/>
        </ComboBox>
        <CheckBox x:Name="BatteryChk" Content="Show battery" FontSize="12" Margin="0,10,0,0"/>
        <CheckBox x:Name="TopChk" Content="Always on top" FontSize="12" Margin="0,6,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="SaveBtn" Content="Save" Width="70" Margin="0,0,8,0"/>
            <Button x:Name="CancelBtn" Content="Cancel" Width="70"/>
        </StackPanel>
    </StackPanel>
</Window>
"@
    $sreader = New-Object System.Xml.XmlNodeReader $sxaml
    $settingsWin = [Windows.Markup.XamlReader]::Load($sreader)

    $unitBox   = $settingsWin.FindName("UnitBox")
    $rateBox   = $settingsWin.FindName("RateBox")
    $batteryChk = $settingsWin.FindName("BatteryChk")
    $topChk    = $settingsWin.FindName("TopChk")
    $saveBtn   = $settingsWin.FindName("SaveBtn")
    $cancelBtn = $settingsWin.FindName("CancelBtn")

    # Riferimenti script-scope: i local della funzione non sono visibili
    # agli event handler al momento del click
    $script:sWin        = $settingsWin
    $script:sUnitBox    = $unitBox
    $script:sRateBox    = $rateBox
    $script:sBatteryChk = $batteryChk
    $script:sTopChk     = $topChk

    # Stato corrente
    foreach ($item in $unitBox.Items) {
        if ($item.Tag -eq $TempUnit) { $unitBox.SelectedItem = $item; break }
    }
    foreach ($item in $rateBox.Items) {
        if ([int]$item.Tag -eq $RefreshRateSec) { $rateBox.SelectedItem = $item; break }
    }
    $batteryChk.IsChecked = $ShowBattery
    $topChk.IsChecked = $AlwaysOnTop

    $cancelBtn.Add_Click({ try { $script:sWin.Close() } catch {} })

    $saveBtn.Add_Click({
        $oldTempUnit = $TempUnit
        $oldRefreshRate = $RefreshRateSec
        $selUnit = $script:sUnitBox.SelectedItem
        if ($selUnit) { $script:TempUnit = [string]$selUnit.Tag }
        $selRate = $script:sRateBox.SelectedItem
        if ($selRate) { $script:RefreshRateSec = [int]$selRate.Tag }
        $script:ShowBattery = ($script:sBatteryChk.IsChecked -eq $true)
        $script:AlwaysOnTop = ($script:sTopChk.IsChecked -eq $true)

        # Salva impostazioni (gestisce errori file silenziosamente)
        try { Save-Settings } catch { Write-Warning "Settings save failed: $_" }

        $window.Topmost = $script:AlwaysOnTop
        if ($script:ShowBattery) {
            Update-BatteryInfo
        } else {
            $percText.Text = ""
            $statusText.Text = ""
            Set-OptionalText $wattText ""
            Set-OptionalText $timeText ""
        }

        # Se è cambiato il refresh rate, riavvia il timer subito
        if ($oldRefreshRate -ne $RefreshRateSec) {
            $timer.Stop()
            $timer.Interval = [TimeSpan]::FromSeconds($RefreshRateSec)
            $timer.Start()
        }

        # Se è cambiata solo l'unità temperatura, aggiorna solo il display (istantaneo)
        # Altrimenti fai il refresh completo (include query hardware lente)
        if ($oldTempUnit -ne $TempUnit -and $oldTempUnit) {
            Update-TempDisplayOnly
        } else {
            Update-SystemInfo
        }
        $script:sWin.Close()
    })

    [void]$settingsWin.ShowDialog()
}

# ------------------------------------------------------------------
# Aggiornamento dati
# ------------------------------------------------------------------

# Native power API: same source the Windows tray uses for remaining time
# (Win32_Battery.EstimatedRunTime is the same value but lags by several minutes)
if (-not ([System.Management.Automation.PSTypeName]'NativePower.Power').Type) {
    Add-Type -TypeDefinition @'
namespace NativePower {
    using System;
    using System.Runtime.InteropServices;
    public struct SYSTEM_BATTERY_STATE {
        public byte AcOnLine;
        public byte BatteryPresent;
        public byte Charging;
        public byte Discharging;
        public byte Spare1_0;
        public byte Spare1_1;
        public byte Spare1_2;
        public byte Tag;
        public uint MaxCapacity;
        public uint RemainingCapacity;
        public uint Rate;
        public uint EstimatedTime;
        public uint DefaultAlert1;
        public uint DefaultAlert2;
    }
    public static class Power {
        [DllImport("powrprof.dll")]
        public static extern int CallNtPowerInformation(int InformationLevel, IntPtr InputBuffer, int InputBufferLength, IntPtr OutputBuffer, int OutputBufferLength);
    }
}
'@
}

function Format-BattTime {
    param([TimeSpan]$ts)
    # Windows tray style: "55 min" under an hour, "1h 05m" above
    if ($ts.TotalMinutes -lt 60) {
        return "~{0} min remaining" -f [int][math]::Round($ts.TotalMinutes)
    }
    return "~{0}h {1:00}m remaining" -f [int]$ts.TotalHours, $ts.Minutes
}

$script:battTimeEwmaSec = $null  # low-pass filtered estimate, seed on first discharging read

function Get-BatteryTimeRemainingSec {
    # Returns estimated seconds until empty while discharging, or $null if unknown
    try {
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][NativePower.SYSTEM_BATTERY_STATE])
        $ptr  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
        try {
            $status = [NativePower.Power]::CallNtPowerInformation(5, [IntPtr]::Zero, 0, $ptr, $size)
            if ($status -eq 0) {
                $s = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][NativePower.SYSTEM_BATTERY_STATE])
                # 0 = not discharging / unknown, 0xFFFFFFFF = "never" sentinel from the API
                if ($s.BatteryPresent -and $s.EstimatedTime -gt 0 -and $s.EstimatedTime -lt 4294967295) {
                    return [int]$s.EstimatedTime
                }
            }
        } finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
        }
    } catch {
        # Power API unavailable: fall through to WMI-based estimate
    }
    return $null
}
function Update-BatteryInfo {
    if (-not $ShowBattery) {
        $percText.Text = ""
        $statusText.Text = ""
        Set-OptionalText $wattText ""
        Set-OptionalText $timeText ""
        return
    }
    try {
        $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop
        if (-not $bat) {
            $percText.Text = "N/A"
            $percText.Foreground = [System.Windows.Media.Brushes]::White
            $statusText.Text = "No battery detected"
            $statusText.Foreground = [System.Windows.Media.Brushes]::White
            Set-OptionalText $wattText ""
            Set-OptionalText $timeText ""
            return
        }

        $percent = $bat.EstimatedChargeRemaining
        $percText.Text = "$percent%"
        $percText.Foreground = Get-BatteryColor $percent

        # Glow effect for critical battery (< 20%)
        if ($percent -lt 20 -and $percent -gt 0) {
            $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $glow.Color = [System.Windows.Media.Color]::FromRgb(255, 107, 107)
            $glow.BlurRadius = 12
            $glow.ShadowDepth = 0
            $glow.Opacity = 0.8
            $percText.Effect = $glow
        } else {
            $percText.Effect = $null
        }

        $rate    = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue
        $fullCap = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue

        # Check if we have valid rate data for power calculations
        $haveChargeRate = $rate -and $rate.ChargeRate -and $rate.ChargeRate -gt 0
        $haveDischargeRate = $rate -and $rate.DischargeRate -and $rate.DischargeRate -gt 0
        $haveFullCap = $fullCap -and $fullCap.FullChargedCapacity -gt 0

        # Determine power source and charging state from BatteryStatus WMI
        $isPowerOnline = $rate -and $rate.PowerOnline
        $isCharging = $rate -and $rate.Charging
        $isDischarging = $rate -and $rate.Discharging
        $isFullyCharged = $percent -ge 99

        # Three distinct states:
        # 1. CHARGING: AC connected AND battery accepting charge (ChargeRate > 0)
        # 2. AC POWER (not charging): AC connected but battery NOT charging (full or not accepting)
        # 3. BATTERY ONLY: No AC power, running on battery

        $isActivelyCharging = $isPowerOnline -and $haveChargeRate
        $isOnAcNotCharging = $isPowerOnline -and (-not $haveChargeRate)
        $isOnBatteryOnly = -not $isPowerOnline

        if ($isActivelyCharging -and -not $isFullyCharged) {
            # State 1: AC connected, battery actively charging
            $statusText.Text = "Charging"
            $statusText.Foreground = Get-StatusColor "Charging"
            $watt = [math]::Round($rate.ChargeRate / 1000, 1)
            Set-OptionalText $wattText "$watt W"
            if ($haveFullCap) {
                $remaining = $fullCap.FullChargedCapacity - $rate.RemainingCapacity
                if ($remaining -gt 0) {
                    $hours = $remaining / $rate.ChargeRate
                    $ts = [TimeSpan]::FromHours($hours)
                    Set-OptionalText $timeText ("~{0:00}:{1:00} to 100%" -f [int]$ts.TotalHours, $ts.Minutes)
                } else {
                    Set-OptionalText $timeText "Finishing..."
                }
            } else {
                Set-OptionalText $timeText ""
            }
        } elseif ($isOnAcNotCharging) {
            # State 2: AC connected but NOT charging (full, or battery not accepting charge)
            if ($isFullyCharged) {
                $statusText.Text = "Fully charged (AC)"
            } else {
                $statusText.Text = "AC power - not charging"
            }
            $statusText.Foreground = Get-StatusColor "Fully charged"
            Set-OptionalText $wattText "0.0 W"
            Set-OptionalText $timeText ""
        } elseif ($isOnBatteryOnly -or $isDischarging) {
            # State 3: Running on battery only
            $statusText.Text = "On battery"
            $statusText.Foreground = Get-StatusColor "Discharging"
            if ($haveDischargeRate) {
                $watt = [math]::Round($rate.DischargeRate / 1000, 1)
                Set-OptionalText $wattText "$watt W"
            } else {
                Set-OptionalText $wattText ""
            }
            $remSec = Get-BatteryTimeRemainingSec
            if ($remSec) {
                # Primary: power manager estimate (same source as the Windows tray icon).
                # The raw value spikes with load swings, so smooth it like the tray does
                # (EWMA, ~2 min time constant at the 4s update tick)
                if ($null -eq $script:battTimeEwmaSec) {
                    $script:battTimeEwmaSec = $remSec
                } else {
                    $script:battTimeEwmaSec = $script:battTimeEwmaSec + ($remSec - $script:battTimeEwmaSec) / 30.0
                }
                $ts = [TimeSpan]::FromSeconds([math]::Round($script:battTimeEwmaSec))
                Set-OptionalText $timeText (Format-BattTime $ts)
            } else {
                # Not discharging or power API unavailable: reset the filter, use fallbacks
                $script:battTimeEwmaSec = $null
                if ($haveDischargeRate -and $rate.RemainingCapacity -gt 0) {
                    # Fallback 1: physical estimate from capacity/discharge rate (both mWh/mW)
                    $hours = $rate.RemainingCapacity / $rate.DischargeRate
                    Set-OptionalText $timeText (Format-BattTime ([TimeSpan]::FromHours($hours)))
                } elseif ($bat.EstimatedRunTime -and $bat.EstimatedRunTime -lt 71582) {
                    # Fallback 2: WMI estimate (lags a few minutes behind the tray)
                    Set-OptionalText $timeText (Format-BattTime ([TimeSpan]::FromMinutes($bat.EstimatedRunTime)))
                } else {
                    Set-OptionalText $timeText ""
                }
            }
        } else {
            # Fallback to Win32_Battery status
            $statusMap = @{
                1="Discharging"; 2="Plugged in (no battery)"; 3="Fully charged";
                4="Low"; 5="Critical"; 6="Charging"; 7="Charging (high)";
                8="Charging (low)"; 9="Charging (critical)"; 10="Unknown"; 11="Partially charged"
            }
            $statusText.Text = $statusMap[[int]$bat.BatteryStatus]
            $statusText.Foreground = Get-StatusColor $statusText.Text
            Set-OptionalText $wattText ""
            Set-OptionalText $timeText ""
        }
    } catch {
        $statusText.Text = "Battery read error"
        $statusText.Foreground = [System.Windows.Media.Brushes]::White
    }
}

function Update-SystemInfo {
    try {
        $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $cpuTemp = Get-HwTemp "Cpu*" "Cpu"
        $cpuText.Text = "{0}% - {1}" -f [int]$cpuLoad, (Format-Temp $cpuTemp)
        $cpuText.Foreground = Get-TempColor $cpuTemp
    } catch { $cpuText.Text = "N/D"; $cpuText.Foreground = [System.Windows.Media.Brushes]::White }

    try {
        $gpuSamples = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop
        $gpuLoad = ($gpuSamples | Where-Object { $_.Name -like "*engtype_3D*" } | Measure-Object -Property UtilizationPercentage -Sum).Sum
        if (-not $gpuLoad) { $gpuLoad = 0 }
        if ($gpuLoad -gt 100) { $gpuLoad = 100 }
        $gpuTemp = Get-HwTemp "Gpu*" "Gpu"
        $gpuText.Text = "{0}% - {1}" -f [int]$gpuLoad, (Format-Temp $gpuTemp)
        $gpuText.Foreground = Get-TempColor $gpuTemp
    } catch { $gpuText.Text = "N/D"; $gpuText.Foreground = [System.Windows.Media.Brushes]::White }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $usedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        $ramPct  = [int](($usedGB / $totalGB) * 100)
        $ramTemp = Get-HwTemp "Memory*" "Ram"
        $ramInfo = "$ramPct% ($usedGB/$totalGB GB)"
        if ($ramTemp) { $ramInfo += " - $(Format-Temp $ramTemp)" }
        $ramText.Text = $ramInfo
        $ramText.Foreground = Get-TempColor $ramTemp
    } catch { $ramText.Text = "N/D"; $ramText.Foreground = [System.Windows.Media.Brushes]::White }

    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $diskPct = [int]((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100)
        $diskFreeGB = [math]::Round($disk.FreeSpace / 1GB, 0)
        $diskTemp = Get-HwTemp "Storage*" "Disk"
        $diskInfo = "{0}% ({1} GB free)" -f $diskPct, $diskFreeGB
        if ($diskTemp) { $diskInfo += " - $(Format-Temp $diskTemp)" }
        $diskText.Text = $diskInfo
        $diskText.Foreground = Get-TempColor $diskTemp
    } catch { $diskText.Text = "N/D"; $diskText.Foreground = [System.Windows.Media.Brushes]::White }

    try {
        $diskD = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" -ErrorAction Stop
        if ($diskD) {
            $diskDPct = [int]((($diskD.Size - $diskD.FreeSpace) / $diskD.Size) * 100)
            $diskDFreeGB = [math]::Round($diskD.FreeSpace / 1GB, 0)
            $diskDTemp = Get-HwTemp "Storage*" "DiskD"
            $diskDInfo = "{0}% ({1} GB free)" -f $diskDPct, $diskDFreeGB
            if ($diskDTemp) { $diskDInfo += " - $(Format-Temp $diskDTemp)" }
            $diskDText.Text = $diskDInfo
            $diskDText.Foreground = Get-TempColor $diskDTemp
        } else {
            $diskDText.Text = "Not present"
            $diskDText.Foreground = [System.Windows.Media.Brushes]::White
        }
    } catch { $diskDText.Text = "Not present"; $diskDText.Foreground = [System.Windows.Media.Brushes]::White }
}

# ------------------------------------------------------------------
# Timer di aggiornamento + avvio
# ------------------------------------------------------------------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($RefreshRateSec)
$timer.Add_Tick({
    Update-BatteryInfo
    Update-SystemInfo
})
$timer.Start()

# Primo aggiornamento solo dopo che la finestra e' visibile (ShowDialog blocca)
$window.Add_ContentRendered({
    Update-BatteryInfo
    Update-SystemInfo
})
$window.ShowDialog() | Out-Null