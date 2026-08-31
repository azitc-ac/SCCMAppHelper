<#
    SCCMAppHelper - application catalog

    Reads the manifests of https://github.com/microsoft/winget-pkgs directly
    over HTTPS. The winget client is deliberately not used: it is a per user
    MSIX and is missing on Windows Server 2022, while the manifests themselves
    are plain files anyone can read.

        catalog.json / search  ->  manifest  ->  download + SHA256  ->  Apps.csv row

    Nothing downloaded here is ever executed. The installer is fetched, its
    hash is checked against the manifest, and it is then read the same way the
    "From MSI..." button reads a file the user picked by hand.
#>

$script:CatalogRepository   = 'microsoft/winget-pkgs'
$script:CatalogBranch       = 'master'
$script:CatalogUserAgent    = 'SCCMAppHelper'
$script:CatalogRequestCache = @{}

#region ------------------------------------------------------------------ yaml

<#
    A YAML reader for the subset the winget manifests actually use: two space
    indentation, "key: value", nested maps, sequences of scalars and sequences
    of maps. No anchors, no flow collections, no multi line scalars - a manifest
    that needs those is rejected rather than silently misread.

    Written by hand on purpose: powershell-yaml is a PSGallery dependency, and
    on a site server PSGallery is exactly what tends not to work.
#>
function ConvertFrom-CatalogYaml {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*#')       { continue }   # comment
        if ($line -match '^\s*$')       { continue }   # blank
        if ($line -match '^\s*---\s*$') { continue }   # document marker
        $lines += ($line -replace '\s+$', '')
    }

    # A script scoped cursor rather than a [ref] parameter: a [ref] handed on
    # through a recursive call is not shared reliably, and the reader then loses
    # everything that follows a nested block - the last installer of a manifest,
    # the ProductCode after an InstallerSwitches map.
    $script:CatalogYamlLines = $lines
    $script:CatalogYamlIndex = 0

    return (Read-CatalogYamlMap -Indent 0)
}

function Get-CatalogYamlIndent {
    param([string]$Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

function ConvertFrom-CatalogYamlScalar {
    param([string]$Raw)

    $value = $Raw.Trim()
    if ($value.Length -ge 2) {
        if ($value.StartsWith("'") -and $value.EndsWith("'")) { return $value.Substring(1, $value.Length - 2).Replace("''", "'") }
        if ($value.StartsWith('"') -and $value.EndsWith('"')) { return $value.Substring(1, $value.Length - 2) }
    }
    return $value
}

function Read-CatalogYamlMap {
    param([int]$Indent)

    $map = [ordered]@{}

    while ($script:CatalogYamlIndex -lt $script:CatalogYamlLines.Count) {
        $line   = $script:CatalogYamlLines[$script:CatalogYamlIndex]
        $lineIndent = Get-CatalogYamlIndent -Line $line
        $text   = $line.Trim()

        if ($lineIndent -lt $Indent)    { break }   # belongs to an outer block
        if ($lineIndent -gt $Indent)    { break }   # handled by whoever opened it
        if ($text.StartsWith('- ')) { break }   # a sequence belongs to the key above
        if ($text -notmatch '^([^:]+):\s*(.*)$') { $script:CatalogYamlIndex++; continue }

        $key   = $Matches[1].Trim()
        $value = $Matches[2]
        $script:CatalogYamlIndex++

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $map[$key] = ConvertFrom-CatalogYamlScalar -Raw $value
            continue
        }

        # The value is whatever follows on the next lines.
        if ($script:CatalogYamlIndex -ge $script:CatalogYamlLines.Count) { $map[$key] = ''; continue }

        $nextLine   = $script:CatalogYamlLines[$script:CatalogYamlIndex]
        $nextIndent = Get-CatalogYamlIndent -Line $nextLine
        $nextText   = $nextLine.Trim()

        if ($nextText.StartsWith('- ') -and $nextIndent -ge $Indent) {
            $map[$key] = Read-CatalogYamlSequence -Indent $nextIndent
        }
        elseif ($nextIndent -gt $Indent) {
            $map[$key] = Read-CatalogYamlMap -Indent $nextIndent
        }
        else {
            $map[$key] = ''
        }
    }

    return $map
}

function Read-CatalogYamlSequence {
    param([int]$Indent)

    $list = @()

    while ($script:CatalogYamlIndex -lt $script:CatalogYamlLines.Count) {
        $line   = $script:CatalogYamlLines[$script:CatalogYamlIndex]
        $lineIndent = Get-CatalogYamlIndent -Line $line
        $text   = $line.Trim()

        if ($lineIndent -ne $Indent -or -not $text.StartsWith('- ')) { break }

        $rest = $text.Substring(2)
        $script:CatalogYamlIndex++

        if ($rest -notmatch '^([^:]+):\s*(.*)$') {
            $list += (ConvertFrom-CatalogYamlScalar -Raw $rest)
            continue
        }

        # A map item: the first pair sits on the dash line, the rest is indented
        # below it.
        $item  = [ordered]@{}
        $key   = $Matches[1].Trim()
        $value = $Matches[2]

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $item[$key] = ConvertFrom-CatalogYamlScalar -Raw $value
        }
        elseif ($script:CatalogYamlIndex -lt $script:CatalogYamlLines.Count) {
            $nextLine   = $script:CatalogYamlLines[$script:CatalogYamlIndex]
            $nextIndent = Get-CatalogYamlIndent -Line $nextLine
            if ($nextLine.Trim().StartsWith('- ') -and $nextIndent -ge ($Indent + 2)) {
                $item[$key] = Read-CatalogYamlSequence -Indent $nextIndent
            }
            elseif ($nextIndent -gt $Indent) {
                $item[$key] = Read-CatalogYamlMap -Indent $nextIndent
            }
            else { $item[$key] = '' }
        }
        else { $item[$key] = '' }

        # Everything else indented below the dash belongs to the same item.
        if ($script:CatalogYamlIndex -lt $script:CatalogYamlLines.Count) {
            $nextIndent = Get-CatalogYamlIndent -Line $script:CatalogYamlLines[$script:CatalogYamlIndex]
            if ($nextIndent -gt $Indent) {
                $rows = Read-CatalogYamlMap -Indent $nextIndent
                foreach ($rowKey in $rows.Keys) { $item[$rowKey] = $rows[$rowKey] }
            }
        }

        $list += , $item
    }

    return , $list
}
#endregion

#region ------------------------------------------------------------ repository

<#
    Windows PowerShell 5.1 still negotiates TLS 1.0 first and GitHub refuses
    that, so the protocol has to be raised before the first request. Every call
    also goes out with -UseBasicParsing - without it Invoke-WebRequest wants the
    Internet Explorer engine, which a freshly installed server does not have.
#>
function Initialize-CatalogSecurity {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }
}

function Invoke-CatalogRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [switch]$NoCache
    )

    Initialize-CatalogSecurity

    if (-not $NoCache -and $script:CatalogRequestCache.ContainsKey($Uri)) {
        return $script:CatalogRequestCache[$Uri]
    }

    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -ErrorAction Stop `
                        -Headers @{ 'User-Agent' = $script:CatalogUserAgent }
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }

        if ($status -eq 403) {
            throw "GitHub refused the request (403). The unauthenticated rate limit is 60 requests per hour - wait, or narrow the search. [$Uri]"
        }
        if ($status -eq 404) {
            throw "Not found in the manifest repository: $Uri"
        }
        throw ("Request to [{0}] failed: {1}" -f $Uri, $_.Exception.Message)
    }

    $script:CatalogRequestCache[$Uri] = $response.Content
    return $response.Content
}

<#
    manifests/<first character>/<identifier split at the dots>
    7zip.7zip -> manifests/7/7zip/7zip, Google.Chrome -> manifests/g/Google/Chrome
#>
function Get-CatalogManifestPath {
    param([Parameter(Mandatory = $true)][string]$PackageIdentifier)

    $first = $PackageIdentifier.Substring(0, 1).ToLowerInvariant()
    return ('manifests/{0}/{1}' -f $first, (($PackageIdentifier -split '\.') -join '/'))
}

<#
    A directory listing, in full.

    The contents API returns at most 100 entries a page and simply stops there -
    no error, no marker. `manifests/m` alone holds well over a thousand
    publishers, so a single request would silently describe a fraction of the
    tree and every search over it would quietly miss things.
#>
function Get-CatalogDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entries = @()
    $page    = 1

    while ($true) {
        $uri = 'https://api.github.com/repos/{0}/contents/{1}?ref={2}&per_page=100&page={3}' -f
                   $script:CatalogRepository, $Path, $script:CatalogBranch, $page
        $batch = @(Invoke-CatalogRequest -Uri $uri | ConvertFrom-Json)

        $entries += $batch
        if ($batch.Count -lt 100) { break }

        $page++
        if ($page -gt 50) {
            Write-Warn "Directory [$Path] has more than 5000 entries - the listing was cut short."
            break
        }
    }

    return $entries
}

<#
    Newest first. A version that does not parse as [version] - "19c" and the
    like - is sorted as text behind the ones that do, so it stays reachable
    without pretending to be comparable.
#>
function Sort-CatalogVersion {
    param([string[]]$Version)

    $parsed = foreach ($item in $Version) {
        $value = $null
        [pscustomobject]@{
            Text   = $item
            Parsed = $(if ([System.Version]::TryParse($item, [ref]$value)) { $value } else { $null })
        }
    }

    return @(
        @($parsed | Where-Object { $_.Parsed } | Sort-Object Parsed -Descending | Select-Object -ExpandProperty Text)
        @($parsed | Where-Object { -not $_.Parsed } | Sort-Object Text -Descending | Select-Object -ExpandProperty Text)
    )
}

function Get-CatalogPackageVersion {
    param([Parameter(Mandatory = $true)][string]$PackageIdentifier)

    $entries  = Get-CatalogDirectory -Path (Get-CatalogManifestPath -PackageIdentifier $PackageIdentifier)
    $versions = @($entries | Where-Object { $_.type -eq 'dir' } | Select-Object -ExpandProperty name)

    if ($versions.Count -eq 0) { throw "No versions found for [$PackageIdentifier]." }
    return (Sort-CatalogVersion -Version $versions)
}

<#
    The installer manifest of one version, plus the English locale manifest for
    the display name and the publisher.
#>
function Get-CatalogManifest {
    param(
        [Parameter(Mandatory = $true)][string]$PackageIdentifier,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $base = 'https://raw.githubusercontent.com/{0}/{1}/{2}/{3}/{4}' -f
                $script:CatalogRepository, $script:CatalogBranch,
                (Get-CatalogManifestPath -PackageIdentifier $PackageIdentifier),
                $Version, $PackageIdentifier

    $installer = ConvertFrom-CatalogYaml -Text (Invoke-CatalogRequest -Uri "$base.installer.yaml")

    $locale = $null
    foreach ($suffix in '.locale.en-US.yaml', '.yaml') {
        try { $locale = ConvertFrom-CatalogYaml -Text (Invoke-CatalogRequest -Uri "$base$suffix"); break }
        catch { }
    }

    $installers = @()
    if ($installer.Contains('Installers')) { $installers = @($installer['Installers']) }
    if ($installers.Count -eq 0) { throw "The manifest of [$PackageIdentifier $Version] lists no installers." }

    return [pscustomobject]@{
        PackageIdentifier = $PackageIdentifier
        PackageVersion    = $(if ($installer.Contains('PackageVersion')) { [string]$installer['PackageVersion'] } else { $Version })
        PackageName       = $(if ($locale -and $locale.Contains('PackageName')) { [string]$locale['PackageName'] } else { $PackageIdentifier })
        Publisher         = $(if ($locale -and $locale.Contains('Publisher'))   { [string]$locale['Publisher'] }   else { '' })
        Description       = $(if ($locale -and $locale.Contains('ShortDescription')) { [string]$locale['ShortDescription'] } else { '' })
        Installers        = $installers
        Root              = $installer
    }
}

<#
    Which of the installers a manifest offers to take. An MSI wins over an EXE:
    it carries a ProductCode, which means native detection and PSADT's
    zero-config MSI deployment, and it needs nothing maintained by hand.
#>
function Select-CatalogInstaller {
    param(
        [Parameter(Mandatory = $true)]$Installers,
        [string]$Architecture = 'x64',
        $Root
    )

    # A manifest may state InstallerType, InstallerSwitches, Scope and the rest
    # once at the top and let every installer inherit them - Visual Studio Code
    # does exactly that. Reading only the installer entry then leaves the type
    # blank, which throws off the ranking, and loses the silent switch, which is
    # what the install command is built from.
    if ($Root) {
        foreach ($entry in @($Installers)) {
            foreach ($key in 'InstallerType', 'InstallerSwitches', 'Scope', 'UpgradeBehavior', 'ProductCode', 'AppsAndFeaturesEntries') {
                if (-not $entry.Contains($key) -and $Root.Contains($key)) { $entry[$key] = $Root[$key] }
            }
        }
    }

    $typeRank = @{ 'wix' = 0; 'msi' = 1; 'burn' = 2; 'inno' = 3; 'nullsoft' = 4; 'exe' = 5; 'msix' = 6; 'appx' = 7; 'zip' = 9 }
    $archRank = @{ 'x64' = 0; 'neutral' = 1; 'x86' = 2; 'arm64' = 3; 'arm' = 4 }

    $rows = foreach ($entry in @($Installers)) {
        $type = [string]$entry['InstallerType']
        if (-not $type -and $entry.Contains('NestedInstallerType')) { $type = [string]$entry['NestedInstallerType'] }
        $arch = [string]$entry['Architecture']

        [pscustomobject]@{
            Architecture = $arch
            InstallerType = $type
            InstallerUrl  = [string]$entry['InstallerUrl']
            Sha256        = [string]$entry['InstallerSha256']
            Entry         = $entry
            ArchRank      = $(if ($archRank.ContainsKey($arch)) { $archRank[$arch] } else { 8 })
            TypeRank      = $(if ($typeRank.ContainsKey($type)) { $typeRank[$type] } else { 8 })
            Preferred     = $(if ($arch -eq $Architecture) { 0 } else { 1 })
        }
    }

    return @($rows | Sort-Object Preferred, TypeRank, ArchRank)
}

#endregion

#region -------------------------------------------------------------- download

<#
    Fetches one installer and checks it against the hash in the manifest. A file
    that does not match is deleted rather than kept - a mismatch means the bytes
    are not what the manifest describes, and there is no sensible way to carry
    on from there.
#>
function Save-CatalogInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Sha256
    )

    Initialize-CatalogSecurity

    if ($Url -notmatch '^https://') { throw "Refusing to download over anything but HTTPS: $Url" }
    if (-not (Test-Path -LiteralPath $Destination)) { $null = New-Item -ItemType Directory -Path $Destination -Force }

    $fileName = Split-Path -Leaf ([uri]$Url).LocalPath
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = 'installer.bin' }
    $target = Join-Path $Destination $fileName

    Write-Info "Downloading $Url"
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes this an order of magnitude slower
    try {
        Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing -ErrorAction Stop `
            -Headers @{ 'User-Agent' = $script:CatalogUserAgent }
    }
    finally { $ProgressPreference = $progress }

    $size = (Get-Item -LiteralPath $target).Length
    Write-Ok ("Downloaded {0} ({1:n1} MB)" -f $fileName, ($size / 1MB))

    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            throw "SHA256 mismatch - the download does not match the manifest and was deleted.`nexpected $($Sha256.ToUpperInvariant())`ngot      $actual"
        }
        Write-Ok 'SHA256 matches the manifest.'
    }
    else {
        Write-Warn 'The manifest carries no SHA256 - the download could not be verified.'
    }

    return $target
}

<#
    What the downloaded file says about itself. The signature is reported rather
    than enforced: plenty of legitimate installers are unsigned, and the
    decision belongs to the person looking at the dialog.
#>
function Get-CatalogInstallerEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)

    $signer = ''
    $status = ''
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $status = [string]$signature.Status
        if ($signature.SignerCertificate) { $signer = $signature.SignerCertificate.Subject }
    }
    catch { $status = 'unknown' }

    $isMsi = ([System.IO.Path]::GetExtension($Path) -eq '.msi')
    $properties = if ($isMsi) { Get-MsiProperties -Path $Path } else { Get-ExeProperties -Path $Path }

    return [pscustomobject]@{
        Path            = $Path
        IsMsi           = $isMsi
        ProductName     = [string]$properties['ProductName']
        ProductVersion  = [string]$properties['ProductVersion']
        Manufacturer    = [string]$properties['Manufacturer']
        ProductCode     = [string]$properties['ProductCode']
        SignatureStatus = $status
        Signer          = $signer
    }
}

#endregion

#region --------------------------------------------------------- the app record

<#
    Turns manifest plus downloaded file into an Apps.csv row.

    The file outranks the manifest wherever both know something: an MSI states
    its own ProductCode and ProductVersion, and those are what the client will
    actually register - which is what detection compares against.
#>
function ConvertTo-CatalogAppRow {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Installer,
        [Parameter(Mandatory = $true)]$Evidence
    )

    $entry = $Installer.Entry

    $name = $Manifest.PackageName
    if (-not $name) { $name = $Evidence.ProductName }

    $publisher = $Manifest.Publisher
    if (-not $publisher) { $publisher = $Evidence.Manufacturer }

    # An MSI states the version it is going to register, so it outranks the
    # catalog label - "26.02" in the manifest, 26.02.00.0 in the uninstall key.
    #
    # The version resource of an EXE installer describes the installer, not the
    # product, and is regularly malformed: the Notepad++ 8.9.8 installer reports
    # "8.98", which as a [version] sorts *above* 8.9.8 and would poison the
    # application name, the detection and the supersedence in one go. There the
    # manifest wins.
    $version = if ($Evidence.IsMsi -and $Evidence.ProductVersion) { $Evidence.ProductVersion }
               else { $Manifest.PackageVersion }
    if (-not $version) { $version = $Evidence.ProductVersion }

    $productCode = $Evidence.ProductCode
    if (-not $productCode) { $productCode = [string]$entry['ProductCode'] }

    # AppsAndFeaturesEntries is where a manifest records what the product looks
    # like in Programs and Features - the uninstall key of an EXE installer
    # included, which is exactly what the native registry detection needs.
    $appsEntry = $null
    if ($entry.Contains('AppsAndFeaturesEntries')) { $appsEntry = @($entry['AppsAndFeaturesEntries'])[0] }

    $detectionMethod  = 'Registry'
    $detectionPattern = ''

    if ($Evidence.IsMsi -and $productCode -match '^\{.+\}$') {
        $detectionMethod = 'MSI'
    }
    else {
        # An uninstall key, in order of trustworthiness.
        if ($appsEntry -and $appsEntry.Contains('ProductCode')) { $detectionPattern = [string]$appsEntry['ProductCode'] }
        elseif ($productCode)                                   { $detectionPattern = $productCode }
        elseif ($appsEntry -and $appsEntry.Contains('DisplayName')) { $detectionPattern = [string]$appsEntry['DisplayName'] }
        $productCode = ''
    }

    $switches = ''
    if ($entry.Contains('InstallerSwitches')) {
        $installerSwitches = $entry['InstallerSwitches']
        foreach ($key in 'Silent', 'SilentWithProgress') {
            if ($installerSwitches.Contains($key)) { $switches = [string]$installerSwitches[$key]; break }
        }
    }

    # A manifest only states a silent switch where the installer needs an unusual
    # one. For the common installer kinds it is a property of the kind, and
    # winget knows it rather than repeating it in every manifest - Inno Setup and
    # NSIS packages carry no switches at all. So the same defaults are applied
    # here, or the command would come out unable to install silently.
    if (-not $switches) {
        $switches = switch ($Installer.InstallerType) {
            'inno'     { '/VERYSILENT /NORESTART' }
            'nullsoft' { '/S' }
            'burn'     { '/quiet /norestart' }
            default    { '' }
        }
    }

    # An MSI package needs no commands at all - PSADT deploys the single MSI in
    # .\Files itself, and anything here would install it a second time. Anything
    # else does need them, and the manifest usually knows the silent switch, so
    # the row comes out ready to package instead of ready to fill in by hand.
    $installCommand   = ''
    $uninstallCommand = ''
    if ($detectionMethod -ne 'MSI') {
        $fileName = Split-Path -Leaf ([uri]$Installer.InstallerUrl).LocalPath
        $installCommand = if ($switches) {
            "Start-ADTProcess -FilePath '$fileName' -ArgumentList '$switches'"
        }
        else {
            "Start-ADTProcess -FilePath '$fileName'   # no silent switch in the manifest - check it"
        }

        # An uninstall string is only guessable from the ProductCode, which a
        # non-MSI installer usually does not have.
        if ($productCode -match '^\{.+\}$') {
            $uninstallCommand = "Start-ADTMsiProcess -Action 'Uninstall' -ProductCode '$productCode'"
        }
    }

    return [pscustomobject]@{
        Publisher        = $publisher
        Name             = $name
        Version          = $version
        DetectionMethod  = $detectionMethod
        DetectionPattern = $detectionPattern
        ProductCode      = $productCode
        InstallCmd       = $installCommand
        UninstallCmd     = $uninstallCommand
        Notes            = ('{0} {1} from winget-pkgs ({2}, {3}){4}' -f
                                $Manifest.PackageIdentifier, $Manifest.PackageVersion,
                                $Installer.Architecture, $Installer.InstallerType,
                                $(if ($switches) { ", silent switch $switches" } else { '' }))
    }
}

#endregion

#region ------------------------------------------------------------- the search

<#
    Appends a package to catalog.json, so the list grows with use.

    The repository cannot be searched by product name - it is keyed by publisher,
    and building an index of it does not hold up: the tree API answers
    intermittently and, when it does answer, comes back incomplete without
    setting its own truncated flag (373 publisher/package pairs for a letter
    holding 562 publishers). So the curated list is the searchable part, and
    anything found the hard way once should not have to be found that way again.
#>
function Add-CatalogEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [string]$Path = (Join-Path $rootDir 'Config\catalog.json')
    )

    $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (@($catalog.packages | Where-Object { $_.packageId -eq $PackageId }).Count -gt 0) {
        Write-Info "Already in the catalog: $PackageId"
        return $false
    }

    $entries = @($catalog.packages) + [pscustomobject]@{ name = $Name; packageId = $PackageId }

    # Written by hand rather than with ConvertTo-Json: this file is meant to be
    # edited by hand, and ConvertTo-Json escapes every apostrophe and angle
    # bracket into ' and > and puts each property on its own line.
    $width = 3 + ($entries | ForEach-Object { [string]$_.name } | Measure-Object -Property Length -Maximum).Maximum
    $lines = foreach ($entry in $entries) {
        $label = ('"' + $entry.name + '",').PadRight($width)
        '        { "name": ' + $label + ' "packageId": "' + $entry.packageId + '" }'
    }

    $json = '{' + [Environment]::NewLine +
            ('    "comment": "{0}",' -f $catalog.comment) + [Environment]::NewLine +
            '    "packages": [' + [Environment]::NewLine +
            (($lines -join (',' + [Environment]::NewLine))) + [Environment]::NewLine +
            '    ]' + [Environment]::NewLine + '}' + [Environment]::NewLine

    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    Write-Ok "Added to the catalog: $Name ($PackageId)"
    return $true
}

function Get-CatalogList {
    param([string]$Path = (Join-Path $rootDir 'Config\catalog.json'))

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try   { return @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).packages) }
    catch { Write-Warn ("catalog.json could not be read: {0}" -f $_.Exception.Message); return @() }
}

<#
    Searches the manifest repository by walking its folders.

    Know what this can and cannot do. The repository is organised by
    **publisher**: `manifests/<first character of the identifier>/<Publisher>/<Package>`.
    So a query is matched against publishers first, and only their packages are
    looked at. Searching for a product whose vendor is named differently does
    not work - "filezilla" never finds it, because the identifier starts with
    the vendor. Paste the full package id (it contains a dot) and it is resolved
    directly instead.

    Walking the whole tree is not an option: unauthenticated GitHub allows 60
    requests an hour and there are tens of thousands of publishers.
#>
function Find-CatalogPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$MaxPublishers = 8
    )

    $query = $Query.Trim()
    if ($query.Length -lt 2) { throw 'Please search for at least two characters.' }

    # A full package id needs no searching.
    if ($query -match '^[^\s]+\.[^\s]+$') {
        $null = Get-CatalogPackageVersion -PackageIdentifier $query
        return @([pscustomobject]@{ Name = ($query -split '\.')[-1]; PackageId = $query; Description = '' })
    }

    $letter     = $query.Substring(0, 1).ToLowerInvariant()
    $publishers = @(Get-CatalogDirectory -Path ('manifests/{0}' -f $letter) |
                        Where-Object { $_.type -eq 'dir' })

    $matching = @($publishers | Where-Object { $_.name -like "*$query*" })

    # "7zip" is both the publisher and the package; "google" is only the
    # publisher. Walk into the matching publishers, and if the query matched no
    # publisher at all, walk into the first few and look at their packages.
    $walk = if ($matching.Count -gt 0) { $matching } else { @($publishers | Select-Object -First $MaxPublishers) }
    if ($walk.Count -gt $MaxPublishers) { $walk = @($walk | Select-Object -First $MaxPublishers) }

    $results = @()
    foreach ($publisher in $walk) {
        foreach ($package in (Get-CatalogDirectory -Path $publisher.path | Where-Object { $_.type -eq 'dir' })) {
            $identifier = '{0}.{1}' -f $publisher.name, $package.name
            if ($identifier -notlike "*$query*") { continue }
            $results += [pscustomobject]@{
                Name        = $package.name
                PackageId   = $identifier
                Description = ''
            }
        }
    }

    return @($results | Sort-Object PackageId)
}

#endregion

#region ----------------------------------------------------------- the workflow

<#
    Everything from picking a package to a finished Apps.csv record: resolve the
    newest version, confirm, download, check the hash against the manifest and
    read what the installer says about itself.

    Nothing is written here. The record is handed back and the record editor
    fills its fields with it, exactly as "From MSI..." and "From EXE..." do -
    the catalog is a third source for the same record, not a workflow of its
    own. Returns $null when the user backs out at any point.
#>
function Read-CatalogPackage {
    param($Config = (Get-ActiveConfig))

    $selection = Show-CatalogDialog -Packages (Get-CatalogList)
    if (-not $selection) { Write-Info 'Cancelled.'; return $null }

    Write-Step "Catalog: $($selection.PackageId)"

    $latest = (Get-CatalogPackageVersion -PackageIdentifier $selection.PackageId)[0]
    Write-Ok "Newest version in the repository: $latest"

    # Get-AppListRow wants a version; here every version of the product is
    # interesting, so the list is read directly.
    $csvPath = Join-Path $rootDir 'Apps.csv'
    Update-AppListSchema -CsvPath $csvPath
    $known = @(Import-Csv -LiteralPath $csvPath -Delimiter ';' | Where-Object { $_.Name.Trim() -eq $selection.Name.Trim() })
    if ($known.Count -gt 0) {
        Write-Info ("Already in the app list: {0}" -f (($known | ForEach-Object { $_.Version }) -join ', '))
    }

    $manifest   = Get-CatalogManifest -PackageIdentifier $selection.PackageId -Version $latest
    $installers = Select-CatalogInstaller -Installers $manifest.Installers -Root $manifest.Root
    $installer  = $installers[0]

    if ($installers.Count -gt 1) {
        $picked = Open-SelectDialog -title 'Which installer?' -data (
            $installers | Select-Object Architecture, InstallerType, InstallerUrl, Sha256)
        if ($null -ne $picked) { $picked = $picked | Where-Object { $_ -isnot [int] } | Select-Object -First 1 }
        if (-not $picked) { Write-Info 'Cancelled.'; return $null }
        $installer = $installers | Where-Object { $_.InstallerUrl -eq $picked.InstallerUrl } | Select-Object -First 1
    }

    $downloadRoot = Join-Path (Get-PackageWorkRoot -Config $Config) ('_DL\{0} - {1}' -f $manifest.PackageName, $manifest.PackageVersion)

    $answer = Show-MessageDialog -Text ("Download this installer?`n`n{0} {1}`n{2} / {3}`n`n{4}`n`nSHA256 {5}`n`nInto:`n{6}" -f
                    $manifest.PackageName, $manifest.PackageVersion,
                    $installer.Architecture, $installer.InstallerType,
                    $installer.InstallerUrl, $installer.Sha256, $downloadRoot) `
                -Caption 'From catalog' -Buttons 'YesNo' -Icon 'Question'
    if ($answer -ne 'Yes') { Write-Info 'Cancelled - nothing was downloaded.'; return $null }

    $file     = Save-CatalogInstaller -Url $installer.InstallerUrl -Destination $downloadRoot -Sha256 $installer.Sha256
    $evidence = Get-CatalogInstallerEvidence -Path $file

    Write-Info ("Signature: {0}{1}" -f $evidence.SignatureStatus, $(if ($evidence.Signer) { " - $($evidence.Signer)" } else { '' }))
    if ($evidence.SignatureStatus -ne 'Valid') {
        Write-Warn 'The installer carries no valid Authenticode signature - check where it came from before deploying it.'
    }

    $row = ConvertTo-CatalogAppRow -Manifest $manifest -Installer $installer -Evidence $evidence
    Write-Ok ("Read from the installer: {0} {1} [{2}]" -f $row.Name, $row.Version, $row.DetectionMethod)

    if ($row.DetectionMethod -eq 'Registry' -and -not $row.DetectionPattern) {
        Write-Warn 'No uninstall key could be derived - fill in DetectionPattern before publishing.'
    }

    return [pscustomobject]@{
        Row       = $row
        File      = $file
        Signature = $evidence.SignatureStatus
    }
}

#endregion
