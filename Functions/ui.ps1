<#
    SCCMAppHelper - WPF dialogs
    Adapted from IntuneWin32Helper so both tools feel the same.
#>

Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName System.Windows.Forms  -ErrorAction SilentlyContinue | Out-Null

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

        $border = New-Object Windows.Controls.Border
        $border.BorderBrush = [System.Windows.Media.Brushes]::LightGray
        $border.BorderThickness = '1'
        $border.CornerRadius = '6'
        $border.Margin = '6'
        $border.Padding = '12'
        $border.Background = [System.Windows.Media.Brushes]::White
        $border.SnapsToDevicePixels = $true
        $border.Width = $Width
        $border.Cursor = 'Hand'
        $border.Tag = $ReturnValue

        $border.Add_MouseEnter({ param($s, $e) $s.BorderBrush = [System.Windows.Media.Brushes]::DodgerBlue })
        $border.Add_MouseLeave({ param($s, $e) $s.BorderBrush = [System.Windows.Media.Brushes]::LightGray })

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
        $border.Child = $stack
        return $border
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
    foreach ($tile in $tiles) { $null = $uniform.Children.Add($tile) }

    # One click handler for the whole tile area - works on icon, text and padding.
    $uniform.Add_PreviewMouseLeftButtonUp({
        param($s, $e)

        $elem = $e.OriginalSource
        $borderFound = $null
        while ($null -ne $elem -and $null -eq $borderFound) {
            if ($elem -is [Windows.Controls.Border]) { $borderFound = $elem }
            elseif ($elem -is [System.Windows.FrameworkElement] -and $null -ne $elem.Parent) { $elem = $elem.Parent }
            else { $elem = [System.Windows.Media.VisualTreeHelper]::GetParent($elem) }
        }

        if ($null -ne $borderFound -and -not [string]::IsNullOrWhiteSpace([string]$borderFound.Tag)) {
            $dlg.Tag = [string]$borderFound.Tag
            $dlg.Close()
        }
    })

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
    $btnClose.Padding = '14,6'
    $btnClose.Add_Click({ $dlg.Tag = 'Cancel'; $dlg.Close() })
    $null = $spClose.Children.Add($btnClose)
    [Windows.Controls.Grid]::SetColumn($spClose, 2)
    $null = $footer.Children.Add($spClose)
    [Windows.Controls.Grid]::SetRow($footer, 2)
    $null = $root.Children.Add($footer)

    $btnSettings.Add_Click({
        try { $null = Edit-SettingsDialog -Owner $dlg -ConfigPath (Join-Path $rootDir 'Config\config.json') }
        catch { [System.Windows.MessageBox]::Show(("Error while opening the settings: {0}" -f $_.Exception.Message), 'Settings', 'OK', 'Error') | Out-Null }
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
    $window.Width = 900
    $window.Height = 800
    $window.SizeToContent = 'Height'
    $window.WindowStartupLocation = 'CenterScreen'

    $scrollViewer = New-Object Windows.Controls.ScrollViewer
    $scrollViewer.VerticalScrollBarVisibility = 'Auto'
    $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
    $scrollViewer.HorizontalAlignment = 'Stretch'

    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = '10'
    $stackPanel.Orientation = 'Vertical'
    $stackPanel.HorizontalAlignment = 'Stretch'

    $textBoxes = @{}
    $keys = if ($PropertyOrder) { $PropertyOrder } else { $item.Keys }

    foreach ($key in $keys) {
        $label = New-Object Windows.Controls.Label
        $label.Content = $key
        $label.Margin = '0,0,0,2'
        $label.HorizontalAlignment = 'Left'
        $null = $stackPanel.Children.Add($label)

        $value = $item[$key]
        $isMultiline = (($value -is [string]) -and ($value -match "`n")) -or ($key -match 'Cmd$')

        $textBox = New-Object Windows.Controls.TextBox
        $textBox.Text = $value
        $textBox.Margin = '0,0,0,8'
        $textBox.AcceptsReturn = $isMultiline
        $textBox.TextWrapping = 'Wrap'
        $textBox.HorizontalAlignment = 'Stretch'
        $textBox.MinWidth = 800
        if ($isMultiline) { $textBox.Height = 100; $textBox.VerticalScrollBarVisibility = 'Auto' }
        else { $textBox.Height = 30 }

        $null = $stackPanel.Children.Add($textBox)
        $textBoxes[$key] = $textBox
    }

    # Prefill from a setup file - this replaces add-NewMSIToAppsCSV.ps1 and is
    # what keeps the naming in Apps.csv unambiguous.
    $msiButton = New-Object Windows.Controls.Button
    $msiButton.Content = 'From MSI...'
    $msiButton.Width = 100
    $msiButton.Margin = '5'
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
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('InstallCmd')   -Value ("Start-ADTMsiProcess -Action 'Install' -FilePath '{0}'" -f (Split-Path -Leaf $ofd.FileName))
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('UninstallCmd') -Value ("Start-ADTMsiProcess -Action 'Uninstall' -ProductCode '{0}'" -f $props['ProductCode'])
            }
        }
        catch { [System.Windows.MessageBox]::Show(("MSI could not be read: {0}" -f $_.Exception.Message), 'MSI', 'OK', 'Error') | Out-Null }
    })

    $exeButton = New-Object Windows.Controls.Button
    $exeButton.Content = 'From EXE...'
    $exeButton.Width = 100
    $exeButton.Margin = '5'
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
        catch { [System.Windows.MessageBox]::Show(("EXE could not be read: {0}" -f $_.Exception.Message), 'EXE', 'OK', 'Error') | Out-Null }
    })

    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = 'OK'
    $okButton.Width = 100
    $okButton.Margin = '5'
    $okButton.Add_Click({ $window.DialogResult = $true })

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Content = 'Cancel'
    $cancelButton.Width = 100
    $cancelButton.Margin = '5'
    $cancelButton.Add_Click({ $window.DialogResult = $false })

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    if (-not $NoFilePrefill) {
        $null = $buttonPanel.Children.Add($msiButton)
        $null = $buttonPanel.Children.Add($exeButton)
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

    $okButton = New-Object Windows.Controls.Button
    $okButton.Height = 40; $okButton.Width = 100; $okButton.Content = 'OK'; $okButton.Margin = '5'
    $okButton.Add_Click({ $window.DialogResult = $true })

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Height = 40; $cancelButton.Width = 100; $cancelButton.Content = 'Cancel'; $cancelButton.Margin = '5'
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

    $data = @(Load-Data)
    if ($data.Count -eq 0) {
        [System.Windows.MessageBox]::Show("The app list is empty:`n$CsvPath", 'SCCMAppHelper', 'OK', 'Information') | Out-Null
        return @()
    }

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

    $columnOrder = ($data | Select-Object -First 1).PSObject.Properties.Name | Where-Object { $_ -ne '__InternalId' }
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
            [System.Windows.MessageBox]::Show('No entries selected.', 'Hint', 'OK', 'Information') | Out-Null
            return
        }
        $confirm = [System.Windows.MessageBox]::Show('Really delete the selected entries?', 'Confirm delete', 'YesNo', 'Warning')
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
            [System.Windows.MessageBox]::Show("Saved: $ConfigPath", 'Settings', 'OK', 'Information') | Out-Null
        }
        catch {
            [System.Windows.MessageBox]::Show(("Save failed: {0}" -f $_.Exception.Message), 'Settings', 'OK', 'Error') | Out-Null
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
