<#
    SCCMAppHelper - retiring an application version

    Two levels, because "stop deploying this" and "delete this" are different
    intentions and only one of them is reversible:

        Retire  removes the deployments. Application, deployment type,
                collections, content and supersedence all stay - nothing
                installs any more, and publishing again undoes it.

        Remove  does that and then takes the rest apart: supersedence
                references, content on the distribution points, the two
                per-application collections, and finally the application.

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

    $signature = [regex]::Escape((Get-ToolSignature))

    # The collections that belong to an application are the ones named after it,
    # not the ones it happens to be deployed to. Deriving them from deployments
    # misses every collection that has none - which is exactly the state a
    # Retire leaves behind, and the state createDeployments = false produces.
    $ownedPatterns = @($Config.collections | ForEach-Object { $_.namePattern })

    # The block returns its result rather than appending to a variable outside
    # it: a scriptblock run with & cannot assign to the caller's variables, it
    # only ever gets a copy. Mutating a hashtable works, "+=" does not.
    $inventory = Invoke-InCMSite -Config $Config -ScriptBlock {
        $rows = @()
        $applications = @(Get-CMApplication)

        # An application that supersedes another names it in its own package
        # XML, so one pass over everything gives the referrers of everything.
        $logicalNames = @{}
        foreach ($application in $applications) {
            $xml = [xml]$application.SDMPackageXML
            $node = $xml.SelectSingleNode('//*[local-name()="AppMgmtDigest"]/*[local-name()="Application"]')
            if ($node) { $logicalNames[$application.LocalizedDisplayName] = $node.LogicalName }
        }

        foreach ($application in $applications) {
            $displayName = $application.LocalizedDisplayName
            $logical     = $logicalNames[$displayName]

            $supersededBy = @()
            if ($logical) {
                foreach ($other in $applications) {
                    if ($other.LocalizedDisplayName -eq $displayName) { continue }
                    if ($other.SDMPackageXML -match [regex]::Escape($logical)) { $supersededBy += $other.LocalizedDisplayName }
                }
            }

            $deployments = @(Get-CMApplicationDeployment -Name $displayName -ErrorAction SilentlyContinue)

            $owned = @()
            foreach ($pattern in $ownedPatterns) {
                $collectionName = $pattern.Replace('{App}', $displayName)
                if (Get-CMDeviceCollection -Name $collectionName -ErrorAction SilentlyContinue) { $owned += $collectionName }
            }

            $rows += [pscustomobject]@{
                AppName          = $displayName
                Name             = $application.LocalizedDisplayName
                Version          = [string]$application.SoftwareVersion
                Deployments      = $deployments.Count
                Collections      = @($deployments | ForEach-Object { $_.CollectionName })
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
        [switch]$DeletePackageFolder,
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

        $packageRoot = Join-Path (Get-PackageWorkRoot -Config $Config) $application.AppName
        if (-not (Test-Path -LiteralPath $packageRoot)) { $packageRoot = $null }

        $plan += [pscustomobject]@{
            AppName             = $application.AppName
            Origin              = $application.Origin
            RemoveDeployments   = @($application.Collections)
            DeleteCollections   = $(if ($Level -eq 'Remove') { $owned } else { @() })
            KeepCollections     = $foreignCollections
            DissolveSupersedence = $(if ($Level -eq 'Remove') { @($application.SupersededBy) } else { @() })
            RevokeContent       = ($Level -eq 'Remove')
            DeleteApplication   = ($Level -eq 'Remove')
            DeletePackageFolder = $(if ($Level -eq 'Remove' -and $DeletePackageFolder) { $packageRoot } else { $null })
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
        if ($entry.Origin -eq 'foreign') { $lines += '    NOTE: this application was not published by this tool' }

        $lines += ''
    }

    if ($Level -eq 'Retire') { $lines += 'The applications, their collections, their content and their supersedence all stay.' }
    $lines += 'The Apps.csv rows are never touched.'

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

    $plan = Get-RetirePlan -Applications $choice.Applications -Level $choice.Level `
                -DeletePackageFolder:$choice.DeletePackageFolder -Config $config

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
