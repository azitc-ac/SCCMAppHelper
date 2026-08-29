<#
    SCCMAppHelper - a small UI Automation driver for the WPF dialogs.

    Used by Test-Dialogs.ps1 to run the tool and operate it from a second
    process, so the dialogs are covered by something other than "it looked
    right when I clicked it".

    Two things are worth knowing before writing a test with this:

    * Address a window by its AutomationId, never by its title. WPF derives a
      window's automation name from its content, so a window whose content is a
      single control reports that control's name instead of the caption.
    * Only WPF controls can be driven. A Win32 dialog - anything drawn by
      [System.Windows.MessageBox] - advertises the Invoke pattern and then
      throws when it is used, because invoking a Win32 control posts it a window
      message and User Interface Privilege Isolation blocks that across
      processes. That is why the tool has its own Show-MessageDialog.
#>

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

<#
    Waits for a window of the given process, optionally the one carrying a
    specific AutomationId - the tool keeps several dialogs in one process.
#>
function Wait-UiaWindow {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$AutomationId,
        [int]$TimeoutSeconds = 60
    )

    $root = [Windows.Automation.AutomationElement]::RootElement
    $byProcess = New-Object Windows.Automation.PropertyCondition(
                     [Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)

    $condition = if ($AutomationId) {
        New-Object Windows.Automation.AndCondition($byProcess,
            (New-Object Windows.Automation.PropertyCondition(
                [Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)))
    }
    else { $byProcess }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $window = $root.FindFirst([Windows.Automation.TreeScope]::Children, $condition)
        if ($window) { return $window }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Find-UiaElement {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$AutomationId,
        [int]$TimeoutSeconds = 20
    )

    $condition = New-Object Windows.Automation.PropertyCondition(
                     [Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $element = $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Invoke-UiaElement {
    param([Parameter(Mandatory = $true)]$Element)
    $Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Set-UiaText {
    param(
        [Parameter(Mandatory = $true)]$Element,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $Element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Text)
}

function Get-UiaElement {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [ValidateSet('Button', 'DataItem', 'Edit', 'Text')][string]$ControlType = 'Button'
    )

    $condition = New-Object Windows.Automation.PropertyCondition(
                     [Windows.Automation.AutomationElement]::ControlTypeProperty,
                     ([Windows.Automation.ControlType]::$ControlType))
    return @($Root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition))
}

<#
    Selects a row of a DataGrid. The row is addressed by the text its automation
    name carries - a WPF DataGrid names a row after the object behind it, so
    "7-Zip" is enough to find the 7-Zip row without counting positions.
#>
function Select-UiaRow {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$Match,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($row in (Get-UiaElement -Root $Root -ControlType DataItem)) {
            if ($row.Current.Name -like "*$Match*") {
                $row.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
                return $row
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

Export-ModuleMember -Function Wait-UiaWindow, Find-UiaElement, Invoke-UiaElement, Set-UiaText, Get-UiaElement, Select-UiaRow
