<#
.SYNOPSIS
    Drives the SCCMAppHelper dialogs through UI Automation.

.DESCRIPTION
    Starts the tool in a second process and operates it the way a person would:
    checks the main window and its buttons, opens the record editor through
    Add -> Blank record, and cancels back out.

    The winget leg really downloads an installer, really writes a row into
    Apps.csv and really builds a package on the share - that is what the feature
    does, and a test that stopped short of it would not be testing much. All of
    it is easy to undo: delete the row, delete the package folder.

    Needs a reachable ConfigMgr site, because the main window asks the site for
    its site column, and network access for the winget leg.

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

    # The winget leg reaches out to GitHub, downloads an installer, writes a
    # row and builds a package. Leave it out to keep the run offline and read
    # only.
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
    winget as a source: press "From winget..." in the record editor, pick a
    package, take the newest installer, confirm the download, and check that the
    record comes back filled, reaches Apps.csv and becomes a package on the
    share with the installer in Files.
#>
function Test-CatalogPrefill {
    param($Tool, $Editor, [string]$Package, [string]$AppListCsv, [string]$SourceRoot)

    Write-Host "`nFrom winget" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $Editor -AutomationId 'FromWinget')

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
        Test-That 'the report says the file goes into Files' ($text -and $text.Current.Name -match 'Files')
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
        # OK writes the row and builds the package; PSADT's template takes a
        # moment, so the main window is waited for rather than a fixed sleep.
        $null = Wait-UiaWindow -ProcessId $Tool.Id -AutomationId 'MainDialog' -TimeoutSeconds 180
        $rows = @(Import-Csv -LiteralPath $AppListCsv -Delimiter ';' | Where-Object { $_.Name -eq $recordName })
        Test-That "Apps.csv holds a row for [$recordName]" ($rows.Count -gt 0)
        Test-That 'the row carries a detection method' (@($rows | Where-Object { $_.DetectionMethod }).Count -gt 0) `
            (($rows | ForEach-Object { "$($_.Version) / $($_.DetectionMethod)" }) -join ', ')

        if ($SourceRoot -and $rows.Count -gt 0) {
            $version = ($rows | Select-Object -Last 1).Version
            $packageRoot = Join-Path $SourceRoot ('{0} - {1}' -f $recordName, $version)
            Test-That "the package folder exists: $packageRoot" (Test-Path -LiteralPath $packageRoot)
            $files = @()
            foreach ($candidate in @((Join-Path $packageRoot 'Files'), (Join-Path $packageRoot 'Content\Files'))) {
                if (Test-Path -LiteralPath $candidate) { $files = @(Get-ChildItem -LiteralPath $candidate -File) }
            }
            Test-That 'the installer is in Files' ($files.Count -gt 0) (($files | ForEach-Object { $_.Name }) -join ', ')
        }
    }
}

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Tool not found: $ToolPath" }
$toolRoot   = Split-Path -Parent $ToolPath
$appListCsv = Join-Path $toolRoot 'Apps.csv'

# Where the packages land, for the winget leg - read the way the tool reads it.
$sourceRoot = ''
try {
    $config = Get-Content -Raw -LiteralPath (Join-Path $toolRoot 'Config\config.json') -Encoding UTF8 | ConvertFrom-Json
    $site = $null
    if ($config.sites) {
        $site = @($config.sites | Where-Object { $_.name -eq $config.activeSite -or $_.siteCode -eq $config.activeSite })[0]
        if (-not $site) { $site = @($config.sites)[0] }
    }
    else { $site = $config }
    foreach ($candidate in @($site.sourceRootLocal, $site.sourceRoot)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $sourceRoot = $candidate; break }
    }
}
catch { }

Write-Host "Starting $ToolPath" -ForegroundColor Cyan
$tool = Start-Process powershell.exe -PassThru -WorkingDirectory $toolRoot -ArgumentList @(
    '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolPath)

try {
    # ------------------------------------------------------------- main window
    Write-Host "`nMain window" -ForegroundColor Cyan
    $main = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'MainDialog' -TimeoutSeconds $TimeoutSeconds
    Test-That 'the main window appears' ($null -ne $main)
    if (-not $main) { return }

    foreach ($id in 'Add', 'NewVersion', 'Edit', 'Delete', 'Build', 'Publish', 'Retire', 'OpenFolder', 'Tools', 'Refresh', 'Settings', 'Cancel') {
        $button = Find-UiaElement -Root $main -AutomationId $id -TimeoutSeconds 5
        Test-That "button [$id] is present" ($null -ne $button)
        if ($button -and $id -in 'Add', 'Retire', 'Tools', 'Refresh', 'Cancel') {
            $invokable = @($button.GetSupportedPatterns() | Where-Object { $_.ProgrammaticName -like 'Invoke*' }).Count -gt 0
            Test-That "button [$id] can be invoked" $invokable
        }
    }

    $rows = Get-UiaElement -Root $main -ControlType DataItem
    Write-Host ("        the list holds {0} row(s)" -f $rows.Count) -ForegroundColor DarkGray
    Test-That 'the rows carry the package state' (@($rows | Where-Object { $_.Current.Name -match 'Package=' }).Count -gt 0)
    Test-That 'the rows carry the site state'    (@($rows | Where-Object { $_.Current.Name -match 'Site=' }).Count -gt 0)

    $status = Find-UiaElement -Root $main -AutomationId 'Status' -TimeoutSeconds 5
    Test-That 'the status line is present' ($null -ne $status) $(if ($status) { $status.Current.Name })
    Test-That 'the site was read' ($status -and $status.Current.Name -notmatch 'not read')

    # With nothing selected, the row actions are greyed out and Add is not.
    Test-That 'Edit is disabled without a selection' (-not (Find-UiaElement -Root $main -AutomationId 'Edit' -TimeoutSeconds 3).Current.IsEnabled)
    Test-That 'Add is enabled without a selection'   ((Find-UiaElement -Root $main -AutomationId 'Add' -TimeoutSeconds 3).Current.IsEnabled)

    # ------------------------------------------------------------- Add -> Blank
    Write-Host "`nAdd -> Blank record" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $main -AutomationId 'Add')
    $blank = Find-UiaElement -Root ([Windows.Automation.AutomationElement]::RootElement) -AutomationId 'AddBlank' -TimeoutSeconds 10
    Test-That 'the Add menu offers a blank record' ($null -ne $blank)
    foreach ($id in 'AddWinget', 'AddFile') {
        Test-That "the Add menu offers [$id]" ($null -ne (Find-UiaElement -Root ([Windows.Automation.AutomationElement]::RootElement) -AutomationId $id -TimeoutSeconds 3))
    }
    if ($blank) { Invoke-UiaElement -Element $blank }

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
        foreach ($id in 'FromMsi', 'FromExe', 'FromWinget') {
            Test-That "prefill button [$id] is present" ($null -ne (Find-UiaElement -Root $editor -AutomationId $id -TimeoutSeconds 3))
        }

        if ($SkipCatalog) { Invoke-UiaElement -Element (Find-UiaElement -Root $editor -AutomationId 'Cancel') }
        else { Test-CatalogPrefill -Tool $tool -Editor $editor -Package $CatalogPackage -AppListCsv $appListCsv -SourceRoot $sourceRoot }
    }

    $main = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'MainDialog' -TimeoutSeconds 180
    Test-That 'the main window is back' ($null -ne $main)
    if (-not $main) { return }

    # ---------------------------------------------------------- Delete complains
    # Delete with nothing selected is disabled; Retire with nothing selected
    # opens the retire dialog against the site, which is cancelled again. That
    # exercises a second window and the way back.
    Write-Host "`nRetire" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $main -AutomationId 'Retire')
    $retire = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'RetireDialog' -TimeoutSeconds 120
    Test-That 'the retire dialog appears' ($null -ne $retire)
    if ($retire) { Invoke-UiaElement -Element (Find-UiaElement -Root $retire -AutomationId 'Cancel') }

    $main = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'MainDialog' -TimeoutSeconds 120
    Test-That 'cancelling returns to the main window' ($null -ne $main)

    # ------------------------------------------------------------------- close
    Write-Host "`nClosing" -ForegroundColor Cyan
    if ($main) { Invoke-UiaElement -Element (Find-UiaElement -Root $main -AutomationId 'Cancel') }

    for ($i = 0; $i -lt 60 -and -not $tool.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    Test-That 'the tool exits on Close' $tool.HasExited
}
finally {
    if (-not $tool.HasExited) {
        Write-Host 'The tool was still running - killing it.' -ForegroundColor Yellow
        $tool.Kill()
    }
    Write-Host ("`n{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
}

exit $(if ($script:Failed) { 1 } else { 0 })
