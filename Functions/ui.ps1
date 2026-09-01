<#
    SCCMAppHelper - WPF dialogs
    Adapted from IntuneWin32Helper so both tools feel the same. The main window
    (Show-InventoryDialog) is where everything starts; the record editor, the
    winget picker, the retire dialog and the settings editor hang off it.
#>

Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName System.Windows.Forms  -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName UIAutomationTypes      -ErrorAction SilentlyContinue | Out-Null

#region ---------------------------------------------------------- main window

<#
    The main window: one row per application, joined from Apps.csv, the source
    share and the site by Get-AppInventory. Every action is taken from here, and
    the dialog returns the action with the selected rows rather than running it,
    so the console stays where the work is reported:

        Action     Add | NewVersion | Edit | Delete | Build | Publish | Retire |
                   OpenFolder | Tools | Refresh | Cancel | Closed
        Source     for Add and NewVersion: Winget | File | Blank
        Selection  the selected inventory rows
#>
function Show-InventoryDialog {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [string]$Title = 'SCCMAppHelper',
        [string]$SourceRoot = '',
        [bool]$SiteRead = $true
    )

    $rows = @($Inventory)

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 1420
    $window.Height = 780
    $window.MinWidth = 960
    $window.MinHeight = 520
    $window.WindowStartupLocation = 'CenterScreen'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'MainDialog')

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '12'
    foreach ($height in 'Auto', '*', 'Auto', 'Auto') {
        $row = New-Object Windows.Controls.RowDefinition
        $row.Height = $(if ($height -eq '*') { New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto })
        $null = $grid.RowDefinitions.Add($row)
    }

    # --- filter row ---
    $top = New-Object Windows.Controls.DockPanel
    $top.Margin = '0,0,0,8'

    $refreshButton = New-Object Windows.Controls.Button
    $refreshButton.Content = 'Refresh'
    $refreshButton.Padding = '14,4'
    $refreshButton.Margin = '8,0,0,0'
    $refreshButton.ToolTip = 'Read the share and the site again'
    [Windows.Automation.AutomationProperties]::SetAutomationId($refreshButton, 'Refresh')
    [Windows.Controls.DockPanel]::SetDock($refreshButton, 'Right')
    $null = $top.Children.Add($refreshButton)

    # The view: which of the three places a row has to be in. "In the site" is
    # what is deployed, "On the share" what could be, and the two combined are
    # the everyday questions this list exists to answer.
    $views = @(
        [pscustomobject]@{ Name = 'All';                                Test = { $true } },
        [pscustomobject]@{ Name = 'On the share';                       Test = { $_.HasPackage } },
        [pscustomobject]@{ Name = 'In the site';                        Test = { $_.IsPublished } },
        [pscustomobject]@{ Name = 'On the share and in the site';       Test = { $_.HasPackage -and $_.IsPublished } },
        [pscustomobject]@{ Name = 'On the share, not in the site';      Test = { $_.HasPackage -and -not $_.IsPublished } },
        [pscustomobject]@{ Name = 'In the site, not on the share';      Test = { $_.IsPublished -and -not $_.HasPackage } },
        [pscustomobject]@{ Name = 'Changed since publishing';           Test = { $_.SourceChanged } },
        [pscustomobject]@{ Name = 'Definition only';                    Test = { $_.HasDefinition -and -not $_.HasPackage -and -not $_.IsPublished } },
        [pscustomobject]@{ Name = 'Without definition';                 Test = { -not $_.HasDefinition } },
        [pscustomobject]@{ Name = 'Legacy (no PSADT)';                  Test = { $_.IsLegacy } }
    )
    $viewLabel = New-Object Windows.Controls.TextBlock
    $viewLabel.Text = 'Show:'
    $viewLabel.VerticalAlignment = 'Center'
    $viewLabel.Margin = '0,0,6,0'
    [Windows.Controls.DockPanel]::SetDock($viewLabel, 'Left')
    $null = $top.Children.Add($viewLabel)

    $viewBox = New-Object Windows.Controls.ComboBox
    $viewBox.ItemsSource = @($views | ForEach-Object { $_.Name })
    $viewBox.SelectedIndex = 0
    $viewBox.Width = 240
    $viewBox.Margin = '0,0,8,0'
    $viewBox.VerticalContentAlignment = 'Center'
    $viewBox.ToolTip = 'Only rows that are in the chosen place - the share, the site, or both'
    [Windows.Automation.AutomationProperties]::SetAutomationId($viewBox, 'View')
    [Windows.Controls.DockPanel]::SetDock($viewBox, 'Left')
    $null = $top.Children.Add($viewBox)

    $filterBox = New-Object Windows.Controls.TextBox
    $filterBox.Padding = '4'
    $filterBox.VerticalContentAlignment = 'Center'
    $filterBox.ToolTip = 'Filter - matches name, version, publisher, status and site'
    [Windows.Automation.AutomationProperties]::SetAutomationId($filterBox, 'Filter')
    $null = $top.Children.Add($filterBox)
    [Windows.Controls.Grid]::SetRow($top, 0)
    $null = $grid.Children.Add($top)

    # --- the list ---
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.GridLinesVisibility = 'Horizontal'
    $dataGrid.HeadersVisibility = 'Column'
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'InventoryGrid')

    foreach ($column in @(
            @{ Header = 'Application'; Binding = 'Name';      Width = 300 },
            @{ Header = 'Version';     Binding = 'Version';   Width = 120 },
            @{ Header = 'Publisher';   Binding = 'Publisher'; Width = 200 },
            @{ Header = 'Status';      Binding = 'Status';    Width = 190 },
            @{ Header = 'Site';        Binding = 'SiteInfo';  Width = 280 })) {
        $col = New-Object Windows.Controls.DataGridTextColumn
        $col.Header = $column.Header
        $col.Binding = New-Object Windows.Data.Binding($column.Binding)
        $col.Width = $column.Width
        $col.CanUserSort = $true

        # The status is what the list is for, so it is coloured: green is done,
        # blue is the next step, orange wants attention, red is not ours, grey
        # is not there yet.
        if ($column.Binding -eq 'Status') {
            try {
                $style = New-Object Windows.Style -ArgumentList ([Windows.Controls.DataGridCell])
                foreach ($pair in @(
                        @('Published', 'DarkGreen'),
                        @('Ready to publish', 'DodgerBlue'),
                        @('Published, changed', 'DarkOrange'),
                        @('Published, no package', 'DarkOrange'),
                        @('No installer', 'DarkOrange'),
                        @('Definition only', 'Gray'),
                        @('Foreign', 'Firebrick'),
                        @('Legacy', 'Firebrick'))) {
                    $trigger = New-Object Windows.DataTrigger
                    $trigger.Binding = New-Object Windows.Data.Binding('Status')
                    $trigger.Value = $pair[0]
                    $brush = [System.Windows.Media.Brushes]::($pair[1])
                    $null = $trigger.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.DataGridCell]::ForegroundProperty), $brush))
                    $null = $style.Triggers.Add($trigger)
                }
                $col.CellStyle = $style
            }
            catch { }
        }
        $null = $dataGrid.Columns.Add($col)
    }

    # The row tooltip spells the three states out; the dialog behind a double
    # click shows everything.
    try {
        $rowStyle = New-Object Windows.Style -ArgumentList ([Windows.Controls.DataGridRow])
        $null = $rowStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.DataGridRow]::ToolTipProperty), (New-Object Windows.Data.Binding('Detail'))))
        $dataGrid.RowStyle = $rowStyle
    }
    catch { }

    $dataGrid.ItemsSource = $rows
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    $null = $grid.Children.Add($dataGrid)

    # View and text filter are applied together, and the status line says how
    # many of the rows are showing.
    $applyFilter = {
        $view   = $views[[Math]::Max(0, $viewBox.SelectedIndex)]
        $needle = $filterBox.Text
        $items  = @($rows | Where-Object $view.Test)
        if (-not [string]::IsNullOrWhiteSpace($needle)) {
            $items = @($items | Where-Object {
                $row = $_
                @(@('Name', 'Version', 'Publisher', 'Status', 'SiteInfo') | Where-Object { [string]$row.$_ -like "*$needle*" }).Count -gt 0
            })
        }
        $dataGrid.ItemsSource = $null
        $dataGrid.ItemsSource = @($items)
        $status.Text = $(if ($items.Count -eq $rows.Count) { $summary } else { '{0} of {1} shown - {2}' -f $items.Count, $rows.Count, $summary })
    }
    $filterBox.Add_TextChanged($applyFilter)
    $viewBox.Add_SelectionChanged($applyFilter)

    # --- status line ---
    $status = New-Object Windows.Controls.TextBlock
    $status.Margin = '0,8,0,0'
    $status.Foreground = [System.Windows.Media.Brushes]::DimGray
    $status.TextWrapping = 'Wrap'
    [Windows.Automation.AutomationProperties]::SetAutomationId($status, 'Status')
    $packages  = @($rows | Where-Object { $_.HasPackage }).Count
    $published = @($rows | Where-Object { $_.IsPublished }).Count
    $changed   = @($rows | Where-Object { $_.SourceChanged }).Count
    $summary = ('{0} application(s) - {1} package(s) on {2} - {3} published{4}{5}' -f
                    $rows.Count, $packages, $SourceRoot, $published,
                    $(if ($changed) { " - $changed changed since publishing" } else { '' }),
                    $(if (-not $SiteRead) { ' - the site was not read, the site column is unknown' } else { '' }))
    $status.Text = $summary
    [Windows.Controls.Grid]::SetRow($status, 2)
    $null = $grid.Children.Add($status)

    # --- buttons ---
    $bar = New-Object Windows.Controls.DockPanel
    $bar.Margin = '0,12,0,0'
    $bar.LastChildFill = $false

    $left = New-Object Windows.Controls.StackPanel
    $left.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($left, 'Left')
    $right = New-Object Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($right, 'Right')
    $null = $bar.Children.Add($left)
    $null = $bar.Children.Add($right)
    [Windows.Controls.Grid]::SetRow($bar, 3)
    $null = $grid.Children.Add($bar)

    $window.Tag = $null
    $choose = {
        param([string]$action, [string]$source)
        $selected = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        if ($action -in 'NewVersion', 'Edit', 'Delete', 'Build', 'Publish' -and $selected.Count -eq 0) {
            $null = Show-MessageDialog -Text 'Select one or more rows first.' -Caption 'SCCMAppHelper' -Buttons 'OK' -Icon 'Information' -Owner $window
            return
        }
        $window.Tag = [pscustomobject]@{ Action = $action; Source = $source; Selection = $selected }
        $window.Close()
    }

    $newButton = {
        param([string]$caption, [string]$id, [string]$tip, $panel)
        $button = New-Object Windows.Controls.Button
        $button.Content = $caption
        $button.Padding = '14,6'
        $button.Margin = '0,0,8,0'
        $button.ToolTip = $tip
        $button.Tag = $id
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, $id)
        $null = $panel.Children.Add($button)
        return $button
    }

    # Settings gear, as before.
    $settingsButton = New-Object Windows.Controls.Button
    $settingsButton.ToolTip = 'Settings'
    $settingsButton.Padding = '10,4'
    $settingsButton.Margin = '0,0,8,0'
    $settingsButton.MinWidth = 40
    [Windows.Automation.AutomationProperties]::SetAutomationId($settingsButton, 'Settings')
    $settingsIcon = New-Object Windows.Controls.TextBlock
    $settingsIcon.Text = [char]0xE713
    $settingsIcon.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $settingsIcon.FontSize = 16
    $settingsIcon.Foreground = [System.Windows.Media.Brushes]::Gray
    $settingsButton.Content = $settingsIcon
    $null = $left.Children.Add($settingsButton)
    $settingsButton.Add_Click({
        try { $null = Edit-SettingsDialog -Owner $window -ConfigPath (Join-Path $rootDir 'Config\config.json') }
        catch { $null = Show-MessageDialog -Text ("Error while opening the settings: {0}" -f $_.Exception.Message) -Caption 'Settings' -Buttons 'OK' -Icon 'Error' -Owner $window }
    })

    $toolsButton   = & $newButton 'Tools...'      'Tools'      'Collection maintenance, retire, site setup' $left
    $folderButton  = & $newButton 'Open folder'   'OpenFolder' 'Open the package folder of the selected row, or the share' $left

    $addButton     = & $newButton 'Add...'              'Add'        'Add an application: from winget, from an installer file, or a blank record' $right
    $versionButton = & $newButton 'New version...'      'NewVersion' 'The selected application in a newer version - resolved from winget, or from a file' $right
    $editButton    = & $newButton 'Edit'                'Edit'       'Edit the definition; a package that exists is rebuilt from it' $right
    $deleteButton  = & $newButton 'Delete definition'   'Delete'     'Remove the row from Apps.csv - the package and the application stay' $right
    $buildButton   = & $newButton 'Build package'       'Build'      'Create or refresh the package on the share from the definition' $right
    $publishButton = & $newButton 'Publish'             'Publish'    'Create or update the application in ConfigMgr: deployment type, content, collections, deployments, supersedence' $right
    $retireButton  = & $newButton 'Retire...'           'Retire'     'Stop deploying a version, or delete it and everything that belongs to it' $right
    $closeButton   = & $newButton 'Close'               'Cancel'     'Close the tool' $right
    $closeButton.Margin = '0'
    $closeButton.IsCancel = $true

    # Add and New version fan out into the three installer sources.
    foreach ($owner in @($addButton, $versionButton)) {
        $menu = New-Object Windows.Controls.ContextMenu
        foreach ($source in @(@('From winget...', 'Winget'), @('From file (MSI or EXE)...', 'File'), @('Blank record', 'Blank'))) {
            $item = New-Object Windows.Controls.MenuItem
            $item.Header = $source[0]
            $item.Tag = '{0}|{1}' -f [string]$owner.Tag, $source[1]
            [Windows.Automation.AutomationProperties]::SetAutomationId($item, ('{0}{1}' -f [string]$owner.Tag, $source[1]))
            $item.Add_Click({ param($s, $e) $parts = ([string]$s.Tag).Split('|'); & $choose $parts[0] $parts[1] })
            $null = $menu.Items.Add($item)
        }
        $menu.PlacementTarget = $owner
        $menu.Placement = 'Bottom'
        $owner.ContextMenu = $menu
        $owner.Add_Click({ param($s, $e) $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.IsOpen = $true })
    }

    $editButton.Add_Click({    & $choose 'Edit'       '' })
    $deleteButton.Add_Click({  & $choose 'Delete'     '' })
    $buildButton.Add_Click({   & $choose 'Build'      '' })
    $publishButton.Add_Click({ & $choose 'Publish'    '' })
    $retireButton.Add_Click({  & $choose 'Retire'     '' })
    $folderButton.Add_Click({  & $choose 'OpenFolder' '' })
    $toolsButton.Add_Click({   & $choose 'Tools'      '' })
    $refreshButton.Add_Click({ & $choose 'Refresh'    '' })
    $closeButton.Add_Click({   & $choose 'Cancel'     '' })
    $dataGrid.Add_MouseDoubleClick({ if ($dataGrid.SelectedItem) { & $choose 'Edit' '' } })

    # What can be done follows from what is selected.
    $syncButtons = {
        $selected = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        $one = ($selected.Count -eq 1)
        # A legacy folder - no PSADT script - is shown and not touched: nothing
        # can be read from it, nothing written into it.
        $usable = @($selected | Where-Object { -not $_.IsLegacy -or $_.HasDefinition })
        $editButton.IsEnabled    = $one -and ($usable.Count -eq 1)
        $versionButton.IsEnabled = $one
        $deleteButton.IsEnabled  = (@($selected | Where-Object { $_.HasDefinition }).Count -gt 0)
        $buildButton.IsEnabled   = (@($usable | Where-Object { $_.HasDefinition -or $_.HasPackage }).Count -gt 0)
        $publishButton.IsEnabled = (@($usable | Where-Object { -not $_.IsLegacy -and ($_.HasDefinition -or $_.HasPackage) }).Count -gt 0)
    }
    & $syncButtons
    $dataGrid.Add_SelectionChanged($syncButtons)

    $window.Content = $grid
    $window.Add_Closing({ if ($null -eq $window.Tag) { $window.Tag = [pscustomobject]@{ Action = 'Closed'; Source = ''; Selection = @() } } })

    $null = $window.ShowDialog()
    return $window.Tag
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

<#
    The record editor. Returns the fields as an ordered hashtable, or nothing
    when cancelled.

    A file picked through From MSI, From EXE or From winget is remembered in
    $script:EditDialogInstallerPath, so the caller can put it into the package -
    the return value stays the record and nothing else, because every caller
    writes its keys straight into an Apps.csv row.
#>
function Open-EditDialog {
    param(
        [hashtable]$item,
        [string]$title,
        [string[]]$PropertyOrder,
        # Setup dialogs are not about a setup file - hides "From MSI/EXE".
        [switch]$NoFilePrefill,
        # Read-only facts shown above the fields: status, package, site - what
        # the main list keeps out of its columns.
        [System.Collections.IDictionary]$Info,
        # Only the facts, no fields: a legacy folder has nothing to edit.
        [switch]$ReadOnly
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

    if ($Info -and $Info.Count -gt 0) {
        $infoBorder = New-Object Windows.Controls.Border
        $infoBorder.Background = [System.Windows.Media.Brushes]::WhiteSmoke
        $infoBorder.BorderBrush = [System.Windows.Media.Brushes]::LightGray
        $infoBorder.BorderThickness = '1'
        $infoBorder.CornerRadius = '4'
        $infoBorder.Padding = '10,8'
        $infoBorder.Margin = '0,0,0,12'
        [Windows.Automation.AutomationProperties]::SetAutomationId($infoBorder, 'Info')

        $infoGrid = New-Object Windows.Controls.Grid
        $infoLabelColumn = New-Object Windows.Controls.ColumnDefinition
        $infoLabelColumn.Width = New-Object Windows.GridLength -ArgumentList 100
        $infoValueColumn = New-Object Windows.Controls.ColumnDefinition
        $infoValueColumn.Width = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
        $null = $infoGrid.ColumnDefinitions.Add($infoLabelColumn)
        $null = $infoGrid.ColumnDefinitions.Add($infoValueColumn)

        $infoRow = 0
        foreach ($infoKey in $Info.Keys) {
            $rowDefinition = New-Object Windows.Controls.RowDefinition
            $rowDefinition.Height = [Windows.GridLength]::Auto
            $null = $infoGrid.RowDefinitions.Add($rowDefinition)

            $infoLabel = New-Object Windows.Controls.TextBlock
            $infoLabel.Text = $infoKey
            $infoLabel.Foreground = [System.Windows.Media.Brushes]::DimGray
            $infoLabel.Margin = '0,1,8,1'
            [Windows.Controls.Grid]::SetRow($infoLabel, $infoRow)
            [Windows.Controls.Grid]::SetColumn($infoLabel, 0)
            $null = $infoGrid.Children.Add($infoLabel)

            $infoValue = New-Object Windows.Controls.TextBox
            $infoValue.Text = [string]$Info[$infoKey]
            $infoValue.IsReadOnly = $true
            $infoValue.BorderThickness = '0'
            $infoValue.Background = [System.Windows.Media.Brushes]::Transparent
            $infoValue.TextWrapping = 'Wrap'
            $infoValue.Margin = '0,1,0,1'
            [Windows.Automation.AutomationProperties]::SetAutomationId($infoValue, 'Info' + $infoKey)
            [Windows.Controls.Grid]::SetRow($infoValue, $infoRow)
            [Windows.Controls.Grid]::SetColumn($infoValue, 1)
            $null = $infoGrid.Children.Add($infoValue)
            $infoRow++
        }
        $infoBorder.Child = $infoGrid
        $null = $stackPanel.Children.Add($infoBorder)
    }

    $textBoxes = @{}
    $keys = if ($PropertyOrder) { $PropertyOrder } elseif ($item) { $item.Keys } else { @() }
    if ($ReadOnly) { $keys = @() }
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
                $script:EditDialogInstallerPath = $ofd.FileName
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
                $script:EditDialogInstallerPath = $ofd.FileName
                $props = Get-ExeProperties -Path $ofd.FileName
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Name', 'DisplayName', 'ProductName') -Value $props['ProductName']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Version', 'ProductVersion')           -Value $props['ProductVersion']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('Publisher', 'Vendor', 'Manufacturer') -Value $props['Manufacturer']
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('DetectionMethod')                     -Value 'Registry'
                Set-IfPresent -TextBoxes $textBoxes -CandidateKeys @('InstallCmd') -Value ("Start-ADTProcess -FilePath '{0}' -ArgumentList '/S' -WindowStyle 'Hidden'" -f (Split-Path -Leaf $ofd.FileName))

                # /S is a guess and it is only right for NSIS. A version resource
                # does not say which installer kind built the file, so the switch
                # cannot be derived from what was just read - and the wrong one
                # does not fail loudly: the installer ignores it, waits for a
                # click nobody can give it in session 0, and the deployment sits
                # at "in progress" until it times out.
                if ($textBoxes.Contains('InstallCmd')) {
                    $textBoxes['InstallCmd'].ToolTip = 'The silent switch depends on the installer kind - /S fits NSIS, and is only a guess here.'
                }
                $null = Show-MessageDialog -Owner $window -Caption 'From EXE' -Buttons 'OK' -Icon 'Warning' -Text (
                    "The install command was filled in with /S. That is the NSIS switch, and it is a guess: " +
                    "an EXE does not say which installer built it.`n`n" +
                    "Check it against the installer:`n" +
                    "    NSIS                    /S`n" +
                    "    Inno Setup              /VERYSILENT /NORESTART`n" +
                    "    Burn, Visual Studio     --quiet --norestart --wait`n" +
                    "    InstallShield           /s /v`"/qn`"`n`n" +
                    "The wrong switch does not fail loudly. The installer ignores it and waits for a click, " +
                    "which nobody can give it when it runs as SYSTEM - the deployment then sits at " +
                    "`"in progress`" until it times out.`n`n" +
                    "For a Visual Studio style bootstrapper --wait matters as much as the silent switch: " +
                    "without it the bootstrapper returns before the installation has finished, and detection " +
                    "runs against a half installed product.")
            }
        }
        catch { $null = Show-MessageDialog -Text ("EXE could not be read: {0}" -f $_.Exception.Message) -Caption 'EXE' -Buttons 'OK' -Icon 'Error' }
    })

    # The third prefill source. From MSI and From EXE read a file the user
    # picked; this one picks the file for them first, out of the winget-pkgs
    # manifests, and then reads it exactly the same way.
    $catalogButton = New-Object Windows.Controls.Button
    $catalogButton.Content = 'From winget...'
    $catalogButton.Width = 120
    $catalogButton.Margin = '5'
    [Windows.Automation.AutomationProperties]::SetAutomationId($catalogButton, 'FromWinget')
    $catalogButton.Add_Click({
        try {
            $found = Read-CatalogPackage
            if (-not $found) { return }
            $script:EditDialogInstallerPath = $found.File

            # Every field, empty ones included - Set-IfPresent skips blanks,
            # which is right for a partial prefill from a file the user picked
            # but wrong here: the catalog replaces the whole record, and a value
            # the previous package left behind has nothing to do with this one.
            foreach ($column in 'Publisher', 'Name', 'Version', 'DetectionMethod',
                                'DetectionPattern', 'ProductCode', 'InstallCmd', 'UninstallCmd', 'Notes') {
                if ($textBoxes.Contains($column)) { $textBoxes[$column].Text = [string]$found.Row.$column }
            }

            $null = Show-MessageDialog -Text ("{0} {1} is ready.`n`nThe installer is here:`n{2}`n`nSignature: {3}`n`nIt goes into Files when the record is saved." -f
                        $found.Row.Name, $found.Row.Version, $found.File, $found.Signature) `
                    -Caption 'From winget' -Buttons 'OK' -Icon 'Information'
        }
        catch { $null = Show-MessageDialog -Text ("winget-pkgs could not be read: {0}" -f $_.Exception.Message) -Caption 'From winget' -Buttons 'OK' -Icon 'Warning' }
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
    if (-not $NoFilePrefill -and -not $ReadOnly) {
        $null = $buttonPanel.Children.Add($msiButton)
        $null = $buttonPanel.Children.Add($exeButton)
        $null = $buttonPanel.Children.Add($catalogButton)
    }
    if ($ReadOnly) { $cancelButton.Content = 'Close' } else { $null = $buttonPanel.Children.Add($okButton) }
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

    # --- tab 2: the per-application collections ------------------------------
    # One line per entry of "collections": name pattern, purpose, notification
    # and the console folder. Required and available collections usually live
    # in different folders, which is what the folder column is for; empty
    # falls back to collectionFolderPath of the site.
    $collectionRows  = New-Object System.Collections.ArrayList
    $collectionPanel = New-Object Windows.Controls.StackPanel
    $collectionPanel.Margin = '10'

    $collectionHint = New-Object Windows.Controls.TextBlock
    $collectionHint.TextWrapping = 'Wrap'
    $collectionHint.Foreground = [System.Windows.Media.Brushes]::DimGray
    $collectionHint.Margin = '0,0,0,8'
    $collectionHint.Text = 'One collection per line is created for every application. {App} in the name becomes "Name - Version". ' +
                           'Folder is the console folder below DeviceCollection, e.g. Deployment\Required - empty means collectionFolderPath of the site. ' +
                           'A line with an empty name is dropped on save.'
    $null = $collectionPanel.Children.Add($collectionHint)

    $collectionHeader = New-Object Windows.Controls.Grid
    foreach ($width in 260, 110, 130, 260) {
        $column = New-Object Windows.Controls.ColumnDefinition
        $column.Width = New-Object Windows.GridLength -ArgumentList $width
        $null = $collectionHeader.ColumnDefinitions.Add($column)
    }
    $headerIndex = 0
    foreach ($caption in 'Name pattern', 'Purpose', 'User notification', 'Folder') {
        $text = New-Object Windows.Controls.TextBlock
        $text.Text = $caption
        $text.FontWeight = 'Bold'
        $text.Margin = '2,0,8,4'
        [Windows.Controls.Grid]::SetColumn($text, $headerIndex)
        $null = $collectionHeader.Children.Add($text)
        $headerIndex++
    }
    $null = $collectionPanel.Children.Add($collectionHeader)

    $collectionLines = New-Object Windows.Controls.StackPanel
    $null = $collectionPanel.Children.Add($collectionLines)

    $addCollectionLine = {
        param($entry)
        $line = New-Object Windows.Controls.Grid
        $line.Margin = '0,0,0,4'
        foreach ($width in 260, 110, 130, 260) {
            $column = New-Object Windows.Controls.ColumnDefinition
            $column.Width = New-Object Windows.GridLength -ArgumentList $width
            $null = $line.ColumnDefinitions.Add($column)
        }

        $nameBox = New-Object Windows.Controls.TextBox
        $nameBox.Text = [string]$entry.namePattern
        $nameBox.Margin = '0,0,8,0'
        [Windows.Controls.Grid]::SetColumn($nameBox, 0)

        $purposeBox = New-Object Windows.Controls.ComboBox
        $purposeBox.ItemsSource = @('Required', 'Available')
        $purposeBox.IsEditable = $true
        $purposeBox.Text = [string]$entry.deployPurpose
        $purposeBox.Margin = '0,0,8,0'
        [Windows.Controls.Grid]::SetColumn($purposeBox, 1)

        $notifyBox = New-Object Windows.Controls.ComboBox
        $notifyBox.ItemsSource = @('DisplayAll', 'DisplaySoftwareCenterOnly', 'HideAll')
        $notifyBox.IsEditable = $true
        $notifyBox.Text = [string]$entry.userNotification
        $notifyBox.Margin = '0,0,8,0'
        [Windows.Controls.Grid]::SetColumn($notifyBox, 2)

        $folderBox = New-Object Windows.Controls.TextBox
        $folderBox.Text = $(if ($entry.PSObject.Properties.Name -contains 'folderPath') { [string]$entry.folderPath } else { '' })
        $folderBox.Margin = '0,0,8,0'
        [Windows.Controls.Grid]::SetColumn($folderBox, 3)

        foreach ($control in @($nameBox, $purposeBox, $notifyBox, $folderBox)) { $null = $line.Children.Add($control) }
        $null = $collectionLines.Children.Add($line)
        $null = $collectionRows.Add([pscustomobject]@{ Name = $nameBox; Purpose = $purposeBox; Notify = $notifyBox; Folder = $folderBox })
    }

    foreach ($entry in @($config.collections)) { if ($entry) { & $addCollectionLine $entry } }

    $addCollectionButton = New-Object Windows.Controls.Button
    $addCollectionButton.Content = 'Add line'
    $addCollectionButton.Padding = '12,4'
    $addCollectionButton.HorizontalAlignment = 'Left'
    $addCollectionButton.Margin = '0,6,0,0'
    [Windows.Automation.AutomationProperties]::SetAutomationId($addCollectionButton, 'AddCollection')
    $addCollectionButton.Add_Click({
        & $addCollectionLine ([pscustomobject]@{ namePattern = ''; deployPurpose = 'Available'; userNotification = 'DisplayAll'; folderPath = '' })
    })
    $null = $collectionPanel.Children.Add($addCollectionButton)

    $collectionScroll = New-Object Windows.Controls.ScrollViewer
    $collectionScroll.VerticalScrollBarVisibility = 'Auto'
    $collectionScroll.Content = $collectionPanel

    $tabCollections = New-Object Windows.Controls.TabItem
    $tabCollections.Header = 'Collections'
    $tabCollections.Content = $collectionScroll
    $null = $tabs.Items.Add($tabCollections)

    # --- tab 3: the remaining complex values as JSON --------------------------
    $complexKeys = $config.PSObject.Properties | Where-Object { $_.Name -notin $scalarKeys -and $_.Name -ne 'collections' } | Select-Object -ExpandProperty Name

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
    $tabAdvanced.Header = 'Deployments and sites (JSON)'
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

            $collections = @()
            foreach ($line in $collectionRows) {
                if ([string]::IsNullOrWhiteSpace($line.Name.Text)) { continue }
                $collections += [pscustomobject]@{
                    namePattern      = $line.Name.Text.Trim()
                    deployPurpose    = $line.Purpose.Text.Trim()
                    userNotification = $line.Notify.Text.Trim()
                    folderPath       = $line.Folder.Text.Trim()
                }
            }
            $result['collections'] = $collections

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
        [string]$Title = 'From winget-pkgs',
        # Prefills the search box - "New version" of a product the curated list
        # does not know by name.
        [string]$Query = ''
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
    $searchBox.Text = $Query
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
            $null = Show-MessageDialog -Text 'Nothing selected.' -Caption 'From winget-pkgs' -Buttons 'OK' -Icon 'Information' -Owner $window
            return
        }
        try {
            $added = Add-CatalogEntry -Name ([string]$picked.Name) -PackageId ([string]$picked.PackageId)
            $null = Show-MessageDialog -Owner $window -Caption 'From winget-pkgs' -Buttons 'OK' -Icon 'Information' -Text $(
                if ($added) { "$($picked.PackageId) is in the catalog now, and will be found by name next time." }
                else        { "$($picked.PackageId) was already in the catalog." })
        }
        catch { $null = Show-MessageDialog -Text $_.Exception.Message -Caption 'From winget-pkgs' -Buttons 'OK' -Icon 'Warning' -Owner $window }
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
                $null = Show-MessageDialog -Owner $window -Caption 'From winget-pkgs' -Buttons 'OK' -Icon 'Information' -Text (
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
            $null = Show-MessageDialog -Text $_.Exception.Message -Caption 'From winget-pkgs' -Buttons 'OK' -Icon 'Warning' -Owner $window
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
