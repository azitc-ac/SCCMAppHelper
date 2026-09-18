<#
    SCCMAppHelper - core functions
    https://blog.zarenko.net

    Workflow:
        definition (Apps.csv)  ->  package on the source share  ->  ConfigMgr application

    The three are joined into one list by Get-AppInventory (inventory.ps1), and
    every action is taken from a row of that list.

    All ConfigMgr work lives in Publish-CMApplication. A package carries nothing
    but its PSADT content - the detection script and the icon are rendered at
    publish time, so fixes made here reach packages built with an older version
    of the tool as well.
#>

if (-not $rootDir) { $rootDir = Split-Path -Parent $PSScriptRoot }
if (-not $toolVersion) {
    # Loaded without the start script - a test, or a dot-source at a prompt.
    $toolVersion = '1.1'
    $versionFile = Join-Path $rootDir 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        $fileVersion = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim()
        if ($fileVersion) { $toolVersion = $fileVersion }
    }
}

. "$rootDir\Functions\ui.ps1"
. "$rootDir\Functions\setup.ps1"
. "$rootDir\Functions\wingetindex.ps1"
. "$rootDir\Functions\catalog.ps1"
. "$rootDir\Functions\retire.ps1"
. "$rootDir\Functions\inventory.ps1"
. "$rootDir\Functions\sourceroot.ps1"

#region --------------------------------------------------------------- output

<#
    An error message with the place it came from.

    "Cannot validate argument on parameter 'Path'" says nothing about which of
    the dozen calls in a publish run produced it. The file and line do, and they
    cost one property of the error record.
#>
function Format-ErrorDetail {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $info    = $ErrorRecord.InvocationInfo
    if ($info -and $info.ScriptName) {
        return ('{0} ({1}:{2})' -f $message, (Split-Path -Leaf $info.ScriptName), $info.ScriptLineNumber)
    }
    return $message
}

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

<#
    The pattern that recognises the signature of any version of the tool. An
    application published by 1.0 is still ours after the version moved on -
    matching the exact signature would have reported every one of them as
    foreign, and Publish would have warned about overwriting its own detection.
#>
function Get-ToolSignaturePattern { return 'SCCMAppHelper \d+(\.\d+)*' }

#endregion

#region --------------------------------------------------------------- config

function Get-AppHelperConfig {
    param([string]$Path = (Join-Path $rootDir 'Config\config.json'))

    # config.json belongs to the machine, not to the repository - it holds the
    # sites of this environment and is not versioned, so no update, pull or
    # reset can overwrite it. What ships is config.sample.json, and the first
    # start copies it. The setup assistant then fills in the real site.
    if (-not (Test-Path -LiteralPath $Path)) {
        $sample = Join-Path (Split-Path -Parent $Path) 'config.sample.json'
        if (Test-Path -LiteralPath $sample) {
            Copy-Item -LiteralPath $sample -Destination $Path -Force
            Write-Info "No configuration yet - started from $(Split-Path -Leaf $sample)."
        }
    }

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
        P01:\Application\Apps    -> <SiteCode>:\Application\Apps
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
    drive and restores the previous location afterwards - no more "cd P01:" /
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
    'PreInstallCmd'      # PSADT code before the install (after the tool's uninstall-previous block)
    'PostInstallCmd'     # PSADT code after the install
    'PreUninstallCmd'    # PSADT code before the uninstall
    'PostUninstallCmd'   # PSADT code after the uninstall
    'UninstallPrevious'  # true: remove older versions in the pre-install section
    'Notes'
)

# The six phases the tool writes from a row, and the column each comes from.
$script:PackagePhases = [ordered]@{
    PreInstall    = 'PreInstallCmd'
    Install       = 'InstallCmd'
    PostInstall   = 'PostInstallCmd'
    PreUninstall  = 'PreUninstallCmd'
    Uninstall     = 'UninstallCmd'
    PostUninstall = 'PostUninstallCmd'
}

<#
    What a column holds in a fresh record. One place, so the columns and their
    defaults cannot drift apart.
#>
function Get-AppColumnDefault {
    param([Parameter(Mandatory = $true)][string]$Column)

    switch ($Column) {
        'DetectionMethod'   { return 'Registry' }
        'UninstallPrevious' { return 'false' }
        default             { return '' }
    }
}

<#
    An empty app record carrying exactly the columns of the app list.

    Every record the tool builds comes from here. Three call sites used to spell
    the same literal out by hand, and adding UninstallPrevious to two of them
    was enough to make publishing fail with "the property cannot be found on
    this object" - a record built from the column list cannot fall behind it.
#>
function New-AppRecord {
    $app = New-Object psobject
    foreach ($column in $script:AppListColumns) {
        $app | Add-Member -MemberType NoteProperty -Name $column -Value (Get-AppColumnDefault -Column $column)
    }
    return $app
}

function Update-AppListSchema {
    param([Parameter(Mandatory = $true)][string]$CsvPath)

    # A missing file and a file emptied by hand are the same situation: there is
    # no header to read the shape from, so one is written.
    $header = $null
    if (Test-Path -LiteralPath $CsvPath) {
        $header = Get-Content -LiteralPath $CsvPath -TotalCount 1 -ErrorAction SilentlyContinue
    }

    if (-not $header -or [string]::IsNullOrWhiteSpace(($header -replace [char]0xFEFF, ''))) {
        Write-Warn "App list is empty, writing the column header: $CsvPath"
        Set-Content -LiteralPath $CsvPath -Value ('"' + ($script:AppListColumns -join '";"') + '"') -Encoding UTF8
        return
    }

    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter ';')
    if ($rows.Count -eq 0) { return }

    $existingColumns = $rows[0].PSObject.Properties.Name
    $missing = $script:AppListColumns | Where-Object { $_ -notin $existingColumns }

    $upgraded = foreach ($row in $rows) {
        foreach ($column in $missing) {
            $row | Add-Member -MemberType NoteProperty -Name $column -Value (Get-AppColumnDefault -Column $column) -Force
        }
        $row
    }

    $order  = $script:AppListColumns + ($existingColumns | Where-Object { $_ -notin $script:AppListColumns })
    $sorted = @($upgraded | Sort-Object Name, Version)

    # This runs on every read of the list, and it used to write the file every
    # time - a write to the share for a question that is almost always "nothing
    # to do". The file is only rewritten when a column is missing or the rows
    # are genuinely out of order.
    $before = ($rows    | ForEach-Object { '{0}|{1}' -f $_.Name, $_.Version }) -join "`n"
    $after  = ($sorted  | ForEach-Object { '{0}|{1}' -f $_.Name, $_.Version }) -join "`n"
    if (-not $missing -and $before -eq $after) { return }

    $sorted |
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
    Flat layout (default):  <package>\          = PSADT root = content location
    Subfolder layout:       <package>\Content\  = PSADT root = content location

    An existing package is read from what is on disk, so both keep working and
    packageLayout only decides where a new one is created.

    Flat is the default because nothing else belongs beside the content: what
    ConfigMgr needs on top of it - detection script and icon - is rendered into a
    temporary folder at publish time by New-PublishArtifact. The Content
    subfolder existed to keep the old _Helper out of what is distributed; with
    that gone it wrapped a single folder and cost eight characters of path
    length, which is what pushed six files of an SQL Server Management Studio
    package past the 260 character limit.
#>
function Get-PackageContentPath {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        $Config = (Get-ActiveConfig)
    )

    if (Get-ADTScript -ContentRoot (Join-Path $PackageRoot 'Content')) { return (Join-Path $PackageRoot 'Content') }
    if (Get-ADTScript -ContentRoot $PackageRoot)                       { return $PackageRoot }
    if (Get-ADTScript -ContentRoot (Join-Path $PackageRoot 'in'))      { return (Join-Path $PackageRoot 'in') }   # the predecessor tool's layout
    if ($Config.packageLayout -eq 'Flat') { return $PackageRoot }
    return (Join-Path $PackageRoot 'Content')
}

<#
    The PSADT script of a package, whichever toolkit generation built it:

        4   Invoke-AppDeployToolkit.ps1, $adtSession block, Config\config.psd1
        3   Deploy-Application.ps1, $appVendor variables, AppDeployToolkitConfig.xml

    Where a package comes from does not matter - the older scripts, another
    tool, a hand made folder - as long as it is "<Name> - <Version>" with a
    PSADT structure inside. Returns $null for anything else, which the
    inventory shows as Legacy and leaves alone.
#>
function Get-ADTScript {
    param([Parameter(Mandatory = $true)][string]$ContentRoot)

    $v4 = Join-Path $ContentRoot 'Invoke-AppDeployToolkit.ps1'
    if (Test-Path -LiteralPath $v4) {
        return [pscustomobject]@{ Path = $v4; Toolkit = '4'; Executable = 'Invoke-AppDeployToolkit.exe' }
    }
    $v3 = Join-Path $ContentRoot 'Deploy-Application.ps1'
    if (Test-Path -LiteralPath $v3) {
        return [pscustomobject]@{ Path = $v3; Toolkit = '3'; Executable = 'Deploy-Application.exe' }
    }
    return $null
}

<#
    The install or uninstall command line of the deployment type. The
    configured one names Invoke-AppDeployToolkit.exe; a PSADT 3 package is
    started through Deploy-Application.exe with the same arguments.
#>
function Get-PackageCommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Section,
        $Config = (Get-ActiveConfig)
    )

    $command = $(if ($Section -eq 'Install') { [string]$Config.installCommand } else { [string]$Config.uninstallCommand })
    $script  = Get-ADTScript -ContentRoot $ContentPath
    if ($script -and $script.Toolkit -eq '3') {
        $command = $command -replace 'Invoke-AppDeployToolkit(\.exe|\.ps1)?', 'Deploy-Application$1'
    }
    return $command
}


<#
    A cheap description of what is in the content folder: how many files, how
    many bytes, and when the newest of them was written. Only metadata is read,
    so even a five gigabyte package is answered in a moment.

    It exists because Update-CMDistributionPoint creates a *new content object*
    every time it runs, not a new version of the existing one. A client treats
    that as content it has never seen and downloads the whole package again.
    Publishing an unchanged package three times therefore left three complete
    copies in the client cache, filled it, and from then on every distribution
    failed with 0x87D01201 while the client quietly went on running the old
    content - the source, the application and the deployment all looked correct
    the whole time.

    The fingerprint is kept in the deployment type comment, which Set-CM
    ScriptDeploymentType writes without touching the content object.
#>
function Measure-ContentFolder {
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        # Given: the path length is measured as the site will see it.
        [string]$ContentUnc,
        # Given: files below this path are counted separately - that is what
        # says whether a package has an installer at all.
        [string]$FilesPath,
        [int]$Limit = 259
    )

    $scan = [pscustomobject]@{
        Fingerprint = ''
        FilesCount  = 0
        TotalFiles  = 0
        Longest     = 0
        Overlong    = 0
        Worst       = ''
        Limit       = $Limit
    }
    if (-not (Test-Path -LiteralPath $ContentPath)) { return $scan }

    $local     = $ContentPath.TrimEnd('\')
    $prefix    = $(if ($ContentUnc) { $ContentUnc.TrimEnd('\') } else { '' })
    $filesRoot = $(if ($FilesPath) { $FilesPath.TrimEnd('\') + '\' } else { '' })

    $bytes  = [long]0
    $newest = [long]0
    # Counted separately on purpose: the fingerprint counts the files it could
    # actually stat, exactly as it did when it was its own function. The
    # deployment types on the site carry fingerprints in that shape, and a
    # different count would report every published package as changed.
    $statted = 0

    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($local, '*', [System.IO.SearchOption]::AllDirectories)) {
            $scan.TotalFiles++

            try {
                $info = [System.IO.FileInfo]::new($file)
                $statted++
                $bytes += $info.Length
                if ($info.LastWriteTimeUtc.Ticks -gt $newest) { $newest = $info.LastWriteTimeUtc.Ticks }
            }
            catch { }   # a file we cannot stat simply does not count towards the sum

            if ($filesRoot -and $file.StartsWith($filesRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $scan.FilesCount++ }

            if ($prefix) {
                $length = $prefix.Length + ($file.Length - $local.Length)
                if ($length -gt $scan.Longest) { $scan.Longest = $length; $scan.Worst = $file.Substring($local.Length) }
                if ($length -gt $Limit) { $scan.Overlong++ }
            }
        }
    }
    catch { }

    $scan.Fingerprint = '{0}f/{1}b/{2}' -f $statted, $bytes, $newest
    if (-not $filesRoot) { $scan.FilesCount = $scan.TotalFiles }
    return $scan
}

<#
    The scan of a package, remembered for the rest of the session.

    The list is read again after every action, and walking a share of packages
    three times over - once for the file count, once for the path length, once
    for the fingerprint - was most of the wait. The walk happens once now, and
    the result is kept until something changes it: Refresh drops everything,
    and an action that touches a package drops that package
    (Clear-InventoryCache).
#>
$script:PackageScanCache = @{}

function Get-PackageScan {
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [string]$ContentUnc,
        [string]$FilesPath,
        [switch]$Force
    )

    $key = $ContentPath.ToLowerInvariant()
    if (-not $Force -and $script:PackageScanCache.ContainsKey($key)) { return $script:PackageScanCache[$key] }

    $scan = Measure-ContentFolder -ContentPath $ContentPath -ContentUnc $ContentUnc -FilesPath $FilesPath
    $script:PackageScanCache[$key] = $scan
    return $scan
}

<#
    The publisher a package carries in its own PSADT script, for the rows that
    have no definition to take it from.

    Read-ADTMetadata parses the whole script through the AST, which is right
    when the values are about to be written back but far too much for filling
    one column of a list: it was 40 ms per package, on every read. Here the
    line is picked out of the text and the answer is kept for the session.
#>
$script:PackagePublisherCache = @{}

function Get-PackagePublisher {
    param([Parameter(Mandatory = $true)][string]$ContentPath)

    $key = $ContentPath.ToLowerInvariant()
    if ($script:PackagePublisherCache.ContainsKey($key)) { return $script:PackagePublisherCache[$key] }

    $publisher = ''
    $script = Get-ADTScript -ContentRoot $ContentPath
    if ($script) {
        try {
            $text = Get-Content -LiteralPath $script.Path -Raw -ErrorAction Stop
            if ($text -match "AppVendor\s*=\s*['`"]([^'`"]*)['`"]") { $publisher = $Matches[1] }
        }
        catch { }
    }

    $script:PackagePublisherCache[$key] = $publisher
    return $publisher
}

<#
    Drops what the inventory remembers. Without arguments: everything, which is
    what the Refresh button does.
#>
function Clear-InventoryCache {
    param(
        [string[]]$ContentPath,
        [switch]$Site
    )

    if (-not $ContentPath -and -not $Site) {
        $script:PackageScanCache = @{}
        $script:PackagePublisherCache = @{}
        $script:SiteStateCache = $null
        $script:SiteStateCacheKey = ''
        return
    }

    foreach ($path in @($ContentPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $key = $path.ToLowerInvariant()
        if ($script:PackageScanCache.ContainsKey($key)) { $null = $script:PackageScanCache.Remove($key) }
        if ($script:PackagePublisherCache.ContainsKey($key)) { $null = $script:PackagePublisherCache.Remove($key) }
    }

    if ($Site) {
        $script:SiteStateCache = $null
        $script:SiteStateCacheKey = ''
    }
}

function Get-ContentFingerprint {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Measure-ContentFolder -ContentPath $Path).Fingerprint
}

function Get-DeploymentTypeFingerprint {
    param($DeploymentType)

    # The -Comment of a deployment type comes back as LocalizedDescription; in
    # the XML it is a <Description> below <DeploymentType>, not under DisplayInfo.
    $comment = [string]$DeploymentType.LocalizedDescription
    if (-not $comment) {
        $node = ([xml]$DeploymentType.SDMPackageXML).SelectSingleNode('//*[local-name()="DeploymentType"]/*[local-name()="Description"]')
        if ($node) { $comment = $node.InnerText }
    }
    if (-not $comment) { return '' }
    if ($comment -match 'content\s+(?<fp>\d+f/\d+b/\d+)') { return $Matches['fp'] }
    return ''
}

<#
    Finds the files whose path is too long for ConfigMgr once the content is
    addressed over UNC.

    Windows stops at 260 characters, so 259 are usable. ConfigMgr does not say
    that: it reports "Die Datei ... konnte nicht gefunden werden" / "Could not
    find file", which sends you looking for a missing file that is sitting right
    there. Worse, it fails halfway - the application is created and the
    deployment type is not.

    The local path is not what counts. The site addresses the package through
    the content share, and a long server name is enough to make the difference:
    the deepest file of an SQL Server Management Studio package measures 259
    characters under \\LAB01.lab.example and 265 under \\CMSERVER.customer.example. The
    same package, published from the same tool, works on one site and not on
    the other.
#>
function Get-OverlongContentPath {
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][string]$ContentUnc,
        [int]$Limit = 259
    )

    if (-not (Test-Path -LiteralPath $ContentPath)) { return @() }

    $prefix = $ContentUnc.TrimEnd('\')
    $local  = $ContentPath.TrimEnd('\')
    $found  = @()

    foreach ($file in [System.IO.Directory]::EnumerateFiles($local, '*', [System.IO.SearchOption]::AllDirectories)) {
        $length = $prefix.Length + ($file.Length - $local.Length)
        if ($length -gt $Limit) {
            $found += [pscustomobject]@{
                Length   = $length
                Over     = $length - $Limit
                Relative = $file.Substring($local.Length)
            }
        }
    }
    return @($found | Sort-Object Length -Descending)
}

<#
    How long the content paths get once the site addresses them over UNC: the
    longest of them, how many are past the limit, and the worst offender. One
    walk over the metadata, so it is cheap enough to run for every package
    the list shows - which is where a too long path should be seen, not at
    the moment of publishing.
#>
function Measure-ContentPath {
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][string]$ContentUnc,
        [int]$Limit = 259
    )

    return (Measure-ContentFolder -ContentPath $ContentPath -ContentUnc $ContentUnc -Limit $Limit)
}

function Set-ADTLogPath {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [string]$LogPath = 'C:\Windows\CCM\Logs\PSADT'
    )

    $configPath = Join-Path $ContentRoot 'Config\config.psd1'
    if (Test-Path -LiteralPath $configPath) {
        # The PSADT template ships the Config folder read-only.
        $configFolder = Get-Item -LiteralPath (Split-Path -Parent $configPath)
        $configFolder.Attributes = ($configFolder.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly)

        $content = Get-Content -LiteralPath $configPath -Raw
        $content = $content -replace "(?m)^\s*LogPath\s*=\s*'.*?'", "    LogPath = '$LogPath'"
        $content = $content -replace "(?m)^\s*LogPathNoAdminRights\s*=\s*'.*?'", "    LogPathNoAdminRights = '$LogPath'"
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        return $true
    }

    # PSADT 3 keeps it in AppDeployToolkitConfig.xml.
    $xmlPath = Join-Path $ContentRoot 'AppDeployToolkit\AppDeployToolkitConfig.xml'
    if (Test-Path -LiteralPath $xmlPath) {
        $content = Get-Content -LiteralPath $xmlPath -Raw
        $content = $content -replace '<Toolkit_LogPath>[^<]*</Toolkit_LogPath>', "<Toolkit_LogPath>$LogPath</Toolkit_LogPath>"
        Set-Content -LiteralPath $xmlPath -Value $content -Encoding UTF8
        return $true
    }

    Write-Warn "No PSADT configuration found below [$ContentRoot] - the log path stays as it is."
    return $false
}

function Set-ADTAppMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [string]$Publisher,
        [string]$Name,
        [string]$Version,
        [string]$Author = $env:USERNAME
    )

    $adt = Get-ADTScript -ContentRoot $ContentRoot
    if (-not $adt) { throw "No PSADT script found below: $ContentRoot" }
    $scriptPath = $adt.Path

    $creationDate = Get-Date -Format 'yyyy-MM-dd'
    $script = Get-Content -LiteralPath $scriptPath

    # Only empty fields are written - a package that already says who it is keeps
    # saying so, whichever toolkit generation and whichever tool wrote it. Except the
    # date: AppScriptDate is the date of the last build, so a package on a client or
    # a site tells whether it was rebuilt since a fix. The author is stamped once.
    if ($adt.Toolkit -eq '4') {
        if ($Publisher) { $script = $script -replace "AppVendor = ''", "AppVendor = '$Publisher'" }
        if ($Name)      { $script = $script -replace "AppName = ''", "AppName = '$Name'" }
        if ($Version)   { $script = $script -replace "AppVersion = ''", "AppVersion = '$Version'" }

        $script = $script `
            -replace "AppScriptDate = '[^']*'", "AppScriptDate = '$creationDate'" `
            -replace "AppScriptAuthor = '<author name>'", "AppScriptAuthor = '$Author'"
    }
    else {
        # PSADT 3: [String]$appVendor = '' and friends near the top of the script.
        if ($Publisher) { $script = $script -replace "(?i)(\`$appVendor\s*=\s*)''", "`$1'$Publisher'" }
        if ($Name)      { $script = $script -replace "(?i)(\`$appName\s*=\s*)''", "`$1'$Name'" }
        if ($Version)   { $script = $script -replace "(?i)(\`$appVersion\s*=\s*)''", "`$1'$Version'" }

        $script = $script `
            -replace "(?i)(\`$appScriptDate\s*=\s*)'[^']*'", "`$1'$creationDate'" `
            -replace "(?i)(\`$appScriptAuthor\s*=\s*)'(|<author name>)'", "`$1'$Author'"
    }

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

<#
    Writes the install or uninstall command from Apps.csv into the PSADT script,
    inside a marked block that is rewritten on every build.

    It used to be inserted once, when the template was created, and never again -
    because inserting twice would have produced the command twice. That made the
    package silently outrank the master list: editing the row changed nothing,
    and Set-ADTAppMetadata rewrote the file on every build anyway, so the
    timestamp moved and the command did not. A wrong install command survived
    every attempt to correct it.

    The block makes rewriting safe, so the row is the source of truth again.

    A package that has no block yet is only written into when its section is
    still empty. If somebody put a command there by hand it stays, and the
    difference is reported rather than overwritten - the tool has no business
    discarding work it did not write.
#>
function Repair-CommandLine {
    <#
        A GUID in braces is a script block to PowerShell, not a string. Written
        into the script unquoted, -ProductCode {102DCD41-...} fails at run time
        with "Cannot evaluate parameter 'ProductCode' because its argument is
        specified as a script block and there is no input" - a message that
        says nothing about the missing quotes. An older version of this tool
        wrote packages like that and the uninstall failed on the client every
        time, so the quotes are restored here instead of being left to whoever
        fills in the app list.
    #>
    param([string]$Line)

    $guid = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
    return [regex]::Replace($Line, "(?<lead>-ProductCode\s+)(?<guid>$guid)(?<tail>\s|$)", {
        param($match)
        $match.Groups['lead'].Value + "'" + $match.Groups['guid'].Value + "'" + $match.Groups['tail'].Value
    })
}

<#
    The marker comment a section is written after. Both toolkit generations
    draw the same three, so one table serves PSADT 3 and 4.
#>
function Get-PackageSectionMarker {
    param([Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall', 'PreInstall', 'PostInstall', 'PreUninstall', 'PostUninstall', 'UninstallPrevious')][string]$Section)

    switch ($Section) {
        'Install'           { return '## <Perform Installation tasks here>' }
        'Uninstall'         { return '## <Perform Uninstallation tasks here>' }
        'PreInstall'        { return '## <Perform Pre-Installation tasks here>' }
        'PostInstall'       { return '## <Perform Post-Installation tasks here>' }
        'PreUninstall'      { return '## <Perform Pre-Uninstallation tasks here>' }
        'PostUninstall'     { return '## <Perform Post-Uninstallation tasks here>' }
        'UninstallPrevious' { return '## <Perform Pre-Installation tasks here>' }   # the tool's own block, same section as PreInstall
    }
}

# A section ends at the next phase header, at the end of the function (Post-Uninstall
# is followed by the closing brace) or at PSADT 3's phase variable.
function Test-PackageSectionEnd {
    param([string]$Line)
    return ($Line -match '^\s*##\*?={5,}' -or $Line -match '^\s*## MARK:' -or $Line -match '^\s*\[String\]\$installPhase\s*=' -or $Line -match '^\}\s*$' -or $Line -match '^function\s')
}

<#
    Until 2026-09-16 the tool's uninstall-previous block was tagged "PreInstall"; that tag now
    belongs to the row's PreInstallCmd. A package built before gets its block re-tagged once,
    recognised by the filter variable only that block carries.
#>
function Rename-UninstallPreviousTag {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return }
    $lines = @(Get-Content -LiteralPath $FilePath)
    $b = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -like '# --- SCCMAppHelper PreInstall begin*') { $b = $i; continue }
        if ($b -ge 0 -and $lines[$i].Trim() -eq '# --- SCCMAppHelper PreInstall end ---') {
            $inner = $lines[($b + 1)..($i - 1)] -join "`n"
            if ($inner -match '\$previousFilter|\$versionFilter') {
                $lines[$b] = $lines[$b].Replace('SCCMAppHelper PreInstall begin', 'SCCMAppHelper UninstallPrevious begin')
                $lines[$i] = $lines[$i].Replace('SCCMAppHelper PreInstall end', 'SCCMAppHelper UninstallPrevious end')
                Set-Content -LiteralPath $FilePath -Value $lines -Encoding UTF8
            }
            return
        }
    }
}

<#
    The lines PSADT's own template puts after a marker - Post-Install carries the
    "customize text" prompt, for example. They are not somebody's code and must not be
    read into a row or thrown out of a section. The template travels with every
    package (PSAppDeployToolkit\Frontend\v4).
#>
function Get-PackageTemplateSectionLines {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string]$Section)
    $template = Join-Path (Split-Path -Parent $FilePath) 'PSAppDeployToolkit\Frontend\v4\Invoke-AppDeployToolkit.ps1'
    if (-not (Test-Path -LiteralPath $template)) { return @() }
    $marker = Get-PackageSectionMarker -Section $Section
    $found = @(); $inSection = $false
    foreach ($line in @(Get-Content -LiteralPath $template)) {
        if (-not $inSection) { if ($line -like "*$marker*") { $inSection = $true }; continue }
        if (Test-PackageSectionEnd -Line $line) { break }
        if ($line.Trim()) { $found += $line.Trim() }
    }
    return $found
}

<#
    The lines of the install or uninstall section as they stand in the script -
    whoever wrote them - without this tool's block markers. This is how a
    package built elsewhere gets its commands into the definition: read them
    out, put them in the row, and from then on the row is the source of truth.

    The section runs from the marker comment to the next phase header, which
    both toolkit generations draw as a line of "=" signs.
#>
function Read-PackageCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall', 'PreInstall', 'PostInstall', 'PreUninstall', 'PostUninstall')][string]$Section,
        # Leave out the lines inside any of this tool's blocks in the section (the
        # uninstall-previous block shares Pre-Install with PreInstallCmd).
        [switch]$OutsideToolBlocks
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return @() }
    $marker = Get-PackageSectionMarker -Section $Section
    $templateLines = New-Object System.Collections.Generic.List[string]
    foreach ($tl in @(Get-PackageTemplateSectionLines -FilePath $FilePath -Section $Section)) { $templateLines.Add($tl) }

    $lines = @(Get-Content -LiteralPath $FilePath)
    $found = @()
    $inSection = $false; $inBlock = $false
    foreach ($line in $lines) {
        if (-not $inSection) {
            if ($line -like "*$marker*") { $inSection = $true }
            continue
        }
        if (Test-PackageSectionEnd -Line $line) { break }
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -like '# --- SCCMAppHelper * begin*') { $inBlock = $true; continue }
        if ($trimmed -like '# --- SCCMAppHelper * end ---') { $inBlock = $false; continue }
        if ($inBlock -and $OutsideToolBlocks) { continue }
        # the template's own line, at most once each
        $ti = $templateLines.IndexOf($trimmed)
        if ($ti -ge 0) { $templateLines.RemoveAt($ti); continue }
        $found += $trimmed
    }
    return $found
}

function Set-PackageCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall', 'PreInstall', 'PostInstall', 'PreUninstall', 'PostUninstall', 'UninstallPrevious')][string]$Section,
        [string]$Command,
        # Importing a package built elsewhere: the lines somebody wrote by hand
        # were read into the row first, so they are replaced by the block that
        # holds the same lines - once, and only when they are the same.
        [switch]$TakeOver,
        # Generated code keeps its own indentation and blank lines instead of
        # being flattened line by line - a foreach block has to stay readable
        # for whoever opens the package afterwards.
        [switch]$Verbatim
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return 'no script' }

    $marker = Get-PackageSectionMarker -Section $Section
    $begin = "        # --- SCCMAppHelper $Section begin - rewritten from Apps.csv on every build ---"
    $end   = "        # --- SCCMAppHelper $Section end ---"

    $lines = @(Get-Content -LiteralPath $FilePath)

    # Where our blocks are - all of them, so the check for hand written code
    # below does not trip over a command this tool wrote itself.
    $ours = @()
    $blockStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -like '# --- SCCMAppHelper * begin*') { $blockStart = $i }
        elseif ($lines[$i].Trim() -like '# --- SCCMAppHelper * end ---' -and $blockStart -ge 0) {
            $ours += , @($blockStart, $i)
            $blockStart = -1
        }
    }

    $beginAt = -1
    $endAt   = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $begin.Trim()) { $beginAt = $i }
        if ($lines[$i].Trim() -eq $end.Trim() -and $beginAt -ge 0 -and $endAt -lt 0) { $endAt = $i }
    }

    $body = @()
    if ($Command -and $Verbatim) {
        $body = @($begin) +
                @($Command -split "`r?`n" |
                    ForEach-Object { if ($_.Trim()) { '        ' + $_.TrimEnd() } else { '' } }) +
                @($end)
    }
    elseif ($Command) {
        $body = @($begin) +
                @($Command -split "`r?`n" | Where-Object { $_.Trim() } |
                    ForEach-Object { '        ' + (Repair-CommandLine -Line $_.Trim()) }) +
                @($end)
    }

    # --- our block is already there: replace what is between the markers ---
    if ($beginAt -ge 0 -and $endAt -gt $beginAt) {
        $current = @()
        if ($endAt -gt $beginAt + 1) { $current = $lines[($beginAt + 1)..($endAt - 1)] }
        if ((($current -join "`n").Trim()) -eq (($body | Select-Object -Skip 1 | Select-Object -SkipLast 1) -join "`n").Trim()) {
            return 'unchanged'
        }

        $new = @()
        if ($beginAt -gt 0) { $new += $lines[0..($beginAt - 1)] }
        $new += $body
        if ($endAt -lt $lines.Count - 1) { $new += $lines[($endAt + 1)..($lines.Count - 1)] }
        Set-Content -LiteralPath $FilePath -Value $new -Encoding UTF8
        return 'replaced'
    }

    $markerAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like "*$marker*") { $markerAt = $i; break }
    }
    if ($markerAt -lt 0) { return 'no marker' }
    if (-not $Command)   { return 'nothing to write' }

    # --- no block yet: only write when nobody put code there by hand ---
    # What stands in the section outside this tool's blocks and outside PSADT's own
    # template lines is somebody's code. The tool's own uninstall-previous block is
    # generated, not taken from a row, so hand written code never stops it.
    $handWritten = @()
    if ($Section -ne 'UninstallPrevious') { $handWritten = @(Read-PackageCommand -FilePath $FilePath -Section $Section -OutsideToolBlocks) }
    if ($handWritten.Count -gt 0) {
        if (-not $TakeOver) { return 'hand written' }

        # The section as it stands has to be exactly what the row says, or the
        # difference is reported rather than one of the two thrown away.
        $wanted = @($Command -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
        if (($handWritten -join "`n") -ne ($wanted -join "`n")) { return 'hand written' }

        # Take the hand written lines out of the section - each once; the template's
        # own lines and other blocks stay - and put the block right after the marker.
        $endAt = $lines.Count
        for ($i = $markerAt + 1; $i -lt $lines.Count; $i++) { if (Test-PackageSectionEnd -Line $lines[$i]) { $endAt = $i; break } }
        $remove = New-Object System.Collections.Generic.List[string]
        foreach ($h in $handWritten) { $remove.Add($h) }
        $kept = @()
        $inBlock = $false
        for ($i = $markerAt + 1; $i -lt $endAt; $i++) {
            $tr = $lines[$i].Trim()
            if ($tr -like '# --- SCCMAppHelper * begin*') { $inBlock = $true }
            $ri = -1
            if (-not $inBlock) { $ri = $remove.IndexOf($tr) }
            if ($ri -ge 0) { $remove.RemoveAt($ri); continue }
            $kept += $lines[$i]
            if ($tr -like '# --- SCCMAppHelper * end ---') { $inBlock = $false }
        }
        $new = @()
        $new += $lines[0..$markerAt]
        $new += $body
        $new += $kept
        if ($endAt -lt $lines.Count) { $new += $lines[$endAt..($lines.Count - 1)] }
        Set-Content -LiteralPath $FilePath -Value $new -Encoding UTF8
        return 'taken over'
    }

    $new = @()
    $new += $lines[0..$markerAt]
    $new += $body
    if ($markerAt -lt $lines.Count - 1) { $new += $lines[($markerAt + 1)..($lines.Count - 1)] }
    Set-Content -LiteralPath $FilePath -Value $new -Encoding UTF8
    return 'inserted'
}

<#
    Name and version of a package: the folder name when it follows "<Name> - <Version>",
    else AppName / AppVersion from the PSADT script inside (a package built by hand or
    by the predecessor tool, "Oracle_Database_Client-19cx64" with the script saying
    Oracle_Database_Client 19c).
#>
function Get-PackageIdentity {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, $Config = (Get-ActiveConfig))
    $parsed = Split-AppFolderName -FolderName (Split-Path -Leaf $PackageRoot)
    if ($parsed.Version) { return $parsed }
    try {
        $content = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config
        if (Get-ADTScript -ContentRoot $content) {
            $adt = Read-ADTMetadata -ContentRoot $content
            if ($adt.Name -and $adt.Version) { return [pscustomobject]@{ Name = $adt.Name.Trim(); Version = $adt.Version.Trim() } }
        }
    } catch { }
    return $parsed
}

<#
    A yes/no column of the app list, in the shapes a CSV round trip produces.
#>
function Test-AppFlag {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim() -match '^(?i:true|1|yes|ja|x|on)$')
}

<#
    The product name to search the uninstall registry with, derived from the
    application name: an architecture suffix in brackets and a trailing version
    are part of our naming convention, not of the DisplayName a client carries.

        7-Zip 26.02 (x64 edition)  ->  7-Zip
        Notepad++ (x64)            ->  Notepad++

    The result is matched with a wildcard on both sides, so it has to be the
    part that stays the same across versions - and no shorter than that, or the
    uninstall reaches products nobody meant.
#>
<#
    Which setup engine built an EXE installer, and the silent switches that
    engine takes. An EXE does say which engine built it - not in its version
    resource, but in the strings of its stub: "Inno Setup" in an Inno Setup
    installer, "Nullsoft" in an NSIS one, ".wixburn" in the PE header of a Burn
    bundle, "InstallShield" in an InstallShield one, and 7-Zip's own installer
    describes itself as "7-Zip Installer". Measured on the packages of the lab
    share: FileZilla (NSIS), SQL Server Management Studio 20 and the .NET
    desktop runtime (Burn), 7-Zip (its SFX) were all told apart by the first
    six megabytes of the file; the Office bootstrapper, the Visual Studio style
    SSMS 22 installer and Oracle's setup.exe carry none of the markers and stay
    'unknown', where /S remains the guess it always was.

    The uninstall switch is what Uninstall-ADTApplication hands to the
    product's UninstallString as -AdditionalArgumentList (it prefers a
    QuietUninstallString when the uninstall key has one).
#>
function Get-InstallerEngine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $engine = 'unknown'
    try {
        $info = (Get-Item -LiteralPath $Path).VersionInfo
        $description = [string]$info.FileDescription + ' ' + [string]$info.InternalName + ' ' + [string]$info.ProductName
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $length = [int][Math]::Min($stream.Length, 6MB)
            $buffer = New-Object byte[] $length
            $null = $stream.Read($buffer, 0, $length)
        }
        finally { $stream.Close() }
        $ascii   = [System.Text.Encoding]::ASCII.GetString($buffer)
        $unicode = [System.Text.Encoding]::Unicode.GetString($buffer)

        if     ($ascii -match 'Inno Setup' -or $unicode -match 'Inno Setup')               { $engine = 'inno' }
        elseif ($ascii -match 'Nullsoft' -or $unicode -match 'Nullsoft')                   { $engine = 'nsis' }
        elseif ($ascii -match '\.wixburn')                                                  { $engine = 'burn' }
        elseif ($ascii -match 'InstallShield' -or $unicode -match 'InstallShield')         { $engine = 'installshield' }
        elseif ($description -match '7-Zip Installer')                                      { $engine = '7zip' }
        elseif ($description -match '^vs_|SSMS Installer|Visual Studio Installer')          { $engine = 'vsbootstrapper' }
    }
    catch { $engine = 'unknown' }

    return (Get-InstallerEngineSwitch -Engine $engine)
}

<#
    The switches per engine, also for what a winget manifest calls the
    installer type (inno, nullsoft, burn, exe). 'exe' and 'unknown' get /S,
    the NSIS switch and a guess for everything else - the note says so and
    goes into the command as a comment.
#>
function Get-InstallerEngineSwitch {
    param([Parameter(Mandatory = $true)][string]$Engine)

    switch ($Engine.ToLower()) {
        'inno'           { return [pscustomobject]@{ Engine = 'inno';           Install = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; Uninstall = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; Note = '' } }
        'nsis'           { return [pscustomobject]@{ Engine = 'nsis';           Install = '/S';                                       Uninstall = '/S';                                       Note = '' } }
        'nullsoft'       { return [pscustomobject]@{ Engine = 'nsis';           Install = '/S';                                       Uninstall = '/S';                                       Note = '' } }
        '7zip'           { return [pscustomobject]@{ Engine = '7zip';           Install = '/S';                                       Uninstall = '/S';                                       Note = '' } }
        'burn'           { return [pscustomobject]@{ Engine = 'burn';           Install = '/quiet /norestart';                        Uninstall = '/quiet /norestart';                        Note = '' } }
        'installshield'  { return [pscustomobject]@{ Engine = 'installshield';  Install = '/s /v"/qn REBOOT=ReallySuppress"';         Uninstall = '/s';                                       Note = 'InstallShield: /s /v"/qn" for MSI-based setups, /s for InstallScript - check the vendor documentation' } }
        'vsbootstrapper' { return [pscustomobject]@{ Engine = 'vsbootstrapper'; Install = '--quiet --norestart --wait';               Uninstall = '--quiet --norestart --wait';               Note = 'Visual Studio-style bootstrapper: --wait is required, otherwise the installer returns before it has finished' } }
        default          { return [pscustomobject]@{ Engine = 'unknown';        Install = '/S';                                       Uninstall = '/S';                                       Note = 'installer type could not be detected - /S is the NSIS switch, verify before deploying' } }
    }
}

<#
    The uninstall command of an EXE based package: Uninstall-ADTApplication
    finds the product's uninstall key by name, runs its UninstallString (the
    QuietUninstallString when there is one) and appends the engine's silent
    switch. The name is the product name without a trailing version, the same
    search the uninstall-previous block uses.
#>
function Get-ExeUninstallCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Engine
    )

    $searchName = (Get-ProductSearchName -Name $Name).Replace("'", "''")
    $command = "Uninstall-ADTApplication -Name '$searchName' -ApplicationType EXE -AdditionalArgumentList '$($Engine.Uninstall)'"
    if ($Engine.Note) { $command += '   # ' + $Engine.Note }
    return $command
}

<#
    The install command of an EXE based package, from the file name and the
    engine's switch.
#>
function Get-ExeInstallCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)]$Engine
    )

    $command = "Start-ADTProcess -FilePath '$FileName' -ArgumentList '$($Engine.Install)'"
    if ($Engine.Note) { $command += '   # ' + $Engine.Note }
    return $command
}

<#
    The installer EXE a package carries: the file named in the install command
    when that file is in Files\, else the only EXE in Files\. Nothing when the
    package has none or several - a guess would name the wrong engine.
#>
function Find-PackageInstallerExe {
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [string]$InstallCmd = ''
    )

    $files = Join-Path $ContentPath 'Files'
    if (-not (Test-Path -LiteralPath $files)) { return $null }
    if ($InstallCmd -match "-FilePath\s+'([^']+\.exe)'" -or $InstallCmd -match '-FilePath\s+"([^"]+\.exe)"') {
        $named = Join-Path $files $Matches[1]
        if (Test-Path -LiteralPath $named) { return $named }
    }
    $exes = @(Get-ChildItem -LiteralPath $files -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 1) { return $exes[0].FullName }
    return $null
}

function Get-ProductSearchName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $trimmed = ($Name -replace '\s*\([^)]*\)\s*$', '')
    $trimmed = ($trimmed -replace '\s+v?\d+[\d.]*$', '').Trim()
    if ($trimmed) { return $trimmed }
    return $Name.Trim()
}

<#
    The pre-installation block that removes every older version of the product
    before the new one is installed - what the "Explicitly uninstall all
    previous versions before installation" checkbox switches on.

    Both halves of the work use the same filter: the registry lookup only exists
    so the log says what was found, Uninstall-ADTApplication does the removing.
    The filter compares parsed versions, so it never touches an installation
    that is the same version or newer.

    Returns an empty string when the column is off - which is what removes an
    existing block from the script again.
#>
function Get-UninstallPreviousCommand {
    param(
        [Parameter(Mandatory = $true)]$App,
        # What this package installs - 'MSI' when Files\ holds an MSI, 'EXE' otherwise.
        # An entry of the other kind is removed whatever its version: an EXE-installed
        # 7-Zip 26.01 next to an MSI-installed 7-Zip 26.02 was the case that showed why.
        # Two installers of one product share a folder, and the one this package does
        # not manage would otherwise stay registered for ever, its files owned by ours.
        [ValidateSet('MSI', 'EXE')][string]$InstallerType = 'EXE'
    )

    if (-not (Test-AppFlag -Value $App.UninstallPrevious)) { return '' }

    # Without a comparable version there is no "previous", and guessing one
    # would uninstall by name alone - on a client, unasked.
    $parsed = $null
    if (-not [System.Version]::TryParse($App.Version, [ref]$parsed)) {
        Write-Warn ("Version [{0}] cannot be compared, so 'uninstall previous versions' is skipped - it would have to remove by name alone." -f $App.Version)
        return ''
    }

    $searchName = Get-ProductSearchName -Name $App.Name

    $template = @'
## Remove every older version of the product before installing this one, and every
## installation of it made by the other kind of installer (this package installs <TYPE>),
## whatever its version - two installers of one product share the folder, and the one
## we do not manage would stay registered while our files sit underneath it.
$targetVersion = [version]'<VERSION>'
$ourInstallerIsMsi = $<ISMSI>
$previousFilter = {
    $v = $_.DisplayVersion
    $parsed = $null
    $older = $v -and [version]::TryParse($v, [ref]$parsed) -and $parsed -lt $targetVersion
    # Registry rows carry WindowsInstaller as 1/0, PSADT's application objects as a bool.
    $isMsi = ($_.WindowsInstaller -eq 1) -or ($_.WindowsInstaller -eq $true)
    $otherKind = ($isMsi -ne $ourInstallerIsMsi)
    $older -or $otherKind
}

$components = @(
    @{ Name = '<NAME>' }
)

foreach ($component in $components) {
    $found = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
        -ErrorAction Ignore |
        Where-Object { $_.DisplayName -like "*$($component.Name)*" } |
        Where-Object $previousFilter

    if ($found) {
        $found | ForEach-Object {
            Write-ADTLogEntry -Message "Found component '$($_.DisplayName)' $($_.DisplayVersion) (WindowsInstaller=$($_.WindowsInstaller)) - uninstalling."
        }
        # MSI first: msiexec removes its own files cleanly. An EXE uninstaller run first
        # would empty the shared folder and leave the MSI registration behind as a leftover.
        Uninstall-ADTApplication -Name $component.Name -ApplicationType MSI -FilterScript $previousFilter
        # An EXE uninstaller runs interactive unless told otherwise, and under SYSTEM nobody
        # can click - it would hang until the deployment's timeout. The silent switch depends
        # on the setup engine; PSADT prefers a QuietUninstallString when the entry has one.
        $exeEntries = @($found | Where-Object { -not (($_.WindowsInstaller -eq 1) -or ($_.WindowsInstaller -eq $true)) })
        foreach ($silent in @($exeEntries | ForEach-Object {
                    switch -Regex ([string]$_.UninstallString) {
                        'unins\d*\.exe'                                  { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }   # Inno Setup
                        '/[Ii]\{|InstallShield|setup\.exe.*-runfromtemp' { '/s' }                                        # InstallShield
                        default                                          { '/S' }                                        # NSIS, 7-Zip, most others
                    }
                } | Select-Object -Unique)) {
            Uninstall-ADTApplication -Name $component.Name -ApplicationType EXE -FilterScript $previousFilter -AdditionalArgumentList $silent
        }
        Write-ADTLogEntry -Message "Uninstall of '$($component.Name)' complete."
    } else {
        Write-ADTLogEntry -Message "Component '$($component.Name)' not found or already current - skipping."
    }
}
'@

    $isMsi = 'false'
    if ($InstallerType -eq 'MSI') { $isMsi = 'true' }
    return $template.Replace('<VERSION>', $App.Version.Trim()).Replace('<NAME>', $searchName.Replace("'", "''")).Replace('<TYPE>', $InstallerType).Replace('<ISMSI>', $isMsi)
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
    # "Custom" is the name this method had before detection went native; rows
    # written back then still say it, so both are accepted.
    if ($method -in 'Script', 'Custom') {
        if ($CustomSource -and (Test-Path -LiteralPath $CustomSource)) {
            $header = "# Generated by SCCMAppHelper $toolVersion - https://blog.zarenko.net" + [Environment]::NewLine +
                      '# Hand written detection, taken verbatim from SupportFiles\detection.ps1.' + [Environment]::NewLine
            Set-Content -LiteralPath $Destination -Value ($header + (Get-Content -LiteralPath $CustomSource -Raw)) -Encoding UTF8
            Write-Ok "Detection script taken from [$CustomSource]"
            return $Destination
        }
        Write-Warn "DetectionMethod [$method] but no SupportFiles\detection.ps1 in the package - falling back to Registry."
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
        # The installer to put into Files\ - a download is moved, anything else
        # is copied, and a file already there with the same name and size is
        # left alone.
        [string]$InstallerPath,
        $Config = (Get-ActiveConfig)
    )

    $appFullName  = Get-AppFullName -Name $App.Name -Version $App.Version
    $workRoot     = Get-PackageWorkRoot -Config $Config
    $packageRoot  = Join-Path $workRoot $appFullName
    $contentPath  = Get-PackageContentPath -PackageRoot $packageRoot -Config $Config

    Write-Step "Building package: $appFullName"

    if ((Test-Path -LiteralPath $packageRoot) -and $Config.removeExistingPackageDirOnEachRun) {
        Write-Warn "Removing existing package directory: $packageRoot"
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }

    $isNewTemplate = -not (Get-ADTScript -ContentRoot $contentPath)

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
    if (Set-ADTLogPath -ContentRoot $contentPath -LogPath $Config.psadtLogPath) {
        Write-Ok "PSADT log path set to [$($Config.psadtLogPath)]"
    }

    $author = $Config.packageAuthor
    if ([string]::IsNullOrWhiteSpace($author)) { $author = $env:USERNAME }

    # Name, vendor and version go into the script for every package. Until 2026-09-15 an
    # MSI package left them empty and relied on PSADT's zero-config MSI deployment, which
    # only fires while AppName is empty - and Set-ADTAppMetadata never blanks a field, so a
    # package once built with another detection method kept its AppName, zero-config stayed
    # off, the Install block was empty and every install ended with exit 0 and nothing on the
    # device (0x87D00324 on the lab client and on a customer client). The MSI is now installed
    # by an explicit Start-ADTMsiProcess written into the Install and Uninstall blocks.
    Set-ADTAppMetadata -ContentRoot $contentPath -Publisher $App.Publisher -Name $App.Name -Version $App.Version -Author $author
    Write-Ok 'PSADT script metadata filled in.'

    # The installer goes into Files\ first. Until 2026-09-18 it was moved in after the
    # commands were written and the checks run, so the first build of a package from a
    # downloaded MSI saw no MSI in Files: it warned "EXE package without UninstallCmd" and
    # "ProductCode set, but no MSI in Files" about an MSI, and wrote the EXE-style commands -
    # only the rebuild after an Edit got it right.
    if ($InstallerPath) { Copy-PackageInstaller -ContentRoot $contentPath -InstallerPath $InstallerPath -Config $Config }

    # What this package actually installs decides the commands, which foreign installations
    # the pre-install block may remove, and whether the detection can trust a ProductCode.
    $packageMsi = Get-PackageMsi -ContentRoot $contentPath

    # The commands are rewritten on every build, so the Apps.csv row stays the
    # source of truth. Correcting a row used to change nothing at all, because
    # the injection ran once and never again. An MSI package gets its commands
    # from the MSI in Files; the row's fields are ignored for it (the editor
    # greys them out).
    $adtScript = (Get-ADTScript -ContentRoot $contentPath).Path
    Rename-UninstallPreviousTag -FilePath $adtScript
    foreach ($section in @($script:PackagePhases.Keys)) {
        $column = $script:PackagePhases[$section]
        $command = [string]$App.$column
        if ($packageMsi -and $section -in 'Install', 'Uninstall') { $command = "Start-ADTMsiProcess -Action $section -FilePath '$($packageMsi.Name)'" }
        $verbatim = ($section -notin 'Install', 'Uninstall')
        switch (Set-PackageCommand -FilePath $adtScript -Section $section -Command $command -TakeOver -Verbatim:$verbatim) {
            'replaced'     { Write-Ok   "$section command updated from the app list." }
            'inserted'     { Write-Ok   "$section command written into the package." }
            'taken over'   { Write-Ok   "$section command taken over into the tool's block." }
            'unchanged'    { Write-Info "$section command already matches the app list." }
            'hand written' { Write-Warn "The package already holds a command that this tool did not write - leaving it alone. The app list says: $command" }
            'no marker'    { Write-Info "No $section marker in the PSADT script - nothing written." }
        }
    }

    $installerType = 'EXE'
    if ($packageMsi) { $installerType = 'MSI' }
    if (-not $packageMsi -and [string]::IsNullOrWhiteSpace([string]$App.UninstallCmd)) {
        # PSADT uninstalls an MSI by itself (zero-config); an EXE it cannot. Without an
        # UninstallCmd the application's uninstall deployment type runs and removes nothing -
        # and supersedence, which uninstalls through exactly that, is silently toothless.
        Write-Warn ("EXE package without UninstallCmd - uninstall and supersedence remove nothing. Edit the row: the field is filled in with Uninstall-ADTApplication for the installer's engine. Example: Start-ADTProcess -FilePath `"`$envProgramFiles\{0}\Uninstall.exe`" -ArgumentList '/S'" -f $App.Name)
    }
    if (-not $packageMsi -and $App.ProductCode -and $App.DetectionMethod -in @('MSI', 'Registry') -and -not $App.DetectionPattern) {
        # The row came from a winget manifest that offers both installers: MSI metadata, EXE
        # in Files. The detection then looks for the MSI's uninstall key, which this package
        # never writes - and reports "installed" on every client that has the MSI by other
        # means, so the install (and the uninstall of previous versions) never runs.
        Write-Warn ("ProductCode [{0}] set, but no MSI in Files - the detection would look for the MSI's key, which this EXE never writes. Set DetectionPattern to the EXE's uninstall key name." -f $App.ProductCode)
    }

    # The generated pre-install block. Switched off, the empty command removes
    # the block that is there - so unticking the box undoes it on the next build.
    $preInstall = Get-UninstallPreviousCommand -App $App -InstallerType $installerType
    $preResult  = Set-PackageCommand -FilePath $adtScript -Section 'UninstallPrevious' -Command $preInstall -Verbatim

    if (-not $preInstall) {
        if ($preResult -eq 'replaced') { Write-Ok 'Uninstall of previous versions removed from the package.' }
    }
    else {
        $other = 'MSI'; if ($installerType -eq 'MSI') { $other = 'EXE' }
        $searched = "searches the uninstall registry for '*{0}*' and removes every version below {1} and every {2}-installed one whatever its version" -f (Get-ProductSearchName -Name $App.Name), $App.Version.Trim(), $other
        switch ($preResult) {
            'replaced'  { Write-Ok   "Uninstall of previous versions updated - $searched." }
            'inserted'  { Write-Ok   "Uninstall of previous versions written into the pre-install section - $searched." }
            'unchanged' { Write-Info 'Uninstall of previous versions already in the package.' }
            'no marker' { Write-Warn 'No pre-install marker in the PSADT script - the uninstall of previous versions was not written.' }
        }
    }

    # Measured here, with the installer in place, so a package that ConfigMgr
    # would refuse is known before anyone tries to publish it.
    $measure = Measure-ContentPath -ContentPath $contentPath -ContentUnc (ConvertTo-CMContentPath -Path $contentPath -Config $Config)
    if ($measure.Overlong -gt 0) {
        Write-Warn ("{0} file(s) are past the {1} character path limit once addressed over UNC - the longest is {2} characters: ...{3}" -f
            $measure.Overlong, $measure.Limit, $measure.Longest, $measure.Worst.Substring([Math]::Max(0, $measure.Worst.Length - 80)))
        Write-Warn ("Shorten the package by at least {0} characters - renaming the folder [{1}] is usually the shortest way - or ConfigMgr reports 'could not find file'." -f
            ($measure.Longest - $measure.Limit), $appFullName)
    }

    Write-Ok "Package ready: $packageRoot"
    return $packageRoot
}

<#
    Puts the installer into Files\. A download from the staging folder _DL is
    moved, so the share does not end up holding every installer twice; a file
    from anywhere else - somebody's Downloads folder - is copied and stays where
    it was. The staging folder is removed once it is empty.
#>
function Copy-PackageInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        $Config = (Get-ActiveConfig)
    )

    if (-not (Test-Path -LiteralPath $InstallerPath)) { Write-Warn "Installer not found: $InstallerPath"; return }

    $filesPath = Join-Path $ContentRoot 'Files'
    if (-not (Test-Path -LiteralPath $filesPath)) { $null = New-Item -ItemType Directory -Path $filesPath -Force }

    $source = Get-Item -LiteralPath $InstallerPath
    $target = Join-Path $filesPath $source.Name

    if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -eq $source.Length) {
        Write-Info "Installer already in Files: $($source.Name)"
        return
    }

    $staging = Join-Path (Get-PackageWorkRoot -Config $Config) '_DL'
    $isStaged = $source.FullName.StartsWith($staging, [System.StringComparison]::OrdinalIgnoreCase)

    if ($isStaged) {
        Move-Item -LiteralPath $source.FullName -Destination $target -Force
        Write-Ok "Installer moved into Files: $($source.Name)"
        $stagingFolder = $source.DirectoryName
        if ($stagingFolder -ne $staging -and -not @(Get-ChildItem -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue).Count) {
            Remove-Item -LiteralPath $stagingFolder -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Copy-Item -LiteralPath $source.FullName -Destination $target -Force
        Write-Ok "Installer copied into Files: $($source.Name)"
    }
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

    $app = New-AppRecord
    $app.Publisher = $Metadata.publisher
    $app.Name      = $Metadata.name
    $app.Version   = $Metadata.version

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

    # For an MSI package the ProductCode is read from the MSI that is going to be deployed -
    # the row's value (a winget manifest, an earlier import) may belong to another build.
    if ($app.DetectionMethod -eq 'MSI') {
        $contentPath = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config
        $msi = Get-PackageMsi -ContentRoot $contentPath
        if ($msi) {
            $fromMsi = [string](Get-MsiProperties -Path $msi.FullName)['ProductCode']
            if ($app.ProductCode -and $fromMsi -and $app.ProductCode -ne $fromMsi) { Write-Warn "ProductCode in the app list [$($app.ProductCode)] is not the one in $($msi.Name) [$fromMsi] - using the MSI's." }
            if ($fromMsi) { $app.ProductCode = $fromMsi }
            Write-Info "ProductCode from $($msi.Name): $($app.ProductCode)"
        }
        else {
            Write-Warn 'DetectionMethod is MSI but .\Files does not hold exactly one MSI - detection falls back to the registry.'
            $app.DetectionMethod = 'Registry'
        }
    }

    # A registry detection with no key can still be answered when the package
    # deploys a single MSI: the ProductCode *is* the uninstall key of an MSI
    # installed product. That is what makes the packages the older scripts built
    # publishable without filling anything in by hand - their rows carry an empty
    # DetectionPattern, which used to mean "DisplayName like <Name>*".
    if ($app.DetectionMethod -eq 'Registry' -and -not $app.DetectionPattern -and -not $app.ProductCode) {
        $contentPath = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config
        $msi = Get-PackageMsi -ContentRoot $contentPath
        if ($msi) {
            $app.DetectionPattern = [string](Get-MsiProperties -Path $msi.FullName)['ProductCode']
            Write-Info "Uninstall key read from $($msi.Name): $($app.DetectionPattern)"
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
<#
    What is wrong with a file detection path, in one sentence - empty when
    there is nothing wrong.

    ConfigMgr validates the Path of a file clause itself, but only when the
    clause is built, which is after the application has been created. What comes
    back then is "Cannot validate argument on parameter 'Path'" and nothing else:
    no path, no reason, and an application left behind without a deployment
    type. A typo like %\ProgramFiles% got that far because it does have a parent
    and a file name - it is simply not a path.
#>
function Get-DetectionFilePathProblem {
    param([string]$Path)

    $path = ([string]$Path).Trim()

    if (-not $path)              { return 'the path is empty' }
    if ($path.EndsWith('\'))     { return 'the path ends at a folder, not at a file' }
    if ($path -notmatch '\\')    { return 'the path holds no folder - it has to be the full path of a file' }

    if ($path -match '^%[^%\\]+%\\')  { return '' }   # %ProgramFiles%\...
    if ($path -match '^[A-Za-z]:\\')  { return '' }   # C:\...
    if ($path -match '^\\\\[^\\]+\\') { return '' }   # \\server\share\...

    if ($path -match '%') {
        return 'the environment variable is malformed - it has to read %ProgramFiles%\ with the name between the two percent signs'
    }
    return 'the path is not absolute - it has to start with a drive letter or an environment variable'
}

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
            $problem = Get-DetectionFilePathProblem -Path $App.DetectionPattern
            if ($problem) {
                throw ("DetectionPattern [{0}] cannot be used for file detection - {1}. It has to be the full path of a file the installation leaves behind, for example %ProgramFiles%\Notepad++\notepad++.exe." -f $App.DetectionPattern, $problem)
            }
            $filePath = Split-Path -Parent $App.DetectionPattern
            $fileName = Split-Path -Leaf   $App.DetectionPattern

            # Is64Bit decides how the client resolves %ProgramFiles% and
            # %SystemRoot%\System32. Without it the clause is evaluated in the 32
            # bit view, %ProgramFiles% becomes "Program Files (x86)", and an x64
            # application is never found there. A path holding an environment
            # variable therefore gets both views connected with Or, exactly like
            # the two registry views; a literal path needs only one clause,
            # because there is nothing left to redirect.
            $views = if ($App.DetectionPattern -match '%') { @($true, $false) } else { @($true) }

            foreach ($is64Bit in $views) {
                $clauseParams = @{ Path = $filePath; FileName = $fileName }
                if ($is64Bit) { $clauseParams['Is64Bit'] = $true }

                $clauses += if ($hasVersion) {
                    New-CMDetectionClauseFile @clauseParams -Value `
                        -PropertyType Version -ExpressionOperator GreaterEquals -ExpectedValue $App.Version
                }
                else {
                    New-CMDetectionClauseFile @clauseParams -Existence
                }
            }
        }

        'Registry' {
            $key = $App.DetectionPattern
            if (-not $key -and $App.ProductCode) { $key = $App.ProductCode }
            if (-not $key) {
                throw 'DetectionMethod is Registry but DetectionPattern holds no uninstall key (and there is no ProductCode to derive it from).'
            }
            # A wildcard is a leftover from when Registry detection meant
            # "DisplayName like ...". A native clause needs one exact key, and it
            # would take the wildcard without complaint and then match nothing.
            if ($key -match '[*?]') {
                throw "DetectionPattern [$key] is a DisplayName pattern, not an uninstall key - registry detection needs the exact key since it became a native clause."
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

    # The operator belongs in here. Without it a foreign clause comparing
    # "ProductVersion Equals 11.24.0" looks the same as ours comparing
    # "GreaterEquals 11.24.0", and the tool would leave the foreign detection in
    # place while reporting success - they mean different things: Equals stops
    # counting the product as installed the moment it is updated.
    $parts = @(
        foreach ($clause in @($Clauses)) {
            '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $clause.SettingSourceType,
                                             $clause.Setting.Location,
                                             $clause.Setting.ValueName,
                                             $clause.Setting.Is64Bit,
                                             $clause.PropertyPath,
                                             $clause.Operator,
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

    $adt = Get-ADTScript -ContentRoot $ContentRoot
    if (-not $adt) { return $result }
    $scriptPath = $adt.Path

    # PSADT 3 keeps the same facts in plain variables near the top.
    if ($adt.Toolkit -eq '3') {
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $v3 = @{ appVendor = 'Publisher'; appName = 'Name'; appVersion = 'Version'; appScriptAuthor = 'Author'; appScriptDate = 'Date' }
        foreach ($key in $v3.Keys) {
            if ($content -match ("(?im)^\s*(\[string\])?\`$" + $key + "\s*=\s*'([^']*)'")) { $result.($v3[$key]) = $Matches[2] }
        }
        return $result
    }

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
    $parsed      = Get-PackageIdentity -PackageRoot $PackageRoot -Config $Config
    $contentPath = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config

    $adt = Read-ADTMetadata -ContentRoot $contentPath
    $msi = Get-PackageMsi -ContentRoot $contentPath

    # A package with one MSI in Files is an MSI package, whatever the session metadata
    # says - the tool fills AppName for every package since 2026-09-15 (the property keeps
    # its old name so its readers need no change).
    $isZeroConfigMsi = ($null -ne $msi)

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
        # The application's name and version as the site knows them - a package that is
        # already published keeps that identity, whatever its folder or script say.
        [string]$Name = '',
        [string]$Version = '',
        $Config = (Get-ActiveConfig)
    )

    $folderName = Split-Path -Leaf $PackageRoot
    $parsed     = Get-PackageIdentity -PackageRoot $PackageRoot -Config $Config
    if ($Name -and $Version) { $parsed = [pscustomobject]@{ Name = $Name.Trim(); Version = $Version.Trim() } }
    $content    = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config

    Write-Step "Importing existing package: $folderName"

    $adt = Get-ADTScript -ContentRoot $content
    if (-not $adt) {
        throw "No PSADT script found in [$content] - this does not look like a package."
    }
    Write-Info "PSADT $($adt.Toolkit) package: $(Split-Path -Leaf $adt.Path)"

    # The folder name is the naming convention the whole workflow rests on. A folder that
    # does not follow it is renamed to "<Name> - <Version>" from the script's own metadata;
    # the site's content location is set anew at the next publish anyway.
    $wanted = Get-AppFullName -Name $parsed.Name -Version $parsed.Version
    if ($parsed.Version -and $folderName -ne $wanted) {
        $target = Join-Path (Split-Path -Parent $PackageRoot) $wanted
        if (Test-Path -LiteralPath $target) { throw "Cannot rename [$folderName] to [$wanted] - that folder exists already." }
        Move-Item -LiteralPath $PackageRoot -Destination $target
        Write-Ok "Folder renamed to [$wanted] - the naming convention."
        $PackageRoot = $target; $folderName = $wanted
        $content = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config
        $adt = Get-ADTScript -ContentRoot $content
    }

    $existing = Get-PackageMetadata -PackageRoot $PackageRoot -Config $Config
    $row = Get-AppListRow -Name $parsed.Name -Version $parsed.Version

    $app = New-AppRecord
    $app.Name    = $parsed.Name
    $app.Version = $parsed.Version

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
        Write-Info 'Single MSI in Files - MSI package, detection by its ProductCode.'
        $app.DetectionMethod = 'MSI'
        $app.ProductCode     = $existing.productCode
    }
    if ($existing.publisher) { $app.Publisher = $existing.publisher }

    # The commands as they stand in the script go into the row, so the row
    # describes the package it names - and is editable from now on.
    Rename-UninstallPreviousTag -FilePath $adt.Path
    foreach ($section in @($script:PackagePhases.Keys)) {
        $column = $script:PackagePhases[$section]
        if ($app.$column) { continue }
        $found = @(Read-PackageCommand -FilePath $adt.Path -Section $section -OutsideToolBlocks)
        if ($found.Count -gt 0) {
            $app.$column = ($found -join [Environment]::NewLine)
            Write-Info ("{0} command read from the script: {1} line(s)" -f $section, $found.Count)
        }
    }

    # Ask only when something essential is missing and we are not in a bulk run.
    if ((-not $app.Publisher -or -not $app.Version) -and -not $Bulk) {
        $item = [ordered]@{}
        foreach ($column in $script:AppListColumns) { $item[$column] = $app.$column }
        $answer = Open-EditDialog -title "Import package: $folderName" -PropertyOrder $script:AppListColumns -item $item
        $answer = $answer | Where-Object { $_ -isnot [int] }
        if (-not $answer) { throw 'Import cancelled.' }
        foreach ($key in $answer.Keys) { $app.$key = $answer[$key] }
    }

    if (-not $app.Version) { throw "No version could be determined for [$folderName] - expected a folder named '<Name> - <Version>'." }

    # Write the metadata where it belongs: into the package's own PSADT script.
    $author = $Config.packageAuthor
    if ([string]::IsNullOrWhiteSpace($author)) { $author = $env:USERNAME }
    Set-ADTAppMetadata -ContentRoot $content -Publisher $app.Publisher -Name $app.Name -Version $app.Version -Author $author
    Write-Ok ("Metadata written into {0} (empty fields only)." -f (Split-Path -Leaf $adt.Path))

    # The hand written commands become the tool's block, so the row is the
    # source of truth from here on. Same lines, only wrapped.
    foreach ($section in @($script:PackagePhases.Keys)) {
        $command = [string]$app.($script:PackagePhases[$section])
        if (-not $command) { continue }
        switch (Set-PackageCommand -FilePath $adt.Path -Section $section -Command $command -TakeOver -Verbatim:($section -notin 'Install', 'Uninstall')) {
            'taken over'   { Write-Ok   "$section command taken over into the tool's block." }
            'inserted'     { Write-Ok   "$section command written into the package." }
            'hand written' { Write-Warn "The $section section differs from the row - left as it is." }
        }
    }

    # Keep the master list complete - that is what the naming convention lives on.
    if ($row) { Set-AppListRow -App $app } else { Add-AppListRow -App $app }

    $metadata = Get-PackageMetadata -PackageRoot $PackageRoot -Config $Config
    Write-Ok "Imported: $($metadata.appFullName)"
    return $metadata
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

    # Refuse before anything is created rather than leaving an application
    # behind without a deployment type - see Get-OverlongContentPath.
    $overlong = Get-OverlongContentPath -ContentPath $contentPath -ContentUnc $contentUnc
    if ($overlong.Count -gt 0) {
        $worst  = $overlong[0]
        $folder = Split-Path -Leaf $PackageRoot
        $spare  = $worst.Over

        Write-Fail ("{0} file(s) are past the {1} character path limit when addressed as [{2}]." -f $overlong.Count, 259, $contentUnc)
        foreach ($item in ($overlong | Select-Object -First 5)) {
            Write-Warn ("  {0} characters ({1} too many): ...{2}" -f $item.Length, $item.Over,
                $item.Relative.Substring([Math]::Max(0, $item.Relative.Length - 90)))
        }
        if ($overlong.Count -gt 5) { Write-Warn ("  and {0} more." -f ($overlong.Count - 5)) }

        throw ("The content path is too long for ConfigMgr. ConfigMgr would report this as " +
               "'could not find file' and would leave the application behind without a deployment type. " +
               "Shorten the package by at least $spare characters - renaming the folder [$folder] is " +
               "usually the shortest way there, and the name comes from the Name and Version columns of " +
               "the app list. Changing sourceRoot also works but re-points every package, and every " +
               "client then downloads all of them again.")
    }

    $app      = Resolve-PackageApp -PackageRoot $PackageRoot -Metadata $metadata -Config $Config
    $artifact = New-PublishArtifact -PackageRoot $PackageRoot -App $app -Config $Config
    $iconFile = $artifact.IconFile

    Write-Step "Publishing to ConfigMgr: $appFullName"
    Write-Info "Content location: $contentUnc"

    # The artifact folder below %TEMP% has to go even when publishing throws -
    # a package that is refused used to leave one behind on every attempt.
    try {
        Invoke-InCMSite -Config $Config -ScriptBlock {

            # ---------------------------------------------------------- application
            $application = Get-CMApplication -Name $appFullName -Fast -ErrorAction SilentlyContinue

            if ($application) {
                $update = $true
                if (-not $Bulk) {
                    $answer = Show-MessageDialog -Text "The application`n`n$appFullName`n`nalready exists. Update it (deployment type, detection, content)?`n`nNo = skip this package." -Caption 'Application already exists' -Buttons 'YesNo' -Icon 'Question'
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

                # Sorting the application into a console folder is cosmetic, and
                # nothing cosmetic may abort a publish that has just created an
                # application - it would leave it behind without a deployment
                # type, which the list then reports as Foreign for ever.
                try {
                    $applicationFolder = Resolve-CMFolderPath -FolderPath $Config.applicationFolderPath -Config $Config -RootNode 'Application'
                    if ($applicationFolder -and (New-CMFolderPath -FolderPath $applicationFolder)) {
                        $null = Move-CMObject -FolderPath $applicationFolder -InputObject $application -ErrorAction Stop
                        Write-Ok "Moved to console folder [$applicationFolder]"
                    }
                }
                catch { Write-Warn ("Could not move the application into a console folder: {0}" -f (Format-ErrorDetail -ErrorRecord $_)) }
            }

            # ------------------------------------------------------ deployment type
            # An application without a deployment type is not usable and the list
            # cannot even tell it is ours - the signature lives in the deployment
            # type comment. So from here on, a failure says that plainly.
            $deploymentTypeName = $appFullName
            $existingDt = Get-CMDeploymentType -ApplicationName $appFullName -DeploymentTypeName $deploymentTypeName -ErrorAction SilentlyContinue

            $dtParams = @{
                ApplicationName          = $appFullName
                DeploymentTypeName       = $deploymentTypeName
                ContentLocation          = $contentUnc
                InstallCommand           = (Get-PackageCommandLine -ContentPath $contentPath -Section Install   -Config $Config)
                UninstallCommand         = (Get-PackageCommandLine -ContentPath $contentPath -Section Uninstall -Config $Config)
                InstallationBehaviorType = 'InstallForSystem'
                LogonRequirementType     = 'WhetherOrNotUserLoggedOn'
                Comment                  = (Get-ToolSignature)
                ErrorAction              = 'Stop'
            }

            # What is in the content folder right now, so the distribution point
            # is only refreshed when it really has to be - see
            # Get-ContentFingerprint for why that matters so much.
            $contentFingerprint = Get-ContentFingerprint -Path $contentPath
            if ($contentFingerprint) {
                $dtParams['Comment'] = '{0} | content {1}' -f (Get-ToolSignature), $contentFingerprint
            }
            $contentChanged = $true
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
                # Sending a location that has not changed is pointless work, and
                # a location that *has* changed deserves to be said out loud -
                # it means every client will fetch the package from somewhere
                # else. (The content object itself is not affected either way;
                # what regenerates it is Update-CMDistributionPoint, which is
                # gated further down.)
                $storedLocation = ([xml]$existingDt.SDMPackageXML).AppMgmtDigest.DeploymentType.Installer.Contents.Content.Location
                if ($storedLocation -and
                    $storedLocation.TrimEnd('\') -eq $contentUnc.TrimEnd('\')) {
                    $dtParams.Remove('ContentLocation')
                    Write-Info 'Content location unchanged - keeping the existing content object.'
                }
                elseif ($storedLocation) {
                    Write-Warn ("Content location changed from [{0}] to [{1}] - ConfigMgr will create new content." -f $storedLocation, $contentUnc)
                }

                $storedFingerprint = Get-DeploymentTypeFingerprint -DeploymentType $existingDt
                if ($contentFingerprint -and $storedFingerprint -eq $contentFingerprint) {
                    $contentChanged = $false
                    Write-Info 'Content is unchanged since the last publish.'
                }
                elseif (-not $storedFingerprint) {
                    Write-Info 'No content fingerprint on the deployment type yet - refreshing once to record one.'
                }

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

                    # Update-CMDistributionPoint creates a new content object, and
                    # every client then downloads the whole package again. Doing
                    # that for a package nobody changed is how the client cache
                    # fills up, so it only runs when the content really differs.
                    if (-not $contentChanged) {
                        Write-Ok 'Content already distributed and unchanged - nothing to send.'
                    }
                    else {
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

                        # Each collection definition may name its own console
                        # folder - required and available deployments usually
                        # live apart - and falls back to the site's folder.
                        $folderPath = [string]$Config.collectionFolderPath
                        if ($collectionDefinition.PSObject.Properties.Name -contains 'folderPath' -and -not [string]::IsNullOrWhiteSpace($collectionDefinition.folderPath)) {
                            $folderPath = [string]$collectionDefinition.folderPath
                        }
                        $collectionFolder = Resolve-CMFolderPath -FolderPath $folderPath -Config $Config -RootNode 'DeviceCollection'
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

        Write-Ok "Finished: $appFullName"
    }
    finally { Remove-Item -LiteralPath $artifact.Path -Recurse -Force -ErrorAction SilentlyContinue }
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
        [pscustomobject]@{ Tool = 'Retire applications';           Description = 'Stop deploying a version, or delete it and everything that belongs to it.' }
        [pscustomobject]@{ Tool = 'Switch ConfigMgr site';         Description = 'Work against a different site of the "sites" list in config.json.' }
        [pscustomobject]@{ Tool = 'Add ConfigMgr site';            Description = 'Setup assistant: connect to a server and read its settings automatically.' }
        [pscustomobject]@{ Tool = 'Check site configuration';      Description = 'Test provider, share, console module, SQL and collections of the active site.' }
        [pscustomobject]@{ Tool = 'Move source root';              Description = 'Move the package share (shorter UNC root): folders, share, every deployment type, config.json.' }
    )

    $selection = Open-SelectDialog -data $tools -title 'Tools'
    if ($null -ne $selection) { $selection = $selection | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
    if (-not $selection) { return }

    switch ($selection.Tool) {
        'Update collections'         { Update-AppCollections }
        'Rebuild outdated apps'      { Update-OutdatedAppsCollection }
        'Role collection membership' { Edit-RoleCollectionMembership }
        'Retire applications'        { retireApps }
        'Switch ConfigMgr site'      { $null = Get-ActiveConfig -ForceSiteSelection }
        'Add ConfigMgr site'         { $null = Start-SetupWizard }
        'Check site configuration'   { $null = Test-SiteConfiguration }
        'Move source root'           { Move-SourceRoot }
    }
}

#endregion
