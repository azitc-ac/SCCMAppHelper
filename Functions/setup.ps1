<#
    SCCMAppHelper - discovery and first run setup

    Reads as much as possible from the ConfigMgr site itself instead of asking
    the user to fill in config.json by hand. Everything here assumes the current
    user may talk to the SMS provider (and, for the SQL details, read the site
    server registry).
#>

#region ------------------------------------------------------------ discovery

function Get-LocalServerName {
    try   { return ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName }
    catch { return $env:COMPUTERNAME }
}

function Test-DnsName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    try   { $null = [System.Net.Dns]::GetHostEntry($Name); return $true }
    catch { return $false }
}

function Test-IsLocalComputer {
    param([string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $true }
    if ($ComputerName -in @('.', 'localhost', '127.0.0.1', $env:COMPUTERNAME)) { return $true }
    return ($ComputerName -eq (Get-LocalServerName))
}

<#
    The SMS provider knows its own site code and provider machine - that is the
    one thing every other lookup can be derived from.
#>
function Get-CMProviderInfo {
    param([string]$ComputerName)

    $target = if (Test-IsLocalComputer -ComputerName $ComputerName) { Get-LocalServerName } else { $ComputerName }

    $params = @{ Namespace = 'root\SMS'; ClassName = 'SMS_ProviderLocation'; ErrorAction = 'Stop' }
    if (-not (Test-IsLocalComputer -ComputerName $ComputerName)) { $params['ComputerName'] = $ComputerName }

    try { $locations = @(Get-CimInstance @params) }
    catch {
        throw ("No SMS provider on [{0}]: {1}. Is this a ConfigMgr site server or SMS provider, and may the current user query it?" -f $target, $_.Exception.Message)
    }

    if ($locations.Count -eq 0) { throw "No SMS provider found on [$target]." }

    $provider = $locations | Where-Object { $_.ProviderForLocalSite } | Select-Object -First 1
    if (-not $provider) { $provider = $locations[0] }

    return [pscustomobject]@{
        SiteCode        = $provider.SiteCode
        ProviderMachine = $provider.Machine
    }
}

<#
    SQL server and database of the site, read from the site server registry.
    Falls back to the provider machine and CM_<SiteCode>.
#>
function Get-CMSqlInfo {
    param(
        [string]$ComputerName,
        [string]$SiteCode
    )

    $server   = $null
    $database = $null

    try {
        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
            $server   = $key.Server
            $database = $key.'Database Name'
        }
        else {
            $hive = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $ComputerName)
            try {
                $subKey = $hive.OpenSubKey('SOFTWARE\Microsoft\SMS\SQL Server')
                if ($subKey) {
                    $server   = $subKey.GetValue('Server')
                    $database = $subKey.GetValue('Database Name')
                    $subKey.Close()
                }
            }
            finally { $hive.Close() }
        }
    }
    catch {
        Write-Info ("SQL details could not be read from the registry ({0}) - using defaults." -f $_.Exception.Message)
    }

    if ([string]::IsNullOrWhiteSpace($server))   { $server = $ComputerName }
    if ([string]::IsNullOrWhiteSpace($database)) { $database = "CM_$SiteCode" }

    # A named instance is stored as "INSTANCE\CM_ABC".
    if ($database -match '\\') {
        $parts = $database -split '\\', 2
        if ($server -notmatch '\\') { $server = "$server\$($parts[0])" }
        $database = $parts[1]
    }

    return [pscustomobject]@{ SqlServer = $server; Database = $database }
}

<#
    Non-administrative file shares of the site server, including the local path
    behind each share - that gives sourceRoot and sourceRootLocal in one go.
#>
function Get-ServerShare {
    param([string]$ComputerName)

    $serverName = if (Test-IsLocalComputer -ComputerName $ComputerName) { Get-LocalServerName } else { $ComputerName }

    $params = @{ ClassName = 'Win32_Share'; ErrorAction = 'Stop' }
    if (-not (Test-IsLocalComputer -ComputerName $ComputerName)) { $params['ComputerName'] = $ComputerName }

    $shares = Get-CimInstance @params | Where-Object { $_.Type -eq 0 -and $_.Name -notlike '*$' }

    $results = @()
    foreach ($share in $shares) {
        $unc = '\\{0}\{1}' -f $serverName, $share.Name
        $results += [pscustomobject]@{
            UncPath   = $unc
            LocalPath = $share.Path
            Comment   = $share.Description
        }

        # First level below the share, so "\\srv\Sources\Applications" can be
        # picked directly instead of typed.
        try {
            $children = Get-ChildItem -LiteralPath $unc -Directory -ErrorAction Stop | Select-Object -First 25
            foreach ($child in $children) {
                $results += [pscustomobject]@{
                    UncPath   = (Join-Path $unc $child.Name)
                    LocalPath = (Join-Path $share.Path $child.Name)
                    Comment   = ''
                }
            }
        }
        catch { }
    }

    return $results
}

<#
    Distribution points and distribution point groups of the site, as one list
    to choose from. Must run inside the site drive.
#>
function Get-CMDistributionTarget {
    $targets = @()

    try {
        foreach ($dp in (Get-CMDistributionPoint -ErrorAction Stop)) {
            $targets += [pscustomobject]@{
                Type = 'DistributionPoint'
                Name = ($dp.NetworkOSPath -replace '^\\\\', '')
            }
        }
    }
    catch { Write-Info ("Distribution points could not be read: {0}" -f $_.Exception.Message) }

    try {
        foreach ($group in (Get-CMDistributionPointGroup -ErrorAction Stop)) {
            $targets += [pscustomobject]@{ Type = 'DistributionPointGroup'; Name = $group.Name }
        }
    }
    catch { }

    return $targets
}

function Get-CMDefaultLimitingCollection {
    # SMS00001 is "All Systems" on every site, whatever it is named locally.
    try {
        $collection = Get-CMDeviceCollection -CollectionId 'SMS00001' -ErrorAction Stop
        if ($collection) { return $collection.Name }
    }
    catch { }
    return 'All Systems'
}

#endregion

#region --------------------------------------------------------------- wizard

<#
    Guided first run: asks for the server (prefilled with this machine), reads
    everything else from the site and writes a new entry into the sites array of
    config.json.
#>
function Start-SetupWizard {
    param([string]$ConfigPath = (Join-Path $rootDir 'Config\config.json'))

    Write-Step 'Setup assistant'

    # --- 1) which server ------------------------------------------------------
    $localName = Get-LocalServerName
    $answer = Open-EditDialog -title 'ConfigMgr site - step 1 of 4: server' -PropertyOrder @('SiteServer') -item ([ordered]@{
        SiteServer = $localName
    })
    $answer = $answer | Where-Object { $_ -isnot [int] }
    if (-not $answer) { Write-Warn 'Setup cancelled.'; return $null }

    $server = [string]$answer['SiteServer']
    if ([string]::IsNullOrWhiteSpace($server)) { $server = $localName }
    if (Test-IsLocalComputer -ComputerName $server) {
        $server = $localName
        Write-Info "Running on the site server itself - using [$server]."
    }

    # --- 2) discovery ---------------------------------------------------------
    Write-Step "Querying [$server]"

    $provider = Get-CMProviderInfo -ComputerName $server
    Write-Ok "Site code [$($provider.SiteCode)], provider [$($provider.ProviderMachine)]"

    $sql = Get-CMSqlInfo -ComputerName $provider.ProviderMachine -SiteCode $provider.SiteCode
    Write-Ok "SQL server [$($sql.SqlServer)], database [$($sql.Database)]"

    $site = [ordered]@{
        name                       = "$($provider.SiteCode) ($($provider.ProviderMachine))"
        siteCode                   = $provider.SiteCode
        siteServer                 = $provider.ProviderMachine
        sqlServer                  = $sql.SqlServer
        database                   = $sql.Database
        sourceRoot                 = ''
        sourceRootLocal            = ''
        distributionPointName      = ''
        distributionPointGroupName = ''
        limitingCollectionName     = 'All Systems'
        applicationFolderPath      = ''
        collectionFolderPath       = ''
    }

    # --- 3) package share -----------------------------------------------------
    Write-Step 'Reading file shares'
    $shares = @()
    try { $shares = @(Get-ServerShare -ComputerName $provider.ProviderMachine) }
    catch { Write-Warn ("File shares could not be read: {0}" -f $_.Exception.Message) }

    $picked = $null
    if ($shares.Count -gt 0) {
        $picked = Open-SelectDialog -data $shares -title 'Step 2 of 4: where do the application packages live?' -large
        if ($null -ne $picked) { $picked = $picked | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
    }

    if ($picked) {
        $site.sourceRoot      = $picked.UncPath
        $site.sourceRootLocal = if (Test-IsLocalComputer -ComputerName $server) { $picked.LocalPath } else { '' }
        Write-Ok "Package share: $($picked.UncPath)"
    }
    else {
        # No share yet (typical on a fresh lab server) or nothing selected -
        # ask for the paths instead of leaving the wizard in a dead end.
        Write-Warn 'No package share picked - asking for the paths.'
        $shareAnswer = Open-EditDialog -title 'Step 2 of 4: package share (none found - please enter)' -PropertyOrder @('SourceRoot', 'SourceRootLocal') -item ([ordered]@{
            SourceRoot      = ('\\{0}\Sources\Applications' -f $provider.ProviderMachine)
            SourceRootLocal = if (Test-IsLocalComputer -ComputerName $server) { 'C:\Sources\Applications' } else { '' }
        })
        $shareAnswer = $shareAnswer | Where-Object { $_ -isnot [int] }
        if ($shareAnswer) {
            $site.sourceRoot      = [string]$shareAnswer['SourceRoot']
            $site.sourceRootLocal = [string]$shareAnswer['SourceRootLocal']
        }

        # Creating the folder is safe; creating and permissioning the SMB share
        # is an environment decision and stays with the admin.
        $localPath = $site.sourceRootLocal
        if ($localPath -and (Test-IsLocalComputer -ComputerName $server) -and -not (Test-Path -LiteralPath $localPath)) {
            $answer = [System.Windows.MessageBox]::Show(
                "The folder`n`n$localPath`n`ndoes not exist. Create it now?`n`nThe SMB share itself still has to be created manually - the site server computer account needs read access to it.",
                'SCCMAppHelper', 'YesNo', 'Question')
            if ($answer -eq 'Yes') {
                $null = New-Item -ItemType Directory -Path $localPath -Force
                Write-Ok "Created: $localPath"
            }
        }
    }

    # --- 4) site drive, distribution target, limiting collection --------------
    # Without the console module this step is skipped - the site is still saved
    # with everything discovered so far.
    $probeConfig = [pscustomobject]@{ siteCode = $site.siteCode; siteServer = $site.siteServer }
    try {
        Invoke-InCMSite -Config $probeConfig -ScriptBlock {
            Write-Step 'Reading distribution points and collections'

            $targets = @(Get-CMDistributionTarget)
            if ($targets.Count -gt 0) {
                $target = Open-SelectDialog -data $targets -title 'Step 3 of 4: distribute content to?'
                if ($null -ne $target) { $target = $target | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
                if ($target) {
                    if ($target.Type -eq 'DistributionPointGroup') { $site.distributionPointGroupName = $target.Name }
                    else { $site.distributionPointName = $target.Name }
                    Write-Ok "Distribution target: $($target.Name) [$($target.Type)]"
                }
            }

            $site.limitingCollectionName = Get-CMDefaultLimitingCollection
            Write-Ok "Limiting collection: $($site.limitingCollectionName)"
        }
    }
    catch { Write-Warn ("Site drive not available ({0}) - distribution point and limiting collection stay at their defaults." -f $_.Exception.Message) }

    # --- 5) confirm and save --------------------------------------------------
    $confirmed = Open-EditDialog -title 'Step 4 of 4: check and save' -PropertyOrder ([string[]]$site.Keys) -item $site
    $confirmed = $confirmed | Where-Object { $_ -isnot [int] }
    if (-not $confirmed) { Write-Warn 'Setup cancelled.'; return $null }

    $newSite = Save-SiteToConfig -Site ([pscustomobject]$confirmed) -ConfigPath $ConfigPath

    Test-SiteConfiguration -Config (Get-ActiveConfig) | Out-Null
    return $newSite
}

<#
    Writes a site into the sites array of config.json - replacing an entry with
    the same site code - and makes it the active one.
#>
function Save-SiteToConfig {
    param(
        [Parameter(Mandatory = $true)]$Site,
        [string]$ConfigPath = (Join-Path $rootDir 'Config\config.json')
    )

    $config = Get-AppHelperConfig -Path $ConfigPath

    $existing = @()
    if ($config.PSObject.Properties.Name -contains 'sites' -and $config.sites) {
        $existing = @($config.sites) | Where-Object { $_.siteCode -ne $Site.siteCode }
    }

    $config | Add-Member -MemberType NoteProperty -Name 'sites' -Value (@($existing) + $Site) -Force
    $config | Add-Member -MemberType NoteProperty -Name 'activeSite' -Value $Site.name -Force
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

    $global:SCCMAppHelperSite = $Site.name
    Write-Ok "Saved to $ConfigPath"

    return $Site
}

<#
    Checks a configured site end to end and prints a report - also useful after
    changing config.json by hand.
#>
function Test-SiteConfiguration {
    param($Config = (Get-ActiveConfig))

    Write-Step "Checking site [$($Config.siteName)]"

    # An ArrayList, because the checks below also run inside a script block -
    # assigning to a plain variable there would only hit the child scope.
    $issues = New-Object System.Collections.ArrayList

    # provider
    try {
        $provider = Get-CMProviderInfo -ComputerName $Config.siteServer
        if ($provider.SiteCode -eq $Config.siteCode) { Write-Ok "Provider reachable, site code [$($provider.SiteCode)]" }
        else {
            Write-Warn "Provider reports site code [$($provider.SiteCode)], configured is [$($Config.siteCode)]"
            $null = $issues.Add('site code mismatch')
        }
    }
    catch {
        Write-Fail ("Provider not reachable: {0}" -f $_.Exception.Message)
        $null = $issues.Add('provider')
    }

    # package share
    if ($Config.sourceRoot -and (Test-Path -LiteralPath $Config.sourceRoot)) { Write-Ok "Package share reachable: $($Config.sourceRoot)" }
    else {
        Write-Fail "Package share not reachable: $($Config.sourceRoot)"
        $null = $issues.Add('package share')
    }

    if ($Config.sourceRootLocal) {
        if (Test-Path -LiteralPath $Config.sourceRootLocal) { Write-Ok "Local package path reachable: $($Config.sourceRootLocal)" }
        else { Write-Info "Local package path not present here (fine when not running on the site server): $($Config.sourceRootLocal)" }
    }

    # console module
    try { $null = Get-CMModulePath; Write-Ok 'ConfigurationManager module found.' }
    catch { Write-Fail $_.Exception.Message; $null = $issues.Add('ConfigurationManager module') }

    # SQL
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = "Server=$($Config.sqlServer);Database=$($Config.database);Integrated Security=true;Connect Timeout=5"
        $connection.Open()
        $connection.Close()
        Write-Ok "SQL reachable: $($Config.sqlServer)/$($Config.database)"
    }
    catch { Write-Warn ("SQL not reachable ({0}) - only the outdated apps report needs it." -f $_.Exception.Message) }

    # collections and naming convention
    try {
        Invoke-InCMSite -Config $Config -ScriptBlock {
            if (Get-CMDeviceCollection -Name $Config.limitingCollectionName -ErrorAction SilentlyContinue) {
                Write-Ok "Limiting collection exists: $($Config.limitingCollectionName)"
            }
            else {
                Write-Fail "Limiting collection not found: $($Config.limitingCollectionName)"
                $null = $issues.Add('limiting collection')
            }

            foreach ($definition in $Config.collections) {
                $pattern = $definition.namePattern.Replace('{App}', '*')
                $count = @(Get-CMDeviceCollection -Name $pattern -ErrorAction SilentlyContinue).Count
                Write-Info "Collections matching [$pattern]: $count"
            }

            foreach ($deployment in $Config.globalDeployments) {
                if (Get-CMDeviceCollection -Name $deployment.collectionName -ErrorAction SilentlyContinue) {
                    Write-Ok "Global deployment collection exists: $($deployment.collectionName)"
                }
                else { Write-Warn "Global deployment collection missing: $($deployment.collectionName) - deployments to it will be skipped." }
            }
        }
    }
    catch {
        Write-Fail ("Collections could not be read: {0}" -f $_.Exception.Message)
        $null = $issues.Add('collections')
    }

    if ($issues.Count -eq 0) {
        Write-Ok 'Site configuration looks good.'
        return $true
    }

    Write-Warn ("Site configuration is incomplete: {0}" -f ($issues -join ', '))
    return $false
}

#endregion
