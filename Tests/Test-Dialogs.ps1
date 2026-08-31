<#
.SYNOPSIS
    Drives the SCCMAppHelper dialogs through UI Automation.

.DESCRIPTION
    Starts the tool in a second process and operates it the way a person would:
    presses the tiles, works through the dialogs behind them, and checks what
    comes back.

    The catalog leg really downloads an installer and really appends a row to
    Apps.csv - that is what the feature does, and a test that stopped short of
    it would not be testing much. Both are easy to undo: delete the row, delete
    the folder under _DL.

    Needs a reachable ConfigMgr site, because the package list asks the site for
    its status column, and network access for the catalog leg.

.NOTES
    Windows PowerShell 5.1. The tool is started with -STA as WPF requires; this
    script does not have to be.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Tests\Test-Dialogs.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Tests\Test-Dialogs.ps1 -SkipCatalog
#>

[CmdletBinding()]
param(
    [string]$ToolPath,
    [int]$TimeoutSeconds = 120,

    # The catalog leg reaches out to GitHub, downloads an installer and writes a
    # row. Leave it out to keep the run offline and read only.
    [switch]$SkipCatalog,

    # Small, an MSI, and not usually in Apps.csv - so the row it writes proves
    # something.
    [string]$CatalogPackage = 'PuTTY'
)

# $PSScriptRoot is not populated while the param block is being bound.
if (-not $ToolPath) { $ToolPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'start-SCCMAppHelper.ps1' }

Import-Module (Join-Path $PSScriptRoot 'UiAutomation.psm1') -Force

$script:Passed = 0
$script:Failed = 0

function Test-That {
    param([string]$Name, [bool]$Condition, [string]$Detail)

    if ($Condition) {
        $script:Passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkGray }
    }
}

<#
    The catalog as a prefill source: press "From catalog...", pick a package,
    take the newest installer, confirm the download, and check that the record
    comes back filled and reaches Apps.csv.
#>
function Test-CatalogPrefill {
    param($Tool, $Editor, [string]$Package, [string]$AppListCsv)

    Write-Host "`nFrom catalog" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $Editor -AutomationId 'FromCatalog')

    $catalog = Wait-UiaWindow -ProcessId $Tool.Id -AutomationId 'CatalogDialog' -TimeoutSeconds 60
    Test-That 'the catalog dialog appears' ($null -ne $catalog)
    if (-not $catalog) { return }

    Test-That 'the curated list is not empty' ((Get-UiaElement -Root $catalog -ControlType DataItem).Count -gt 0)

    Test-That 'the catalog dialog offers Remember' ($null -ne (Find-UiaElement -Root $catalog -AutomationId 'Remember' -TimeoutSeconds 3))

    $picked = Select-UiaRow -Root $catalog -Match $Package
    Test-That "[$Package] can be selected" ($null -ne $picked)
    if (-not $picked) { return }
    Invoke-UiaElement -Element (Find-UiaElement -Root $catalog -AutomationId 'Next')

    # A manifest usually offers several installers, which brings up the ordinary
    # selection dialog; the first row is the one the tool ranks highest.
    $installer = Wait-UiaWindow -ProcessId $Tool.Id -AutomationId 'SelectDialog' -TimeoutSeconds 90
    if ($installer) {
        $first = (Get-UiaElement -Root $installer -ControlType DataItem)[0]
        Test-That 'the installer picker offers installers' ($null -ne $first) $(if ($first) { $first.Current.Name })
        if ($first) {
            $first.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
            Invoke-UiaElement -Element (Find-UiaElement -Root $installer -AutomationId 'OK')
        }
    }

    $confirm = Wait-UiaWindow -ProcessId $Tool.Id -AutomationId 'MessageDialog' -TimeoutSeconds 60
    Test-That 'the download is confirmed before it starts' ($null -ne $confirm)
    if ($confirm) {
        $text = Find-UiaElement -Root $confirm -AutomationId 'MessageText' -TimeoutSeconds 5
        Test-That 'the confirmation names the hash' ($text -and $text.Current.Name -match 'SHA256')
        Invoke-UiaElement -Element (Find-UiaElement -Root $confirm -AutomationId 'Yes')
    }

    # Download, hash check and reading the installer happen here.
    $report = Wait-UiaWindow -ProcessId $Tool.Id -AutomationId 'MessageDialog' -TimeoutSeconds 300
    Test-That 'the download reports back' ($null -ne $report)
    if ($report) {
        $text = Find-UiaElement -Root $report -AutomationId 'MessageText' -TimeoutSeconds 5
        Test-That 'the report names the download folder' ($text -and $text.Current.Name -match '_DL')
        Invoke-UiaElement -Element (Find-UiaElement -Root $report -AutomationId 'OK')
    }

    # Back in the editor, which should now be filled in.
    $recordName = $null
    foreach ($field in 'Publisher', 'Name', 'Version', 'DetectionMethod') {
        $box = Find-UiaElement -Root $Editor -AutomationId $field -TimeoutSeconds 10
        $value = $(if ($box) { $box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value } else { '' })
        if ($field -eq 'Name') { $recordName = $value }
        Test-That "the catalog filled in $field" (-not [string]::IsNullOrWhiteSpace($value)) "value: [$value]"
    }

    Invoke-UiaElement -Element (Find-UiaElement -Root $Editor -AutomationId 'OK')

    if ($recordName) {
        Start-Sleep -Seconds 2
        $rows = @(Import-Csv -LiteralPath $AppListCsv -Delimiter ';' | Where-Object { $_.Name -eq $recordName })
        Test-That "Apps.csv holds a row for [$recordName]" ($rows.Count -gt 0)
        Test-That 'the row carries a detection method' (@($rows | Where-Object { $_.DetectionMethod }).Count -gt 0) `
            (($rows | ForEach-Object { "$($_.Version) / $($_.DetectionMethod)" }) -join ', ')
    }
}

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Tool not found: $ToolPath" }
$appListCsv = Join-Path (Split-Path -Parent $ToolPath) 'Apps.csv'

Write-Host "Starting $ToolPath" -ForegroundColor Cyan
$tool = Start-Process powershell.exe -PassThru -WorkingDirectory (Split-Path -Parent $ToolPath) -ArgumentList @(
    '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolPath)

try {
    # ------------------------------------------------------------ start dialog
    Write-Host "`nStart dialog" -ForegroundColor Cyan
    $start = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'StartDialog' -TimeoutSeconds $TimeoutSeconds
    Test-That 'the start dialog appears' ($null -ne $start)
    if (-not $start) { return }

    foreach ($id in 'CreateNew', 'CreateNewAndPublish', 'PublishExisting', 'Tools') {
        $tile = Find-UiaElement -Root $start -AutomationId $id -TimeoutSeconds 5
        Test-That "tile [$id] is present" ($null -ne $tile)
        if ($tile) {
            $invokable = @($tile.GetSupportedPatterns() | Where-Object { $_.ProgrammaticName -like 'Invoke*' }).Count -gt 0
            Test-That "tile [$id] can be invoked"       $invokable
            Test-That "tile [$id] takes keyboard focus" $tile.Current.IsKeyboardFocusable
        }
    }

    # -------------------------------------------------------- publish packages
    Write-Host "`nPublish packages" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $start -AutomationId 'PublishExisting')

    $select = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'SelectDialog' -TimeoutSeconds $TimeoutSeconds
    Test-That 'the package selection dialog appears' ($null -ne $select)
    if ($select) {
        $rows = Get-UiaElement -Root $select -ControlType DataItem
        Test-That 'the package list is not empty' ($rows.Count -gt 0) "rows: $($rows.Count)"
        Test-That 'the rows carry a status' (@($rows | Where-Object { $_.Current.Name -match 'Status=' }).Count -gt 0)
        Invoke-UiaElement -Element (Find-UiaElement -Root $select -AutomationId 'Cancel')
    }

    $start = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'StartDialog' -TimeoutSeconds 60
    Test-That 'cancelling returns to the start dialog' ($null -ne $start)
    if (-not $start) { return }

    # --------------------------------------------------------- create packages
    Write-Host "`nCreate packages" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $start -AutomationId 'CreateNew')

    $appList = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'AppListDialog' -TimeoutSeconds $TimeoutSeconds
    Test-That 'the app list dialog appears' ($null -ne $appList)
    if ($appList) {
        $rows = Get-UiaElement -Root $appList -ControlType DataItem
        Write-Host ("        the app list holds {0} row(s)" -f $rows.Count) -ForegroundColor DarkGray
        foreach ($id in 'New', 'Edit', 'Duplicate', 'Delete', 'OK', 'Cancel') {
            Test-That "app list button [$id] is present" ($null -ne (Find-UiaElement -Root $appList -AutomationId $id -TimeoutSeconds 3))
        }

        # Delete with nothing selected only complains, and that complaint is the
        # tool's own message dialog - a Win32 one could not be driven at all.
        Invoke-UiaElement -Element (Find-UiaElement -Root $appList -AutomationId 'Delete')
        $message = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'MessageDialog' -TimeoutSeconds 20
        Test-That 'the message dialog appears' ($null -ne $message)
        if ($message) {
            $text = Find-UiaElement -Root $message -AutomationId 'MessageText' -TimeoutSeconds 5
            Test-That 'the message dialog carries its text' ($null -ne $text) $(if ($text) { $text.Current.Name })
            Test-That 'the message dialog has an OK button' ($null -ne (Find-UiaElement -Root $message -AutomationId 'OK' -TimeoutSeconds 5))
            Invoke-UiaElement -Element (Find-UiaElement -Root $message -AutomationId 'OK')
        }

        # -------------------------------------------------------- record editor
        Invoke-UiaElement -Element (Find-UiaElement -Root $appList -AutomationId 'New')
        $editor = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'EditDialog' -TimeoutSeconds 30
        Test-That 'the record editor appears' ($null -ne $editor)

        if ($editor) {
            # By id rather than by control type: DetectionMethod is a combo box,
            # not a text box, and an editable combo box brings its own inner edit
            # control along, so counting types is not a stable check.
            $missing = @()
            foreach ($field in 'Publisher', 'Name', 'Version', 'DetectionMethod', 'DetectionPattern',
                               'ProductCode', 'InstallCmd', 'UninstallCmd', 'Notes') {
                if (-not (Find-UiaElement -Root $editor -AutomationId $field -TimeoutSeconds 3)) { $missing += $field }
            }
            Test-That 'the editor shows all nine columns' ($missing.Count -eq 0) "missing: $($missing -join ', ')"
            Test-That 'DetectionMethod is a list' ((Find-UiaElement -Root $editor -AutomationId 'DetectionMethod' -TimeoutSeconds 3).Current.ControlType.ProgrammaticName -match 'ComboBox')
            Test-That 'DetectionPattern has a hint' ($null -ne (Find-UiaElement -Root $editor -AutomationId 'DetectionPatternHint' -TimeoutSeconds 3))
            foreach ($id in 'FromMsi', 'FromExe', 'FromCatalog') {
                Test-That "prefill button [$id] is present" ($null -ne (Find-UiaElement -Root $editor -AutomationId $id -TimeoutSeconds 3))
            }

            if ($SkipCatalog) { Invoke-UiaElement -Element (Find-UiaElement -Root $editor -AutomationId 'Cancel') }
            else { Test-CatalogPrefill -Tool $tool -Editor $editor -Package $CatalogPackage -AppListCsv $appListCsv }
        }

        $appList = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'AppListDialog' -TimeoutSeconds 60
        Test-That 'the app list is back' ($null -ne $appList)
        if ($appList) { Invoke-UiaElement -Element (Find-UiaElement -Root $appList -AutomationId 'Cancel') }
    }

    $start = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'StartDialog' -TimeoutSeconds 60
    Test-That 'cancelling returns to the start dialog again' ($null -ne $start)

    # ------------------------------------------------------------------- close
    Write-Host "`nClosing" -ForegroundColor Cyan
    if ($start) { Invoke-UiaElement -Element (Find-UiaElement -Root $start -AutomationId 'Cancel') }

    for ($i = 0; $i -lt 60 -and -not $tool.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    Test-That 'the tool exits on Cancel' $tool.HasExited
}
finally {
    if (-not $tool.HasExited) {
        Write-Host 'The tool was still running - killing it.' -ForegroundColor Yellow
        $tool.Kill()
    }
    Write-Host ("`n{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
}

exit $(if ($script:Failed) { 1 } else { 0 })
