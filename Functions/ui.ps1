<#
    SCCMAppHelper - WPF dialogs
    Adapted from IntuneWin32Helper so both tools feel the same.
#>

Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName System.Windows.Forms  -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName UIAutomationTypes      -ErrorAction SilentlyContinue | Out-Null

<#
    The start menu tiles are Buttons wearing this template, so they keep the
    card look while staying a real control: reachable with Tab, pressed with
    Space, announced by a screen reader, and drivable through the UI Automation
    Invoke pattern. A Border with a mouse handler is none of those things.
#>
$script:TileTemplateXaml = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="Button">
    <Border x:Name="tile" Background="White" BorderBrush="LightGray" BorderThickness="1"
            CornerRadius="6" Padding="12" SnapsToDevicePixels="True">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
    </Border>
    <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="tile" Property="BorderBrush" Value="DodgerBlue" />
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
            <Setter TargetName="tile" Property="BorderBrush" Value="DodgerBlue" />
            <Setter TargetName="tile" Property="BorderThickness" Value="2" />
        </Trigger>
    </ControlTemplate.Triggers>
</ControlTemplate>
'@

#region ----------------------------------------------------------- start menu

function Show-StartDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][System.Windows.Window]$Owner,
        [string]$Title = 'SCCMAppHelper - https://blog.zarenko.net/',
        [int]$TileWidth = 220
    )

    $dlg = New-Object Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 960
    $dlg.Height = 450
    if ($null -ne $Owner) { $dlg.Owner = $Owner; $dlg.WindowStartupLocation = 'CenterOwner' }
    else { $dlg.WindowStartupLocation = 'CenterScreen' }
    $dlg.ResizeMode = 'NoResize'
    [Windows.Automation.AutomationProperties]::SetAutomationId($dlg, 'StartDialog')

    $root = New-Object Windows.Controls.Grid
    $root.Margin = '16'
    $rowTitle   = New-Object Windows.Controls.RowDefinition; $rowTitle.Height   = [Windows.GridLength]::Auto
    $rowContent = New-Object Windows.Controls.RowDefinition; $rowContent.Height = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
    $rowFooter  = New-Object Windows.Controls.RowDefinition; $rowFooter.Height  = [Windows.GridLength]::Auto
    $null = $root.RowDefinitions.Add($rowTitle)
    $null = $root.RowDefinitions.Add($rowContent)
    $null = $root.RowDefinitions.Add($rowFooter)

    $txtTitle = New-Object Windows.Controls.TextBlock
    $txtTitle.Text = 'What would you like to do?'
    $txtTitle.FontSize = 18
    $txtTitle.FontWeight = 'Bold'
    $txtTitle.Margin = '0,0,0,12'
    [Windows.Controls.Grid]::SetRow($txtTitle, 0)
    $null = $root.Children.Add($txtTitle)

    $uniform = New-Object Windows.Controls.Primitives.UniformGrid
    $uniform.Rows = 1
    $uniform.Columns = 4
    $uniform.Margin = '0,8,0,0'
    [Windows.Controls.Grid]::SetRow($uniform, 1)
    $null = $root.Children.Add($uniform)

    function New-Glyph {
        param([int]$Code, [int]$Size = 42, [string]$Margin = '0,6,0,8')
        $glyph = New-Object Windows.Controls.TextBlock
        $glyph.Text = [char]$Code
        $glyph.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
        $glyph.FontSize = $Size
        $glyph.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
        $glyph.HorizontalAlignment = 'Center'
        $glyph.Margin = $Margin
        return $glyph
    }

    function New-OptionTile {
        param(
            [string]$Caption,
            [string]$Description,
            [System.Windows.UIElement]$IconElement,
            [string]$ReturnValue,
            [int]$Width = 220
        )

        # A real Button, not a Border with a mouse handler: it can be reached
        # with Tab and pressed with Space, a screen reader announces it, and it
        # exposes the Invoke pattern so the dialog can be driven by UI
        # Automation. The template keeps the card look the Border had.
        $tile = New-Object Windows.Controls.Button
        $tile.Template = [Windows.Markup.XamlReader]::Parse($script:TileTemplateXaml)
        $tile.Margin = '6'
        $tile.Width = $Width
        $tile.Cursor = 'Hand'
        $tile.Tag = $ReturnValue
        $tile.ToolTip = $Description
        [Windows.Automation.AutomationProperties]::SetAutomationId($tile, $ReturnValue)
        [Windows.Automation.AutomationProperties]::SetName($tile, $Caption)

        $stack = New-Object Windows.Controls.StackPanel
        $stack.Orientation = 'Vertical'
        $stack.VerticalAlignment = 'Center'
        $stack.HorizontalAlignment = 'Center'
        $stack.Width = $Width - 24

        if ($null -ne $IconElement) {
            $iconHost = New-Object Windows.Controls.ContentControl
            $iconHost.Content = $IconElement
            $iconHost.HorizontalAlignment = 'Center'
            $iconHost.Margin = '0,6,0,8'
            $null = $stack.Children.Add($iconHost)
        }

        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = $Caption
        $lbl.FontWeight = 'Bold'
        $lbl.FontSize = 14
        $lbl.HorizontalAlignment = 'Center'
        $lbl.TextAlignment = 'Center'
        $lbl.TextWrapping = 'Wrap'
        $lbl.Margin = '0,0,0,4'
        $lbl.MaxWidth = $Width - 24

        $desc = New-Object Windows.Controls.TextBlock
        $desc.Text = $Description
        $desc.TextAlignment = 'Center'
        $desc.Foreground = [System.Windows.Media.Brushes]::DimGray
        $desc.Margin = '0,0,0,6'
        $desc.TextWrapping = 'Wrap'
        $desc.MaxWidth = $Width - 24

        $null = $stack.Children.Add($lbl)
        $null = $stack.Children.Add($desc)
        $tile.Content = $stack
        return $tile
    }

    # Create + publish tile shows both glyphs next to each other.
    $iconCreatePublish = New-Object Windows.Controls.StackPanel
    $iconCreatePublish.Orientation = 'Horizontal'
    $iconCreatePublish.HorizontalAlignment = 'Center'
    $iconCreatePublish.Margin = '0,6,0,8'
    $null = $iconCreatePublish.Children.Add((New-Glyph -Code 0xE710 -Size 36 -Margin '0,0,8,0'))
    $null = $iconCreatePublish.Children.Add((New-Glyph -Code 0xE898 -Size 36 -Margin '0'))

    $tiles = @(
        (New-OptionTile -Caption 'Create packages' -Description 'Create PSADT packages on the source share.' -IconElement (New-Glyph -Code 0xE710) -ReturnValue 'CreateNew' -Width $TileWidth),
        (New-OptionTile -Caption 'Create and publish' -Description 'Create packages and publish them as ConfigMgr applications.' -IconElement $iconCreatePublish -ReturnValue 'CreateNewAndPublish' -Width $TileWidth),
        (New-OptionTile -Caption 'Publish packages' -Description 'Publish existing packages as ConfigMgr applications.' -IconElement (New-Glyph -Code 0xE898) -ReturnValue 'PublishExisting' -Width $TileWidth),
        (New-OptionTile -Caption 'Tools' -Description 'Collection maintenance and reporting helpers.' -IconElement (New-Glyph -Code 0xE90F) -ReturnValue 'Tools' -Width $TileWidth)
    )
    # The handler is attached here rather than inside New-OptionTile, so that it
    # closes over $dlg while Show-StartDialog is still on the stack.
    foreach ($tile in $tiles) {
        $null = $uniform.Children.Add($tile)
        $tile.Add_Click({ param($s, $e) $dlg.Tag = [string]$s.Tag; $dlg.Close() })
    }

    $footer = New-Object Windows.Controls.Grid
    $footer.Margin = '0,14,0,0'
    $colLeft  = New-Object Windows.Controls.ColumnDefinition; $colLeft.Width  = 'Auto'
    $colFill  = New-Object Windows.Controls.ColumnDefinition; $colFill.Width  = '*'
    $colRight = New-Object Windows.Controls.ColumnDefinition; $colRight.Width = 'Auto'
    $null = $footer.ColumnDefinitions.Add($colLeft)
    $null = $footer.ColumnDefinitions.Add($colFill)
    $null = $footer.ColumnDefinitions.Add($colRight)

    $btnSettings = New-Object Windows.Controls.Button
    $btnSettings.ToolTip = 'Settings'
    [Windows.Automation.AutomationProperties]::SetAutomationId($btnSettings, 'Settings')
    $btnSettings.Padding = '10,6'
    $btnSettings.MinWidth = 40
    $btnSettings.HorizontalAlignment = 'Left'
    $btnSettings.VerticalAlignment = 'Center'
    $settingsIcon = New-Object Windows.Controls.TextBlock
    $settingsIcon.Text = [char]0xE713
    $settingsIcon.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $settingsIcon.FontSize = 18
    $settingsIcon.Foreground = [System.Windows.Media.Brushes]::Gray
    $btnSettings.Content = $settingsIcon
    [Windows.Controls.Grid]::SetColumn($btnSettings, 0)
    $null = $footer.Children.Add($btnSettings)

    $spClose = New-Object Windows.Controls.StackPanel
    $spClose.Orientation = 'Horizontal'
    $spClose.HorizontalAlignment = 'Right'
    $btnClose = New-Object Windows.Controls.Button
    $btnClose.Content = 'Cancel'
    [Windows.Automation.AutomationProperties]::SetAutomationId($btnClose, 'Cancel')
    $btnClose.Padding = '14,6'
    $btnClose.Add_Click({ $dlg.Tag = 'Cancel'; $dlg.Close() })
    $null = $spClose.Children.Add($btnClose)
    [Windows.Controls.Grid]::SetColumn($spClose, 2)
    $null = $footer.Children.Add($spClose)
    [Windows.Controls.Grid]::SetRow($footer, 2)
    $null = $root.Children.Add($footer)

    $btnSettings.Add_Click({
        try { $null = Edit-SettingsDialog -Owner $dlg -ConfigPath (Join-Path $rootDir 'Config\config.json') }
        catch { $null = Show-MessageDialog -Text ("Error while opening the settings: {0}" -f $_.Exception.Message) -Caption 'Settings' -Buttons 'OK' -Icon 'Error' }
    })

    $dlg.Content = $root
    $dlg.Tag = $null
    $dlg.Add_Closing({ if ([string]::IsNullOrWhiteSpace([string]$dlg.Tag)) { $dlg.Tag = 'Closed' } })

    $null = $dlg.ShowDialog()
    return $dlg.Tag
}

#endregion

#region --------------------------------------------------------- setup readers

<#
    Reads ProductName / ProductVersion / Manufacturer / ProductCode from an MSI.
#>
function Get-MsiProperties {
    param([Parameter(Mandatory = $true)][string]$Path)

    $props = @{}
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database  = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))

        foreach ($p in 'ProductName', 'ProductVersion', 'Manufacturer', 'ProductCode') {
            $view   = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$p'"))
            $null   = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($record) {
                $value = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
                if ($value) { $props[$p] = $value }
            }
            $null = $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        }
    }
    catch { }
    finally {
        if ($installer) { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer); [System.GC]::Collect() }
    }
    return $props
}

<#
    Reads the version resource of an EXE so setup.exe based packages can be
    named just as precisely as MSI based ones.
#>
function Get-ExeProperties {
    param([Parameter(Mandatory = $true)][string]$Path)

    $info = (Get-Item -LiteralPath $Path).VersionInfo
    $version = $info.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $info.FileVersion }
    if ($version) { $version = ($version -replace ',', '.').Trim() }

    return @{
        ProductName    = $info.ProductName
        ProductVersion = $version
        Manufacturer   = $info.CompanyName
        FilePath       = $Path
    }
}

<#
    Empties the two command fields and says why.

    A package whose detection is MSI is a zero-config PSADT package: the session
    block stays empty and PSADT installs the single MSI in .\Files itself. An
    install command on top of that runs the installation twice, so the fields are
    cleared rather than filled, and the reason is put where the user will look
    for it.
#>
function Clear-CommandFields {
    param([Parameter(Mandatory = $true)][hashtable]$TextBoxes)

    foreach ($key in 'InstallCmd', 'UninstallCmd') {
        if (-not $TextBoxes.Contains($key)) { continue }
        $TextBoxes[$key].Text = ''
        $TextBoxes[$key].IsEnabled = $false
        $TextBoxes[$key].Background = [System.Windows.Media.Brushes]::WhiteSmoke
        $TextBoxes[$key].ToolTip = 'Handled by the PSADT zero-config MSI deployment - leave empty.'
    }
}

<#
    Re-enables the command fields when the detection is not MSI any more.
#>
function Enable-CommandFields {
    param([Parameter(Mandatory = $true)][hashtable]$TextBoxes)

    foreach ($key in 'InstallCmd', 'UninstallCmd') {
        if (-not $TextBoxes.Contains($key)) { continue }
        $TextBoxes[$key].IsEnabled = $true
        $TextBoxes[$key].Background = [System.Windows.Media.Brushes]::White
        $TextBoxes[$key].ToolTip = $null
    }
}

function Set-IfPresent {
    param(
        [Parameter(Mandatory = $true)][hashtable]$TextBoxes,
        [Parameter(Mandatory = $true)][string[]]$CandidateKeys,
        [Parameter()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    foreach ($key in $CandidateKeys) {
        if ($TextBoxes.Contains($key)) { $TextBoxes[$key].Text = $Value; break }
    }
}

#endregion

#region -------------------------------------------------------- record editing

function Open-EditDialog {
    param(
        [hashtable]$item,
        [string]$title,
        [string[]]$PropertyOrder,
        # Setup dialogs are not about a setup file - hides "From MSI/EXE".
        [switch]$NoFilePrefill
    )

    $window = New-Object Windows.Window
    $window.Title = $title
    $window.Width = 760
    $window.SizeToContent = 'Height'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'EditDialog')
    $window.WindowStartupLocation = 'CenterScreen'

    $scrollViewer = New-Object Windows.Controls.ScrollViewer
    $scrollViewer.VerticalScrollBarVisibility = 'Auto'
    $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
    $scrollViewer.HorizontalAlignment = 'Stretch'

    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = '10'
    $stackPanel.Orientation = 'Vertical'
    $stackPanel.HorizontalAlignment = 'Stretch'

    # Label and value share a row. Stacking them cost two rows per field, which
    # pushed a nine column record past the bottom of the screen without making
    # the pairs any easier to read.
    $fieldGrid = New-Object Windows.Controls.Grid
    $labelColumn = New-Object Windows.Controls.ColumnDefinition
    $labelColumn.Width = New-Object Windows.GridLength -ArgumentList 150
    $valueColumn = New-Object Windows.Controls.ColumnDefinition
    $valueColumn.Width = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
    $null = $fieldGrid.ColumnDefinitions.Add($labelColumn)
    $null = $fieldGrid.ColumnDefinitions.Add($valueColumn)

    $textBoxes = @{}
    $keys = if ($PropertyOrder) { $PropertyOrder } else { $item.Keys }
    $rowIndex = 0

    foreach ($key in $keys) {
        $rowDefinition = New-Object Windows.Controls.RowDefinition
        $rowDefinition.Height = [Windows.GridLength]::Auto
        $null = $fieldGrid.RowDefinitions.Add($rowDefinition)

        $value = $item[$key]
        $isMultiline = (($value -is [string]) -and ($value -match "`n")) -or ($key -match 'Cmd$')

        $label = New-Object Windows.Controls.Label
        $label.Content = $key
        $label.Margin = '0,0,8,6'
        $label.HorizontalAlignment = 'Left'
        $label.VerticalAlignment = $(if ($isMultiline) { 'Top' } else { 'Center' })
        [Windows.Controls.Grid]::SetRow($label, $rowIndex)
        [Windows.Controls.Grid]::SetColumn($label, 0)
        $null = $fieldGrid.Children.Add($label)

        # DetectionMethod has four possible values and no others, so it is a list
        # rather than a free text field. Editable all the same, so an unexpected
        # value in an old row survives being looked at.
        if ($key -eq 'DetectionMethod') {
            $textBox = New-Object Windows.Controls.ComboBox
            $textBox.IsEditable = $true
            $textBox.ItemsSource = @('Registry', 'MSI', 'File', 'Script')
            $textBox.Height = 26
        }
        else {
            $textBox = New-Object Windows.Controls.TextBox
            $textBox.AcceptsReturn = $isMultiline
            $textBox.TextWrapping = 'Wrap'
            if ($isMultiline) { $textBox.Height = 100; $textBox.VerticalScrollBarVisibility = 'Auto' }
            else { $textBox.Height = 26 }
        }

        $textBox.Text = $value
        $textBox.Margin = '0,0,0,6'
        $textBox.HorizontalAlignment = 'Stretch'
        $textBox.VerticalContentAlignment = 'Center'
        [Windows.Automation.AutomationProperties]::SetAutomationId($textBox, $key)
        [Windows.Automation.AutomationProperties]::SetName($textBox, $key)
        [Windows.Controls.Grid]::SetRow($textBox, $rowIndex)
        [Windows.Controls.Grid]::SetColumn($textBox, 1)
        $null = $fieldGrid.Children.Add($textBox)

        $textBoxes[$key] = $textBox
        $rowIndex++

        # What DetectionPattern has to contain depends entirely on the method, so
        # the hint sits under the field and follows it.
        if ($key -eq 'DetectionPattern') {
            $rowDefinition = New-Object Windows.Controls.RowDefinition
            $rowDefinition.Height = [Windows.GridLength]::Auto
            $null = $fieldGrid.RowDefinitions.Add($rowDefinition)

            $script:PatternHint = New-Object Windows.Controls.TextBlock
            $script:PatternHint.Foreground = [System.Windows.Media.Brushes]::DimGray
            $script:PatternHint.TextWrapping = 'Wrap'
            $script:PatternHint.Margin = '2,0,0,8'
            [Windows.Automation.AutomationProperties]::SetAutomationId($script:PatternHint, 'DetectionPatternHint')
            [Windows.Controls.Grid]::SetRow($script:PatternHint, $rowIndex)
            [Windows.Controls.Grid]::SetColumn($script:PatternHint, 1)
            $null = $fieldGrid.Children.Add($script:PatternHint)
            $rowIndex++
        }
    }

    $null = $stackPanel.Children.Add($fieldGrid)

    # The command fields follow the detection method. MSI means the package is a
    # zero-config PSADT package, so the commands have to stay empty - the fields
    # are greyed out and say so rather than silently accepting something that
    # would install the product twice.
    if ($textBoxes.Contains('DetectionMethod')) {
        # Each hint says two things: what belongs in the field, and what the tool
        # builds out of it. The second half matters as much as the first - the
        # rule that reaches ConfigMgr is assembled from this field, the Version
        # column and nothing else, and none of that is visible here otherwise.
        $hints = @{
            'Registry' = 'Put in the uninstall key: a bare name is taken below SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall, a value starting with SOFTWARE\ is used as it is, and empty falls back to the ProductCode of the single MSI in .\Files. Examples: 7-Zip, or {23170F69-40C1-2702-2602-000001000000}.' + [Environment]::NewLine +
                         'Becomes: DisplayVersion greater or equal to the Version column, checked in the 64 bit and the 32 bit registry view and joined with Or.'
            'MSI'      = 'Nothing to put in - the ProductCode comes from the column beside this one, or is read from the single MSI in .\Files.' + [Environment]::NewLine +
                         'Becomes: Windows Installer ProductVersion greater or equal to the Version column.'
            'File'     = 'Put in the full path of the installed file, environment variables included. Example: %ProgramFiles%\Notepad++\notepad++.exe' + [Environment]::NewLine +
                         'Becomes: path and file name split for you, file version greater or equal to the Version column. A path holding a variable is checked in both the 64 bit and the 32 bit view; a literal path only in the 64 bit one.'
            'Script'   = 'Nothing to put in - the script is read from Content\SupportFiles\detection.ps1 inside the package.' + [Environment]::NewLine +
                         'Becomes: that script, unchanged, as the deployment type detection, with the tool signature prepended.'
        }

        # Everything above compares against the Version column, so what happens
        # when it is not a version has to be said once.
        $existenceNote = [Environment]::NewLine +
                         'If the Version column is not a comparable version - "19c" and the like - the rule becomes a plain existence check instead.'

        $syncMethod = {
            $method = $textBoxes['DetectionMethod'].Text
            if ($method) { $method = $method.Trim() }

            if ($method -eq 'MSI') { Clear-CommandFields -TextBoxes $textBoxes }
            else                   { Enable-CommandFields -TextBoxes $textBoxes }

            $hint = ''
            if ($hints.ContainsKey($method)) {
                $hint = $hints[$method]
                if ($method -ne 'Script') { $hint += $existenceNote }
            }

            if ($script:PatternHint) { $script:PatternHint.Text = $hint }
            if ($textBoxes.Contains('DetectionPattern')) {
                $textBoxes['DetectionPattern'].ToolTip = $(if ($hint) { $hint } else { $null })
                $textBoxes['DetectionPattern'].IsEnabled = ($method -notin 'MSI', 'Script')
            }
        }

        & $syncMethod
        # A ComboBox reports a pick through SelectionChanged; typing into it goes
        # through the text box inside its template, which only exists once the
        # control is loaded.
        $textBoxes['DetectionMethod'].Add_SelectionChanged($syncMethod)
        $textBoxes['DetectionMethod'].Add_Loaded({
            $inner = $textBoxes['DetectionMethod'].Template.FindName('PART_EditableTextBox', $textBoxes['DetectionMethod'])
            if ($inner) { $inner.Add_TextChanged($syncMethod) }
        })
    }

    # Prefill from a setup file - this replaces add-NewMSIToAppsCSV.ps1 and is
    # what keeps the naming in Apps.csv unambiguous.
    $msiButton = New-Object Windows.Controls.Button
    $msiButton.Content = 'From MSI...'
    $msiButton.Width = 100
    $msiButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($msiButton, 'FromMsi')
    $msiButton.Add_Click({
        try {
            $ofd = New-Object Microsoft.Win32.OpenFileDialog
            $ofd.Title = 'Select MSI'
            $ofd.Filter = 'MSI files (*.msi)|*.msi|All files (*.*)|*.*'
            if ($ofd.ShowDialog() -eq $true -and $ofd.FileName) {
                $props = Get-MsiProperties -Path $ofd.FileName
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Name', 'DisplayName', 'ProductName') -Value $props['ProductName']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Version', 'ProductVersion')           -Value $props['ProductVersion']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Publisher', 'Vendor', 'Manufacturer') -Value $props['Manufacturer']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('ProductCode')                         -Value $props['ProductCode']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('DetectionMethod')                     -Value 'MSI'

                # No install commands for an MSI. PSADT deploys the single MSI in
                # .\Files by itself as long as the session block stays empty, and
                # an injected Start-ADTMsiProcess would install it a second time.
                Clear-CommandFields -TextBoxes $textBoxes
            }
        }
        catch { $null = Show-MessageDialog -Text ("MSI could not be read: {0}" -f $_.Exception.Message) -Caption 'MSI' -Buttons 'OK' -Icon 'Error' }
    })

    $exeButton = New-Object Windows.Controls.Button
    $exeButton.Content = 'From EXE...'
    $exeButton.Width = 100
    $exeButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($exeButton, 'FromExe')
    $exeButton.Add_Click({
        try {
            $ofd = New-Object Microsoft.Win32.OpenFileDialog
            $ofd.Title = 'Select setup EXE'
            $ofd.Filter = 'Executables (*.exe)|*.exe|All files (*.*)|*.*'
            if ($ofd.ShowDialog() -eq $true -and $ofd.FileName) {
                $props = Get-ExeProperties -Path $ofd.FileName
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Name', 'DisplayName', 'ProductName') -Value $props['ProductName']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Version', 'ProductVersion')           -Value $props['ProductVersion']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Publisher', 'Vendor', 'Manufacturer') -Value $props['Manufacturer']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('DetectionMethod')                     -Value 'Registry'
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('InstallCmd') -Value ("Start-ADTProcess -FilePath '{0}' -ArgumentList '/S' -WindowStyle 'Hidden'" -f (Split-Path -Leaf $ofd.FileName))
            }
        }
        catch { $null = Show-MessageDialog -Text ("EXE could not be read: {0}" -f $_.Exception.Message) -Caption 'EXE' -Buttons 'OK' -Icon 'Error' }
    })

    # The third prefill source. From MSI and From EXE read a file the user
    # picked; this one picks the file for them first, out of the winget-pkgs
    # manifests, and then reads it exactly the same way.
    $catalogButton = New-Object Windows.Controls.Button
    $catalogButton.Content = 'From catalog...'
    $catalogButton.Width = 120
    $catalogButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($catalogButton, 'FromCatalog')
    $catalogButton.Add_Click({
        try {
            $found = Read-CatalogPackage
            if (-not $found) { return }

            # Every field, empty ones included - Set-IfPresent skips blanks,
            # which is right for a partial prefill from a file the user picked
            # but wrong here: the catalog replaces the whole record, and a value
            # the previous package left behind has nothing to do with this one.
            foreach ($column in 'Publisher', 'Name', 'Version', 'DetectionMethod',
                                'DetectionPattern', 'ProductCode', 'InstallCmd', 'UninstallCmd', 'Notes') {
                if ($textBoxes.Contains($column)) { $textBoxes[$column].Text = [string]$found.Row.$column }
            }

            $null = Show-MessageDialog -Text ("{0} {1} is ready.`n`nThe installer is here:`n{2}`n`nSignature: {3}" -f
                        $found.Row.Name, $found.Row.Version, $found.File, $found.Signature) `
                    -Caption 'From catalog' -Buttons 'OK' -Icon 'Information'
        }
        catch { $null = Show-MessageDialog -Text ("The catalog could not be read: {0}" -f $_.Exception.Message) -Caption 'From catalog' -Buttons 'OK' -Icon 'Warning' }
    })

    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = 'OK'
    $okButton.Width = 100
    $okButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($okButton, 'OK')
    $okButton.Add_Click({ $window.DialogResult = $true })

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Content = 'Cancel'
    $cancelButton.Width = 100
    $cancelButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($cancelButton, 'Cancel')
    $cancelButton.Add_Click({ $window.DialogResult = $false })

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    if (-not $NoFilePrefill) {
        $null = $buttonPanel.Children.Add($msiButton)
        $null = $buttonPanel.Children.Add($exeButton)
        $null = $buttonPanel.Children.Add($catalogButton)
    }
    $null = $buttonPanel.Children.Add($okButton)
    $null = $buttonPanel.Children.Add($cancelButton)

    $null = $stackPanel.Children.Add($buttonPanel)
    $scrollViewer.Content = $stackPanel
    $window.Content = $scrollViewer

    if ($window.ShowDialog() -eq $true) {
        $newItem = [ordered]@{}
        foreach ($key in $keys) { $newItem[$key] = $textBoxes[$key].Text }
        return $newItem
    }
}

#endregion

#region -------------------------------------------------------------- message

<#
    The tool's own message box.

    [System.Windows.MessageBox] draws a Win32 dialog, and a Win32 control is
    driven by posting it a window message - which User Interface Privilege
    Isolation blocks across processes. Its buttons advertise the Invoke pattern
    and then throw when it is used, so a MessageBox in the middle of a workflow
    makes that workflow impossible to drive or test. A WPF window is executed by
    its automation peer inside the owning process and has no such problem.

    Returns 'Yes', 'No' or 'OK'.
#>
function Show-MessageDialog {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Caption = 'SCCMAppHelper',
        [ValidateSet('OK', 'YesNo')][string]$Buttons = 'OK',
        [ValidateSet('Information', 'Warning', 'Error', 'Question')][string]$Icon = 'Information',
        [System.Windows.Window]$Owner
    )

    $window = New-Object Windows.Window
    $window.Title = $Caption
    $window.SizeToContent = 'WidthAndHeight'
    $window.ResizeMode = 'NoResize'
    $window.ShowInTaskbar = $false
    if ($Owner) { $window.Owner = $Owner; $window.WindowStartupLocation = 'CenterOwner' }
    else { $window.WindowStartupLocation = 'CenterScreen' }
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'MessageDialog')

    $glyphs = @{ Information = 0xE946; Warning = 0xE7BA; Error = 0xEA39; Question = 0xE9CE }
    $colours = @{
        Information = [System.Windows.Media.Brushes]::DodgerBlue
        Warning     = [System.Windows.Media.Brushes]::DarkOrange
        Error       = [System.Windows.Media.Brushes]::Firebrick
        Question    = [System.Windows.Media.Brushes]::DodgerBlue
    }

    $glyph = New-Object Windows.Controls.TextBlock
    $glyph.Text = [char]$glyphs[$Icon]
    $glyph.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $glyph.FontSize = 30
    $glyph.Foreground = $colours[$Icon]
    $glyph.VerticalAlignment = 'Top'
    $glyph.Margin = '0,0,14,0'

    $message = New-Object Windows.Controls.TextBlock
    $message.Text = $Text
    $message.TextWrapping = 'Wrap'
    $message.MaxWidth = 460
    $message.VerticalAlignment = 'Center'
    [Windows.Automation.AutomationProperties]::SetAutomationId($message, 'MessageText')

    $body = New-Object Windows.Controls.StackPanel
    $body.Orientation = 'Horizontal'
    $body.Margin = '20,20,20,10'
    $null = $body.Children.Add($glyph)
    $null = $body.Children.Add($message)

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = '20,0,20,16'

    $result = 'No'
    $captions = if ($Buttons -eq 'YesNo') { @('Yes', 'No') } else { @('OK') }
    foreach ($caption in $captions) {
        $button = New-Object Windows.Controls.Button
        $button.Content = $caption
        $button.MinWidth = 88
        $button.Padding = '14,5'
        $button.Margin = '8,0,0,0'
        $button.Tag = $caption
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, $caption)
        if ($caption -in @('Yes', 'OK')) { $button.IsDefault = $true }
        if ($caption -eq 'No') { $button.IsCancel = $true }
        $button.Add_Click({ param($s, $e) $script:MessageDialogResult = [string]$s.Tag; $window.Close() })
        $null = $buttonPanel.Children.Add($button)
    }

    $layout = New-Object Windows.Controls.StackPanel
    $layout.Orientation = 'Vertical'
    $null = $layout.Children.Add($body)
    $null = $layout.Children.Add($buttonPanel)

    $window.Content = $layout
    $script:MessageDialogResult = $(if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' })
    $null = $window.ShowDialog()
    return $script:MessageDialogResult
}

#endregion

#region ------------------------------------------------------------ selection

function Open-SelectDialog {
    param(
        $data,
        [string]$title,
        [switch]$large
    )

    $window = New-Object Windows.Window
    $window.Title = $title
    if ($large) { $window.Width = 1024; $window.Height = 768 } else { $window.Width = 800; $window.Height = 600 }

    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true

    $items = @($data)
    $firstItem = $items | Select-Object -First 1
    foreach ($property in $firstItem.PSObject.Properties.Name) {
        $column = New-Object Windows.Controls.DataGridTextColumn
        $column.Header = $property
        $column.Binding = New-Object Windows.Data.Binding($property)
        $column.CanUserSort = $true
        $null = $dataGrid.Columns.Add($column)
    }
    $dataGrid.ItemsSource = $items
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'SelectDialog')
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'SelectGrid')

    $okButton = New-Object Windows.Controls.Button
    $okButton.Height = 40; $okButton.Width = 100; $okButton.Content = 'OK'; $okButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($okButton, 'OK')
    $okButton.Add_Click({ $window.DialogResult = $true })

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Height = 40; $cancelButton.Width = 100; $cancelButton.Content = 'Cancel'; $cancelButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($cancelButton, 'Cancel')
    $cancelButton.Add_Click({ $window.DialogResult = $false })

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = '10'
    $null = $buttonPanel.Children.Add($okButton)
    $null = $buttonPanel.Children.Add($cancelButton)

    $grid = New-Object Windows.Controls.Grid
    $null = $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $null = $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[1].Height = [Windows.GridLength]::Auto
    $null = $grid.Children.Add($dataGrid)
    [Windows.Controls.Grid]::SetRow($dataGrid, 0)
    $null = $grid.Children.Add($buttonPanel)
    [Windows.Controls.Grid]::SetRow($buttonPanel, 1)

    $window.Content = $grid
    $window.WindowStartupLocation = 'CenterScreen'

    if ($window.ShowDialog() -eq $true) { return $dataGrid.SelectedItems }
}

function Open-SelectDialogWithEdit {
    param(
        [string]$CsvPath,
        [string]$title = 'Selection',
        [ValidateSet('small', 'medium', 'large')][string]$size = 'medium'
    )

    function Load-Data {
        Import-Csv -LiteralPath $CsvPath -Delimiter ';' | ForEach-Object {
            $obj = $_ | Select-Object *
            $obj | Add-Member -MemberType NoteProperty -Name __InternalId -Value ([guid]::NewGuid().ToString())
            $obj
        }
    }

    function Save-Data {
        param([System.Collections.IEnumerable]$data, [string[]]$columnOrder)
        $data | Select-Object -Property $columnOrder |
            Sort-Object Name, Version |
            Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }

    # An empty list is a normal starting state, not a problem: it is exactly what
    # a new site looks like. Refusing to open the dialog then was a dead end -
    # this dialog is the only way to add the first row, so an empty Apps.csv
    # made it impossible to add anything at all.
    $data = @(Load-Data)

    $window = New-Object Windows.Window
    $window.Title = $title
    switch ($size) {
        'small'  { $window.Width = 500;  $window.Height = 400 }
        'medium' { $window.Width = 800;  $window.Height = 600 }
        'large'  { $window.Width = 1600; $window.Height = 800 }
    }
    $window.WindowStartupLocation = 'CenterScreen'
    $window.ResizeMode = 'CanResize'

    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.IsReadOnly = $true

    # With rows, the columns are whatever they carry. Without them there is
    # nothing to read the shape from, so it comes from the master list schema -
    # which is what New would fill in anyway.
    # The empty entry has to be filtered out, not just the internal one: with no
    # rows, .PSObject on nothing yields $null, and @($null) is an array of one -
    # so a plain count check never sees an empty list.
    $columnOrder = @(($data | Select-Object -First 1).PSObject.Properties.Name |
                        Where-Object { $_ -and $_ -ne '__InternalId' })
    if ($columnOrder.Count -eq 0) { $columnOrder = @($script:AppListColumns) }

    foreach ($property in $columnOrder) {
        $column = New-Object Windows.Controls.DataGridTextColumn
        $column.Header = $property
        $column.Binding = New-Object Windows.Data.Binding($property)
        $column.CanUserSort = $true
        $null = $dataGrid.Columns.Add($column)
    }

    function Refresh-Grid {
        $dataGrid.ItemsSource = $null
        $dataGrid.ItemsSource = @(Load-Data)
    }
    Refresh-Grid

    $filterBox = New-Object Windows.Controls.TextBox
    $filterBox.Margin = '10,10,10,0'
    $filterBox.Height = 26
    $filterBox.ToolTip = 'Filter (matches any column)'
    $filterBox.Add_TextChanged({
        $needle = $filterBox.Text
        $items = @(Load-Data)
        if (-not [string]::IsNullOrWhiteSpace($needle)) {
            $items = $items | Where-Object {
                $row = $_
                ($columnOrder | Where-Object { [string]$row.$_ -like "*$needle*" }).Count -gt 0
            }
        }
        $dataGrid.ItemsSource = $null
        $dataGrid.ItemsSource = @($items)
    })

    $okButton        = New-Object Windows.Controls.Button; $okButton.Content        = 'OK';        $okButton.Width = 100;        $okButton.Margin = '5'; $okButton.IsDefault = $true
    $cancelButton    = New-Object Windows.Controls.Button; $cancelButton.Content    = 'Cancel';    $cancelButton.Width = 100;    $cancelButton.Margin = '5'; $cancelButton.IsCancel = $true
    $editButton      = New-Object Windows.Controls.Button; $editButton.Content      = 'Edit';      $editButton.Width = 100;      $editButton.Margin = '5'
    $newButton       = New-Object Windows.Controls.Button; $newButton.Content       = 'New';       $newButton.Width = 100;       $newButton.Margin = '5'
    $duplicateButton = New-Object Windows.Controls.Button; $duplicateButton.Content = 'Duplicate'; $duplicateButton.Width = 100; $duplicateButton.Margin = '5'
    $deleteButton    = New-Object Windows.Controls.Button; $deleteButton.Content    = 'Delete';    $deleteButton.Width = 100;    $deleteButton.Margin = '5'

    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'AppListDialog')
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'AppListGrid')
    [Windows.Automation.AutomationProperties]::SetAutomationId($okButton, 'OK')
    [Windows.Automation.AutomationProperties]::SetAutomationId($cancelButton, 'Cancel')
    [Windows.Automation.AutomationProperties]::SetAutomationId($editButton, 'Edit')
    [Windows.Automation.AutomationProperties]::SetAutomationId($newButton, 'New')
    [Windows.Automation.AutomationProperties]::SetAutomationId($duplicateButton, 'Duplicate')
    [Windows.Automation.AutomationProperties]::SetAutomationId($deleteButton, 'Delete')

    $okButton.Add_Click({
        $selection = @()
        foreach ($item in $dataGrid.SelectedItems) { if ($item -isnot [int]) { $selection += $item } }
        $window.Tag = [pscustomobject]@{ Result = 'Ok'; Selection = $selection }
        $window.Close()
    })

    $cancelButton.Add_Click({
        $window.Tag = [pscustomobject]@{ Result = 'Cancel'; Selection = @() }
        $window.Close()
    })

    $editButton.Add_Click({
        if (-not $dataGrid.SelectedItem) { return }
        $selected = $dataGrid.SelectedItem
        $hash = @{}
        foreach ($property in $columnOrder) { $hash[$property] = $selected.$property }

        $edited = Open-EditDialog -item $hash -title 'Edit entry' -PropertyOrder $columnOrder
        $edited = $edited | Where-Object { $_ -isnot [int] }
        if (-not $edited) { return }

        $rows = @(Load-Data)
        foreach ($row in $rows) {
            $isSame = $true
            foreach ($property in @('Name', 'Version')) {
                if ([string]$row.$property -ne [string]$selected.$property) { $isSame = $false; break }
            }
            if ($isSame) { foreach ($key in $edited.Keys) { $row.$key = $edited[$key] } }
        }
        Save-Data -data $rows -columnOrder $columnOrder
        Refresh-Grid
    })

    $addEntry = {
        param($template, $dialogTitle)
        $newItem = Open-EditDialog -item $template -title $dialogTitle -PropertyOrder $columnOrder
        $newItem = $newItem | Where-Object { $_ -isnot [int] }
        if (-not $newItem) { return }

        $newObject = New-Object psobject
        foreach ($key in $newItem.Keys) { $newObject | Add-Member -MemberType NoteProperty -Name $key -Value $newItem[$key] }

        $rows = @(Load-Data) + $newObject
        Save-Data -data $rows -columnOrder $columnOrder
        Refresh-Grid
    }

    $newButton.Add_Click({
        $template = [ordered]@{}
        foreach ($property in $columnOrder) { $template[$property] = '' }
        if ($template.Contains('DetectionMethod')) { $template['DetectionMethod'] = 'Registry' }
        & $addEntry $template 'Add new entry'
    })

    $duplicateButton.Add_Click({
        if (-not $dataGrid.SelectedItem) { return }
        $selected = $dataGrid.SelectedItem
        $template = [ordered]@{}
        foreach ($property in $columnOrder) { $template[$property] = $selected.$property }
        & $addEntry $template 'Edit duplicated entry'
    })

    $deleteButton.Add_Click({
        $selectedItems = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        if ($selectedItems.Count -eq 0) {
            $null = Show-MessageDialog -Text 'No entries selected.' -Caption 'Hint' -Buttons 'OK' -Icon 'Information'
            return
        }
        $confirm = Show-MessageDialog -Text 'Really delete the selected entries?' -Caption 'Confirm delete' -Buttons 'YesNo' -Icon 'Warning'
        if ($confirm -ne 'Yes') { return }

        $keys = $selectedItems | ForEach-Object { '{0}|{1}' -f $_.Name, $_.Version }
        $rows = @(Load-Data) | Where-Object { ('{0}|{1}' -f $_.Name, $_.Version) -notin $keys }
        Save-Data -data $rows -columnOrder $columnOrder
        Refresh-Grid
    })

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = '10'
    foreach ($button in @($newButton, $duplicateButton, $editButton, $deleteButton, $okButton, $cancelButton)) {
        $null = $buttonPanel.Children.Add($button)
    }

    $grid = New-Object Windows.Controls.Grid
    $null = $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $null = $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $null = $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[0].Height = [Windows.GridLength]::Auto
    $grid.RowDefinitions[2].Height = [Windows.GridLength]::Auto

    $null = $grid.Children.Add($filterBox)
    [Windows.Controls.Grid]::SetRow($filterBox, 0)
    $null = $grid.Children.Add($dataGrid)
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    $null = $grid.Children.Add($buttonPanel)
    [Windows.Controls.Grid]::SetRow($buttonPanel, 2)

    $window.Content = $grid
    $window.Add_Closing({ if ($null -eq $window.Tag) { $window.Tag = [pscustomobject]@{ Result = 'Closed'; Selection = @() } } })

    $null = $window.ShowDialog()

    if ($null -ne $window.Tag -and $window.Tag.Result -eq 'Ok') { return $window.Tag.Selection }
    return @()
}

#endregion

#region ------------------------------------------------------------- settings

<#
    Generic settings editor: every scalar value of config.json becomes a text
    box or a check box, lists and nested objects are edited as raw JSON. New
    config keys therefore show up without touching this dialog.
#>
function Edit-SettingsDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][System.Windows.Window]$Owner,
        [string]$ConfigPath = (Join-Path $rootDir 'Config\config.json')
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration file not found: $ConfigPath" }
    $config = Get-Content -Raw -LiteralPath $ConfigPath -Encoding UTF8 | ConvertFrom-Json

    $dlg = New-Object Windows.Window
    $dlg.Title = "Settings - $ConfigPath"
    $dlg.Width = 900
    $dlg.Height = 700
    $dlg.WindowStartupLocation = 'CenterOwner'
    if ($null -ne $Owner) { $dlg.Owner = $Owner } else { $dlg.WindowStartupLocation = 'CenterScreen' }

    $root = New-Object Windows.Controls.Grid
    $root.Margin = '12'
    $rowTabs = New-Object Windows.Controls.RowDefinition; $rowTabs.Height = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
    $rowBtns = New-Object Windows.Controls.RowDefinition; $rowBtns.Height = [Windows.GridLength]::Auto
    $null = $root.RowDefinitions.Add($rowTabs)
    $null = $root.RowDefinitions.Add($rowBtns)

    $tabs = New-Object Windows.Controls.TabControl
    [Windows.Controls.Grid]::SetRow($tabs, 0)
    $null = $root.Children.Add($tabs)

    # --- tab 1: scalar values -------------------------------------------------
    $scalarKeys = $config.PSObject.Properties |
        Where-Object { $_.Value -is [string] -or $_.Value -is [bool] -or $_.Value -is [int] -or $_.Value -is [long] -or $null -eq $_.Value } |
        Select-Object -ExpandProperty Name

    $scalarGrid = New-Object Windows.Controls.Grid
    $scalarGrid.Margin = '10'
    $colLabel = New-Object Windows.Controls.ColumnDefinition; $colLabel.Width = 'Auto'
    $colValue = New-Object Windows.Controls.ColumnDefinition; $colValue.Width = '*'
    $null = $scalarGrid.ColumnDefinitions.Add($colLabel)
    $null = $scalarGrid.ColumnDefinitions.Add($colValue)

    $controls = @{}
    $rowIndex = 0
    foreach ($key in $scalarKeys) {
        $rowDefinition = New-Object Windows.Controls.RowDefinition
        $rowDefinition.Height = [Windows.GridLength]::Auto
        $null = $scalarGrid.RowDefinitions.Add($rowDefinition)

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = "$key :"
        $label.Margin = '0,6,8,6'
        $label.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetRow($label, $rowIndex)
        [Windows.Controls.Grid]::SetColumn($label, 0)
        $null = $scalarGrid.Children.Add($label)

        if ($config.$key -is [bool]) {
            $control = New-Object Windows.Controls.CheckBox
            $control.IsChecked = $config.$key
            $control.Margin = '0,6,0,6'
            $control.VerticalAlignment = 'Center'
        }
        else {
            $control = New-Object Windows.Controls.TextBox
            $control.Text = [string]$config.$key
            $control.Margin = '0,4,0,4'
        }
        [Windows.Controls.Grid]::SetRow($control, $rowIndex)
        [Windows.Controls.Grid]::SetColumn($control, 1)
        $null = $scalarGrid.Children.Add($control)

        $controls[$key] = $control
        $rowIndex++
    }

    $scalarScroll = New-Object Windows.Controls.ScrollViewer
    $scalarScroll.VerticalScrollBarVisibility = 'Auto'
    $scalarScroll.Content = $scalarGrid

    $tabGeneral = New-Object Windows.Controls.TabItem
    $tabGeneral.Header = 'General'
    $tabGeneral.Content = $scalarScroll
    $null = $tabs.Items.Add($tabGeneral)

    # --- tab 2: complex values as JSON ---------------------------------------
    $complexKeys = $config.PSObject.Properties | Where-Object { $_.Name -notin $scalarKeys } | Select-Object -ExpandProperty Name

    $jsonBox = New-Object Windows.Controls.TextBox
    $jsonBox.AcceptsReturn = $true
    $jsonBox.AcceptsTab = $true
    $jsonBox.VerticalScrollBarVisibility = 'Auto'
    $jsonBox.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
    $jsonBox.Margin = '10'

    $complexObject = [ordered]@{}
    foreach ($key in $complexKeys) { $complexObject[$key] = $config.$key }
    $jsonBox.Text = ($complexObject | ConvertTo-Json -Depth 8)

    $tabAdvanced = New-Object Windows.Controls.TabItem
    $tabAdvanced.Header = 'Collections and deployments (JSON)'
    $tabAdvanced.Content = $jsonBox
    $null = $tabs.Items.Add($tabAdvanced)

    # --- buttons --------------------------------------------------------------
    $btnSave = New-Object Windows.Controls.Button
    $btnSave.Content = 'Save'; $btnSave.Width = 100; $btnSave.Margin = '5'
    $btnClose = New-Object Windows.Controls.Button
    $btnClose.Content = 'Close'; $btnClose.Width = 100; $btnClose.Margin = '5'

    $btnSave.Add_Click({
        try {
            $result = [ordered]@{}
            foreach ($key in $scalarKeys) {
                $control = $controls[$key]
                if ($control -is [Windows.Controls.CheckBox]) { $result[$key] = [bool]$control.IsChecked }
                elseif ($config.$key -is [int] -or $config.$key -is [long]) {
                    $number = 0
                    if ([int]::TryParse($control.Text, [ref]$number)) { $result[$key] = $number } else { $result[$key] = $control.Text }
                }
                else { $result[$key] = $control.Text }
            }

            $complex = $jsonBox.Text | ConvertFrom-Json -ErrorAction Stop
            foreach ($property in $complex.PSObject.Properties) { $result[$property.Name] = $property.Value }

            $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
            $null = Show-MessageDialog -Text "Saved: $ConfigPath" -Caption 'Settings' -Buttons 'OK' -Icon 'Information'
        }
        catch {
            $null = Show-MessageDialog -Text ("Save failed: {0}" -f $_.Exception.Message) -Caption 'Settings' -Buttons 'OK' -Icon 'Error'
        }
    })

    $btnClose.Add_Click({ $dlg.Close() })

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = '0,10,0,0'
    $null = $buttonPanel.Children.Add($btnSave)
    $null = $buttonPanel.Children.Add($btnClose)
    [Windows.Controls.Grid]::SetRow($buttonPanel, 1)
    $null = $root.Children.Add($buttonPanel)

    $dlg.Content = $root
    $null = $dlg.ShowDialog()
    return $true
}

#endregion

#region --------------------------------------------------------------- catalog

<#
    Picks a package for "New from catalog": the curated list from catalog.json
    up front, and a search box for everything else in the manifest repository.
    Returns an object with Name and PackageId, or $null when cancelled.
#>
function Show-CatalogDialog {
    param(
        $Packages,
        [string]$Title = 'New from catalog'
    )

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 780
    $window.Height = 560
    $window.WindowStartupLocation = 'CenterScreen'

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '12'
    foreach ($height in 'Auto', '*', 'Auto') {
        $row = New-Object Windows.Controls.RowDefinition
        $row.Height = $(if ($height -eq '*') { New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto })
        $null = $grid.RowDefinitions.Add($row)
    }

    # --- search row ---
    $searchPanel = New-Object Windows.Controls.DockPanel
    $searchPanel.Margin = '0,0,0,8'
    $searchBox = New-Object Windows.Controls.TextBox
    $searchBox.Padding = '4'
    $searchBox.VerticalContentAlignment = 'Center'
    $searchButton = New-Object Windows.Controls.Button
    $searchButton.Content = 'Search winget-pkgs'
    $searchButton.Padding = '12,4'
    $searchButton.Margin = '8,0,0,0'
    [Windows.Controls.DockPanel]::SetDock($searchButton, 'Right')
    $null = $searchPanel.Children.Add($searchButton)
    $null = $searchPanel.Children.Add($searchBox)
    [Windows.Controls.Grid]::SetRow($searchPanel, 0)
    $null = $grid.Children.Add($searchPanel)

    # --- list ---
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.SelectionMode = 'Single'
    $dataGrid.SelectionUnit = 'FullRow'
    foreach ($column in 'Name', 'PackageId') {
        $col = New-Object Windows.Controls.DataGridTextColumn
        $col.Header = $column
        $col.Binding = New-Object Windows.Data.Binding($column)
        $col.Width = $(if ($column -eq 'Name') { 260 } else { 420 })
        $null = $dataGrid.Columns.Add($col)
    }
    $dataGrid.ItemsSource = @($Packages)
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'CatalogDialog')
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'CatalogGrid')
    [Windows.Automation.AutomationProperties]::SetAutomationId($searchBox, 'SearchQuery')
    [Windows.Automation.AutomationProperties]::SetAutomationId($searchButton, 'Search')
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    $null = $grid.Children.Add($dataGrid)

    # --- buttons ---
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = '0,10,0,0'
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = 'Next'; $okButton.Padding = '18,6'; $okButton.Margin = '0,0,8,0'; $okButton.IsDefault = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($okButton, 'Next')
    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Content = 'Cancel'; $cancelButton.Padding = '18,6'; $cancelButton.IsCancel = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($cancelButton, 'Cancel')
    # Anything found through the repository can be kept, so the curated list -
    # the only part that can be searched by product name - grows with use
    # instead of staying whatever it was the day it was written.
    $rememberButton = New-Object Windows.Controls.Button
    $rememberButton.Content = 'Remember'
    $rememberButton.Padding = '18,6'
    $rememberButton.Margin = '0,0,8,0'
    $rememberButton.ToolTip = 'Add the selected package to Config\catalog.json'
    [Windows.Automation.AutomationProperties]::SetAutomationId($rememberButton, 'Remember')
    $rememberButton.Add_Click({
        $picked = $dataGrid.SelectedItem
        if (-not $picked) {
            $null = Show-MessageDialog -Text 'Nothing selected.' -Caption 'New from catalog' -Buttons 'OK' -Icon 'Information' -Owner $window
            return
        }
        try {
            $added = Add-CatalogEntry -Name ([string]$picked.Name) -PackageId ([string]$picked.PackageId)
            $null = Show-MessageDialog -Owner $window -Caption 'New from catalog' -Buttons 'OK' -Icon 'Information' -Text $(
                if ($added) { "$($picked.PackageId) is in the catalog now, and will be found by name next time." }
                else        { "$($picked.PackageId) was already in the catalog." })
        }
        catch { $null = Show-MessageDialog -Text $_.Exception.Message -Caption 'New from catalog' -Buttons 'OK' -Icon 'Warning' -Owner $window }
    })

    $null = $buttons.Children.Add($rememberButton)
    $null = $buttons.Children.Add($okButton)
    $null = $buttons.Children.Add($cancelButton)
    [Windows.Controls.Grid]::SetRow($buttons, 2)
    $null = $grid.Children.Add($buttons)

    $okButton.Add_Click({ if ($dataGrid.SelectedItem) { $window.DialogResult = $true } })
    $dataGrid.Add_MouseDoubleClick({ if ($dataGrid.SelectedItem) { $window.DialogResult = $true } })

    $searchButton.Add_Click({
        $query = $searchBox.Text
        if ([string]::IsNullOrWhiteSpace($query)) { $dataGrid.ItemsSource = @($Packages); return }

        # The curated list first: it is already here, it matches on the product
        # name, and it covers the everyday case. Only what it does not know is
        # worth a request.
        $local = @($Packages | Where-Object { $_.name -like "*$query*" -or $_.packageId -like "*$query*" } |
                        ForEach-Object { [pscustomobject]@{ Name = $_.name; PackageId = $_.packageId } })
        if ($local.Count -gt 0) { $dataGrid.ItemsSource = $local; return }

        $window.Cursor = 'Wait'
        try {
            $found = @(Find-CatalogPackage -Query $query)
            if ($found.Count -eq 0) {
                $null = Show-MessageDialog -Owner $window -Caption 'New from catalog' -Buttons 'OK' -Icon 'Information' -Text (
                    "Nothing found for [$query].`n`n" +
                    "The repository is organised by publisher, not by product: a package lives under " +
                    "manifests\<letter>\<Publisher>\<Package>, and the letter is the publisher's. " +
                    "Searching for a product whose vendor is named differently cannot work - KeePass sits " +
                    "under DominikReichl, Visual Studio Code under Microsoft.`n`n" +
                    "Try the vendor name, or paste the full package id (it contains a dot) and it is taken as it is.")
            }
            $dataGrid.ItemsSource = $found
        }
        catch {
            $null = Show-MessageDialog -Text $_.Exception.Message -Caption 'New from catalog' -Buttons 'OK' -Icon 'Warning' -Owner $window
        }
        finally { $window.Cursor = 'Arrow' }
    })
    $searchBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $searchButton.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })

    $window.Content = $grid
    if ($window.ShowDialog() -ne $true) { return $null }
    return $dataGrid.SelectedItem
}

#endregion
#region ---------------------------------------------------------------- retire

<#
    Picks the applications to retire or remove, and which of the two it is.

    The list is the site, not the share: an application whose package folder is
    long gone still has to be reachable. "Only replaced versions" is the
    everyday case - a version that has a newer sibling in the site.

    Returns Applications / Level / DeletePackageFolder, or $null when cancelled.
#>
function Show-RetireDialog {
    param($Inventory, [string]$Title = 'Retire applications')

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 1000
    $window.Height = 640
    $window.WindowStartupLocation = 'CenterScreen'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'RetireDialog')

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '12'
    foreach ($height in 'Auto', '*', 'Auto', 'Auto') {
        $row = New-Object Windows.Controls.RowDefinition
        $row.Height = $(if ($height -eq '*') { New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto })
        $null = $grid.RowDefinitions.Add($row)
    }

    $filterBox = New-Object Windows.Controls.CheckBox
    $filterBox.Content = 'Only versions that have a newer one in the site'
    $filterBox.Margin = '0,0,0,8'
    $filterBox.IsChecked = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($filterBox, 'OnlyReplaced')
    [Windows.Controls.Grid]::SetRow($filterBox, 0)
    $null = $grid.Children.Add($filterBox)

    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'RetireGrid')
    foreach ($column in @(
            @{ Header = 'Application';   Binding = 'AppName';          Width = 380 },
            @{ Header = 'Deployments';   Binding = 'Deployments';      Width = 90  },
            @{ Header = 'Superseded by'; Binding = 'SupersededByText'; Width = 300 },
            @{ Header = 'Published by';  Binding = 'Origin';           Width = 100 })) {
        $col = New-Object Windows.Controls.DataGridTextColumn
        $col.Header = $column.Header
        $col.Binding = New-Object Windows.Data.Binding($column.Binding)
        $col.Width = $column.Width
        $null = $dataGrid.Columns.Add($col)
    }
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    $null = $grid.Children.Add($dataGrid)

    foreach ($application in $Inventory) {
        Add-Member -InputObject $application -NotePropertyName 'SupersededByText' `
            -NotePropertyValue (@($application.SupersededBy) -join ', ') -Force
    }
    $applyFilter = { $dataGrid.ItemsSource = @($Inventory | Where-Object { -not $filterBox.IsChecked -or $_.HasNewer }) }
    & $applyFilter
    $filterBox.Add_Checked($applyFilter)
    $filterBox.Add_Unchecked($applyFilter)

    $folderBox = New-Object Windows.Controls.CheckBox
    $folderBox.Content = 'Remove: delete the package folder on the share as well'
    $folderBox.Margin = '0,10,0,0'
    [Windows.Automation.AutomationProperties]::SetAutomationId($folderBox, 'DeletePackageFolder')
    [Windows.Controls.Grid]::SetRow($folderBox, 2)
    $null = $grid.Children.Add($folderBox)

    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = '0,12,0,0'
    [Windows.Controls.Grid]::SetRow($buttons, 3)
    $null = $grid.Children.Add($buttons)

    $retireButton = New-Object Windows.Controls.Button
    $retireButton.Content = 'Retire (deployments only)'
    $retireButton.Padding = '16,6'; $retireButton.Margin = '0,0,8,0'
    [Windows.Automation.AutomationProperties]::SetAutomationId($retireButton, 'Retire')

    $removeButton = New-Object Windows.Controls.Button
    $removeButton.Content = 'Remove (delete everything)'
    $removeButton.Padding = '16,6'; $removeButton.Margin = '0,0,8,0'
    [Windows.Automation.AutomationProperties]::SetAutomationId($removeButton, 'Remove')

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Content = 'Cancel'
    $cancelButton.Padding = '16,6'; $cancelButton.IsCancel = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($cancelButton, 'Cancel')

    $null = $buttons.Children.Add($retireButton)
    $null = $buttons.Children.Add($removeButton)
    $null = $buttons.Children.Add($cancelButton)

    $choose = {
        param($level)
        $selected = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        if ($selected.Count -eq 0) {
            $null = Show-MessageDialog -Text 'Nothing selected.' -Caption $Title -Buttons 'OK' -Icon 'Information' -Owner $window
            return
        }
        $window.Tag = [pscustomobject]@{
            Applications        = $selected
            Level               = $level
            DeletePackageFolder = [bool]$folderBox.IsChecked
        }
        $window.Close()
    }
    $retireButton.Add_Click({ & $choose 'Retire' })
    $removeButton.Add_Click({ & $choose 'Remove' })

    $window.Content = $grid
    $window.Tag = $null
    $null = $window.ShowDialog()
    return $window.Tag
}

#endregion
