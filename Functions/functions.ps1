<#
    SCCMAppHelper - core functions
    https://blog.zarenko.net

    Workflow (mirrors IntuneWin32Helper):
        Apps.csv  ->  PSADT package on the source share  ->  ConfigMgr application

    All ConfigMgr work lives in Publish-CMApplication. A package carries nothing
    but its PSADT content - the detection script and the icon are rendered at
    publish time, so fixes made here reach packages built with an older version
    of the tool as well.
#>

if (-not $rootDir) { $rootDir = Split-Path -Parent $PSScriptRoot }
if (-not $toolVersion) { $toolVersion = '1.0' }

. "$rootDir\Functions\ui.ps1"
. "$rootDir\Functions\setup.ps1"
. "$rootDir\Functions\catalog.ps1"

#region --------------------------------------------------------------- output

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }

<#
    The signature a published application carries so it can be recognised as
    maintained by this tool. It goes into the comment of the deployment type,
    which is the only place that works for every detection method - a native
    clause holds no script that could carry it.
#>
function Get-ToolSignature { return "SCCMAppHelper $toolVersion" }

#endregion

#region --------------------------------------------------------------- config

function Get-AppHelperConfig {
    param([string]$Path = (Join-Path $rootDir 'Config\config.json'))

    if (-not (Test-Path -LiteralPath $Path)) { throw "Configuration file not found: $Path" }
    return (Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json)
}

<#
    Everything that differs between ConfigMgr environments lives in the "sites"
    array of config.json; everything else (naming patterns, commands, switches)
    is shared. A config without a "sites" array is treated as a single site
    built from the top level keys.
#>
$script:SiteProperties = @(
    'siteCode'
    'siteServer'
    'sqlServer'
    'database'
    'sourceRoot'
    'sourceRootLocal'
    'distributionPointName'
    'distributionPointGroupName'
    'limitingCollectionName'
    'applicationFolderPath'
    'collectionFolderPath'
)

function Get-CMSiteList {
    param($BaseConfig = (Get-AppHelperConfig))

    if ($BaseConfig.PSObject.Properties.Name -contains 'sites' -and $BaseConfig.sites) {
        return @($BaseConfig.sites)
    }

    # Legacy / single environment configuration. Without a site code there is
    # nothing configured yet and the setup assistant takes over.
    if ([string]::IsNullOrWhiteSpace($BaseConfig.siteCode)) { return @() }

    $site = [ordered]@{ name = $BaseConfig.siteCode }
    foreach ($property in $script:SiteProperties) { $site[$property] = $BaseConfig.$property }
    return @([pscustomobject]$site)
}

<#
    Returns the site to work with. The choice is remembered for the rest of the
    session so a bulk run does not ask again; -Force asks anyway.
#>
function Select-CMSite {
    param(
        [switch]$Force,
        $BaseConfig = (Get-AppHelperConfig)
    )

    # @() around the call: a single site would otherwise be unrolled to a scalar.
    $sites = @(Get-CMSiteList -BaseConfig $BaseConfig)
    if ($sites.Count -eq 0) { throw 'No ConfigMgr site configured. Add one under "sites" in config.json.' }
    if ($sites.Count -eq 1) { return $sites[0] }

    if (-not $Force) {
        if ($global:SCCMAppHelperSite) {
            $remembered = $sites | Where-Object { $_.name -eq $global:SCCMAppHelperSite -or $_.siteCode -eq $global:SCCMAppHelperSite } | Select-Object -First 1
            if ($remembered) { return $remembered }
        }
        if ($BaseConfig.activeSite) {
            $configured = $sites | Where-Object { $_.name -eq $BaseConfig.activeSite -or $_.siteCode -eq $BaseConfig.activeSite } | Select-Object -First 1
            if ($configured) { return $configured }
        }
    }

    $selection = Open-SelectDialog -data ($sites | Select-Object name, siteCode, siteServer, sourceRoot) -title 'Select ConfigMgr site'
    if ($null -ne $selection) { $selection = $selection | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
    if (-not $selection) { throw 'No ConfigMgr site selected.' }

    $chosen = $sites | Where-Object { $_.name -eq $selection.name } | Select-Object -First 1
    $global:SCCMAppHelperSite = $chosen.name
    Write-Info "Active site: $($chosen.name) [$($chosen.siteCode)]"
    return $chosen
}

<#
    Base configuration with the values of the active site merged in - this is
    what every function in the tool works with.
#>
function Get-ActiveConfig {
    param([switch]$ForceSiteSelection)

    $base = Get-AppHelperConfig
    $site = Select-CMSite -BaseConfig $base -Force:$ForceSiteSelection

    $config = $base.PSObject.Copy()
    foreach ($property in $site.PSObject.Properties) {
        if ($property.Name -eq 'name') { continue }
        $config | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
    }
    $config | Add-Member -MemberType NoteProperty -Name 'siteName' -Value $site.name -Force

    if ([string]::IsNullOrWhiteSpace($config.database) -and $config.siteCode) {
        $config | Add-Member -MemberType NoteProperty -Name 'database' -Value ("CM_{0}" -f $config.siteCode) -Force
    }

    return $config
}

<#
    Console folder paths may be configured in any of these ways - the site code
    and the provider root node are filled in as needed, so the same config also
    works against another site:

        Apps                     -> <SiteCode>:\Application\Apps
        Application\Apps         -> <SiteCode>:\Application\Apps
        CCL:\Application\Apps    -> <SiteCode>:\Application\Apps
#>
function Resolve-CMFolderPath {
    param(
        [string]$FolderPath,
        $Config,
        [string]$RootNode
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath)) { return $null }

    $path = $FolderPath
    if ($path -match '^[A-Za-z0-9]{3}:\\(.*)$') { $path = $Matches[1] }
    $path = $path.Trim('\')
    if (-not $path) { return $null }

    if ($RootNode -and $path -notmatch ('^{0}(\\|$)' -f [regex]::Escape($RootNode))) {
        $path = "$RootNode\$path"
    }

    return ('{0}:\{1}' -f $Config.siteCode, $path)
}

<#
    Creates a console folder including missing intermediate levels, so a folder
    configured in config.json does not have to exist in the console first.
    Must run inside the site drive.
#>
function New-CMFolderPath {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    if (Test-Path -LiteralPath $FolderPath) { return $true }

    $segments = $FolderPath -split '\\'
    $current = $segments[0]          # "<SiteCode>:"
    if ($segments.Count -lt 3) { return $false }

    $current = "$current\$($segments[1])"   # provider root node, always exists
    for ($i = 2; $i -lt $segments.Count; $i++) {
        $next = "$current\$($segments[$i])"
        if (-not (Test-Path -LiteralPath $next)) {
            try {
                $null = New-Item -Path $current -Name $segments[$i] -ErrorAction Stop
                Write-Ok "Console folder created: $next"
            }
            catch {
                Write-Warn ("Console folder [{0}] could not be created: {1}" -f $next, $_.Exception.Message)
                return $false
            }
        }
        $current = $next
    }

    return $true
}

function check-prereqs {
    param($Config = (Get-ActiveConfig))

    Write-Step 'Checking prerequisites'

    # Get-Module -ListAvailable instead of Get-InstalledModule: it finds the
    # module however it was installed and it does not pull in PowerShellGet.
    # Started from a pwsh 7 terminal, Windows PowerShell inherits a PSModulePath
    # that contains the PowerShell 7 WindowsApps folder; PowerShellGet then fails
    # to load and Install-Module hangs on the NuGet provider prompt.
    foreach ($requiredModule in @('PSAppDeployToolkit')) {
        $module = Get-Module -ListAvailable -Name $requiredModule -ErrorAction SilentlyContinue |
                    Sort-Object Version -Descending | Select-Object -First 1
        if ($module) {
            Write-Ok "Required module [$requiredModule] detected (version $($module.Version))."
            continue
        }

        Write-Warn "Required module [$requiredModule] not detected - installing..."
        try {
            Install-Module $requiredModule -Force -Scope CurrentUser -AllowClobber -Confirm:$false -ErrorAction Stop
            Write-Ok "Required module [$requiredModule] installed."
        }
        catch {
            Write-Fail ("Could not install [{0}]: {1}" -f $requiredModule, $_.Exception.Message)
            Write-Warn 'Install it manually - package creation needs it, publishing to ConfigMgr does not.'
        }
    }

    try {
        $null = Get-CMModulePath
        Write-Ok 'ConfigurationManager module detected.'
    }
    catch {
        Write-Warn $_.Exception.Message
        Write-Warn 'Package creation still works, publishing to ConfigMgr does not.'
    }

    foreach ($path in @($Config.sourceRoot, $Config.sourceRootLocal)) {
        if ($path -and (Test-Path -LiteralPath $path)) { Write-Ok "Source root reachable: $path" }
        elseif ($path) { Write-Info "Source root not reachable from here: $path" }
    }
}

#endregion

#region ------------------------------------------------------- ConfigMgr site

function Get-CMModulePath {
    $candidates = @()
    if ($env:SMS_ADMIN_UI_PATH) {
        $candidates += (Join-Path (Split-Path -Parent $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
    }

    # The console installation directory, for sessions where the environment
    # variable is missing or the console sits on a non-default drive.
    # SilentlyContinue, not try/catch: the console user may not be able to read
    # this key, and a caught terminating error still shows up in the transcript as
    # "TerminatingError(Get-ItemProperty)", which reads like a failure but is not.
    $setupKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction SilentlyContinue
    if ($setupKey -and $setupKey.'UI Installation Directory') {
        $candidates += (Join-Path $setupKey.'UI Installation Directory' 'bin\ConfigurationManager.psd1')
    }
    $candidates += @(
        "$env:ProgramFiles\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
        "${env:ProgramFiles(x86)}\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
        'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1',
        'D:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1',
        'E:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
    )

    $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $found) { throw 'ConfigurationManager.psd1 not found. Is the ConfigMgr console installed on this machine?' }
    return $found
}

function Connect-CMSite {
    param($Config = (Get-ActiveConfig))

    if (-not (Get-Module -Name ConfigurationManager)) {
        Import-Module (Get-CMModulePath) -ErrorAction Stop
    }

    $siteCode = $Config.siteCode
    if (-not (Get-PSDrive -Name $siteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        Write-Info "Creating site drive [$siteCode] on [$($Config.siteServer)]"
        $null = New-PSDrive -Name $siteCode -PSProvider CMSite -Root $Config.siteServer -Scope Global -ErrorAction Stop
    }

    return "$($siteCode):"
}

<#
    Runs a script block with the current location set to the ConfigMgr site
    drive and restores the previous location afterwards - no more "cd CCL:" /
    "cd c:\" juggling in the middle of a package loop.
#>
function Invoke-InCMSite {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        $Config = (Get-ActiveConfig)
    )

    $drive = Connect-CMSite -Config $Config
    Push-Location
    try {
        Set-Location "$drive\"
        & $ScriptBlock
    }
    finally {
        Pop-Location
    }
}

#endregion

#region ---------------------------------------------------------- app catalog

<#
    Columns of Apps.csv. Publisher / Name / Version are the original three
    columns, everything else is optional and is added transparently to older
    files by Update-AppListSchema.
#>
$script:AppListColumns = @(
    'Publisher'
    'Name'
    'Version'
    'DetectionMethod'    # Registry (default) | MSI | File | Script
    'DetectionPattern'   # Registry: uninstall key  /  File: full file path
    'ProductCode'        # MSI detection
    'InstallCmd'         # optional PSADT code for the install section
    'UninstallCmd'       # optional PSADT code for the uninstall section
    'Notes'
)

function Update-AppListSchema {
    param([Parameter(Mandatory = $true)][string]$CsvPath)

    if (-not (Test-Path -LiteralPath $CsvPath)) {
        Write-Warn "App list not found, creating an empty one: $CsvPath"
        Set-Content -LiteralPath $CsvPath -Value ('"' + ($script:AppListColumns -join '";"') + '"') -Encoding UTF8
        return
    }

    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter ';')
    if ($rows.Count -eq 0) { return }

    $existingColumns = $rows[0].PSObject.Properties.Name
    $missing = $script:AppListColumns | Where-Object { $_ -notin $existingColumns }

    $upgraded = foreach ($row in $rows) {
        foreach ($column in $missing) {
            $value = ''
            if ($column -eq 'DetectionMethod') { $value = 'Registry' }
            $row | Add-Member -MemberType NoteProperty -Name $column -Value $value -Force
        }
        $row
    }

    $order = $script:AppListColumns + ($existingColumns | Where-Object { $_ -notin $script:AppListColumns })
    $upgraded |
        Sort-Object Name, Version |
        Select-Object -Property $order |
        Export-Csv -LiteralPath $CsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

    if ($missing) { Write-Info ("App list upgraded with columns: {0}" -f ($missing -join ', ')) }
}

function Get-AppFullName {
    param([string]$Name, [string]$Version)
    return ('{0} - {1}' -f $Name.Trim(), $Version.Trim())
}

#endregion

#region ------------------------------------------------------------- packages

function Get-PackageWorkRoot {
    param($Config = (Get-ActiveConfig))

    if ($Config.sourceRootLocal -and (Test-Path -LiteralPath $Config.sourceRootLocal)) { return $Config.sourceRootLocal }
    if ($Config.sourceRoot -and (Test-Path -LiteralPath $Config.sourceRoot)) { return $Config.sourceRoot }
    throw ("Neither sourceRootLocal [{0}] nor sourceRoot [{1}] is reachable." -f $Config.sourceRootLocal, $Config.sourceRoot)
}

<#
    ConfigMgr needs a UNC content location. When the tool runs directly on the
    site server the packages are created on a local path, so translate it.
#>
function ConvertTo-CMContentPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Config = (Get-ActiveConfig)
    )

    if ($Path -like '\\*') { return $Path }

    $local = $Config.sourceRootLocal
    $unc   = $Config.sourceRoot
    if ($local -and $unc -and $Path.ToLower().StartsWith($local.ToLower())) {
        return ($unc.TrimEnd('\') + $Path.Substring($local.TrimEnd('\').Length))
    }

    Write-Warn "Content path [$Path] is local and cannot be translated to UNC - check sourceRoot/sourceRootLocal."
    return $Path
}

<#
    Subfolder layout (default):  <package>\Content\  = PSADT root = content location
    Flat layout (legacy):        <package>\          = PSADT root = content location

    Nothing else belongs beside the content. What ConfigMgr needs on top of it -
    detection script and icon - is rendered into a temporary folder at publish
    time by New-PublishArtifact.
#>
function Get-PackageContentPath {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        $Config = (Get-ActiveConfig)
    )

    if (Test-Path -LiteralPath (Join-Path $PackageRoot 'Content\Invoke-AppDeployToolkit.ps1')) { return (Join-Path $PackageRoot 'Content') }
    if (Test-Path -LiteralPath (Join-Path $PackageRoot 'Invoke-AppDeployToolkit.ps1'))         { return $PackageRoot }
    if ($Config.packageLayout -eq 'Flat') { return $PackageRoot }
    return (Join-Path $PackageRoot 'Content')
}


function Set-ADTLogPath {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [string]$LogPath = 'C:\Windows\CCM\Logs\PSADT'
    )

    $configPath = Join-Path $ContentRoot 'Config\config.psd1'
    if (-not (Test-Path -LiteralPath $configPath)) { throw "config.psd1 not found: $configPath" }

    # The PSADT template ships the Config folder read-only.
    $configFolder = Get-Item -LiteralPath (Split-Path -Parent $configPath)
    $configFolder.Attributes = ($configFolder.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly)

    $content = Get-Content -LiteralPath $configPath -Raw
    $content = $content -replace "(?m)^\s*LogPath\s*=\s*'.*?'", "    LogPath = '$LogPath'"
    $content = $content -replace "(?m)^\s*LogPathNoAdminRights\s*=\s*'.*?'", "    LogPathNoAdminRights = '$LogPath'"
    Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
}

function Set-ADTAppMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [string]$Publisher,
        [string]$Name,
        [string]$Version,
        [string]$Author = $env:USERNAME
    )

    $scriptPath = Join-Path $ContentRoot 'Invoke-AppDeployToolkit.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Invoke-AppDeployToolkit.ps1 not found: $scriptPath" }

    $creationDate = Get-Date -Format 'yyyy-MM-dd'
    $script = Get-Content -LiteralPath $scriptPath

    # Empty values are skipped, so a zero-config MSI package keeps its empty
    # AppVendor / AppName / AppVersion while author and date are still stamped.
    if ($Publisher) { $script = $script -replace "AppVendor = ''", "AppVendor = '$Publisher'" }
    if ($Name)      { $script = $script -replace "AppName = ''", "AppName = '$Name'" }
    if ($Version)   { $script = $script -replace "AppVersion = ''", "AppVersion = '$Version'" }

    $script = $script `
        -replace "AppScriptDate = '2000-12-31'", "AppScriptDate = '$creationDate'" `
        -replace "AppScriptAuthor = '<author name>'", "AppScriptAuthor = '$Author'"

    $script | Out-File -LiteralPath $scriptPath -Encoding utf8 -Force
}

<#
    Inserts PSADT code after the install / uninstall marker comments of
    Invoke-AppDeployToolkit.ps1 (taken from IntuneWin32Helper).
#>
function Insert-Commands {
    param(
        [string]$FilePath,
        [string[]]$Install,
        [string[]]$Uninstall
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Fail "File '$FilePath' was not found."
        return
    }

    $markers = @{}
    if ($Install)   { $markers['## <Perform Installation tasks here>']   = $Install }
    if ($Uninstall) { $markers['## <Perform Uninstallation tasks here>'] = $Uninstall }
    if ($markers.Count -eq 0) { return }

    $content = Get-Content -LiteralPath $FilePath
    $newContent = @()
    $insertedMarkers = @{}

    foreach ($line in $content) {
        $newContent += $line
        foreach ($marker in $markers.Keys) {
            if ($line -like "*$marker*" -and -not $insertedMarkers.ContainsKey($marker)) {
                $newContent += $markers[$marker]
                $insertedMarkers[$marker] = $true
            }
        }
    }

    Set-Content -LiteralPath $FilePath -Value $newContent
    if ($insertedMarkers.Count -gt 0) { Write-Ok ("Code added after: {0}" -f ($insertedMarkers.Keys -join ', ')) }
}

function New-DetectionScript {
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$CustomSource,
        $Config = (Get-ActiveConfig)
    )

    $method = $App.DetectionMethod
    if ([string]::IsNullOrWhiteSpace($method)) { $method = 'Registry' }

    # A hand written detection lives inside the package, in
    # Content\SupportFiles\detection.ps1, so it travels with the content instead
    # of sitting beside it. It is copied verbatim - only the tool signature is
    # prepended, so an application published from it is recognisable as ours
    # just like the generated ones.
    if ($method -eq 'Custom') {
        if ($CustomSource -and (Test-Path -LiteralPath $CustomSource)) {
            $header = "# Generated by SCCMAppHelper $toolVersion - https://blog.zarenko.net" + [Environment]::NewLine +
                      '# Custom detection, taken verbatim from SupportFiles\detection.ps1.' + [Environment]::NewLine
            Set-Content -LiteralPath $Destination -Value ($header + (Get-Content -LiteralPath $CustomSource -Raw)) -Encoding UTF8
            Write-Ok "Detection script taken from [$CustomSource]"
            return $Destination
        }
        Write-Warn 'DetectionMethod [Custom] but no SupportFiles\detection.ps1 in the package - falling back to Registry.'
        $method = 'Registry'
    }

    $templatePath = Join-Path $rootDir ("Templates\detection_template-{0}.ps1" -f $method)
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Detection template not found: $templatePath" }

    $pattern = $App.DetectionPattern
    if ([string]::IsNullOrWhiteSpace($pattern) -and $method -eq 'Registry') { $pattern = ('{0}*' -f $App.Name) }

    $logPath = $Config.psadtLogPath
    if ([string]::IsNullOrWhiteSpace($logPath)) { $logPath = 'C:\Windows\CCM\Logs\PSADT' }

    # Replace placeholders literally - app names regularly contain regex
    # metacharacters such as "+" (Notepad++) or "(x64 edition)".
    $script = Get-Content -LiteralPath $templatePath -Raw
    $replacements = @{
        '#DN#'          = $App.Name
        '#VER#'         = $App.Version
        '#PATTERN#'     = $pattern
        '#PRODUCTCODE#' = $App.ProductCode
        '#FILEPATH#'    = $App.DetectionPattern
        '#LOGPATH#'     = $logPath
        '#TOOLVER#'     = $toolVersion
    }
    foreach ($key in $replacements.Keys) {
        $script = $script.Replace($key, [string]$replacements[$key])
    }

    Set-Content -LiteralPath $Destination -Value $script -Encoding UTF8
    Write-Ok "Detection script written ($method): $Destination"
    return $Destination
}

<#
    ConfigMgr rejects oversized icons, so every logo is normalised to a square
    PNG of at most 250x250 pixels.
#>
function Resize-IconFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$MaxSize = 250
    )

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $image = [System.Drawing.Image]::FromFile($Path)
        try {
            if ($image.Width -le $MaxSize -and $image.Height -le $MaxSize) {
                $image.Dispose()
                Copy-Item -LiteralPath $Path -Destination $Destination -Force
                return $Destination
            }

            $ratio  = [Math]::Min($MaxSize / $image.Width, $MaxSize / $image.Height)
            $width  = [int]($image.Width * $ratio)
            $height = [int]($image.Height * $ratio)

            $bitmap = New-Object System.Drawing.Bitmap $width, $height
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($image, 0, 0, $width, $height)
            $graphics.Dispose()
            $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
            $bitmap.Dispose()
            Write-Info "Icon resized to ${width}x${height}."
        }
        finally {
            $image.Dispose()
        }
    }
    catch {
        Write-Warn ("Icon could not be resized ({0}) - copying as is." -f $_.Exception.Message)
        Copy-Item -LiteralPath $Path -Destination $Destination -Force
    }

    return $Destination
}

<#
    Looks for a logo in .\Logos, in decreasing order of confidence:

        1. <AppName>.png                       exact match
        2. <AppName without "(x64)" / trailing version>.png
        3. the longest logo name that is a prefix of the app name
           ("7-Zip" for "7-Zip 26.02 (x64 edition)")
        4. the longest logo name that starts with the app name
           ("Oracle_Database_Client" for "Oracle")

    Steps 3 and 4 require a word boundary after the match, so "PDF" never
    picks up "PDF24 Creator". Dropping a file named exactly like the app
    always wins.
#>
function Find-AppLogo {
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$LogoDir
    )

    $safeName = $AppName -replace '[\\/:*?"<>|]', '_'

    $exact = Join-Path $LogoDir "$safeName.png"
    if (Test-Path -LiteralPath $exact) { return $exact }

    $trimmed = ($safeName -replace '\s*\([^)]*\)\s*$', '')
    $trimmed = ($trimmed -replace '\s+v?\d+[\d.]*$', '').Trim()
    if ($trimmed -and $trimmed -ne $safeName) {
        $candidate = Join-Path $LogoDir "$trimmed.png"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    # Only space and underscore count as a boundary: a hyphen is usually part of
    # the product name itself ("PDF-XChange", "7-Zip"), and treating it as a
    # separator would let "PDF" match "PDF-XChange Editor".
    $boundary = '[\s_]'
    $best = $null
    foreach ($logo in (Get-ChildItem -LiteralPath $LogoDir -Filter '*.png' -File -ErrorAction SilentlyContinue)) {
        $base = $logo.BaseName
        if ($base -eq 'defaultlogo' -or $base.Length -lt 3) { continue }

        $logoIsPrefix = ($safeName.Length -gt $base.Length) -and
                        $safeName.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase) -and
                        ($safeName[$base.Length] -match $boundary)

        $appIsPrefix  = ($base.Length -gt $safeName.Length) -and
                        $base.StartsWith($safeName, [System.StringComparison]::OrdinalIgnoreCase) -and
                        ($base[$safeName.Length] -match $boundary)

        if ($logoIsPrefix -or $appIsPrefix) {
            if (-not $best -or $base.Length -gt $best.BaseName.Length) { $best = $logo }
        }
    }

    if ($best) { return $best.FullName }
    return $null
}

function Resolve-AppLogo {
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $logoDir = Join-Path $rootDir 'Logos'
    $candidate = Find-AppLogo -AppName $AppName -LogoDir $logoDir

    if ($candidate) { Write-Info ("Using logo [{0}]" -f (Split-Path -Leaf $candidate)) }
    else {
        $candidate = Join-Path $logoDir 'defaultlogo.png'
        Write-Info 'No app logo found - using the default logo.'
    }

    return (Resize-IconFile -Path $candidate -Destination $Destination)
}

function New-AppPackage {
    param(
        [Parameter(Mandatory = $true)]$App,
        $Config = (Get-ActiveConfig)
    )

    $appFullName  = Get-AppFullName -Name $App.Name -Version $App.Version
    $workRoot     = Get-PackageWorkRoot -Config $Config
    $packageRoot  = Join-Path $workRoot $appFullName
    $contentPath  = Get-PackageContentPath -PackageRoot $packageRoot -Config $Config

    Write-Step "Creating package: $appFullName"

    if ((Test-Path -LiteralPath $packageRoot) -and $Config.removeExistingPackageDirOnEachRun) {
        Write-Warn "Removing existing package directory: $packageRoot"
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }

    $isNewTemplate = -not (Test-Path -LiteralPath (Join-Path $contentPath 'Invoke-AppDeployToolkit.ps1'))

    if ($isNewTemplate) {
        if (-not (Test-Path -LiteralPath $packageRoot)) { $null = New-Item -ItemType Directory -Path $packageRoot -Force }

        $templateParent = Split-Path -Parent $contentPath
        $templateName   = Split-Path -Leaf $contentPath
        Write-Info "Creating PSADT template in [$contentPath]"
        New-ADTTemplate -Destination $templateParent -Name $templateName -ErrorAction Stop
    }
    else {
        Write-Info 'PSADT template already present - keeping the existing content.'
    }

    # Both steps only replace placeholders / fixed values and are safe to repeat.
    Set-ADTLogPath -ContentRoot $contentPath -LogPath $Config.psadtLogPath
    Write-Ok "PSADT log path set to [$($Config.psadtLogPath)]"

    $author = $Config.packageAuthor
    if ([string]::IsNullOrWhiteSpace($author)) { $author = $env:USERNAME }

    # A single MSI is deployed by PSADT in zero-config mode: vendor, name and
    # version have to stay empty so PSADT takes them from the MSI itself.
    if ($App.DetectionMethod -eq 'MSI') {
        Set-ADTAppMetadata -ContentRoot $contentPath -Author $author
        Write-Info 'MSI package - AppVendor/AppName/AppVersion left empty for the PSADT zero-config deployment.'
    }
    else {
        Set-ADTAppMetadata -ContentRoot $contentPath -Publisher $App.Publisher -Name $App.Name -Version $App.Version -Author $author
        Write-Ok 'Invoke-AppDeployToolkit.ps1 metadata filled in.'
    }

    # Injecting the command snippets is NOT idempotent, so only do it once.
    if ($isNewTemplate) {
        $adtScript = Join-Path $contentPath 'Invoke-AppDeployToolkit.ps1'
        if ($App.InstallCmd)   { Insert-Commands -FilePath $adtScript -Install   ($App.InstallCmd   -split "`r?`n") }
        if ($App.UninstallCmd) { Insert-Commands -FilePath $adtScript -Uninstall ($App.UninstallCmd -split "`r?`n") }
    }

    Write-Ok "Package ready: $packageRoot"
    return $packageRoot
}

<#
    The Apps.csv shaped object a detection is built from. The master list is the
    source; a package that deploys a single MSI without PSADT metadata outranks
    it and brings its own ProductCode.
#>
function Resolve-PackageApp {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)]$Metadata,
        $Config = (Get-ActiveConfig)
    )

    $app = [pscustomobject]@{
        Publisher        = $Metadata.publisher
        Name             = $Metadata.name
        Version          = $Metadata.version
        DetectionMethod  = 'Registry'
        DetectionPattern = ''
        ProductCode      = ''
        InstallCmd       = ''
        UninstallCmd     = ''
        Notes            = ''
    }

    $row = Get-AppListRow -Name $Metadata.name -Version $Metadata.version
    if ($row) {
        foreach ($column in $script:AppListColumns) {
            if ($row.PSObject.Properties.Name -contains $column) { $app.$column = $row.$column }
        }
    }

    # "Custom" was the name for script detection before the native clauses
    # became the default - keep reading it so older rows still work.
    if ($app.DetectionMethod -eq 'Custom') { $app.DetectionMethod = 'Script' }
    if ([string]::IsNullOrWhiteSpace($app.DetectionMethod)) { $app.DetectionMethod = 'Registry' }

    if ($Metadata.isZeroConfigMsi) {
        $app.DetectionMethod = 'MSI'
        $app.ProductCode     = $Metadata.productCode
    }

    # For an MSI package the ProductCode does not have to be maintained by hand -
    # it is read from the MSI that is going to be deployed.
    if ($app.DetectionMethod -eq 'MSI' -and -not $app.ProductCode) {
        $contentPath = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config
        $msi = Get-PackageMsi -ContentRoot $contentPath
        if ($msi) {
            $app.ProductCode = [string](Get-MsiProperties -Path $msi.FullName)['ProductCode']
            Write-Info "ProductCode read from $($msi.Name): $($app.ProductCode)"
        }
        else {
            Write-Warn 'DetectionMethod is MSI but .\Files does not hold exactly one MSI - detection falls back to the registry.'
            $app.DetectionMethod = 'Registry'
        }
    }

    return $app
}

<#
    Renders what ConfigMgr needs on top of the content and the package does not
    store: the application icon, and for DetectionMethod = Script the detection
    script. Both go into a temporary folder the caller removes again - a package
    holds its PSADT content and nothing else.
#>
function New-PublishArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)]$App,
        $Config = (Get-ActiveConfig)
    )

    $contentPath  = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config
    $artifactPath = Join-Path ([System.IO.Path]::GetTempPath()) ('SCCMAppHelper_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $artifactPath -Force

    $detectionPath = $null
    if ($App.DetectionMethod -eq 'Script') {
        $detectionPath = New-DetectionScript -App $App `
            -Destination (Join-Path $artifactPath 'detection.ps1') `
            -CustomSource (Join-Path $contentPath 'SupportFiles\detection.ps1') `
            -Config $Config
    }

    # A logo shipped with the package wins - that is where packages built with
    # the older scripts keep their icon.
    $iconPath    = Join-Path $artifactPath 'logo.png'
    $shippedLogo = Join-Path $contentPath 'SupportFiles\logo.png'
    if (Test-Path -LiteralPath $shippedLogo) {
        Write-Info 'Using the logo from SupportFiles.'
        $null = Resize-IconFile -Path $shippedLogo -Destination $iconPath
    }
    else {
        $null = Resolve-AppLogo -AppName $App.Name -Destination $iconPath
    }

    return [pscustomobject]@{
        Path            = $artifactPath
        DetectionScript = $detectionPath
        IconFile        = $iconPath
    }
}

<#
    Builds the native ConfigMgr detection clauses for an application.

    Native clauses are evaluated by the ConfigMgr client itself - no script
    host, no execution context, no timeout, and an MSI is matched on its
    ProductCode instead of a registry lookup that reproduces it. Only
    DetectionMethod = Script falls back to a PowerShell script, for the hard
    cases a clause cannot express.

    Registry: DetectionPattern holds the uninstall key. A bare name is taken
    below the uninstall root, a value that already starts with SOFTWARE\ is
    used as it is, and for an MSI the ProductCode is the key - so it does not
    have to be maintained by hand. Both registry views are checked and
    connected with Or, because a 32 bit product on a 64 bit client registers
    below Wow6432Node.

    Returns the clauses plus what Add-/Set-CMScriptDeploymentType needs to wire
    more than one of them together.
#>
function New-AppDetectionClause {
    param([Parameter(Mandatory = $true)]$App)

    $parsedVersion = $null
    $hasVersion    = [System.Version]::TryParse($App.Version, [ref]$parsedVersion)
    $clauses       = @()

    switch ($App.DetectionMethod) {

        'MSI' {
            if (-not $App.ProductCode) { throw 'DetectionMethod is MSI but no ProductCode is known.' }
            $clauses = @(
                if ($hasVersion) {
                    New-CMDetectionClauseWindowsInstaller -ProductCode $App.ProductCode -Value `
                        -PropertyType ProductVersion -ExpressionOperator GreaterEquals -ExpectedValue $App.Version
                }
                else {
                    New-CMDetectionClauseWindowsInstaller -ProductCode $App.ProductCode -Existence
                }
            )
        }

        'File' {
            if (-not $App.DetectionPattern) { throw 'DetectionMethod is File but DetectionPattern holds no file path.' }
            $filePath = Split-Path -Parent $App.DetectionPattern
            $fileName = Split-Path -Leaf   $App.DetectionPattern
            if (-not $filePath) { throw "DetectionPattern [$($App.DetectionPattern)] is not a full file path." }
            $clauses = @(
                if ($hasVersion) {
                    New-CMDetectionClauseFile -Path $filePath -FileName $fileName -Value `
                        -PropertyType Version -ExpressionOperator GreaterEquals -ExpectedValue $App.Version
                }
                else {
                    New-CMDetectionClauseFile -Path $filePath -FileName $fileName -Existence
                }
            )
        }

        'Registry' {
            $key = $App.DetectionPattern
            if (-not $key -and $App.ProductCode) { $key = $App.ProductCode }
            if (-not $key) {
                throw 'DetectionMethod is Registry but DetectionPattern holds no uninstall key (and there is no ProductCode to derive it from).'
            }
            if ($key -notmatch '^(SOFTWARE|SYSTEM)\\') {
                $key = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$key"
            }

            foreach ($is64Bit in $true, $false) {
                $clauseParams = @{
                    Hive      = 'LocalMachine'
                    KeyName   = $key
                    ValueName = 'DisplayVersion'
                }
                if ($is64Bit) { $clauseParams['Is64Bit'] = $true }

                $clauses += if ($hasVersion) {
                    New-CMDetectionClauseRegistryKeyValue @clauseParams -Value `
                        -PropertyType Version -ExpressionOperator GreaterEquals -ExpectedValue $App.Version
                }
                else {
                    New-CMDetectionClauseRegistryKeyValue @clauseParams -Existence
                }
            }
        }

        default { throw "DetectionMethod [$($App.DetectionMethod)] has no native clause." }
    }

    # The connector belongs on the clause itself. Passing it through
    # -DetectionClauseConnector together with -GroupDetectionClauses is what the
    # documentation suggests and it silently leaves the rule at "And", which for
    # the two registry views would mean the key had to exist in both.
    foreach ($clause in $clauses) { $clause.Connector = 'Or' }

    return [pscustomobject]@{
        Clauses     = $clauses
        Fingerprint = (Get-DetectionFingerprint -Clauses $clauses)
    }
}

<#
    A comparable description of a detection, built from the clause objects -
    used to tell an unchanged deployment type from one whose detection really
    has to be replaced.
#>
function Get-DetectionFingerprint {
    param($Clauses)

    $parts = @(
        foreach ($clause in @($Clauses)) {
            '{0}|{1}|{2}|{3}|{4}|{5}' -f $clause.SettingSourceType,
                                         $clause.Setting.Location,
                                         $clause.Setting.ValueName,
                                         $clause.Setting.Is64Bit,
                                         $clause.PropertyPath,
                                         $clause.Constant.Value
        }
    )
    return (($parts | Sort-Object) -join ' && ')
}

<#
    What the deployment type stores today. The rule of the enhanced detection
    method is the ground truth - Get-CMDeploymentTypeDetectionClause has been
    seen disagreeing with it, and a mismatch between the two is itself a reason
    to treat the detection as "not what we want".
#>
function Get-DeploymentTypeDetection {
    param([Parameter(Mandatory = $true)]$DeploymentType)

    $xml   = [xml]$DeploymentType.SDMPackageXML
    $rule  = $xml.SelectSingleNode('//*[local-name()="EnhancedDetectionMethod"]/*[local-name()="Rule"]')
    $count = if ($rule) { $rule.SelectNodes('.//*[local-name()="SettingReference"]').Count } else { 0 }

    $clauses = @(Get-CMDeploymentTypeDetectionClause -InputObject $DeploymentType -ErrorAction SilentlyContinue)

    return [pscustomobject]@{
        RuleCount   = $count
        Clauses     = $clauses
        Fingerprint = if ($clauses.Count -eq $count) { Get-DetectionFingerprint -Clauses $clauses } else { '<inconsistent>' }
    }
}
<#
    Splits "<Name> - <Version>" at the last separator, so names containing " - "
    themselves survive.
#>
function Split-AppFolderName {
    param([Parameter(Mandatory = $true)][string]$FolderName)

    $separator = ' - '
    $index = $FolderName.LastIndexOf($separator)
    if ($index -lt 0) { return [pscustomobject]@{ Name = $FolderName; Version = '' } }

    return [pscustomobject]@{
        Name    = $FolderName.Substring(0, $index).Trim()
        Version = $FolderName.Substring($index + $separator.Length).Trim()
    }
}

<#
    Reads the $adtSession block of Invoke-AppDeployToolkit.ps1 - the package's
    own metadata. Parsed via the PowerShell AST so reformatting, double quotes
    or extra keys do not break it; falls back to a regex if the file cannot be
    parsed.
#>
function Read-ADTMetadata {
    param([Parameter(Mandatory = $true)][string]$ContentRoot)

    $result = [pscustomobject]@{ Publisher = ''; Name = ''; Version = ''; Author = ''; Date = '' }

    $scriptPath = Join-Path $ContentRoot 'Invoke-AppDeployToolkit.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { return $result }

    $map = @{
        AppVendor       = 'Publisher'
        AppName         = 'Name'
        AppVersion      = 'Version'
        AppScriptAuthor = 'Author'
        AppScriptDate   = 'Date'
    }

    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

        $assignment = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$adtSession'
        }, $true) | Select-Object -First 1

        if ($assignment) {
            $hashtable = $assignment.Right.Find({
                param($node) $node -is [System.Management.Automation.Language.HashtableAst]
            }, $true)

            if ($hashtable) {
                foreach ($pair in $hashtable.KeyValuePairs) {
                    $key = $pair.Item1.Extent.Text.Trim("'", '"')
                    if (-not $map.ContainsKey($key)) { continue }

                    $value = $pair.Item2.Extent.Text.Trim()
                    # Anything that is not a plain literal (a variable, an
                    # expression) counts as "not set".
                    if ($value.StartsWith('$')) { continue }
                    $result.($map[$key]) = $value.Trim("'", '"')
                }
                return $result
            }
        }
    }
    catch { }

    $content = Get-Content -LiteralPath $scriptPath -Raw
    foreach ($key in $map.Keys) {
        if ($content -match ("{0}\s*=\s*'([^']*)'" -f $key)) { $result.($map[$key]) = $Matches[1] }
    }

    return $result
}

<#
    The single MSI of a package, if there is exactly one. That is what PSADT's
    zero-config deployment runs on - and it is also the authoritative source for
    publisher, version and ProductCode of such a package.
#>
function Get-PackageMsi {
    param([Parameter(Mandatory = $true)][string]$ContentRoot)

    $filesPath = Join-Path $ContentRoot 'Files'
    if (-not (Test-Path -LiteralPath $filesPath)) { return $null }

    $msi = @(Get-ChildItem -LiteralPath $filesPath -Filter '*.msi' -File -ErrorAction SilentlyContinue)
    if ($msi.Count -eq 1) { return $msi[0] }
    return $null
}

<#
    Everything ConfigMgr needs about a package, derived from the package itself:

        name / version   folder name "<Name> - <Version>" - the naming convention
        publisher        $adtSession.AppVendor
        MSI packages     $adtSession is deliberately empty (PSADT zero-config),
                         so publisher, version and ProductCode are read from the
                         single MSI in .\Files and detection is by ProductCode

    Apps.csv is only consulted when the package itself says nothing.
#>
function Get-PackageMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        $Config = (Get-ActiveConfig)
    )

    $folderName  = Split-Path -Leaf $PackageRoot
    $parsed      = Split-AppFolderName -FolderName $folderName
    $contentPath = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config

    $adt = Read-ADTMetadata -ContentRoot $contentPath
    $msi = Get-PackageMsi -ContentRoot $contentPath

    # PSADT derives vendor, name and version from the MSI when the session
    # metadata is left empty - that is the zero-config case.
    $isZeroConfigMsi = ($null -ne $msi) -and -not $adt.Name -and -not $adt.Version

    $name        = $parsed.Name
    $version     = $parsed.Version
    $publisher   = $adt.Publisher
    $productCode = ''

    if ($isZeroConfigMsi) {
        $properties = Get-MsiProperties -Path $msi.FullName
        $productCode = [string]$properties['ProductCode']
        if (-not $publisher) { $publisher = [string]$properties['Manufacturer'] }
        if (-not $name)      { $name      = [string]$properties['ProductName'] }
        if (-not $version)   { $version   = [string]$properties['ProductVersion'] }
    }
    else {
        if (-not $name)    { $name    = $adt.Name }
        if (-not $version) { $version = $adt.Version }
    }

    # The master list fills the gaps the package leaves.
    $description = $name
    $row = Get-AppListRow -Name $name -Version $version
    if ($row) {
        if (-not $publisher) { $publisher = $row.Publisher }
        if ($row.Notes)      { $description = $row.Notes }
    }

    return [pscustomobject]@{
        appFullName     = (Get-AppFullName -Name $name -Version $version)
        name            = $name
        version         = $version
        publisher       = $publisher
        description     = $description
        detectionMethod = if ($isZeroConfigMsi) { 'MSI' } else { 'Registry' }
        productCode     = $productCode
        isZeroConfigMsi = $isZeroConfigMsi
        author          = $adt.Author
        created         = $adt.Date
    }
}

function Get-AppListRow {
    param(
        [string]$Name,
        [string]$Version,
        [string]$CsvPath = (Join-Path $rootDir 'Apps.csv')
    )

    if (-not (Test-Path -LiteralPath $CsvPath)) { return $null }

    return (Import-Csv -LiteralPath $CsvPath -Delimiter ';' | Where-Object {
        $_.Name.Trim() -eq $Name.Trim() -and $_.Version.Trim() -eq $Version.Trim()
    } | Select-Object -First 1)
}

function Add-AppListRow {
    param(
        [Parameter(Mandatory = $true)]$App,
        [string]$CsvPath = (Join-Path $rootDir 'Apps.csv')
    )

    Update-AppListSchema -CsvPath $CsvPath
    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter ';')

    $new = New-Object psobject
    foreach ($column in $script:AppListColumns) {
        $value = ''
        if ($App.PSObject.Properties.Name -contains $column) { $value = $App.$column }
        $new | Add-Member -MemberType NoteProperty -Name $column -Value $value
    }

    ($rows + $new) |
        Sort-Object Name, Version |
        Select-Object -Property $script:AppListColumns |
        Export-Csv -LiteralPath $CsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

    Write-Ok ("Added to the app list: {0} - {1}" -f $App.Name, $App.Version)
}

<#
    Takes over a package that was not built by this tool - typically a PSADT
    folder created by the older create-AppsInCM workflow - by stamping its
    metadata into the PSADT script and appending it to the master list. Name
    and version come from the folder name, the remaining details from Apps.csv
    or from the PSADT script.
#>
function Import-AppPackage {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [switch]$Bulk,
        $Config = (Get-ActiveConfig)
    )

    $folderName = Split-Path -Leaf $PackageRoot
    $parsed     = Split-AppFolderName -FolderName $folderName
    $content    = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config

    Write-Step "Importing existing package: $folderName"

    if (-not (Test-Path -LiteralPath (Join-Path $content 'Invoke-AppDeployToolkit.ps1'))) {
        throw "No PSADT script found in [$content] - this does not look like a package."
    }

    $existing = Get-PackageMetadata -PackageRoot $PackageRoot -Config $Config
    $row = Get-AppListRow -Name $parsed.Name -Version $parsed.Version

    $app = [pscustomobject]@{
        Publisher        = ''
        Name             = $parsed.Name
        Version          = $parsed.Version
        DetectionMethod  = 'Registry'
        DetectionPattern = ''
        ProductCode      = ''
        InstallCmd       = ''
        UninstallCmd     = ''
        Notes            = ''
    }

    if ($row) {
        Write-Info 'Found in the app list - using its values.'
        foreach ($column in $script:AppListColumns) {
            if ($row.PSObject.Properties.Name -contains $column) { $app.$column = $row.$column }
        }
    }
    else {
        Write-Info 'Not in the app list yet.'
    }

    # The package itself outranks the list: a zero-config MSI package brings its
    # own publisher, version and ProductCode.
    if ($existing.isZeroConfigMsi) {
        Write-Info 'Single MSI without PSADT metadata - zero-config deployment, detection by ProductCode.'
        $app.DetectionMethod = 'MSI'
        $app.ProductCode     = $existing.productCode
    }
    if ($existing.publisher) { $app.Publisher = $existing.publisher }

    # Ask only when something essential is missing and we are not in a bulk run.
    if ((-not $app.Publisher -or -not $app.Version) -and -not $Bulk) {
        $answer = Open-EditDialog -title "Import package: $folderName" -PropertyOrder $script:AppListColumns -item ([ordered]@{
            Publisher        = $app.Publisher
            Name             = $app.Name
            Version          = $app.Version
            DetectionMethod  = $app.DetectionMethod
            DetectionPattern = $app.DetectionPattern
            ProductCode      = $app.ProductCode
            InstallCmd       = $app.InstallCmd
            UninstallCmd     = $app.UninstallCmd
            Notes            = $app.Notes
        })
        $answer = $answer | Where-Object { $_ -isnot [int] }
        if (-not $answer) { throw 'Import cancelled.' }
        foreach ($key in $answer.Keys) { $app.$key = $answer[$key] }
    }

    if (-not $app.Version) { throw "No version could be determined for [$folderName] - expected a folder named '<Name> - <Version>'." }

    # Write the metadata where it belongs: into the package's own PSADT script.
    # Zero-config MSI packages keep their empty fields.
    if (-not $existing.isZeroConfigMsi) {
        $author = $Config.packageAuthor
        if ([string]::IsNullOrWhiteSpace($author)) { $author = $env:USERNAME }
        Set-ADTAppMetadata -ContentRoot $content -Publisher $app.Publisher -Name $app.Name -Version $app.Version -Author $author
        Write-Ok 'Metadata written into Invoke-AppDeployToolkit.ps1 (empty fields only).'
    }

    # Keep the master list complete - that is what the naming convention lives on.
    if (-not $row) { Add-AppListRow -App $app }

    $metadata = Get-PackageMetadata -PackageRoot $PackageRoot -Config $Config
    Write-Ok "Imported: $($metadata.appFullName)"
    return $metadata
}

<#
    Every folder below sourceRoot holding a PSADT script is a package - that is
    the only condition. What ConfigMgr knows about it is asked at the site: an
    application named "<Name> - <Version>" whose deployment type carries our
    signature is maintained by this tool, one without it was created by hand or
    by the older scripts and would have its detection overwritten on publish.
#>
function Get-AppPackage {
    param(
        $Config = (Get-ActiveConfig),
        [switch]$NoSiteLookup
    )

    $workRoot = Get-PackageWorkRoot -Config $Config
    $results  = @()

    foreach ($dir in (Get-ChildItem -LiteralPath $workRoot -Directory -ErrorAction SilentlyContinue)) {
        $contentPath = Get-PackageContentPath -PackageRoot $dir.FullName -Config $Config
        $adtScript   = Join-Path $contentPath 'Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path -LiteralPath $adtScript)) { continue }

        $parsed = Split-AppFolderName -FolderName $dir.Name

        $results += [pscustomobject]@{
            AppName      = $parsed.Name
            AppVersion   = $parsed.Version
            Status       = 'Unknown'
            LastModified = (Get-Item -LiteralPath $adtScript).LastWriteTime
            PackageRoot  = $dir.FullName
        }
    }

    if (-not $NoSiteLookup -and $results.Count -gt 0) {
        $signature = [regex]::Escape((Get-ToolSignature))
        $published = @{}

        try {
            Invoke-InCMSite -Config $Config -ScriptBlock {
                foreach ($application in (Get-CMApplication)) {
                    # The comment of the deployment type since native detection,
                    # the header of the generated detection script before that.
                    $xml = $application.SDMPackageXML
                    $published[$application.LocalizedDisplayName] =
                        ($xml -match $signature) -or ($xml -match 'Generated by SCCMAppHelper')
                }
            }

            foreach ($package in $results) {
                $fullName = Get-AppFullName -Name $package.AppName -Version $package.AppVersion
                $package.Status =
                    if     (-not $published.ContainsKey($fullName)) { 'Not published' }
                    elseif ($published[$fullName])                  { 'Published (this tool)' }
                    else                                            { 'Published (foreign)' }
            }
        }
        catch {
            Write-Warn ("Could not read the applications from the site - status stays unknown: {0}" -f $_.Exception.Message)
        }
    }

    return ($results | Sort-Object AppName, AppVersion)
}
#endregion

#region -------------------------------------------------- ConfigMgr publishing

function Publish-CMApplication {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [switch]$Bulk,
        $Config = (Get-ActiveConfig)
    )

    $metadata = Get-PackageMetadata -PackageRoot $PackageRoot -Config $Config

    # A package the master list does not know yet is taken over on the fly - the
    # detection is built from its row, so there has to be one.
    if (-not (Get-AppListRow -Name $metadata.name -Version $metadata.version)) {
        $metadata = Import-AppPackage -PackageRoot $PackageRoot -Bulk:$Bulk -Config $Config
    }

    $appFullName = $metadata.appFullName
    $contentPath = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config
    $contentUnc  = ConvertTo-CMContentPath -Path $contentPath -Config $Config

    if (-not $metadata.version) { throw "No version could be determined for [$PackageRoot] - expected a folder named '<Name> - <Version>'." }

    $app      = Resolve-PackageApp -PackageRoot $PackageRoot -Metadata $metadata -Config $Config
    $artifact = New-PublishArtifact -PackageRoot $PackageRoot -App $app -Config $Config
    $iconFile = $artifact.IconFile

    Write-Step "Publishing to ConfigMgr: $appFullName"
    Write-Info "Content location: $contentUnc"

    Invoke-InCMSite -Config $Config -ScriptBlock {

        # ---------------------------------------------------------- application
        $application = Get-CMApplication -Name $appFullName -Fast -ErrorAction SilentlyContinue

        if ($application) {
            $update = $true
            if (-not $Bulk) {
                $answer = [System.Windows.MessageBox]::Show(
                    "The application`n`n$appFullName`n`nalready exists. Update it (deployment type, detection, content)?`n`nNo = skip this package.",
                    'Application already exists', 'YesNo', 'Question')
                $update = ($answer -eq 'Yes')
            }
            if (-not $update) {
                Write-Warn 'Skipped by user.'
                return
            }
            Write-Info 'Application exists - updating.'
        }
        else {
            Write-Info 'Creating application...'
            $newAppParams = @{
                Name             = $appFullName
                LocalizedName    = $metadata.name
                Description      = $metadata.description
                Publisher        = $metadata.publisher
                SoftwareVersion  = $metadata.version
                AutoInstall      = $true          # allow use in task sequences
                ErrorAction      = 'Stop'
            }
            if (Test-Path -LiteralPath $iconFile) { $newAppParams['IconLocationFile'] = $iconFile }

            $application = New-CMApplication @newAppParams
            Write-Ok "Application created: $appFullName"

            $applicationFolder = Resolve-CMFolderPath -FolderPath $Config.applicationFolderPath -Config $Config -RootNode 'Application'
            if ($applicationFolder -and (New-CMFolderPath -FolderPath $applicationFolder)) {
                try {
                    $null = Move-CMObject -FolderPath $applicationFolder -InputObject $application -ErrorAction Stop
                    Write-Ok "Moved to console folder [$applicationFolder]"
                }
                catch { Write-Warn ("Could not move the application to [{0}]: {1}" -f $applicationFolder, $_.Exception.Message) }
            }
        }

        # ------------------------------------------------------ deployment type
        $deploymentTypeName = $appFullName
        $existingDt = Get-CMDeploymentType -ApplicationName $appFullName -DeploymentTypeName $deploymentTypeName -ErrorAction SilentlyContinue

        $dtParams = @{
            ApplicationName          = $appFullName
            DeploymentTypeName       = $deploymentTypeName
            ContentLocation          = $contentUnc
            InstallCommand           = $Config.installCommand
            UninstallCommand         = $Config.uninstallCommand
            InstallationBehaviorType = 'InstallForSystem'
            LogonRequirementType     = 'WhetherOrNotUserLoggedOn'
            Comment                  = (Get-ToolSignature)
            ErrorAction              = 'Stop'
        }
        if ($Config.maximumRuntimeMins)   { $dtParams['MaximumRuntimeMins']   = $Config.maximumRuntimeMins }
        if ($Config.estimatedRuntimeMins) { $dtParams['EstimatedRuntimeMins'] = $Config.estimatedRuntimeMins }

        # Detection: a native clause wherever the ConfigMgr client can evaluate
        # it itself, a PowerShell script only for DetectionMethod = Script.
        if ($app.DetectionMethod -eq 'Script') {
            $dtParams['ScriptLanguage'] = 'PowerShell'
            $dtParams['ScriptText']     = Get-Content -Raw -LiteralPath $artifact.DetectionScript
            Write-Info 'Detection: PowerShell script.'
        }
        else {
            $detection = New-AppDetectionClause -App $app
            $dtParams['AddDetectionClause'] = $detection.Clauses
            Write-Info ("Detection: native {0} clause, {1} rule(s)." -f $app.DetectionMethod, $detection.Clauses.Count)
        }

        if ($existingDt) {
            # Detection clauses are only ever added, never replaced, and a clause
            # that was created together with the deployment type cannot be
            # removed again at all - Set-CMScriptDeploymentType reports it as
            # "not found" and silently leaves it in place. Re-applying the same
            # clauses on every publish therefore stacks another copy on top and
            # the rule ends up referencing all of them.
            # So the detection is compared first and only touched when it really
            # differs. ScriptText has no such problem, it simply overwrites.
            if ($dtParams.ContainsKey('AddDetectionClause')) {
                $stored = Get-DeploymentTypeDetection -DeploymentType $existingDt

                if ($stored.Fingerprint -eq $detection.Fingerprint) {
                    $dtParams.Remove('AddDetectionClause')
                    Write-Info 'Detection unchanged - leaving it alone.'
                }
                else {
                    $obsolete = @($stored.Clauses | ForEach-Object { $_.Setting.LogicalName } | Where-Object { $_ })
                    if ($obsolete.Count -gt 0) { $dtParams['RemoveDetectionClause'] = $obsolete }
                    Write-Warn ("Detection differs from the {0} rule(s) on the deployment type - replacing it." -f $stored.RuleCount)
                }
            }

            Write-Info 'Updating deployment type...'
            $null = Set-CMScriptDeploymentType @dtParams
            Write-Ok 'Deployment type updated.'

            # ConfigMgr accepts a removal it did not perform, so the result has
            # to be checked rather than assumed.
            if ($dtParams.ContainsKey('AddDetectionClause')) {
                $after = Get-DeploymentTypeDetection -DeploymentType (Get-CMDeploymentType -ApplicationName $appFullName -DeploymentTypeName $deploymentTypeName)
                if ($after.RuleCount -ne $detection.Clauses.Count) {
                    Write-Fail ("Detection now has {0} rule(s) instead of {1}. ConfigMgr kept clauses it refuses to remove - correct the detection method of [{2}] in the console." -f $after.RuleCount, $detection.Clauses.Count, $deploymentTypeName)
                }
            }
        }
        else {
            Write-Info 'Creating deployment type...'
            $null = Add-CMScriptDeploymentType @dtParams
            Write-Ok "Deployment type created: $deploymentTypeName"
        }

        # ------------------------------------------------------------- content
        # Start-CMContentDistribution assigns the content to a distribution
        # target, Update-CMDistributionPoint only refreshes content that is
        # already assigned. Which of the two applies does not follow from
        # "the deployment type already existed": a package first published
        # with distributeContent off has a deployment type but no content on
        # any distribution point, and a refresh alone would never put it
        # there - the deployments then fail with "There are no distribution
        # points or distribution point groups in this application".
        # So always try to assign first and fall back to a refresh when the
        # content already sits on the target.
        if ($Config.distributeContent) {
            $distributionParams = @{ ApplicationName = $appFullName; ErrorAction = 'Stop' }
            if ($Config.distributionPointGroupName) { $distributionParams['DistributionPointGroupName'] = $Config.distributionPointGroupName }
            elseif ($Config.distributionPointName)  { $distributionParams['DistributionPointName']      = $Config.distributionPointName }

            try {
                $null = Start-CMContentDistribution @distributionParams
                Write-Ok 'Content distribution started.'
            }
            catch {
                # Already distributed to this target - ConfigMgr reports
                # "No content destination was found. ... or if the content has
                # already been distributed to the specified destination."
                $distributionError = $_.Exception.Message
                try {
                    $null = Update-CMDistributionPoint -ApplicationName $appFullName -DeploymentTypeName $deploymentTypeName -ErrorAction Stop
                    Write-Ok 'Content already distributed - update triggered on the distribution points.'
                }
                catch {
                    Write-Warn ("Content distribution: {0}" -f $distributionError)
                    Write-Warn ("Content update: {0}" -f $_.Exception.Message)
                }
            }
        }

        # --------------------------------------------------------- collections
        $targetCollections = @()
        foreach ($collectionDefinition in $Config.collections) {
            $collectionName = $collectionDefinition.namePattern.Replace('{App}', $appFullName)
            $collection = Get-CMDeviceCollection -Name $collectionName -ErrorAction SilentlyContinue

            if (-not $collection) {
                try {
                    $schedule = New-CMSchedule -RecurInterval Days -RecurCount 1
                    $collection = New-CMDeviceCollection -Name $collectionName `
                        -LimitingCollectionName $Config.limitingCollectionName `
                        -RefreshType Periodic -RefreshSchedule $schedule -ErrorAction Stop
                    Write-Ok "Collection created: $collectionName"

                    $collectionFolder = Resolve-CMFolderPath -FolderPath $Config.collectionFolderPath -Config $Config -RootNode 'DeviceCollection'
                    if ($collectionFolder -and (New-CMFolderPath -FolderPath $collectionFolder)) {
                        try { $null = Move-CMObject -FolderPath $collectionFolder -InputObject $collection -ErrorAction Stop }
                        catch { Write-Warn ("Could not move the collection: {0}" -f $_.Exception.Message) }
                    }
                }
                catch { Write-Fail ("Collection [{0}]: {1}" -f $collectionName, $_.Exception.Message); continue }
            }
            else { Write-Info "Collection already exists: $collectionName" }

            $targetCollections += [pscustomobject]@{
                CollectionName   = $collectionName
                DeployPurpose    = $collectionDefinition.deployPurpose
                UserNotification = $collectionDefinition.userNotification
            }
        }

        foreach ($globalDeployment in $Config.globalDeployments) {
            $targetCollections += [pscustomobject]@{
                CollectionName   = $globalDeployment.collectionName
                DeployPurpose    = $globalDeployment.deployPurpose
                UserNotification = $globalDeployment.userNotification
            }
        }

        # --------------------------------------------------------- deployments
        if ($Config.createDeployments) {
            foreach ($target in $targetCollections) {
                if (-not (Get-CMDeviceCollection -Name $target.CollectionName -ErrorAction SilentlyContinue)) {
                    Write-Warn "Collection [$($target.CollectionName)] does not exist - skipping deployment."
                    continue
                }

                $existingDeployment = $null
                try { $existingDeployment = Get-CMApplicationDeployment -Name $appFullName -CollectionName $target.CollectionName -ErrorAction SilentlyContinue } catch { }
                if ($existingDeployment) {
                    Write-Info "Deployment already exists: $($target.CollectionName)"
                    continue
                }

                try {
                    $null = New-CMApplicationDeployment -ApplicationName $appFullName `
                        -CollectionName $target.CollectionName `
                        -DeployAction Install `
                        -DeployPurpose $target.DeployPurpose `
                        -UserNotification $target.UserNotification `
                        -ErrorAction Stop
                    Write-Ok "Deployment created: $($target.DeployPurpose) -> $($target.CollectionName)"
                }
                catch { Write-Fail ("Deployment [{0}]: {1}" -f $target.CollectionName, $_.Exception.Message) }
            }
        }

        # -------------------------------------------------------- supersedence
        if ($Config.supersedeOlderVersions) {
            Add-CMApplicationSupersedenceForOlderVersions -AppFullName $appFullName -Name $metadata.name -Version $metadata.version -Config $Config
        }
    }

    Remove-Item -LiteralPath $artifact.Path -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Finished: $appFullName"
}

<#
    Wires the new application as superseding every older version of the same
    product ("<Name> - <older version>"). This is what makes ConfigMgr replace
    an old package instead of leaving two versions deployed side by side.
#>
function Add-CMApplicationSupersedenceForOlderVersions {
    param(
        [Parameter(Mandatory = $true)][string]$AppFullName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        $Config = (Get-ActiveConfig)
    )

    $newVersion = $null
    if (-not [System.Version]::TryParse($Version, [ref]$newVersion)) {
        Write-Info 'Version is not comparable - skipping supersedence.'
        return
    }

    $candidates = Get-CMApplication -Fast | Where-Object {
        $_.LocalizedDisplayName -like ("{0} - *" -f $Name) -and $_.LocalizedDisplayName -ne $AppFullName
    }

    $newDt = Get-CMDeploymentType -ApplicationName $AppFullName | Select-Object -First 1
    if (-not $newDt) { return }

    foreach ($candidate in $candidates) {
        $oldVersion = $null
        if (-not [System.Version]::TryParse($candidate.SoftwareVersion, [ref]$oldVersion)) { continue }
        if ($oldVersion -ge $newVersion) { continue }

        $oldDt = Get-CMDeploymentType -ApplicationName $candidate.LocalizedDisplayName | Select-Object -First 1
        if (-not $oldDt) { continue }

        # Set-CMApplicationSupersedence, not Add-CMDeploymentTypeSupersedence:
        # the latter is deprecated and warns on every publish. Same relation -
        # the superseding deployment type replaces the old one.
        try {
            $null = Set-CMApplicationSupersedence -Name $AppFullName `
                -CurrentDeploymentTypeName $newDt.LocalizedDisplayName `
                -SupersededApplicationName $candidate.LocalizedDisplayName `
                -OldDeploymentTypeName $oldDt.LocalizedDisplayName `
                -IsUninstall ([bool]$Config.supersedenceUninstall) `
                -ErrorAction Stop
            Write-Ok "Supersedes: $($candidate.LocalizedDisplayName)"
        }
        catch {
            Write-Info ("Supersedence for [{0}] not set: {1}" -f $candidate.LocalizedDisplayName, $_.Exception.Message)
        }
    }
}

#endregion

#region ------------------------------------------------------------ workflows

function createApps {
    param(
        [switch]$createAndPublish,
        [string]$csvPath = (Join-Path $rootDir 'Apps.csv')
    )

    $config = Get-ActiveConfig
    Update-AppListSchema -CsvPath $csvPath

    while ($true) {
        $title = if ($createAndPublish) { 'Select applications to create and publish' } else { 'Select applications to create' }
        $apps = Open-SelectDialogWithEdit -CsvPath $csvPath -title $title -size large

        # Known WPF quirk: the selection collection can also contain int values.
        if ($null -ne $apps) { $apps = $apps | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] } }
        if ($null -eq $apps -or ($apps | Measure-Object).Count -eq 0) { break }

        foreach ($app in $apps) {
            try {
                $packageRoot = New-AppPackage -App $app -Config $config

                if ($config.openExplorerOnCreate -or $config.openEditorOnCreate) {
                    $contentPath = Get-PackageContentPath -PackageRoot $packageRoot -Config $config

                    if ($config.openExplorerOnCreate) {
                        Write-Host 'ToDo: copy all setup files into .\Files, then press ENTER' -ForegroundColor Cyan
                        explorer (Join-Path $contentPath 'Files')
                        pause
                    }
                    if ($config.openEditorOnCreate) {
                        Write-Host 'ToDo: fill the Install & Uninstall sections, then press ENTER' -ForegroundColor Cyan
                        $editor = if ($config.editor) { $config.editor } else { 'notepad' }
                        & $editor (Join-Path $contentPath 'Invoke-AppDeployToolkit.ps1')
                        pause
                    }
                }

                if ($createAndPublish) {
                    Publish-CMApplication -PackageRoot $packageRoot -Bulk:(($apps | Measure-Object).Count -gt 1) -Config $config
                }
            }
            catch {
                Write-Fail ("[{0} - {1}] {2}" -f $app.Name, $app.Version, $_.Exception.Message)
                if (($apps | Measure-Object).Count -eq 1) { pause }
            }
        }
    }
}

function deployApps {
    $config = Get-ActiveConfig
    $packages = Get-AppPackage -Config $config

    if (($packages | Measure-Object).Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No packages found below`n`n$(Get-PackageWorkRoot -Config $config)`n`nExpected one folder per package, containing Invoke-AppDeployToolkit.ps1 either directly or in a Content subfolder.",
            'SCCMAppHelper', 'OK', 'Information') | Out-Null
        return
    }

    $selection = Open-SelectDialog -data ($packages | Select-Object AppName, AppVersion, Status, LastModified, PackageRoot) -title 'Select packages to publish to ConfigMgr' -large
    if ($null -ne $selection) { $selection = $selection | Where-Object { $_ -isnot [int] } }
    if ($null -eq $selection -or ($selection | Measure-Object).Count -eq 0) { return }

    $bulk = (($selection | Measure-Object).Count -gt 1)
    foreach ($package in $selection) {
        try   { Publish-CMApplication -PackageRoot $package.PackageRoot -Bulk:$bulk -Config $config }
        catch { Write-Fail ("[{0}] {1}" -f $package.AppName, $_.Exception.Message) }
    }
}

#endregion

#region ---------------------------------------------------------------- tools

function Update-AppCollections {
    $config = Get-ActiveConfig

    Invoke-InCMSite -Config $config -ScriptBlock {
        foreach ($pattern in $config.collectionUpdatePatterns) {
            Write-Step "Updating collections matching [$pattern]"
            foreach ($collection in (Get-CMDeviceCollection -Name $pattern)) {
                $null = Invoke-CMCollectionUpdate -CollectionId $collection.CollectionID
                Write-Ok "Updated: $($collection.Name)"
            }
        }
    }
}

<#
    Rebuilds a collection of clients that have an older version installed than
    the version currently deployed as required (ported from
    create-CollForOutdatedApps.ps1).
#>
function Update-OutdatedAppsCollection {
    $config = Get-ActiveConfig
    $collectionName = $config.outdatedAppsCollectionName

    $sql = @"
SELECT DISTINCT sys.Name0 AS ComputerName, sys.ResourceID
FROM v_R_System sys
INNER JOIN vAppDeploymentAssetDetails ads ON ads.MachineName = sys.Name0
INNER JOIN v_ApplicationAssignment aa
    ON  aa.AssignmentID = ads.AssignmentID
    AND aa.OfferTypeID  = 0
    AND aa.CollectionName LIKE @requiredCollectionPattern
INNER JOIN v_Applications app ON app.ModelId = aa.AppModelID
OUTER APPLY (
    SELECT TOP 1 DisplayName0, Version0
    FROM (
        SELECT DisplayName0, Version0, ResourceID FROM v_GS_ADD_REMOVE_PROGRAMS
        UNION ALL
        SELECT DisplayName0, Version0, ResourceID FROM v_GS_ADD_REMOVE_PROGRAMS_64
    ) arp_all
    WHERE arp_all.ResourceID = sys.ResourceID
      AND arp_all.DisplayName0 LIKE
          LEFT(app.DisplayName,
               CASE WHEN CHARINDEX(' - ', app.DisplayName) > 0
                    THEN CHARINDEX(' - ', app.DisplayName) - 1
                    ELSE LEN(app.DisplayName) END) + '%'
    ORDER BY LEN(arp_all.DisplayName0) ASC
) arp
WHERE arp.DisplayName0 IS NOT NULL
  AND arp.Version0 IS NOT NULL
  AND arp.Version0 != app.SoftwareVersion
  AND (
    CASE
      WHEN ISNULL(TRY_CAST(PARSENAME(arp.Version0,4) AS INT),0) < ISNULL(TRY_CAST(PARSENAME(app.SoftwareVersion,4) AS INT),0) THEN -1
      WHEN ISNULL(TRY_CAST(PARSENAME(arp.Version0,4) AS INT),0) > ISNULL(TRY_CAST(PARSENAME(app.SoftwareVersion,4) AS INT),0) THEN 1
      WHEN ISNULL(TRY_CAST(PARSENAME(arp.Version0,3) AS INT),0) < ISNULL(TRY_CAST(PARSENAME(app.SoftwareVersion,3) AS INT),0) THEN -1
      WHEN ISNULL(TRY_CAST(PARSENAME(arp.Version0,3) AS INT),0) > ISNULL(TRY_CAST(PARSENAME(app.SoftwareVersion,3) AS INT),0) THEN 1
      WHEN ISNULL(TRY_CAST(PARSENAME(arp.Version0,2) AS INT),0) < ISNULL(TRY_CAST(PARSENAME(app.SoftwareVersion,2) AS INT),0) THEN -1
      WHEN ISNULL(TRY_CAST(PARSENAME(arp.Version0,2) AS INT),0) > ISNULL(TRY_CAST(PARSENAME(app.SoftwareVersion,2) AS INT),0) THEN 1
      WHEN ISNULL(TRY_CAST(PARSENAME(arp.Version0,1) AS INT),0) < ISNULL(TRY_CAST(PARSENAME(app.SoftwareVersion,1) AS INT),0) THEN -1
      ELSE 0
    END
  ) < 0
"@

    # Derive the pattern of the "required" collections from the naming scheme
    # instead of hard coding it, so the query follows a changed convention.
    $requiredDefinition = $config.collections | Where-Object { $_.deployPurpose -eq 'Required' } | Select-Object -First 1
    $requiredPattern = if ($requiredDefinition) { $requiredDefinition.namePattern.Replace('{App}', '%') } else { 'ins-req-dev-%' }

    Write-Step "Querying outdated clients on [$($config.sqlServer)/$($config.database)] for [$requiredPattern]"

    $results = @()
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=$($config.sqlServer);Database=$($config.database);Integrated Security=true"
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        $null = $command.Parameters.AddWithValue('@requiredCollectionPattern', $requiredPattern)
        $reader = $command.ExecuteReader()
        while ($reader.Read()) {
            $results += [pscustomobject]@{ ComputerName = $reader['ComputerName']; ResourceID = $reader['ResourceID'] }
        }
        $reader.Close()
    }
    finally {
        $connection.Close()
    }

    Write-Ok "$($results.Count) clients with outdated applications found."

    Invoke-InCMSite -Config $config -ScriptBlock {
        $collection = Get-CMDeviceCollection -Name $collectionName -ErrorAction SilentlyContinue

        if (-not $collection) {
            $schedule = New-CMSchedule -RecurInterval Days -RecurCount 1
            $collection = New-CMDeviceCollection -Name $collectionName `
                -LimitingCollectionName $config.limitingCollectionName `
                -RefreshType Periodic -RefreshSchedule $schedule
            Write-Ok "Collection created: $collectionName"
        }
        else {
            Get-CMDeviceCollectionDirectMembershipRule -CollectionName $collectionName | ForEach-Object {
                $null = Remove-CMDeviceCollectionDirectMembershipRule -CollectionName $collectionName -ResourceId $_.ResourceID -Force
            }
            Write-Info "Collection emptied: $collectionName"
        }

        foreach ($device in $results) {
            $null = Add-CMDeviceCollectionDirectMembershipRule -CollectionName $collectionName -ResourceId $device.ResourceID
        }

        $null = Invoke-CMCollectionUpdate -Name $collectionName
        Write-Ok "$($results.Count) clients written to [$collectionName]"
    }
}

<#
    Adds or removes a role collection (rol-dev-*) as an include rule of the
    application collections (ins-*) - ported from add-ServerRoleToAppCollections.ps1.
#>
function Edit-RoleCollectionMembership {
    $config = Get-ActiveConfig

    Invoke-InCMSite -Config $config -ScriptBlock {
        $roleCollections = Get-CMCollection -Name $config.roleCollectionPattern |
            Select-Object Name, CollectionID

        if (-not $roleCollections) { Write-Warn "No collections matching [$($config.roleCollectionPattern)] found."; return }

        $selectedRole = Open-SelectDialog -data $roleCollections -title 'Which role collection should be changed?'
        if ($null -ne $selectedRole) { $selectedRole = $selectedRole | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
        if (-not $selectedRole) { return }

        $roleName = $selectedRole.Name

        $action = Open-SelectDialog -data (@('Add', 'Remove') | ForEach-Object { [pscustomobject]@{ Action = $_ } }) -title 'Which action?'
        if ($null -ne $action) { $action = $action | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
        if (-not $action) { return }

        Write-Step "Reading application collections [$($config.appCollectionPattern)]"
        $appCollections = Get-CMCollection -CollectionType Device -Name $config.appCollectionPattern

        $currentMemberships = @()
        foreach ($appCollection in $appCollections) {
            $rule = Get-CMDeviceCollectionIncludeMembershipRule -CollectionName $appCollection.Name |
                Where-Object { $_.RuleName -eq $roleName }
            if ($rule) { $currentMemberships += $appCollection.Name }
        }

        if ($action.Action -eq 'Add') {
            $available = $appCollections |
                Where-Object { $_.Name -notin $currentMemberships } |
                Select-Object Name, CollectionID

            $targets = Open-SelectDialog -data $available -title "Add [$roleName] to which collections?" -large
            if ($null -ne $targets) { $targets = $targets | Where-Object { $_ -isnot [int] } }

            foreach ($target in $targets) {
                Write-Info "Adding $roleName -> $($target.Name)"
                $null = Add-CMDeviceCollectionIncludeMembershipRule -CollectionName $target.Name -IncludeCollectionName $roleName
            }
        }
        else {
            if ($currentMemberships.Count -eq 0) { Write-Info "[$roleName] is not included anywhere."; return }

            $targets = Open-SelectDialog -data ($currentMemberships | ForEach-Object { [pscustomobject]@{ Name = $_ } }) -title "Remove [$roleName] from which collections?" -large
            if ($null -ne $targets) { $targets = $targets | Where-Object { $_ -isnot [int] } }

            foreach ($target in $targets) {
                Write-Info "Removing $roleName <- $($target.Name)"
                $null = Remove-CMDeviceCollectionIncludeMembershipRule -CollectionName $target.Name -IncludeCollectionName $roleName -Force
            }
        }

        Write-Ok 'Finished.'
    }
}

function Show-ToolsMenu {
    $tools = @(
        [pscustomobject]@{ Tool = 'Update collections';            Description = 'Trigger a membership update for all configured collection patterns.' }
        [pscustomobject]@{ Tool = 'Rebuild outdated apps';         Description = 'Refill the collection of clients running an outdated version.' }
        [pscustomobject]@{ Tool = 'Role collection membership';    Description = 'Add or remove a role collection in the application collections.' }
        [pscustomobject]@{ Tool = 'Switch ConfigMgr site';         Description = 'Work against a different site of the "sites" list in config.json.' }
        [pscustomobject]@{ Tool = 'Add ConfigMgr site';            Description = 'Setup assistant: connect to a server and read its settings automatically.' }
        [pscustomobject]@{ Tool = 'Check site configuration';      Description = 'Test provider, share, console module, SQL and collections of the active site.' }
    )

    $selection = Open-SelectDialog -data $tools -title 'Tools'
    if ($null -ne $selection) { $selection = $selection | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
    if (-not $selection) { return }

    switch ($selection.Tool) {
        'Update collections'         { Update-AppCollections }
        'Rebuild outdated apps'      { Update-OutdatedAppsCollection }
        'Role collection membership' { Edit-RoleCollectionMembership }
        'Switch ConfigMgr site'      { $null = Get-ActiveConfig -ForceSiteSelection }
        'Add ConfigMgr site'         { $null = Start-SetupWizard }
        'Check site configuration'   { $null = Test-SiteConfiguration }
    }
}

#endregion
