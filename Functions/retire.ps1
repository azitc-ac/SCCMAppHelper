<#
    SCCMAppHelper - retiring an application version

    Two levels, because "stop deploying this" and "delete this" are different
    intentions and only one of them is reversible:

        Retire  removes the deployments. Application, deployment type,
                collections, content and supersedence all stay - nothing
                installs any more, and publishing again undoes it.

        Remove  does that and then takes the rest apart: supersedence
                references, content on the distribution points, the two
                per-application collections, the application, the package
                folder on the share and the row in Apps.csv - the version is
                gone from all three places the tool keeps in step. (Until
                2026-09-16 the folder was a checkbox and the row was never
                touched; the user wanted old versions gone, not half gone.)

    Two rules the code keeps throughout:

    * A collection that is not named after the application is never deleted.
      The catalog collection from globalDeployments loses its deployment and
      nothing else.
    * Nothing is changed that the user did not select - with one exception,
      which is why it needs its own confirmation: an application can only be
      deleted once the newer versions stop superseding it, and those are other
      objects.
#>

#region ------------------------------------------------------------ inventory

<#
    Every application in the site, with the numbers a retire decision needs:
    how many deployments hang off it, whether its content sits on a
    distribution point, which applications supersede it, and whether the tool
    published it in the first place.
#>
function Get-CMApplicationInventory {
    param($Config = (Get-ActiveConfig))

    $signature = Get-ToolSignaturePattern

    # The collections that belong to an application are the ones named after it,
    # not the ones it happens to be deployed to. Deriving them from deployments
    # misses every collection that has none - which is exactly the state a
    # Retire leaves behind, and the state createDeployments = false produces.
    $ownedPatterns = @($Config.collections | ForEach-Object { $_.namePattern })

    # The block returns its result rather than appending to a variable outside
    # it: a scriptblock run with & cannot assign to the caller's variables, it
    # only ever gets a copy. Mutating a hashtable works, "+=" does not.
    # Deployments and collections come from two provider queries for the whole
    # site, not from two cmdlets per application: Get-CMApplicationDeployment
    # -Name and Get-CMDeviceCollection -Name cost about a second each, and with
    # 22 applications the list took 34 s to read. SMS_ApplicationAssignment
    # carries the collection name of every deployment; SMS_Collection is asked
    # once for every name the owned patterns can produce (their fixed prefix).
    $namespace = 'root\SMS\site_{0}' -f $Config.siteCode
    $assignmentsByApp = @{}
    try {
        foreach ($a in @(Get-WmiObject -Namespace $namespace -ComputerName $Config.siteServer -Query 'SELECT ApplicationName, CollectionName FROM SMS_ApplicationAssignment' -ErrorAction Stop)) {
            $n = [string]$a.ApplicationName
            if (-not $assignmentsByApp.ContainsKey($n)) { $assignmentsByApp[$n] = @() }
            $assignmentsByApp[$n] += [string]$a.CollectionName
        }
    }
    catch { Write-Warn ("Could not read the deployments: {0}" -f $_.Exception.Message) }
    $collectionNames = @{}
    foreach ($pattern in $ownedPatterns) {
        $prefix = ($pattern -split '\{App\}')[0]
        try {
            foreach ($c in @(Get-WmiObject -Namespace $namespace -ComputerName $Config.siteServer -Query ("SELECT Name FROM SMS_Collection WHERE Name LIKE '{0}%'" -f ($prefix -replace "'", "''")) -ErrorAction Stop)) { $collectionNames[([string]$c.Name).ToLower()] = $true }
        }
        catch { Write-Warn ("Could not read the collections: {0}" -f $_.Exception.Message) }
    }

    $inventory = Invoke-InCMSite -Config $Config -ScriptBlock {
        $rows = @()
        $applications = @(Get-CMApplication)

        # An application that supersedes another names the other's logical
        # name in its own package XML. One pass collects, per application,
        # its own logical name and every Application_<guid> it refers to; the
        # referrers of an application are then a set lookup, not a regex over
        # every other application's 40 KB of XML.
        $logicalNames = @{}; $references = @{}
        foreach ($application in $applications) {
            $xml = [string]$application.SDMPackageXML
            if ($xml -match '<Application\b[^>]*\bLogicalName="(?<name>Application_[^"]+)"') { $logicalNames[$application.LocalizedDisplayName] = $Matches['name'] }
            $set = @{}
            foreach ($m in [regex]::Matches($xml, 'Application_[0-9a-fA-F-]{36}')) { $set[$m.Value] = $true }
            $references[$application.LocalizedDisplayName] = $set
        }

        foreach ($application in $applications) {
            $displayName = $application.LocalizedDisplayName
            $logical     = $logicalNames[$displayName]

            $supersededBy = @()
            if ($logical) {
                foreach ($other in $applications) {
                    if ($other.LocalizedDisplayName -eq $displayName) { continue }
                    if ($references[$other.LocalizedDisplayName].ContainsKey($logical)) { $supersededBy += $other.LocalizedDisplayName }
                }
            }

            $deploymentCollections = @()
            if ($assignmentsByApp.ContainsKey($displayName)) { $deploymentCollections = @($assignmentsByApp[$displayName]) }

            $owned = @()
            foreach ($pattern in $ownedPatterns) {
                $collectionName = $pattern.Replace('{App}', $displayName)
                if ($collectionNames.ContainsKey($collectionName.ToLower())) { $owned += $collectionName }
            }

            $rows += [pscustomobject]@{
                AppName          = $displayName
                Name             = $application.LocalizedDisplayName
                Version          = [string]$application.SoftwareVersion
                Deployments      = $deploymentCollections.Count
                Collections      = $deploymentCollections
                OwnedCollections = $owned
                SupersededBy     = $supersededBy
                Origin           = $(if ($application.SDMPackageXML -match $signature) { 'this tool' } else { 'foreign' })
                ModelName        = $application.ModelName
            }
        }

        return $rows
    }

    return (@($inventory) | Sort-Object AppName)
}

<#
    True when the site holds a newer version of the same product. The name is
    "<Product> - <Version>" by convention, so the product is everything before
    the last separator - the same split the package folders use.
#>
function Test-HasNewerVersion {
    param(
        [Parameter(Mandatory = $true)]$Application,
        [Parameter(Mandatory = $true)]$Inventory
    )

    $mine = $null
    $parsed = Split-AppFolderName -FolderName $Application.AppName
    if (-not [System.Version]::TryParse($parsed.Version, [ref]$mine)) { return $false }

    foreach ($other in $Inventory) {
        if ($other.AppName -eq $Application.AppName) { continue }
        $otherParsed = Split-AppFolderName -FolderName $other.AppName
        if ($otherParsed.Name -ne $parsed.Name) { continue }

        $theirs = $null
        if (-not [System.Version]::TryParse($otherParsed.Version, [ref]$theirs)) { continue }
        if ($theirs -gt $mine) { return $true }
    }
    return $false
}

#endregion

#region ----------------------------------------------------------------- plan

<#
    What retiring or removing the given applications would do, worked out
    before anything is touched so it can be shown and confirmed as a whole.
#>
function Get-RetirePlan {
    param(
        [Parameter(Mandatory = $true)]$Applications,
        [ValidateSet('Retire', 'Remove')][string]$Level = 'Retire',
        $Config = (Get-ActiveConfig)
    )

    # Collections named after the application belong to it - the inventory
    # already worked out which of those exist. Everything else the application
    # happens to be deployed to, the catalog collection from globalDeployments
    # above all, keeps its deployment removed and itself intact.
    $plan = @()
    foreach ($application in $Applications) {
        $owned = @($application.OwnedCollections)
        $foreignCollections = @($application.Collections | Where-Object { $_ -notin $owned })

        # The package folder and the Apps.csv row of this version: the folder
        # by the convention "<Name> - <Version>", else the folder whose content
        # location the application points at; the row by name and version.
        $packageRoot = Join-Path (Get-PackageWorkRoot -Config $Config) $application.AppName
        if (-not (Test-Path -LiteralPath $packageRoot)) { $packageRoot = $null }
        $identity = Split-AppFolderName -FolderName $application.AppName
        $definition = $null
        if ($identity.Version -and (Test-AppListRow -Name $identity.Name -Version $identity.Version)) { $definition = $identity }

        $plan += [pscustomobject]@{
            AppName             = $application.AppName
            Origin              = $application.Origin
            RemoveDeployments   = @($application.Collections)
            DeleteCollections   = $(if ($Level -eq 'Remove') { $owned } else { @() })
            KeepCollections     = $foreignCollections
            DissolveSupersedence = $(if ($Level -eq 'Remove') { @($application.SupersededBy) } else { @() })
            RevokeContent       = ($Level -eq 'Remove')
            DeleteApplication   = ($Level -eq 'Remove')
            DeletePackageFolder = $(if ($Level -eq 'Remove') { $packageRoot } else { $null })
            DeleteDefinition    = $(if ($Level -eq 'Remove') { $definition } else { $null })
        }
    }

    return $plan
}

<#
    The plan as text, one block per application - this is what the user reads
    before saying yes, so it names every object by name and says explicitly
    what is being left alone.
#>
function Format-RetirePlan {
    param([Parameter(Mandatory = $true)]$Plan, [string]$Level = 'Retire')

    $lines = @()
    foreach ($entry in $Plan) {
        $lines += ('{0}   [{1}]' -f $entry.AppName, $entry.Origin)

        if ($entry.RemoveDeployments.Count -gt 0) {
            foreach ($collection in $entry.RemoveDeployments) { $lines += "    remove deployment on   $collection" }
        }
        else { $lines += '    no deployments' }

        foreach ($collection in $entry.DeleteCollections)    { $lines += "    delete collection      $collection" }
        foreach ($collection in $entry.KeepCollections)      { $lines += "    keep collection        $collection   (not named after the application)" }
        foreach ($other in $entry.DissolveSupersedence)      { $lines += "    change application     $other   (stops superseding this one)" }

        if ($entry.RevokeContent)       { $lines += '    revoke content from the distribution points' }
        if ($entry.DeleteApplication)   { $lines += '    delete the application' }
        if ($entry.DeletePackageFolder) { $lines += "    delete folder          $($entry.DeletePackageFolder)" }
        if ($entry.DeleteDefinition)    { $lines += "    delete Apps.csv row    $($entry.DeleteDefinition.Name) - $($entry.DeleteDefinition.Version)" }
        if ($entry.Origin -eq 'foreign') { $lines += '    NOTE: this application was not published by this tool' }

        $lines += ''
    }

    if ($Level -eq 'Retire') { $lines += 'The applications, their collections, their content, their supersedence, the package folders and the Apps.csv rows all stay.' }
    else { $lines += 'Remove takes the version out of the site, off the share and out of Apps.csv.' }

    return ($lines -join [Environment]::NewLine)
}

#endregion

#region -------------------------------------------------------------- execute

function Invoke-RetirePlan {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $Config = (Get-ActiveConfig)
    )

    Invoke-InCMSite -Config $Config -ScriptBlock {
        foreach ($entry in $Plan) {
            Write-Step $entry.AppName

            # 1. Deployments first - an application with one cannot be deleted.
            foreach ($collection in $entry.RemoveDeployments) {
                try {
                    $null = Remove-CMApplicationDeployment -Name $entry.AppName -CollectionName $collection -Force -ErrorAction Stop
                    Write-Ok "Deployment removed: $collection"
                }
                catch { Write-Fail ("Deployment on [{0}]: {1}" -f $collection, $_.Exception.Message) }
            }

            # 2. Newer versions have to stop superseding it - not because
            #    ConfigMgr refuses the deletion otherwise, it does not, but
            #    because it would leave them pointing at something that is gone.
            #
            #    Remove-CMDeploymentTypeSupersedence warns that it is deprecated
            #    and points at Set-CMApplicationSupersedence -RemoveSupersedence.
            #    Do not follow that advice: the replacement answers "object
            #    reference not set to an instance of an object" in both its
            #    parameter sets, by name and by object, while the deprecated
            #    cmdlet does the job. The warning is suppressed rather than the
            #    call changed.
            $stranded = @()
            foreach ($other in $entry.DissolveSupersedence) {
                try {
                    $newDt = Get-CMDeploymentType -ApplicationName $other -ErrorAction Stop | Select-Object -First 1
                    $oldDt = Get-CMDeploymentType -ApplicationName $entry.AppName -ErrorAction Stop | Select-Object -First 1
                    $null = Remove-CMDeploymentTypeSupersedence -SupersedingDeploymentType $newDt `
                                -SupersededDeploymentType $oldDt -Force `
                                -ErrorAction Stop -WarningAction SilentlyContinue
                    Write-Ok "Supersedence dissolved: $other"
                }
                catch {
                    $stranded += $other
                    Write-Fail ("Supersedence on [{0}]: {1}" -f $other, $_.Exception.Message)
                }
            }

            # 3. Content, then the collections that belong to the application.
            #    Remove-CMContentDistribution insists on being told where from.
            if ($entry.RevokeContent) {
                $contentParams = @{ ApplicationName = $entry.AppName; Force = $true; ErrorAction = 'Stop' }
                if ($Config.distributionPointGroupName) { $contentParams['DistributionPointGroupName'] = $Config.distributionPointGroupName }
                elseif ($Config.distributionPointName)  { $contentParams['DistributionPointName']      = $Config.distributionPointName }

                try {
                    $null = Remove-CMContentDistribution @contentParams
                    Write-Ok 'Content revoked.'
                }
                catch { Write-Info ("Content: {0}" -f $_.Exception.Message) }
            }

            foreach ($collection in $entry.DeleteCollections) {
                try {
                    $null = Remove-CMDeviceCollection -Name $collection -Force -ErrorAction Stop
                    Write-Ok "Collection deleted: $collection"
                }
                catch { Write-Fail ("Collection [{0}]: {1}" -f $collection, $_.Exception.Message) }
            }

            # 4. The application last, so a failure above leaves something to
            #    retry - and only if nothing is still pointing at it. ConfigMgr
            #    does not enforce this: it will happily delete an application
            #    that four others supersede and leave them referencing something
            #    that no longer exists, which no cmdlet can then clean up,
            #    because removing a supersedence needs the deployment type that
            #    has just been deleted.
            if ($entry.DeleteApplication -and $stranded.Count -gt 0) {
                Write-Fail ("Not deleting [{0}]: {1} application(s) still supersede it and could not be dissolved - they would be left pointing at nothing. Fix the supersedence in the console first." -f
                    $entry.AppName, $stranded.Count)
            }
            $applicationDeleted = $false
            if ($entry.DeleteApplication -and $stranded.Count -eq 0) {
                try {
                    $null = Remove-CMApplication -Name $entry.AppName -Force -ErrorAction Stop
                    $applicationDeleted = $true
                    Write-Ok 'Application deleted.'
                }
                catch { Write-Fail ("Application: {0}" -f $_.Exception.Message) }
            }

            # The source stays as long as the application does - otherwise the
            # content location points at a folder that is no longer there.
            if ($entry.DeletePackageFolder -and -not $applicationDeleted) {
                Write-Info "Keeping the package folder - the application is still in the site."
            }
            elseif ($entry.DeletePackageFolder) {
                try {
                    Remove-Item -LiteralPath $entry.DeletePackageFolder -Recurse -Force -ErrorAction Stop
                    Write-Ok "Folder deleted: $($entry.DeletePackageFolder)"
                }
                catch { Write-Fail ("Folder: {0}" -f $_.Exception.Message) }
            }

            # The row goes last, and only once the application is gone - a row
            # without an application is "ready to publish", which would bring
            # the version straight back.
            if ($entry.DeleteDefinition -and $applicationDeleted) {
                Remove-AppListRow -Name $entry.DeleteDefinition.Name -Version $entry.DeleteDefinition.Version
            }
            elseif ($entry.DeleteDefinition) {
                Write-Info 'Keeping the Apps.csv row - the application is still in the site.'
            }
        }
    }
}

#endregion

#region ------------------------------------------------------------- workflow

<#
    Retire applications: pick them from the site, read what would happen, and
    only then decide. The filter is the everyday case - versions that have been
    replaced by a newer one.
#>
function retireApps {
    $config = Get-ActiveConfig

    Write-Step 'Reading the applications from the site'
    $inventory = Get-CMApplicationInventory -Config $config
    if (@($inventory).Count -eq 0) {
        $null = Show-MessageDialog -Text 'The site holds no applications.' -Caption 'Retire' -Buttons 'OK' -Icon 'Information'
        return
    }

    foreach ($application in $inventory) {
        Add-Member -InputObject $application -NotePropertyName 'HasNewer' `
            -NotePropertyValue (Test-HasNewerVersion -Application $application -Inventory $inventory) -Force
    }

    $choice = Show-RetireDialog -Inventory $inventory
    if (-not $choice) { Write-Info 'Cancelled.'; return }

    $plan = Get-RetirePlan -Applications $choice.Applications -Level $choice.Level -Config $config

    $answer = Show-MessageDialog -Text ("{0} {1} application(s):`n`n{2}" -f $choice.Level, @($plan).Count, (Format-RetirePlan -Plan $plan -Level $choice.Level)) `
                -Caption "$($choice.Level) applications" -Buttons 'YesNo' -Icon 'Warning'
    if ($answer -ne 'Yes') { Write-Info 'Cancelled.'; return }

    # Dissolving a supersedence changes an application the user did not pick,
    # so it is asked for separately rather than buried in the list above.
    $foreign = @($plan | ForEach-Object { $_.DissolveSupersedence } | Where-Object { $_ } | Sort-Object -Unique)
    if ($foreign.Count -gt 0) {
        $answer = Show-MessageDialog -Text ("These {0} application(s) are not in your selection and will be changed, because they supersede what you are removing:`n`n{1}`n`nProceed?" -f
                        $foreign.Count, ($foreign -join [Environment]::NewLine)) `
                    -Caption 'Other applications will be changed' -Buttons 'YesNo' -Icon 'Warning'
        if ($answer -ne 'Yes') { Write-Info 'Cancelled.'; return }
    }

    Invoke-RetirePlan -Plan $plan -Config $config
    Write-Ok 'Done.'
}

#endregion
