<#
.SYNOPSIS
    Drives the SCCMAppHelper dialogs through UI Automation.

.DESCRIPTION
    Starts the tool in a second process and operates it the way a person would:
    presses the tiles, checks that the dialog behind each one comes up and holds
    what it should, and cancels back out. Nothing is created, published or
    downloaded - every path ends on Cancel.

    The tool needs a reachable ConfigMgr site, because the package list asks the
    site for its status column.

.NOTES
    Windows PowerShell 5.1. The tool itself is started with -STA, as WPF
    requires; this script does not have to be.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Tests\Test-Dialogs.ps1
#>

[CmdletBinding()]
param(
    [string]$ToolPath,
    [int]$TimeoutSeconds = 120
)

# $PSScriptRoot is not populated yet while the param block is being bound,
# so the default path is worked out here instead.
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

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Tool not found: $ToolPath" }

Write-Host "Starting $ToolPath" -ForegroundColor Cyan
$tool = Start-Process powershell.exe -PassThru -WorkingDirectory (Split-Path -Parent $ToolPath) -ArgumentList @(
    '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolPath)

try {
    # --------------------------------------------------------- start dialog
    Write-Host "`nStart dialog" -ForegroundColor Cyan
    $start = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'StartDialog' -TimeoutSeconds $TimeoutSeconds
    Test-That 'the start dialog appears' ($null -ne $start)
    if (-not $start) { return }

    foreach ($id in 'CreateNew', 'CreateNewAndPublish', 'PublishExisting', 'NewFromCatalog', 'Tools') {
        $tile = Find-UiaElement -Root $start -AutomationId $id -TimeoutSeconds 5
        Test-That "tile [$id] is present" ($null -ne $tile)
        if ($tile) {
            $invokable = @($tile.GetSupportedPatterns() | Where-Object { $_.ProgrammaticName -like 'Invoke*' }).Count -gt 0
            Test-That "tile [$id] can be invoked"      $invokable
            Test-That "tile [$id] takes keyboard focus" $tile.Current.IsKeyboardFocusable
        }
    }

    # ------------------------------------------------- publish packages flow
    Write-Host "`nPublish packages" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $start -AutomationId 'PublishExisting')

    $select = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'SelectDialog' -TimeoutSeconds $TimeoutSeconds
    Test-That 'the package selection dialog appears' ($null -ne $select)
    if ($select) {
        $rows = Get-UiaElement -Root $select -ControlType DataItem
        Test-That 'the package list is not empty' ($rows.Count -gt 0) "rows: $($rows.Count)"
        Test-That 'the rows carry a status' (($rows | Where-Object { $_.Current.Name -match 'Status=' }).Count -gt 0)
        Invoke-UiaElement -Element (Find-UiaElement -Root $select -AutomationId 'Cancel')
    }

    $start = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'StartDialog' -TimeoutSeconds 60
    Test-That 'cancelling returns to the start dialog' ($null -ne $start)
    if (-not $start) { return }

    # --------------------------------------------------- create packages flow
    Write-Host "`nCreate packages" -ForegroundColor Cyan
    Invoke-UiaElement -Element (Find-UiaElement -Root $start -AutomationId 'CreateNew')

    $appList = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'AppListDialog' -TimeoutSeconds $TimeoutSeconds
    Test-That 'the app list dialog appears' ($null -ne $appList)
    if ($appList) {
        $rows = Get-UiaElement -Root $appList -ControlType DataItem
        Test-That 'the app list is not empty' ($rows.Count -gt 0) "rows: $($rows.Count)"
        foreach ($id in 'New', 'Edit', 'Duplicate', 'Delete', 'OK', 'Cancel') {
            Test-That "app list button [$id] is present" ($null -ne (Find-UiaElement -Root $appList -AutomationId $id -TimeoutSeconds 3))
        }
        # Delete with nothing selected only complains, and that complaint is the
        # tool's own message dialog - the Win32 one could not be driven at all.
        Invoke-UiaElement -Element (Find-UiaElement -Root $appList -AutomationId 'Delete')
        $message = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'MessageDialog' -TimeoutSeconds 20
        Test-That 'the message dialog appears' ($null -ne $message)
        if ($message) {
            $text = Find-UiaElement -Root $message -AutomationId 'MessageText' -TimeoutSeconds 5
            Test-That 'the message dialog carries its text' ($null -ne $text) $(if ($text) { $text.Current.Name })
            $ok = Find-UiaElement -Root $message -AutomationId 'OK' -TimeoutSeconds 5
            Test-That 'the message dialog has an OK button' ($null -ne $ok)
            if ($ok) { Invoke-UiaElement -Element $ok }
        }

        # New opens the record editor on an empty row.
        Invoke-UiaElement -Element (Find-UiaElement -Root $appList -AutomationId 'New')
        $edit = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'EditDialog' -TimeoutSeconds 30
        Test-That 'the record editor appears' ($null -ne $edit)
        if ($edit) {
            foreach ($field in 'Publisher', 'Name', 'Version', 'DetectionMethod', 'DetectionPattern') {
                Test-That "editor field [$field] is present" ($null -ne (Find-UiaElement -Root $edit -AutomationId $field -TimeoutSeconds 3))
            }
            $boxes = Get-UiaElement -Root $edit -ControlType Edit
            Test-That 'the editor shows all nine columns' ($boxes.Count -eq 9) "text boxes: $($boxes.Count)"
            Invoke-UiaElement -Element (Find-UiaElement -Root $edit -AutomationId 'Cancel')
        }

        $appList = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'AppListDialog' -TimeoutSeconds 30
        if ($appList) { Invoke-UiaElement -Element (Find-UiaElement -Root $appList -AutomationId 'Cancel') }
    }

    $start = Wait-UiaWindow -ProcessId $tool.Id -AutomationId 'StartDialog' -TimeoutSeconds 60
    Test-That 'cancelling returns to the start dialog again' ($null -ne $start)

    # --------------------------------------------------------------- closing
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
