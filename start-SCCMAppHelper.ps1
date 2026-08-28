<#
.SYNOPSIS
    SCCMAppHelper - create PSADT packages and publish them as ConfigMgr applications.

.DESCRIPTION
    Companion tool to IntuneWin32Helper (https://blog.zarenko.net) for
    Microsoft Configuration Manager.

        Apps.csv  ->  PSADT package on the source share  ->  ConfigMgr application
                      (collections, deployments, content distribution, supersedence)

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

$config = Get-ActiveConfig
check-prereqs -Config $config

$continue = $true
while ($continue) {
    # Re-read every round so a site switch in the tools menu takes effect.
    $config = Get-ActiveConfig
    $choice = Show-StartDialog -Title ("SCCMAppHelper - {0} [{1}] - https://blog.zarenko.net/" -f $config.siteName, $config.siteCode)
    switch ($choice) {
        'CreateNew'           { Write-Step 'Packaging assistant';               createApps }
        'CreateNewAndPublish' { Write-Step 'Packaging + ConfigMgr publishing';  createApps -createAndPublish }
        'PublishExisting'     { Write-Step 'Publishing existing packages';      deployApps }
        'Tools'               { Write-Step 'Tools';                             Show-ToolsMenu }
        'Cancel'              { Write-Info 'Cancelled';        $continue = $false }
        'Closed'              { Write-Info 'Closed with [X]';  $continue = $false }
        default               { Write-Info "Unexpected: $choice"; $continue = $false }
    }
}

Stop-Transcript | Out-Null
