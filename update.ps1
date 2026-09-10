<#
.SYNOPSIS
    Updates this installation to the current state of the repository.

.DESCRIPTION
    "git pull" for a machine that has no git - a server reachable over RDP and
    nothing else. The current branch is downloaded from GitHub as a zip and
    unpacked over this folder. The repository is public, so nothing has to be
    authenticated and no credential ends up on the machine.

    What belongs to this installation is never touched:

        Config\config.json      the sites and conventions of this environment
        Apps.csv                the master list
        Logs\                   transcripts
        Config\winget-index\    the downloaded winget index

    Nothing is deleted either - a file that disappeared from the repository
    stays behind rather than being removed from a running installation.

.PARAMETER Branch
    Which branch to pull. Defaults to main.

.PARAMETER Token
    Only needed if the repository is ever made private again.

.PARAMETER WhatIf
    Say what would be replaced, change nothing.

.EXAMPLE
    .\update.ps1
    Updates to the newest state of main.

.EXAMPLE
    .\update.ps1 -WhatIf
    Lists what would be replaced.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Branch = 'main',
    [string]$Token
)

$ErrorActionPreference = 'Stop'

$repoOwner = 'azitc-ac'
$repoName  = 'SCCMAppHelper'

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

# Kept as they are on this machine. Matched against the path inside the
# repository, so a file of the same name somewhere else is still updated.
# config.json is not in the repository at all any more - the tool creates it
# from config.sample.json on first start - but it stays listed here so an
# installation that still has a tracked one from an older version keeps it.
$keep = @(
    'Config\config.json'
    'Apps.csv'
)
$keepFolders = @(
    'Logs'
    'Config\winget-index'
)

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

#region ------------------------------------------------------------- download

Write-Step "Downloading $repoOwner/$repoName ($Branch)"

# TLS 1.2 has to be asked for on Windows PowerShell 5.1; without it the
# download fails against GitHub with a connection error that says nothing.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$headers = @{
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'SCCMAppHelper-update'
}
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

# -WhatIf:$false throughout the download: fetching and unpacking into a temp
# folder changes nothing about the installation, and without it a dry run would
# have nothing to compare against - it failed on the missing folder instead.
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("SCCMAppHelper-update-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $temp -Force -WhatIf:$false
$zip  = Join-Path $temp 'repo.zip'

try {
    Invoke-WebRequest -Uri "https://api.github.com/repos/$repoOwner/$repoName/zipball/$Branch" `
        -Headers $headers -OutFile $zip -UseBasicParsing -ErrorAction Stop
}
catch {
    $status = ''
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    switch ($status) {
        401     { throw "GitHub asked for authentication - is the repository private again? Then pass -Token." }
        403     { throw "GitHub refused the request (403). Unauthenticated calls are limited to 60 per hour - wait, or pass -Token." }
        404     { throw "Neither the repository nor the branch [$Branch] was found." }
        default { throw ("Download failed: {0}" -f $_.Exception.Message) }
    }
}

Write-Ok ("Downloaded: {0:N1} MB" -f ((Get-Item -LiteralPath $zip).Length / 1MB))

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $temp)

# GitHub wraps the tree in one folder named owner-repo-<sha>.
$source = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
if (-not $source) { throw 'The downloaded archive holds no folder.' }

$commit = ''
if ($source.Name -match '-(?<sha>[0-9a-f]{7,40})$') { $commit = $Matches['sha'].Substring(0, 7) }

#endregion

#region -------------------------------------------------------------- install

Write-Step "Updating $root"

$copied  = 0
$kept    = 0
$prefix  = $source.FullName.TrimEnd('\') + '\'

foreach ($file in (Get-ChildItem -LiteralPath $source.FullName -Recurse -File)) {
    $relative = $file.FullName.Substring($prefix.Length)

    # Only kept on a machine that already has the file - a first installation
    # needs the one from the repository to start from.
    if (($keep -contains $relative) -and (Test-Path -LiteralPath (Join-Path $root $relative))) {
        Write-Info "kept: $relative"
        $kept++
        continue
    }

    $inKeptFolder = $false
    foreach ($folder in $keepFolders) {
        if ($relative.StartsWith($folder + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $inKeptFolder = $true; break }
    }
    if ($inKeptFolder) { $kept++; continue }

    $target = Join-Path $root $relative
    if ($PSCmdlet.ShouldProcess($relative, 'replace')) {
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $copied++
}

if ($commit -and -not $WhatIfPreference) {
    Set-Content -LiteralPath (Join-Path $root 'DEPLOYED-VERSION.txt') -Encoding ASCII -Value (
        "{0} {1} {2}" -f $commit, $Branch, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
}

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false

Write-Ok ("{0} file(s) updated, {1} kept{2}" -f $copied, $kept, $(if ($commit) { " - now at $commit" } else { '' }))
Write-Info 'Start the tool with start-SCCMAppHelper.cmd.'

#endregion
