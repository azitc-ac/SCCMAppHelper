<#
    SCCMAppHelper - the inventory, and the actions taken from it

    Three things exist per application, and the tool's job is to keep them in
    step and to say which of them are there:

        the definition   a row in Apps.csv - name, version, detection, commands
        the package      "<Name> - <Version>\" on the source share, with PSADT
                         and the installer in Files\
        the application  in the ConfigMgr site, with content on the distribution
                         points and deployments to the collections

    Get-AppInventory joins the three into one row per application, and the main
    dialog shows nothing else. Every action - add, build, publish, retire - is
    taken from a row of that list, and what makes sense follows from the state
    of the row: a definition without a package is built, a package without an
    application is published, a published application whose source has changed
    since is published again.

    Adding an application is one step. The installer is fetched - from the
    winget manifests, or picked from disk - the record is confirmed in the
    editor, and the package is built with the installer already in Files\. The
    row appears in the list as "ready, not published"; publishing is a second,
    deliberate click.
#>

#region ------------------------------------------------------------ inventory

<#
    The package folders on the source share: every folder below the work root
    holding a PSADT script. Nothing is asked of the site here.
#>
function Get-AppPackage {
    param($Config = (Get-ActiveConfig))

    $workRoot = Get-PackageWorkRoot -Config $Config
    $results  = @()

    foreach ($dir in (Get-ChildItem -LiteralPath $workRoot -Directory -ErrorAction SilentlyContinue)) {
        # _DL is the download staging folder; anything else starting with an
        # underscore or a dot is bookkeeping, not a package.
        if ($dir.Name -like '_*' -or $dir.Name -like '.*') { continue }

        $contentPath = Get-PackageContentPath -PackageRoot $dir.FullName -Config $Config
        $adt         = Get-ADTScript -ContentRoot $contentPath
        $parsed      = Get-PackageIdentity -PackageRoot $dir.FullName -Config $Config
        # managed = the tool's tagged blocks are in the script (built or imported by it)
        $managed = $false
        if ($adt) { try { $managed = ((Select-String -LiteralPath $adt.Path -Pattern '# --- SCCMAppHelper \w+ begin' -Quiet) -eq $true) } catch { } }

        # One walk of the package answers three questions at once: what Files\
        # holds - which decides whether the package can install anything - how
        # long the longest path is once the site addresses it, and the
        # fingerprint the site column compares against. A folder without a PSADT
        # script is Legacy: listed, so it is known to be there, and left alone,
        # because nothing in it is understood.
        $unc = $(if ($adt) { ConvertTo-CMContentPath -Path $contentPath -Config $Config } else { '' })
        $scan = Get-PackageScan -ContentPath $contentPath -ContentUnc $unc `
            -FilesPath $(if ($adt) { Join-Path $contentPath 'Files' } else { '' })

        $results += [pscustomobject]@{
            AppName      = $parsed.Name
            AppVersion   = $parsed.Version
            PackageRoot  = $dir.FullName
            ContentPath  = $contentPath
            Toolkit      = $(if ($adt) { $adt.Toolkit } else { '' })
            IsLegacy     = (-not $adt)
            IsManaged    = $managed
            FilesCount   = $scan.FilesCount
            LongestPath  = $scan.Longest
            OverlongFiles = $scan.Overlong
            WorstPath    = $scan.Worst
            Fingerprint  = $scan.Fingerprint
            LastModified = $(if ($adt) { (Get-Item -LiteralPath $adt.Path).LastWriteTime } else { $dir.LastWriteTime })
        }
    }

    return ($results | Sort-Object AppName, AppVersion)
}

<#
    What the site knows, keyed by application name. Read in three calls rather
    than three per application: every application with its package XML, every
    application deployment, and the distribution status of every package.

    The deployment type comment carries the tool signature and the content
    fingerprint, and both sit in the package XML - so the application object is
    enough to say whether this tool published it and whether the source has
    changed since (see Get-ContentFingerprint).
#>
<#
    One counter of a distribution status object, by whichever of the given names
    the site actually carries.

    Reading a property that is not there answers $null, and [int]$null is 0 -
    indistinguishable from "no distribution point has it". That is how content
    sitting on every distribution point reported "targeted, not there yet" for
    ever. Returns -1 when none of the names exist, so the caller can tell an
    unknown shape from a real zero.
#>
function Get-StatusCount {
    param(
        [Parameter(Mandatory = $true)]$Status,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $available = @($Status.PSObject.Properties.Name)
    foreach ($name in $Names) {
        if ($available -contains $name) { return [int]$Status.$name }
    }
    return -1
}

<#
    The application list out of the site database: the latest application CIs
    with their deployment type digests (v_ConfigurationItems, CIType_ID 21 -
    the location, the tool's signature and fingerprint live there, not in the
    application's own digest), the package id from v_CIContentPackage, and
    the deployment count from v_ApplicationAssignment. Returns the same table
    the provider path builds, keyed by application name, or throws - the caller
    then falls back to the provider.
#>
function Get-CMApplicationStateFromSql {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][scriptblock]$EntryOf
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=$($Config.sqlServer);Database=$($Config.database);Integrated Security=true;Connect Timeout=10"
    $apps = @(); $dts = @{}; $counts = @{}
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = @"
SELECT app.CI_ID, app.DisplayName, app.Manufacturer, app.SoftwareVersion,
       CAST(ci.SDMPackageDigest AS nvarchar(max)) AS Digest,
       (SELECT TOP 1 cp.PkgID FROM v_CIContentPackage cp WHERE cp.CI_ID = app.CI_ID) AS PkgID
FROM fn_ListLatestApplicationCIs(1033) app
JOIN v_ConfigurationItems ci ON ci.CI_ID = app.CI_ID
"@
        $reader = $command.ExecuteReader()
        while ($reader.Read()) { $apps += [pscustomobject]@{ Name = [string]$reader['DisplayName']; Publisher = [string]$reader['Manufacturer']; Version = [string]$reader['SoftwareVersion']; PackageID = [string]$reader['PkgID']; Digest = [string]$reader['Digest'] } }
        $reader.Close()

        $command.CommandText = 'SELECT ModelName, CAST(SDMPackageDigest AS nvarchar(max)) AS Digest FROM v_ConfigurationItems WHERE CIType_ID = 21 AND IsLatest = 1 AND IsExpired = 0'
        $reader = $command.ExecuteReader()
        while ($reader.Read()) { $dts[[string]$reader['ModelName']] = [string]$reader['Digest'] }
        $reader.Close()

        $command.CommandText = 'SELECT ApplicationName FROM v_ApplicationAssignment'
        $reader = $command.ExecuteReader()
        while ($reader.Read()) { $n = [string]$reader['ApplicationName']; if ($counts.ContainsKey($n)) { $counts[$n]++ } else { $counts[$n] = 1 } }
        $reader.Close()
    }
    finally { $connection.Close() }

    $result = @{}
    foreach ($app in $apps) {
        # the application's digest names its deployment types by scope and logical name
        $xml = $app.Digest
        foreach ($m in [regex]::Matches($app.Digest, '<DeploymentType AuthoringScopeId="(?<scope>[^"]+)" LogicalName="(?<name>[^"]+)"')) {
            $model = $m.Groups['scope'].Value + '/' + $m.Groups['name'].Value
            if ($dts.ContainsKey($model)) { $xml += $dts[$model] }
        }
        $entry = & $EntryOf $app.Name $app.Publisher $app.Version $app.PackageID $xml
        if ($counts.ContainsKey($app.Name)) { $entry.Deployments = $counts[$app.Name] }
        $result[$app.Name] = $entry
    }
    return $result
}

function Get-CMApplicationState {
    param(
        $Config = (Get-ActiveConfig),
        [switch]$Force
    )

    # Three provider calls that take seconds on a grown site, for a list that is
    # read again after every action. Kept until something changes it - see
    # Clear-InventoryCache - and keyed by site code, so switching sites in the
    # tools menu cannot hand back the wrong one.
    if (-not $Force -and $script:SiteStateCache -and $script:SiteStateCacheKey -eq [string]$Config.siteCode) {
        return $script:SiteStateCache
    }

    $signature = Get-ToolSignaturePattern

    # What is read out of an application's package XML: the tool's signature and
    # fingerprint in the deployment type's description, the content location.
    # Text, not DOM: loading the whole package XML into a DOM for one element
    # cost more than the rest of this loop together, once per application. The
    # SQL digest carries a namespace prefix on the elements, the provider's
    # XML does not - the pattern takes both.
    $entryOf = { param([string]$name, [string]$publisher, [string]$version, [string]$packageId, [string]$xml)
        $fingerprint = ''; if ($xml -match 'content\s+(?<fp>\d+f/\d+b/\d+)') { $fingerprint = $Matches['fp'] }
        $location = '';    if ($xml -match '<(?:\w+:)?Location>(?<loc>[^<]*)</(?:\w+:)?Location>') { $location = $Matches['loc'] }
        [pscustomobject]@{
            AppName     = $name
            Publisher   = $publisher
            Version     = $version
            PackageID   = $packageId
            Origin      = $(if (($xml -match $signature) -or ($xml -match 'Generated by SCCMAppHelper')) { 'this tool' } else { 'foreign' })
            Fingerprint = $fingerprint
            Location    = $location
            Deployments = 0
            Content     = ''
        }
    }

    # The site database first: every application and deployment type digest
    # in two queries, 0.5 s where Get-CMApplication took 1.9 s for 22
    # applications - and the provider fetches the package XML per application,
    # so a site with two hundred of them pays for each. The provider path
    # below stays as it was, for a site whose database is not reachable.
    $fromSql = $null
    if ($Config.sqlServer -and $Config.database) {
        try { $fromSql = Get-CMApplicationStateFromSql -Config $Config -EntryOf $entryOf } catch { Write-Info ("site database not used: {0}" -f $_.Exception.Message); $fromSql = $null }
    }

    $state = Invoke-InCMSite -Config $Config -ScriptBlock {
        $result = @{}

        if ($fromSql) { $result = $fromSql }
        else {
            foreach ($application in @(Get-CMApplication)) {
                $result[$application.LocalizedDisplayName] = & $entryOf $application.LocalizedDisplayName ([string]$application.Manufacturer) ([string]$application.SoftwareVersion) ([string]$application.PackageID) ([string]$application.SDMPackageXML)
            }
        }

        # Only the count per application is needed, and SMS_ApplicationAssignment
        # answers that straight from the provider: 0.2 s for 49 deployments where
        # Get-CMApplicationDeployment took 5.6 s (it fetches the status of every
        # deployment as well) - half of what "Reading the share and the site"
        # used to cost. The cmdlet stays as the fallback; a failure of both
        # leaves the count at zero and says so, rather than taking the whole
        # inventory down.
        if (-not $fromSql) {
            try {
                $assignments = $null
                try { $assignments = @(Get-WmiObject -Namespace ("root\SMS\site_{0}" -f $Config.siteCode) -ComputerName $Config.siteServer -Query 'SELECT ApplicationName FROM SMS_ApplicationAssignment' -ErrorAction Stop) }
                catch { $assignments = @(Get-CMApplicationDeployment -ErrorAction Stop) }
                foreach ($deployment in $assignments) {
                    $name = [string]$deployment.ApplicationName
                    if ($result.ContainsKey($name)) { $result[$name].Deployments++ }
                }
            }
            catch { Write-Warn ("Could not read the deployments: {0}" -f $_.Exception.Message) }
        }

        # Distribution status per package id: how many distribution points hold
        # the content, are still receiving it, or failed.
        #
        # The counters are read by name from a list of candidates, because a
        # property that is not there answers $null, [int]$null is 0, and a count
        # of zero is indistinguishable from "none of them have it". That is how
        # content sitting on every distribution point reported "targeted, not
        # there yet" for ever: the class calls its success counter NumberSuccess
        # on some site versions and NumberInstalled on others, and reading only
        # one of the two made the other one look like nothing had arrived.
        try {
            $byPackage = @{}
            foreach ($status in @(Get-CMDistributionStatus -ErrorAction Stop)) {
                $byPackage[[string]$status.PackageID] = $status
            }

            foreach ($entry in $result.Values) {
                if (-not $entry.PackageID -or -not $byPackage.ContainsKey($entry.PackageID)) { $entry.Content = 'Not distributed'; continue }
                $status = $byPackage[$entry.PackageID]

                $errors     = Get-StatusCount -Status $status -Names 'NumberErrors', 'NumberFailed'
                $inProgress = Get-StatusCount -Status $status -Names 'NumberInProgress'
                $installed  = Get-StatusCount -Status $status -Names 'NumberSuccess', 'NumberInstalled'
                $unknown    = Get-StatusCount -Status $status -Names 'NumberUnknown'
                $targeted   = Get-StatusCount -Status $status -Names 'Targeted', 'NumberTargeted'

                $entry.Content =
                    if     ($errors -gt 0)     { 'Error on {0} DP' -f $errors }
                    elseif ($inProgress -gt 0) { 'In progress ({0} DP)' -f $inProgress }
                    elseif ($installed -gt 0)  { 'On {0} DP' -f $installed }
                    elseif ($installed -lt 0)  { 'Distributed' }   # no counter this build understands
                    elseif ($unknown -gt 0)    { 'Unknown on {0} DP' -f $unknown }
                    elseif ($targeted -gt 0)   { 'Targeted, not there yet' }
                    else                       { 'Not distributed' }
            }
        }
        catch { Write-Warn ("Could not read the distribution status: {0}" -f $_.Exception.Message) }

        return $result
    }

    $script:SiteStateCache    = $state
    $script:SiteStateCacheKey = [string]$Config.siteCode
    return $state
}

<#
    One row per application: definition, package and site joined on the
    application name "<Name> - <Version>". Returns the rows together with
    whether the site could be read and where the packages are.

    Site applications with no definition and no package are listed when this
    tool published them - the folder may have been cleaned away, and the
    application still has to be reachable for retiring. Foreign applications
    without a row or a folder are not: on a grown site they would outnumber
    everything the tool is about.
#>
function Get-AppInventory {
    param(
        $Config = (Get-ActiveConfig),
        [switch]$NoSiteLookup
    )

    $csvPath = Join-Path $rootDir 'Apps.csv'
    Update-AppListSchema -CsvPath $csvPath
    $definitions = @(Import-Csv -LiteralPath $csvPath -Delimiter ';')

    $rows = [ordered]@{}
    $newRow = {
        param($name, $version)
        [pscustomobject]@{
            Name           = $name
            Version        = $version
            Publisher      = ''
            AppFullName    = (Get-AppFullName -Name $name -Version $version)
            HasDefinition  = $false
            Definition     = '-'
            HasPackage     = $false
            IsLegacy       = $false
            IsManaged      = $false
            Toolkit        = ''
            Package        = '-'
            PackageRoot    = ''
            ContentPath    = ''
            FilesCount     = 0
            LongestPath    = 0
            OverlongFiles  = 0
            WorstPath      = ''
            Fingerprint    = ''
            Modified       = $null
            IsPublished    = $false
            Origin         = ''
            SourceChanged  = $false
            Site           = 'Unknown'
            Content        = ''
            Deployments    = ''
            Status         = ''
            SiteInfo       = ''
            Detail         = ''
            Row            = $null
        }
    }
    $keyOf = { param($name, $version) (Get-AppFullName -Name $name -Version $version).ToLowerInvariant() }

    # --- definitions ---
    foreach ($definition in $definitions) {
        if ([string]::IsNullOrWhiteSpace($definition.Name)) { continue }
        $key = & $keyOf $definition.Name $definition.Version
        if (-not $rows.Contains($key)) { $rows[$key] = & $newRow $definition.Name.Trim() ([string]$definition.Version).Trim() }
        $row = $rows[$key]
        $row.HasDefinition = $true
        $row.Definition    = 'Yes'
        $row.Publisher     = [string]$definition.Publisher
        $row.Row           = $definition
    }

    # --- packages ---
    # Timed, because how long this takes depends on the share and cannot be
    # guessed from here - it is the number to look at when the list feels slow.
    $workRoot = ''
    $packages = @()
    $shareTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $workRoot = Get-PackageWorkRoot -Config $Config
        $packages = @(Get-AppPackage -Config $Config)
    }
    catch { Write-Warn ("The source share is not reachable - only the definitions are listed: {0}" -f $_.Exception.Message) }
    $shareTimer.Stop()

    foreach ($package in $packages) {
        $key = & $keyOf $package.AppName $package.AppVersion
        if (-not $rows.Contains($key)) { $rows[$key] = & $newRow $package.AppName $package.AppVersion }
        $row = $rows[$key]
        $row.HasPackage  = $true
        $row.IsLegacy    = $package.IsLegacy
        $row.IsManaged   = $package.IsManaged
        $row.Toolkit     = $package.Toolkit
        $row.PackageRoot = $package.PackageRoot
        $row.ContentPath = $package.ContentPath
        $row.FilesCount  = $package.FilesCount
        $row.LongestPath = $package.LongestPath
        $row.OverlongFiles = $package.OverlongFiles
        $row.WorstPath   = $package.WorstPath
        $row.Fingerprint = $package.Fingerprint
        $row.Modified    = $package.LastModified
        $row.Package     = $(if ($package.IsLegacy) { 'Legacy' } elseif ($package.FilesCount -gt 0) { 'Ready' } else { 'No files' })
        if (-not $row.Publisher -and -not $package.IsLegacy) { $row.Publisher = Get-PackagePublisher -ContentPath $package.ContentPath }
    }

    # --- site ---
    $siteRead = $false
    $siteTimer = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $NoSiteLookup) {
        try {
            $state = Get-CMApplicationState -Config $Config
            $siteRead = $true

            foreach ($entry in $state.Values) {
                $parsed = Split-AppFolderName -FolderName $entry.AppName
                $key = & $keyOf $parsed.Name $parsed.Version
                # An application that exists only in the site gets a row too,
                # ours or not. Skipping the foreign ones made the documented
                # view "In the site, not on the share" unable to show the very
                # rows it is for: on the lab site two applications - one of them
                # a customer package - were in the site, in no view, and in no
                # count, with nothing saying so.
                if (-not $rows.Contains($key) -and $entry.Location) {
                    # Built by hand or by the predecessor tool: the folder is not named after
                    # the application, but the deployment type's content location names the
                    # folder. That package row becomes this application's row.
                    $loc = ([string]$entry.Location).TrimEnd('\').ToLowerInvariant()
                    $match = $rows.Values | Where-Object { $_.HasPackage -and -not $_.IsPublished -and $_.ContentPath } | Where-Object {
                        $unc = ''; try { $unc = [string](ConvertTo-CMContentPath -Path $_.ContentPath -Config $Config) } catch { }
                        $unc -and ($unc.TrimEnd('\').ToLowerInvariant() -eq $loc)
                    } | Select-Object -First 1
                    if ($match) {
                        $oldKey = & $keyOf $match.Name $match.Version
                        $match.Name = $parsed.Name; $match.Version = $parsed.Version
                        $match.AppFullName = (Get-AppFullName -Name $parsed.Name -Version $parsed.Version)
                        $rows.Remove($oldKey)
                        $rows[$key] = $match
                    }
                }
                if (-not $rows.Contains($key)) {
                    $rows[$key] = & $newRow $parsed.Name $parsed.Version
                    if ($entry.Publisher) { $rows[$key].Publisher = $entry.Publisher }
                }
                $row = $rows[$key]
                $row.IsPublished = $true
                $row.Origin      = $entry.Origin
                $row.Content     = $entry.Content
                $row.Deployments = $entry.Deployments

                if ($entry.Origin -ne 'this tool') {
                    $row.Site = 'Foreign'
                }
                elseif ($row.HasPackage -and $entry.Fingerprint) {
                    # From the walk the package already had - this used to be a
                    # third pass over every published package.
                    $row.SourceChanged = ($row.Fingerprint -ne $entry.Fingerprint)
                    $row.Site = $(if ($row.SourceChanged) { 'Published, source changed' } else { 'Published' })
                }
                else {
                    $row.Site = 'Published'
                }
            }
        }
        catch {
            Write-Warn ("Could not read the applications from the site - the site column stays unknown: {0}" -f $_.Exception.Message)
        }
    }
    $siteTimer.Stop()

    Write-Info ("share {0:N1} s, site {1:N1} s" -f $shareTimer.Elapsed.TotalSeconds, $siteTimer.Elapsed.TotalSeconds)

    foreach ($row in $rows.Values) {
        if ($siteRead -and -not $row.IsPublished) { $row.Site = 'Not published' }

        # One word for how far the row has come and whether something is in
        # the way - checked in the order that matters, so the first thing that
        # needs doing is what is shown.
        $row.Status =
            if     ($row.IsLegacy)                                    { 'Legacy' }
            elseif ($row.IsPublished -and $row.Origin -ne 'this tool' -and $row.IsManaged) { 'Imported, publish pending' }
            elseif ($row.IsPublished -and $row.Origin -ne 'this tool') { 'Foreign' }
            elseif ($row.OverlongFiles -gt 0)                          { 'Path too long' }
            elseif ($row.IsPublished -and -not $row.HasPackage)        { 'Published, no package' }
            elseif ($row.IsPublished -and $row.SourceChanged)          { 'Published, changed' }
            elseif ($row.IsPublished)                                  { 'Published' }
            elseif ($row.HasPackage -and $row.FilesCount -eq 0)        { 'No installer' }
            elseif ($row.HasPackage -and -not $row.HasDefinition)     { 'Ready to import' }    # a folder the list does not know: Build / Import takes it over
            elseif ($row.HasPackage)                                   { 'Ready to publish' }
            else                                                       { 'Ready to build' }     # a definition without a package: Build / Import builds it

        # What the site says in numbers, in one cell.
        if (-not $siteRead)            { $row.SiteInfo = 'not read' }
        elseif (-not $row.IsPublished) { $row.SiteInfo = '' }
        else {
            $deployments = switch ([int]$row.Deployments) { 0 { 'no deployments' } 1 { '1 deployment' } default { "$_ deployments" } }
            $content = [string]$row.Content
            if ($content) { $content = $content.Substring(0, 1).ToLower() + $content.Substring(1) }
            if ($content -like 'Error*' -or $content -like 'error*') { $content = 'content ' + $content }
            $row.SiteInfo = $(if ($content) { '{0}, {1}' -f $deployments, $content } else { $deployments })
        }

        $detail = @()
        $detail += $(if ($row.HasDefinition) { 'Definition: row in Apps.csv' }
                     elseif ($row.IsLegacy) { 'Definition: none' }
                     else { 'Definition: none - the package is imported on Build or Publish' })
        $detail += $(if ($row.IsLegacy) { 'Package: {0} - no PSADT script inside, so the tool does not touch it ({1} file(s))' -f $row.PackageRoot, $row.FilesCount }
                     elseif ($row.HasPackage) { 'Package: {0} - PSADT {1}, {2} file(s) in Files' -f $row.PackageRoot, $row.Toolkit, $row.FilesCount }
                     else { 'Package: none - build it first' })
        $detail += $(switch ($row.Site) {
            'Published'                 { 'Site: published by this tool, content unchanged since' }
            'Published, source changed' { 'Site: published by this tool, but the package changed since - publish again to send the new content' }
            'Foreign'                   { 'Site: an application of this name exists, but was not created by this tool - publishing overwrites its detection' }
            'Not published'             { 'Site: no application of this name' }
            default                     { 'Site: not read' }
        })
        if ($row.IsPublished) { $detail += ('Content: {0} - Deployments: {1}' -f $row.Content, $row.Deployments) }
        if ($row.OverlongFiles -gt 0) {
            $detail += ('Path: {0} file(s) past 259 characters over UNC, longest {1} - shorten by {2}, e.g. by renaming the folder. ConfigMgr would report "could not find file".' -f
                $row.OverlongFiles, $row.LongestPath, ($row.LongestPath - 259))
        }
        elseif ($row.HasPackage -and -not $row.IsLegacy) { $detail += ('Path: longest {0} of 259 characters over UNC' -f $row.LongestPath) }
        $row.Detail = ($detail -join [Environment]::NewLine)
    }

    return [pscustomobject]@{
        Rows     = @($rows.Values | Sort-Object Name, Version)
        SiteRead = $siteRead
        WorkRoot = $workRoot
    }
}

#endregion

#region ------------------------------------------------------ the definition

<#
    Writes a row into Apps.csv, replacing the row of the same name and version
    if there is one. -ReplaceName / -ReplaceVersion name the row to replace when
    the key itself was edited.
#>
function Set-AppListRow {
    param(
        [Parameter(Mandatory = $true)]$App,
        [string]$ReplaceName,
        [string]$ReplaceVersion,
        [string]$CsvPath = (Join-Path $rootDir 'Apps.csv')
    )

    Update-AppListSchema -CsvPath $CsvPath
    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter ';')

    $oldName    = $(if ($ReplaceName)    { $ReplaceName }    else { $App.Name })
    $oldVersion = $(if ($ReplaceVersion) { $ReplaceVersion } else { $App.Version })

    $kept = @($rows | Where-Object {
        -not ($_.Name.Trim() -eq $oldName.Trim() -and ([string]$_.Version).Trim() -eq $oldVersion.Trim()) -and
        -not ($_.Name.Trim() -eq $App.Name.Trim() -and ([string]$_.Version).Trim() -eq $App.Version.Trim())
    })
    $replaced = ($kept.Count -lt $rows.Count)

    $new = New-Object psobject
    foreach ($column in $script:AppListColumns) {
        $value = ''
        if ($App.PSObject.Properties.Name -contains $column) { $value = [string]$App.$column }
        $new | Add-Member -MemberType NoteProperty -Name $column -Value $value
    }

    ($kept + $new) |
        Sort-Object Name, Version |
        Select-Object -Property $script:AppListColumns |
        Export-Csv -LiteralPath $CsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

    if ($replaced) { Write-Ok ("App list updated: {0} - {1}" -f $App.Name, $App.Version) }
    else           { Write-Ok ("Added to the app list: {0} - {1}" -f $App.Name, $App.Version) }
}

function Test-AppListRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$CsvPath = (Join-Path $rootDir 'Apps.csv')
    )

    if (-not (Test-Path -LiteralPath $CsvPath)) { return $false }
    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter ';')
    return (@($rows | Where-Object { $_.Name.Trim() -eq $Name.Trim() -and ([string]$_.Version).Trim() -eq $Version.Trim() }).Count -gt 0)
}

function Remove-AppListRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$CsvPath = (Join-Path $rootDir 'Apps.csv')
    )

    if (-not (Test-Path -LiteralPath $CsvPath)) { return }
    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter ';')
    $kept = @($rows | Where-Object { -not ($_.Name.Trim() -eq $Name.Trim() -and ([string]$_.Version).Trim() -eq $Version.Trim()) })
    if ($kept.Count -eq $rows.Count) { return }

    if ($kept.Count -eq 0) {
        Set-Content -LiteralPath $CsvPath -Value ('"' + ($script:AppListColumns -join '";"') + '"') -Encoding UTF8
    }
    else {
        $kept | Sort-Object Name, Version | Select-Object -Property $script:AppListColumns |
            Export-Csv -LiteralPath $CsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    }
    Write-Ok ("Removed from the app list: {0} - {1}" -f $Name, $Version)
}

<#
    An Apps.csv shaped object from whatever carries the columns - a CSV row, an
    inventory row's definition, or the ordered hashtable the editor returns.
#>
<#
    Which row the main window should come back to after an action.

    Normally that is whatever was selected, and the loop carries it over on its
    own. An action that renames a row - editing name or version - or creates one
    says so here, so the window lands on the row that came out of the action
    rather than on the name that no longer exists.
#>
$script:InventorySelectAfterAction = @()

function Set-InventorySelection {
    param([string[]]$AppFullName)
    $script:InventorySelectAfterAction = @($AppFullName | Where-Object { $_ })
}

function Get-InventorySelection {
    $selection = @($script:InventorySelectAfterAction)
    $script:InventorySelectAfterAction = @()
    return $selection
}

function ConvertTo-AppRecord {
    param($Source)

    $app = New-AppRecord
    if ($null -eq $Source) { return $app }

    foreach ($column in $script:AppListColumns) {
        $value = $null
        if ($Source -is [System.Collections.IDictionary]) { if ($Source.Contains($column)) { $value = $Source[$column] } }
        elseif ($Source.PSObject.Properties.Name -contains $column) { $value = $Source.$column }
        if ($null -ne $value) { $app.$column = [string]$value }
    }
    if ([string]::IsNullOrWhiteSpace($app.DetectionMethod)) { $app.DetectionMethod = 'Registry' }
    return $app
}

<#
    The row for an installer picked from disk - the same reading the From MSI
    and From EXE buttons of the editor do, as a record.
#>
function ConvertTo-FileAppRow {
    param([Parameter(Mandatory = $true)][string]$Path)

    $app = ConvertTo-AppRecord
    $fileName = Split-Path -Leaf $Path

    if ([System.IO.Path]::GetExtension($Path) -eq '.msi') {
        $props = Get-MsiProperties -Path $Path
        $app.Publisher       = [string]$props['Manufacturer']
        $app.Name            = [string]$props['ProductName']
        $app.Version         = [string]$props['ProductVersion']
        $app.ProductCode     = [string]$props['ProductCode']
        $app.DetectionMethod = 'MSI'
        $app.Notes           = "from $fileName"
    }
    else {
        $props = Get-ExeProperties -Path $Path
        $app.Publisher       = [string]$props['Manufacturer']
        $app.Name            = [string]$props['ProductName']
        $app.Version         = [string]$props['ProductVersion']
        $app.DetectionMethod = 'Registry'
        # The engine that built the EXE decides both switches (Get-InstallerEngine);
        # an installer of unknown type gets /S, and the command says so.
        $engine = Get-InstallerEngine -Path $Path
        $app.InstallCmd      = Get-ExeInstallCommand -FileName $fileName -Engine $engine
        if ($app.Name) { $app.UninstallCmd = Get-ExeUninstallCommand -Name $app.Name -Engine $engine }
        $app.Notes           = "from $fileName ($($engine.Engine))"
    }

    return $app
}

<#
    Opens the folder and the script of a package the way the old packaging
    assistant did - only wanted when the tool could not put the installer in
    Files itself.
#>
function Open-PackageForEditing {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        $Config = (Get-ActiveConfig)
    )

    if (-not ($Config.openExplorerOnCreate -or $Config.openEditorOnCreate)) { return }
    $contentPath = Get-PackageContentPath -PackageRoot $PackageRoot -Config $Config

    if ($Config.openExplorerOnCreate) {
        Write-Host 'ToDo: copy all setup files into .\Files, then press ENTER' -ForegroundColor Cyan
        explorer (Join-Path $contentPath 'Files')
        pause
    }
    if ($Config.openEditorOnCreate) {
        Write-Host 'ToDo: check the Install & Uninstall sections, then press ENTER' -ForegroundColor Cyan
        $editor = if ($Config.editor) { $Config.editor } else { 'notepad' }
        & $editor (Get-ADTScript -ContentRoot $contentPath).Path
        pause
    }
}

#endregion

#region ---------------------------------------------------------- the actions

<#
    Adds an application in one step: fetch the installer, confirm the record,
    build the package with the installer in Files, write the row.

        Winget   pick a package from the manifests, download and verify
        File     pick an EXE or MSI that was downloaded separately
        Blank    an empty record - the package is built without an installer
                 and the folder is opened for filling in by hand

    -Template prefills the editor from an existing row, which is what "New
    version" is: the same product, resolved to its newest version.
#>
function Add-AppFromSource {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Winget', 'File', 'Blank')][string]$Source,
        $Template,
        $Config = (Get-ActiveConfig)
    )

    $app       = ConvertTo-AppRecord -Source $Template
    $installer = $null
    $title     = 'New application'

    switch ($Source) {
        'Winget' {
            $found = Read-CatalogPackage -Config $Config -Template $Template
            if (-not $found) { return $null }
            $winget = $found.Row

            if (-not $Template) { $app = ConvertTo-AppRecord -Source $winget }
            else {
                # A new version of a known product. The name stays - it is what
                # the versions are grouped by and what supersedence follows - and
                # so does a detection somebody has worked out, unless the new
                # installer is an MSI, where the ProductCode is the better rule.
                # Version, commands and notes follow the new installer.
                $app.Version      = $winget.Version
                $app.InstallCmd   = $winget.InstallCmd
                $app.UninstallCmd = $winget.UninstallCmd
                $app.Notes        = $winget.Notes
                if (-not $app.Publisher) { $app.Publisher = $winget.Publisher }
                if ($winget.DetectionMethod -eq 'MSI' -or -not $app.DetectionPattern) {
                    $app.DetectionMethod  = $winget.DetectionMethod
                    $app.DetectionPattern = $winget.DetectionPattern
                    $app.ProductCode      = $winget.ProductCode
                }
            }
            $installer = $found.File
            $title     = 'New application from winget'
            # A manifest of type "exe" says nothing about the engine; the
            # downloaded file does. Only then are the switches worth a second look.
            if ($installer -and $app.DetectionMethod -ne 'MSI' -and $app.Notes -match '\(\w+, exe' -and (Test-Path -LiteralPath $installer)) {
                $engine = Get-InstallerEngine -Path $installer
                if ($engine.Engine -ne 'unknown') {
                    $app.InstallCmd   = Get-ExeInstallCommand -FileName (Split-Path -Leaf $installer) -Engine $engine
                    $app.UninstallCmd = Get-ExeUninstallCommand -Name $app.Name -Engine $engine
                    $app.Notes        = $app.Notes + ', engine ' + $engine.Engine
                }
            }
        }
        'File' {
            $ofd = New-Object Microsoft.Win32.OpenFileDialog
            $ofd.Title  = 'Select the installer'
            $ofd.Filter = 'Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*'
            if ($ofd.ShowDialog() -ne $true -or -not $ofd.FileName) { Write-Info 'Cancelled.'; return $null }

            $read = ConvertTo-FileAppRow -Path $ofd.FileName
            if (-not $Template) { $app = $read }
            else {
                if ($read.Version) { $app.Version = $read.Version } else { $app.Version = '' }
                $app.InstallCmd   = $read.InstallCmd
                $app.UninstallCmd = $read.UninstallCmd
                $app.Notes        = $read.Notes
                if (-not $app.Publisher) { $app.Publisher = $read.Publisher }
                if ($read.DetectionMethod -eq 'MSI' -or -not $app.DetectionPattern) {
                    $app.DetectionMethod  = $read.DetectionMethod
                    $app.DetectionPattern = $read.DetectionPattern
                    $app.ProductCode      = $read.ProductCode
                }
            }
            $installer = $ofd.FileName
            $title     = 'New application from ' + (Split-Path -Leaf $ofd.FileName)
        }
        'Blank' {
            if ($Template) { $app.Version = '' }
            $title = 'New application'
        }
    }

    $item = [ordered]@{}
    foreach ($column in $script:AppListColumns) { $item[$column] = $app.$column }

    $script:EditDialogInstallerPath = $null
    $answer = Open-EditDialog -item $item -title $title -PropertyOrder $script:AppListColumns
    $answer = $answer | Where-Object { $_ -isnot [int] }
    if (-not $answer) {
        if ($installer -and $installer -like (Join-Path (Get-PackageWorkRoot -Config $Config) '_DL\*')) {
            Write-Info "Cancelled - the download stays in $installer"
        }
        else { Write-Info 'Cancelled.' }
        return $null
    }
    if ($script:EditDialogInstallerPath) { $installer = $script:EditDialogInstallerPath }

    $app = ConvertTo-AppRecord -Source $answer
    if (-not $app.Name -or -not $app.Version) { throw 'Name and Version are required - they name the package folder and the application.' }

    Set-AppListRow -App $app
    # The new row is what the window should land on, not what was selected
    # before it existed.
    Set-InventorySelection -AppFullName (Get-AppFullName -Name $app.Name -Version $app.Version)
    $packageRoot = New-AppPackage -App $app -Config $Config -InstallerPath $installer
    if (-not $installer) { Open-PackageForEditing -PackageRoot $packageRoot -Config $Config }

    # Said in the window too, not only on the console: the package exists now,
    # and it is the moment to rename it, before anything refers to it.
    $contentPath = Get-PackageContentPath -PackageRoot $packageRoot -Config $Config
    $measure = Measure-ContentPath -ContentPath $contentPath -ContentUnc (ConvertTo-CMContentPath -Path $contentPath -Config $Config)
    if ($measure.Overlong -gt 0) {
        $null = Show-MessageDialog -Caption 'Path too long' -Buttons 'OK' -Icon 'Warning' -Text (
            "The package is built, but {0} file(s) in it are past the 259 character path limit once ConfigMgr addresses the content over UNC. The longest is {1} characters:`n`n...{2}`n`nShorten it by at least {3} characters - a shorter Name or Version is usually enough - or publishing will be refused." -f
            $measure.Overlong, $measure.Longest, $measure.Worst.Substring([Math]::Max(0, $measure.Worst.Length - 90)), ($measure.Longest - $measure.Limit))
    }
    return $packageRoot
}

<#
    The read-only facts about a row, for the top of the per-application dialog:
    what the list no longer shows as columns.
#>
function Get-InventoryRowInfo {
    param([Parameter(Mandatory = $true)]$InventoryRow)

    $info = [ordered]@{}
    $info['Status']     = [string]$InventoryRow.Status
    $info['Definition'] = $(if ($InventoryRow.HasDefinition) { 'row in Apps.csv' } else { 'none' })
    $info['Package']    = $(if ($InventoryRow.HasPackage) { [string]$InventoryRow.PackageRoot } else { 'none' })
    if ($InventoryRow.HasPackage) {
        $info['PSADT'] = $(if ($InventoryRow.IsLegacy) { 'none - legacy folder' } else { 'generation ' + $InventoryRow.Toolkit })
        $info['Files'] = '{0} file(s)' -f $InventoryRow.FilesCount
        if ($InventoryRow.Modified) { $info['Modified'] = ([datetime]$InventoryRow.Modified).ToString('yyyy-MM-dd HH:mm') }
        if (-not $InventoryRow.IsLegacy) {
            $info['Path'] = $(if ($InventoryRow.OverlongFiles -gt 0) {
                '{0} file(s) past 259 characters over UNC - longest {1}, shorten by {2}: ...{3}' -f $InventoryRow.OverlongFiles, $InventoryRow.LongestPath,
                    ($InventoryRow.LongestPath - 259), ([string]$InventoryRow.WorstPath).Substring([Math]::Max(0, ([string]$InventoryRow.WorstPath).Length - 60))
            } else { 'longest {0} of 259 characters over UNC' -f $InventoryRow.LongestPath })
        }
    }
    $site = [string]$InventoryRow.Site
    if ($InventoryRow.SiteInfo -and $InventoryRow.SiteInfo -ne 'not read') { $site += ' - ' + $InventoryRow.SiteInfo }
    $info['Site'] = $site
    return $info
}

<#
    Edits the definition of a row. A package that exists is rebuilt from the
    edited row - metadata and commands, nothing else - so the row stays the
    source of truth. Name and Version are the key: editing them does not rename
    a package folder, and the message says so.
#>
function Edit-AppDefinition {
    param(
        [Parameter(Mandatory = $true)]$InventoryRow,
        $Config = (Get-ActiveConfig)
    )

    $info = Get-InventoryRowInfo -InventoryRow $InventoryRow

    if ($InventoryRow.IsLegacy -and -not $InventoryRow.HasDefinition) {
        $info['Note'] = 'No PSADT script inside, so there is nothing the tool could read a definition from or write one into. Add the application afresh, or put a PSADT structure into the folder.'
        $null = Open-EditDialog -Info $info -ReadOnly -title ('View: ' + $InventoryRow.AppFullName) -PropertyOrder @()
        return $false
    }

    # A package the list only knows from the share or the site has no row to
    # edit: the editor would open empty, and OK would rebuild the package from
    # that emptiness, over the commands the foreign script carries. Build /
    # Import reads them into a row first; Edit is for the row.
    if (-not $InventoryRow.HasDefinition) {
        $info['Note'] = 'No definition yet. Build / Import reads the package into a row of Apps.csv - then the row can be edited.'
        $null = Open-EditDialog -Info $info -ReadOnly -title ('View: ' + $InventoryRow.AppFullName) -PropertyOrder @()
        return $false
    }

    $app  = ConvertTo-AppRecord -Source $InventoryRow.Row
    # An EXE package without an uninstall command removes nothing on uninstall
    # and supersedence. The installer in Files\ says which engine built it, and
    # that decides the switch - so the field comes filled in, and the user only
    # has to keep it.
    if ([string]::IsNullOrWhiteSpace([string]$app.UninstallCmd) -and $app.DetectionMethod -ne 'MSI' -and $InventoryRow.HasPackage -and -not $InventoryRow.IsLegacy) {
        $exe = Find-PackageInstallerExe -ContentPath $InventoryRow.ContentPath -InstallCmd ([string]$app.InstallCmd)
        if ($exe) {
            $app.UninstallCmd = Get-ExeUninstallCommand -Name $app.Name -Engine (Get-InstallerEngine -Path $exe)
            Write-Info ("UninstallCmd filled in from {0}" -f (Split-Path -Leaf $exe))
        }
    }
    $item = [ordered]@{}
    foreach ($column in $script:AppListColumns) { $item[$column] = $app.$column }

    $script:EditDialogInstallerPath = $null
    $answer = Open-EditDialog -item $item -Info $info -title ('Edit: ' + $InventoryRow.AppFullName) -PropertyOrder $script:AppListColumns
    $answer = $answer | Where-Object { $_ -isnot [int] }
    if (-not $answer) { Write-Info 'Cancelled.'; return $false }

    $edited = ConvertTo-AppRecord -Source $answer
    if (-not $edited.Name -or -not $edited.Version) { throw 'Name and Version are required.' }

    $keyChanged = ($edited.Name.Trim() -ne $InventoryRow.Name) -or ($edited.Version.Trim() -ne $InventoryRow.Version)
    Set-AppListRow -App $edited -ReplaceName $InventoryRow.Name -ReplaceVersion $InventoryRow.Version

    # Come back to this row - under its new name, if it got one.
    Set-InventorySelection -AppFullName (Get-AppFullName -Name $edited.Name -Version $edited.Version)

    if ($InventoryRow.HasPackage -and $keyChanged) {
        $null = Show-MessageDialog -Caption 'Definition edited' -Buttons 'OK' -Icon 'Information' -Text (
            "The name or version changed. The package folder`n`n{0}`n`nkeeps its name - Build / Import creates a new one for `"{1} - {2}`"." -f
            $InventoryRow.PackageRoot, $edited.Name, $edited.Version)
        return $true
    }

    if ($InventoryRow.HasPackage -and -not $InventoryRow.IsLegacy) {
        $null = New-AppPackage -App $edited -Config $Config -InstallerPath $script:EditDialogInstallerPath
    }
    return $true
}

<#
    Removes definitions. The package folder and the application in the site are
    not touched - Retire is for those.
#>
function Remove-AppDefinition {
    param([Parameter(Mandatory = $true)]$InventoryRows)

    # a row with a definition, or a folder the list only knows from the share
    $rows = @($InventoryRows | Where-Object { $_.HasDefinition -or $_.HasPackage })
    if ($rows.Count -eq 0) {
        $null = Show-MessageDialog -Text 'None of the selected rows has a definition in Apps.csv or a package folder.' -Caption 'Delete definition' -Buttons 'OK' -Icon 'Information'
        return
    }

    # A row is one of three things the list joins; deleting only the row left
    # the package folder, and the application kept showing up as "Imported" -
    # "nach delete definition taucht die app immer noch auf". So Delete takes
    # the package folder with it, and a version that is published in the site
    # is not touched here at all: that is Retire > Remove, which takes the
    # application, the folder and the row apart in the right order.
    $published = @($rows | Where-Object { $_.IsPublished })
    $deletable = @($rows | Where-Object { -not $_.IsPublished })
    if ($deletable.Count -eq 0) {
        $null = Show-MessageDialog -Text ("Published in the site - use Retire > Remove to delete the version completely:`n`n{0}" -f (($published | ForEach-Object { $_.AppFullName }) -join [Environment]::NewLine)) -Caption 'Delete definition' -Buttons 'OK' -Icon 'Information'
        return
    }
    $lines = @($deletable | ForEach-Object { $_.AppFullName + $(if ($_.HasPackage) { '   + folder ' + $_.PackageRoot } else { '' }) })
    $text = "Delete {0} definition(s) from Apps.csv?`n`n{1}" -f $deletable.Count, ($lines -join [Environment]::NewLine)
    if ($published.Count -gt 0) {
        $text += "`n`nNot touched, published in the site (Retire > Remove deletes those):`n{0}" -f (($published | ForEach-Object { $_.AppFullName }) -join [Environment]::NewLine)
    }
    $answer = Show-MessageDialog -Text $text -Caption 'Delete definition' -Buttons 'YesNo' -Icon 'Warning'
    if ($answer -ne 'Yes') { Write-Info 'Cancelled.'; return }

    foreach ($row in $deletable) {
        if ($row.HasPackage -and $row.PackageRoot -and (Test-Path -LiteralPath $row.PackageRoot)) {
            try { Remove-Item -LiteralPath $row.PackageRoot -Recurse -Force -ErrorAction Stop; Write-Ok ("Folder deleted: {0}" -f $row.PackageRoot) }
            catch { Write-Fail ("Folder {0}: {1}" -f $row.PackageRoot, $_.Exception.Message); continue }
        }
        if ($row.HasDefinition) { Remove-AppListRow -Name $row.Name -Version $row.Version }
    }
}

<#
    Builds the packages of the selected rows. A row without a definition but
    with a package is taken over instead - that is what Import-AppPackage does.
#>
function Build-AppPackages {
    param(
        [Parameter(Mandatory = $true)]$InventoryRows,
        $Config = (Get-ActiveConfig)
    )

    $rows = @($InventoryRows)
    foreach ($row in $rows) {
        try {
            if ($row.IsLegacy) {
                Write-Warn ("[{0}] is a legacy folder without a PSADT script - nothing to build. Put a PSADT structure in it, or add the application afresh." -f $row.AppFullName)
                continue
            }
            # A package the tool has not taken over yet is imported even when a
            # row exists (a row from the older scripts next to their package):
            # Import reads the script's sections into the row and keeps what
            # the row already says; a plain rebuild would write the row over
            # the script. Edge on the lab share was that case - row, MSI
            # package, no tool blocks, status Foreign, and Build greyed out.
            if ($row.HasDefinition -and ($row.IsManaged -or -not $row.HasPackage)) {
                $packageRoot = New-AppPackage -App (ConvertTo-AppRecord -Source $row.Row) -Config $Config
                if (-not $row.HasPackage -and $rows.Count -eq 1) { Open-PackageForEditing -PackageRoot $packageRoot -Config $Config }
            }
            elseif ($row.HasPackage) {
                $null = Import-AppPackage -PackageRoot $row.PackageRoot -Name $row.Name -Version $row.Version -Bulk:($rows.Count -gt 1) -Config $Config
            }
            else {
                Write-Warn ("[{0}] has neither a definition nor a package - nothing to build." -f $row.AppFullName)
            }
        }
        catch {
            Write-Fail ("[{0}] {1}" -f $row.AppFullName, (Format-ErrorDetail -ErrorRecord $_))
            if ($rows.Count -eq 1) { pause }
        }
    }
}

<#
    Publishes the selected rows. A row without a package cannot be published;
    it is built first when it has a definition, so "publish" on a fresh row does
    the whole way.
#>
function Publish-AppPackages {
    param(
        [Parameter(Mandatory = $true)]$InventoryRows,
        $Config = (Get-ActiveConfig)
    )

    $rows = @($InventoryRows)
    $bulk = ($rows.Count -gt 1)
    foreach ($row in $rows) {
        try {
            if ($row.IsLegacy) {
                Write-Warn ("[{0}] is a legacy folder without a PSADT script - the tool cannot publish it." -f $row.AppFullName)
                continue
            }
            $packageRoot = $row.PackageRoot
            if (-not $row.HasPackage) {
                if (-not $row.HasDefinition) { Write-Warn ("[{0}] has no package on the share - nothing to publish." -f $row.AppFullName); continue }
                Write-Info ("[{0}] has no package yet - building it first." -f $row.AppFullName)
                $packageRoot = New-AppPackage -App (ConvertTo-AppRecord -Source $row.Row) -Config $Config
            }
            if ($row.HasPackage -and $row.FilesCount -eq 0) {
                Write-Warn ("[{0}] Files\ is empty - the package installs nothing until the installer is in there." -f $row.AppFullName)
            }
            Publish-CMApplication -PackageRoot $packageRoot -Bulk:$bulk -Config $Config
        }
        catch {
            Write-Fail ("[{0}] {1}" -f $row.AppFullName, (Format-ErrorDetail -ErrorRecord $_))
            if (-not $bulk) { pause }
        }
    }
}

<#
    Runs the action the main dialog returned. Returns $false when the tool
    should exit, $true to show the list again.
#>
function Invoke-InventoryAction {
    param(
        [Parameter(Mandatory = $true)]$Choice,
        $Config = (Get-ActiveConfig)
    )

    $selection = @($Choice.Selection)
    $first     = $selection | Select-Object -First 1

    # What an action invalidates of what the inventory remembers. Everything
    # not listed here - opening a folder, deleting a definition, a cancelled
    # dialog - leaves the share and the site untouched, so the list comes back
    # without walking either again.
    $touched = @($selection | ForEach-Object { $_.ContentPath } | Where-Object { $_ })
    $touchedAll = @($selection | Where-Object { -not $_.HasPackage }).Count -gt 0

    switch ($Choice.Action) {
        'Add' {
            Write-Step ("Add application from {0}" -f $Choice.Source.ToLower())
            try { $null = Add-AppFromSource -Source $Choice.Source -Config $Config }
            catch { Write-Fail (Format-ErrorDetail -ErrorRecord $_); pause }
            Clear-InventoryCache                                    # a folder appeared
        }
        'NewVersion' {
            if (-not $first) { break }
            Write-Step ("New version of {0}" -f $first.Name)
            try { $null = Add-AppFromSource -Source $Choice.Source -Template (ConvertTo-AppRecord -Source $(if ($first.Row) { $first.Row } else { $first })) -Config $Config }
            catch { Write-Fail (Format-ErrorDetail -ErrorRecord $_); pause }
            Clear-InventoryCache                                    # a folder appeared
        }
        'Edit' {
            if (-not $first) { break }
            Write-Step ("Edit {0}" -f $first.AppFullName)
            try { $null = Edit-AppDefinition -InventoryRow $first -Config $Config }
            catch { Write-Fail (Format-ErrorDetail -ErrorRecord $_); pause }
            if ($first.ContentPath) { Clear-InventoryCache -ContentPath $first.ContentPath } else { Clear-InventoryCache }
        }
        'Delete' {
            if ($selection.Count -eq 0) { break }
            Write-Step 'Delete definition'
            Remove-AppDefinition -InventoryRows $selection
        }
        'Build' {
            if ($selection.Count -eq 0) { break }
            Write-Step 'Build packages'
            Build-AppPackages -InventoryRows $selection -Config $Config
            if ($touchedAll) { Clear-InventoryCache } else { Clear-InventoryCache -ContentPath $touched }
        }
        'Publish' {
            if ($selection.Count -eq 0) { break }
            Write-Step 'Publish to ConfigMgr'
            Publish-AppPackages -InventoryRows $selection -Config $Config
            if ($touchedAll) { Clear-InventoryCache } else { Clear-InventoryCache -ContentPath $touched -Site }
        }
        'Retire' {
            Write-Step 'Retire applications'
            retireApps
            Clear-InventoryCache                                    # applications and folders may be gone
        }
        'OpenFolder' {
            try {
                $path = $(if ($first -and $first.HasPackage) { $first.PackageRoot } else { Get-PackageWorkRoot -Config $Config })
                Write-Info "Opening $path"
                explorer $path
            }
            catch { Write-Warn $_.Exception.Message }
        }
        'Tools'   { Write-Step 'Tools'; Show-ToolsMenu; Clear-InventoryCache -Site }
        'Refresh' { Clear-InventoryCache }
        'Cancel'  { Write-Info 'Closed';          return $false }
        'Closed'  { Write-Info 'Closed with [X]'; return $false }
        default   { Write-Info "Unexpected: $($Choice.Action)"; return $false }
    }
    return $true
}

#endregion
