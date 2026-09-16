<#
.SYNOPSIS
    Installs the SCCMAppHelper action into the ConfigMgr console: right-click on the
    Applications node, one of its folders or an application - "SCCMAppHelper".

.DESCRIPTION
    Writes SCCMAppHelper.xml into the console's XmlStorage\Extensions\Actions folder of the
    Applications node, with the path of this SCCMAppHelper installation filled in. The tool is
    started in place (start-SCCMAppHelper.cmd, its own console window stays visible - that is
    where the work is reported); nothing is copied. An application that was right-clicked is
    selected in the main window when it opens.

    Writing below the AdminConsole folder needs administrator rights. Restart the console
    afterwards. If the entry does not appear: Administration > Site Configuration > Sites >
    Hierarchy Settings > "Only allow console extensions that are approved for the hierarchy"
    must be off.

.PARAMETER ConsolePath
    AdminConsole folder. Found by itself from SMS_ADMIN_UI_PATH or the usual locations.

.PARAMETER Uninstall
    Remove the action.
#>
[CmdletBinding()]
param(
    [string]$ConsolePath = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

if (-not $ConsolePath) {
    $candidates = @()
    if ($env:SMS_ADMIN_UI_PATH) { $candidates += (Split-Path -Path (Split-Path -Path $env:SMS_ADMIN_UI_PATH -Parent) -Parent) }
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($root) { $candidates += (Join-Path $root 'Microsoft Endpoint Manager\AdminConsole'); $candidates += (Join-Path $root 'Microsoft Configuration Manager\AdminConsole') }
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'bin'))) { $ConsolePath = $c; break } }
}
if (-not $ConsolePath -or -not (Test-Path -LiteralPath $ConsolePath)) { throw 'AdminConsole folder not found - give -ConsolePath.' }
Write-Host "AdminConsole: $ConsolePath"

$nodeGuid = '{d2e2cba7-98f5-4d3b-bc2f-b670f0621207}'     # Applications node, its folders and applications
$xmlName = 'SCCMAppHelper.xml'
$target = Join-Path -Path $ConsolePath -ChildPath "XmlStorage\Extensions\Actions\$nodeGuid\$xmlName"
$toolRoot = Split-Path -Path $PSScriptRoot -Parent

if ($Uninstall) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force; Write-Host "Removed: $target" }
    $d = Split-Path -Path $target -Parent
    if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force; Write-Host "Removed: $d" }
    Write-Host 'Uninstalled. Restart the console.'
    return
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Writing below the AdminConsole folder needs administrator rights - run elevated.' }
if (-not (Test-Path -LiteralPath (Join-Path $toolRoot 'start-SCCMAppHelper.cmd'))) { throw "start-SCCMAppHelper.cmd not found in $toolRoot - this script belongs into the Console folder of an SCCMAppHelper installation." }

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot $xmlName) -Raw -Encoding UTF8
$content = $template.Replace('##TOOL_PATH##', $toolRoot.TrimEnd('\'))
$dir = Split-Path -Path $target -Parent
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Action:   $target"
Write-Host "Tool:     $toolRoot"
Write-Host ''
Write-Host 'Installed. Close the console completely and start it again.'
