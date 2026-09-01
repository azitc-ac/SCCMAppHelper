<#
.SYNOPSIS
    SCCMAppHelper - create PSADT packages and publish them as ConfigMgr applications.

.DESCRIPTION
    Companion tool to IntuneWin32Helper (https://blog.zarenko.net) for
    Microsoft Configuration Manager.

        definition (Apps.csv)  ->  package on the source share  ->  ConfigMgr application
                                   (PSADT + installer in Files)     (deployment type, content,
                                                                    collections, deployments,
                                                                    supersedence)

    The main window lists every application with the state of all three, and
    every action is taken from a row of that list.

.NOTES
    Run in Windows PowerShell 5.1 with the ConfigMgr console installed.
#>

$toolVersion = '1.0'

$rootDir = $PSScriptRoot
if (-not $rootDir) { $rootDir = (Get-Location).Path }

$logDir = Join-Path $rootDir 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
$log = Join-Path $logDir ((Get-Date -UFormat '%Y-%m-%d_%H-%M-%S') + '.log')
Start-Transcript -Path $log | Out-Null

. "$rootDir\Functions\functions.ps1"

# --- first run -------------------------------------------------------------
# Nothing configured yet, or a configuration cloned from another environment:
# offer to read everything from the site instead of editing config.json.
if (@(Get-CMSiteList).Count -eq 0) {
    Write-Warn 'No ConfigMgr site configured yet - starting the setup assistant.'
    if (-not (Start-SetupWizard)) { Stop-Transcript | Out-Null; return }
}

$config = Get-ActiveConfig

if (-not (Test-DnsName -Name $config.siteServer)) {
    Write-Warn "Configured site server [$($config.siteServer)] cannot be resolved from this machine."
    $answer = Show-MessageDialog -Text "The configured site server`n`n$($config.siteServer)`n`ncannot be reached from this machine.`n`nRun the setup assistant and connect to a site on this server instead?" -Caption 'SCCMAppHelper' -Buttons 'YesNo' -Icon 'Question'
    if ($answer -eq 'Yes') {
        if (Start-SetupWizard) { $config = Get-ActiveConfig }
    }
}

check-prereqs -Config $config

# --- the main loop ---------------------------------------------------------
# The list is read afresh every round, so what an action changed - a package
# built, an application published, a site switched in the tools menu - shows
# up as soon as the window is back.
$continue = $true
while ($continue) {
    $config = Get-ActiveConfig

    Write-Step ("Reading the share and the site [{0}]" -f $config.siteCode)
    $inventory = Get-AppInventory -Config $config
    Write-Info ("{0} application(s)" -f @($inventory.Rows).Count)

    $choice = Show-InventoryDialog -Inventory $inventory.Rows `
        -Title ("SCCMAppHelper - {0} [{1}] - https://blog.zarenko.net/" -f $config.siteName, $config.siteCode) `
        -SourceRoot $inventory.WorkRoot -SiteRead $inventory.SiteRead

    $continue = Invoke-InventoryAction -Choice $choice -Config $config
}

Stop-Transcript | Out-Null
