<#
    Tools > Move source root: the package share moves, and everything that
    points at it follows.

    Why: the 260 character path limit counts the UNC path the site reads the
    content through - \\server\share\<package>\<file>. "Sources\Applications"
    below the server name is 21 characters of every path; a share "Apps"
    straight on the folder is 4. Renaming the folder on disk alone changes
    nothing for the site; the share and every deployment type's content
    location have to move with it.

    What hangs on the root, in the order it is handled:

        1. the package folders on disk    <old local root>\*  ->  <new local root>\*
                                          (one rename when the new root does not exist yet, else per package)
        2. the share                      created on the site server with the old share's access list
                                          when the tool runs there; elsewhere the admin creates it first
        3. every deployment type on the site whose content location lies below the old UNC root
                                          Set-CM<Technology>DeploymentType -ContentLocation (Script and MSI;
                                          other technologies are listed and left to the console)
        4. config.json                    sourceRoot / sourceRootLocal of the active site

    Each step skips what is already done, so a run that stopped halfway is
    simply started again; config.json is written last and only when every
    deployment type is across, because the old root in it is what a second run
    finds the rest by.

    What the site does with it, measured on the lab site (17 deployment types):
    a changed content location is a NEW content object - every deployment type
    got a new Content_<guid>, revision +1 - and the distribution manager takes
    a snapshot from the new path and sends it to the distribution points on its
    own, within a minute, without an Update-CMDistributionPoint. So: DP traffic
    for every package once, and a client that later repairs, uninstalls or
    re-installs downloads the package again under the new id (the old copy
    stays in its cache until the cache makes room). An installed application
    stays installed; nothing runs on the clients because of the move.
#>

<#
    Whether a content location lies below a root, with the server spelled any
    way: \\cm1\Sources\Applications\X and \\CM1.lab.example\Sources\Applications\X
    are the same place. Older scripts wrote the short name, this tool writes the
    FQDN, and a site has both. Returns the part below the root ("\X\Content") or
    $null.
#>
function Get-UncPathBelowRoot {
    param([string]$Path, [string]$Root)
    if ($Path -notlike '\\*\*' -or $Root -notlike '\\*\*') { return $null }
    $pathServer = $Path.Substring(2).Split('\')[0]; $rootServer = $Root.Substring(2).Split('\')[0]
    if (-not $pathServer -or -not $rootServer) { return $null }
    $pathRest = $Path.Substring(2 + $pathServer.Length).TrimEnd('\')
    $rootRest = $Root.Substring(2 + $rootServer.Length).TrimEnd('\')
    if (-not ($pathRest.ToLower() -eq $rootRest.ToLower() -or $pathRest.ToLower().StartsWith($rootRest.ToLower() + '\'))) { return $null }
    if ($pathServer.ToLower() -ne $rootServer.ToLower()) {
        $hostOf = { param($n) try { ([System.Net.Dns]::GetHostEntry($n)).HostName.ToLower() } catch { $n.ToLower() } }
        if ((& $hostOf $pathServer) -ne (& $hostOf $rootServer)) { return $null }
    }
    return $pathRest.Substring($rootRest.Length)
}

function Get-SourceRootMovePlan {
    param(
        [Parameter(Mandatory = $true)][string]$NewLocalRoot,
        [Parameter(Mandatory = $true)][string]$NewUncRoot,
        $Config = (Get-ActiveConfig)
    )

    $oldLocal = [string]$Config.sourceRootLocal
    $oldUnc   = [string]$Config.sourceRoot
    if (-not $oldUnc) { throw 'sourceRoot of the active site is empty - nothing to move from.' }
    if ($NewUncRoot -notlike '\\*\*') { throw "The new source root must be a UNC path (\\server\share[\folder]): $NewUncRoot" }
    if ($NewLocalRoot -notmatch '^[A-Za-z]:\\') { throw "The new local root must be a drive path on the site server (E:\Apps): $NewLocalRoot" }

    $oldLocal = $oldLocal.TrimEnd('\'); $oldUnc = $oldUnc.TrimEnd('\')
    $newLocal = $NewLocalRoot.TrimEnd('\'); $newUnc = $NewUncRoot.TrimEnd('\')
    if ($newUnc -eq $oldUnc -and $newLocal -eq $oldLocal) { throw 'The new root is the old root.' }
    if ($newLocal.ToLower().StartsWith($oldLocal.ToLower() + '\')) { throw 'The new local root lies inside the old one - that cannot be moved.' }

    $onServer = Test-IsLocalComputer -ComputerName $Config.siteServer

    # Same volume = one rename; another volume = a copy of everything. A mounted
    # volume hides behind a plain folder name (the lab's C:\Sources is volume H:),
    # so the drive letter alone does not tell: the nearest junction above each
    # path is its volume root.
    $volumeOf = { param([string]$path)
        $p = $path; $root = [System.IO.Path]::GetPathRoot($p).TrimEnd('\'); $p = $p.TrimEnd('\')
        while ($p -and $p.Length -gt $root.Length) {
            try { if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $p.TrimEnd('\').ToLower() } } catch { }
            $p = Split-Path -Path $p -Parent
        }
        return $root.ToLower()
    }
    $sameVolume = $true; $sizeBytes = 0
    if ($oldLocal -and (Test-Path -LiteralPath $oldLocal)) {
        $newProbe = $newLocal; while ($newProbe -and -not (Test-Path -LiteralPath $newProbe)) { $newProbe = Split-Path -Path $newProbe -Parent }
        $sameVolume = ((& $volumeOf $oldLocal) -eq (& $volumeOf $newProbe))
        if (-not $sameVolume) { try { $sizeBytes = (Get-ChildItem -LiteralPath $oldLocal -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { } }
    }
    $shareServer = ($newUnc -split '\\')[2]
    $shareName   = ($newUnc -split '\\')[3]
    $shareExists = $false
    try { $shareExists = [bool](Get-CimInstance -ClassName Win32_Share -ComputerName $shareServer -Filter "Name = '$shareName'" -ErrorAction Stop) } catch { }

    # 1. packages: whatever lies as a folder directly below the old root
    $packages = @()
    $walkRoot = $(if ($oldLocal -and (Test-Path -LiteralPath $oldLocal)) { $oldLocal } elseif (Test-Path -LiteralPath $oldUnc) { $oldUnc } else { '' })
    if ($walkRoot) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $walkRoot -Directory)) {
            $packages += [pscustomobject]@{
                Name    = $dir.Name
                Source  = $dir.FullName
                Target  = (Join-Path $newLocal $dir.Name)
                Done    = (Test-Path -LiteralPath (Join-Path $newLocal $dir.Name))
            }
        }
    }

    # 3. deployment types below the old UNC root, all applications of the site
    $signature = Get-ToolSignaturePattern
    $dts = @(Invoke-InCMSite -Config $Config -ScriptBlock {
        foreach ($app in @(Get-CMApplication -Fast)) {
            foreach ($dt in @(Get-CMDeploymentType -ApplicationName $app.LocalizedDisplayName)) {
                $xml = [string]$dt.SDMPackageXML
                $loc = ''; if ($xml -match '<Location>(?<loc>[^<]*)</Location>') { $loc = $Matches['loc'] }
                if (-not $loc) { continue }
                $restOld = Get-UncPathBelowRoot -Path $loc -Root $oldUnc
                $restNew = Get-UncPathBelowRoot -Path $loc -Root $newUnc
                $below = ($null -ne $restOld); $already = ($null -ne $restNew)
                if (-not $below -and -not $already) { continue }
                $tech = [string]$dt.Technology
                [pscustomobject]@{
                    Application = $app.LocalizedDisplayName
                    DeploymentType = $dt.LocalizedDisplayName
                    Technology  = $tech
                    Origin      = $(if (($xml -match $signature) -or ($xml -match 'Generated by SCCMAppHelper')) { 'this tool' } else { 'foreign' })
                    OldLocation = $loc
                    NewLocation = $(if ($already) { $loc } else { $newUnc + $restOld + '\' })
                    Supported   = ($tech -in 'Script', 'MSI')
                    Done        = $already
                }
            }
        }
    })

    # the path gain: the longest UNC path of every package, before and after
    $longestBefore = 0; $longestAfter = 0
    foreach ($p in $packages) {
        $walk = $(if ($p.Done) { $p.Target } else { $p.Source })
        if (-not (Test-Path -LiteralPath $walk)) { continue }
        $scan = Measure-ContentFolder -ContentPath $walk -ContentUnc ($oldUnc + '\' + $p.Name) -Limit 259
        if ($scan.Longest -gt $longestBefore) { $longestBefore = $scan.Longest }
        $after = $scan.Longest - $oldUnc.Length + $newUnc.Length
        if ($after -gt $longestAfter) { $longestAfter = $after }
    }

    $warnings = @()
    if (-not $onServer -and -not $shareExists) { $warnings += "Share \\$shareServer\$shareName does not exist and this is not the site server - create it on $shareServer (path $newLocal) before the move." }
    if (-not $onServer -and $oldLocal -and -not (Test-Path -LiteralPath $oldLocal)) { $warnings += "The local root $oldLocal is not reachable from here - the folders are moved through the old share instead, which is slower." }
    if ((Test-Path -LiteralPath $newLocal) -and @(Get-ChildItem -LiteralPath $newLocal -Force -ErrorAction SilentlyContinue).Count -gt 0 -and @($packages | Where-Object { -not $_.Done }).Count -eq $packages.Count) { $warnings += "$newLocal exists and is not empty." }
    foreach ($d in @($dts | Where-Object { -not $_.Supported -and -not $_.Done })) { $warnings += ('Deployment type "{0}" of "{1}" is {2} - its content location must be changed in the console.' -f $d.DeploymentType, $d.Application, $d.Technology) }
    if (@($dts | Where-Object { $_.Origin -eq 'foreign' -and -not $_.Done }).Count -gt 0) { $warnings += 'Deployment types not published by this tool lie below the old root too; they are moved as well - nothing else would keep working.' }
    if ($longestAfter -gt 259) { $warnings += "Even after the move the longest path is $longestAfter characters (limit 259)." }

    return [pscustomobject]@{
        OldLocalRoot = $oldLocal; OldUncRoot = $oldUnc
        NewLocalRoot = $newLocal; NewUncRoot = $newUnc
        OnServer     = $onServer
        SameVolume   = $sameVolume; CopyBytes = $sizeBytes
        ShareServer  = $shareServer; ShareName = $shareName; ShareExists = $shareExists
        OldShareName = ($oldUnc -split '\\')[3]
        Packages     = $packages
        DeploymentTypes = $dts
        LongestBefore = $longestBefore; LongestAfter = $longestAfter
        Warnings     = $warnings
    }
}

function Format-SourceRootMovePlan {
    param([Parameter(Mandatory = $true)]$Plan)
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine(('Root:    {0}  ->  {1}' -f $Plan.OldUncRoot, $Plan.NewUncRoot))
    $null = $sb.AppendLine(('Disk:    {0}  ->  {1}{2}' -f $Plan.OldLocalRoot, $Plan.NewLocalRoot, $(if ($Plan.SameVolume) { '  (same volume: a rename)' } else { '  (ANOTHER VOLUME: {0:N1} GB are copied)' -f ($Plan.CopyBytes / 1GB) })))
    $null = $sb.AppendLine(('Share:   \\{0}\{1} {2}' -f $Plan.ShareServer, $Plan.ShareName, $(if ($Plan.ShareExists) { 'exists' } elseif ($Plan.OnServer) { 'will be created with the access list of share ' + $Plan.OldShareName } else { 'MISSING' })))
    $pending = @($Plan.Packages | Where-Object { -not $_.Done }); $donePk = $Plan.Packages.Count - $pending.Count
    $null = $sb.AppendLine(('Folders: {0} to move{1}' -f $pending.Count, $(if ($donePk) { ", $donePk already at the new root" } else { '' })))
    $dtPending = @($Plan.DeploymentTypes | Where-Object { -not $_.Done }); $dtDone = $Plan.DeploymentTypes.Count - $dtPending.Count
    $null = $sb.AppendLine(('DTs:     {0} to re-point ({1} of this tool, {2} foreign, {3} unsupported){4}' -f $dtPending.Count, @($dtPending | Where-Object { $_.Origin -eq 'this tool' }).Count, @($dtPending | Where-Object { $_.Origin -eq 'foreign' }).Count, @($dtPending | Where-Object { -not $_.Supported }).Count, $(if ($dtDone) { ", $dtDone already there" } else { '' })))
    $null = $sb.AppendLine(('Longest: {0} -> {1} of 259 characters' -f $Plan.LongestBefore, $Plan.LongestAfter))
    foreach ($w in $Plan.Warnings) { $null = $sb.AppendLine('! ' + $w) }
    $null = $sb.AppendLine()
    foreach ($p in $pending) { $null = $sb.AppendLine('  move  ' + $p.Name) }
    foreach ($d in $dtPending) { $null = $sb.AppendLine(('  {0}  {1} / {2} [{3}]' -f $(if ($d.Supported) { 'dt   ' } else { 'skip ' }), $d.Application, $d.DeploymentType, $d.Technology)) }
    return $sb.ToString()
}

function Invoke-SourceRootMove {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        $Config = (Get-ActiveConfig)
    )

    # 1. the folders. Directory.Move, not Move-Item: on the same volume that is a
    # rename - instant, atomic, nothing is copied, ACLs travel with it. Move-Item
    # copies and deletes instead (measured: 4 MB of a 35 GB tree copied, then a
    # "cannot remove" on the first folder the account may not delete, and the
    # target left half-filled). Across volumes Directory.Move refuses; then it is
    # robocopy /MOVE per package, which keeps what it copied on a failure.
    Write-Step 'Moving the package folders'
    $pending = @($Plan.Packages | Where-Object { -not $_.Done })
    $moveDir = {
        param([string]$From, [string]$To)
        if ($Plan.SameVolume) { [System.IO.Directory]::Move($From, $To); return 'rename' }
        $out = & robocopy.exe $From $To /E /MOVE /COPY:DATSO /R:2 /W:2 /NFL /NDL /NJH /NJS /NP 2>&1
        if ($LASTEXITCODE -ge 8) { throw ('robocopy {0} -> {1} failed with {2}: {3}' -f $From, $To, $LASTEXITCODE, ($out -join ' ')) }
        return 'copied'
    }
    if ($pending.Count -eq 0) { Write-Info 'Nothing to move.' }
    elseif (-not (Test-Path -LiteralPath $Plan.NewLocalRoot) -and $pending.Count -eq $Plan.Packages.Count -and (Test-Path -LiteralPath $Plan.OldLocalRoot)) {
        # the whole root at once
        $parent = Split-Path -Path $Plan.NewLocalRoot -Parent
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $how = & $moveDir $Plan.OldLocalRoot $Plan.NewLocalRoot
        Write-Ok ('{0} -> {1} ({2} folders, {3})' -f $Plan.OldLocalRoot, $Plan.NewLocalRoot, $pending.Count, $how)
    }
    else {
        if (-not (Test-Path -LiteralPath $Plan.NewLocalRoot)) { $null = New-Item -ItemType Directory -Path $Plan.NewLocalRoot -Force }
        foreach ($p in $pending) {
            $how = & $moveDir $p.Source $p.Target
            Write-Ok ('{0}  {1}' -f $how.PadRight(6), $p.Name)
        }
    }

    # 2. the share
    Write-Step ('Share \\{0}\{1}' -f $Plan.ShareServer, $Plan.ShareName)
    if ($Plan.ShareExists) { Write-Info 'exists' }
    elseif ($Plan.OnServer) {
        $null = New-SmbShare -Name $Plan.ShareName -Path $Plan.NewLocalRoot -ErrorAction Stop
        # the old share's access list, entry by entry
        foreach ($a in @(Get-SmbShareAccess -Name $Plan.OldShareName -ErrorAction SilentlyContinue)) {
            if ($a.AccessControlType -eq 'Allow') { $null = Grant-SmbShareAccess -Name $Plan.ShareName -AccountName $a.AccountName -AccessRight $a.AccessRight -Force }
            else { $null = Block-SmbShareAccess -Name $Plan.ShareName -AccountName $a.AccountName -Force }
        }
        # the default "Everyone Read" that New-SmbShare adds is not part of the copy
        if (@(Get-SmbShareAccess -Name $Plan.OldShareName -ErrorAction SilentlyContinue | Where-Object { $_.AccountName -eq 'Everyone' }).Count -eq 0) { $null = Revoke-SmbShareAccess -Name $Plan.ShareName -AccountName 'Everyone' -Force -ErrorAction SilentlyContinue }
        Write-Ok ('created on {0}, access list copied from {1}' -f $Plan.NewLocalRoot, $Plan.OldShareName)
    }
    else { throw ('Share \\{0}\{1} does not exist - create it and run the tool again; the folders are already moved.' -f $Plan.ShareServer, $Plan.ShareName) }
    if (-not (Test-Path -LiteralPath $Plan.NewUncRoot)) { throw ('{0} is not reachable from here.' -f $Plan.NewUncRoot) }

    # 3. the deployment types
    Write-Step 'Re-pointing the deployment types'
    $failed = New-Object System.Collections.Generic.List[object]   # a list: the site script block adds to it from its own scope
    $work = @($Plan.DeploymentTypes | Where-Object { -not $_.Done })
    Invoke-InCMSite -Config $Config -ScriptBlock {
        foreach ($d in $work) {
            if (-not $d.Supported) { Write-Warn ('skip   {0} / {1} [{2}] - change the content location in the console: {3}' -f $d.Application, $d.DeploymentType, $d.Technology, $d.NewLocation); continue }
            # .NET, not Test-Path: inside the site drive a UNC path is handed to the CMSite provider and comes back false
            if (-not [System.IO.Directory]::Exists($d.NewLocation)) { Write-Fail ('missing {0} - {1} / {2} left as it is' -f $d.NewLocation, $d.Application, $d.DeploymentType); $failed.Add($d); continue }
            try {
                switch ($d.Technology) {
                    'Script' { $null = Set-CMScriptDeploymentType -ApplicationName $d.Application -DeploymentTypeName $d.DeploymentType -ContentLocation $d.NewLocation -ErrorAction Stop }
                    'MSI'    { $null = Set-CMMsiDeploymentType    -ApplicationName $d.Application -DeploymentTypeName $d.DeploymentType -ContentLocation $d.NewLocation -ErrorAction Stop }
                }
                Write-Ok ('dt     {0} / {1}' -f $d.Application, $d.DeploymentType)
            }
            catch { Write-Fail ('failed {0} / {1}: {2}' -f $d.Application, $d.DeploymentType, $_.Exception.Message); $failed.Add($d) }
        }
    }

    # 4. config.json - last, and only when every deployment type is across: the
    # old root in config.json is what a second run finds the rest by.
    Clear-InventoryCache -Site
    if ($failed.Count -gt 0) {
        Write-Warn ('{0} deployment type(s) not re-pointed - config.json keeps the old root; fix the cause and run the tool again, it continues where it stopped.' -f $failed.Count)
        return
    }
    Write-Step 'config.json'
    $site = Get-AppHelperConfig | Select-Object -ExpandProperty sites | Where-Object { $_.name -eq $Config.siteName } | Select-Object -First 1
    if (-not $site) { throw ('Site [{0}] not found in config.json.' -f $Config.siteName) }
    $site | Add-Member -MemberType NoteProperty -Name 'sourceRoot' -Value $Plan.NewUncRoot -Force
    $site | Add-Member -MemberType NoteProperty -Name 'sourceRootLocal' -Value $Plan.NewLocalRoot -Force
    $null = Save-SiteToConfig -Site $site
    Write-Ok ('Done. The old share {0} can be removed once nothing else uses it.' -f $Plan.OldUncRoot)
}

function Move-SourceRoot {
    param($Config = (Get-ActiveConfig))

    $input = Show-MoveSourceRootDialog -Config $Config
    if (-not $input) { Write-Info 'Cancelled.'; return }

    $plan = Get-SourceRootMovePlan -NewLocalRoot $input.NewLocalRoot -NewUncRoot $input.NewUncRoot -Config $Config
    Write-Host (Format-SourceRootMovePlan -Plan $plan)
    if (@($plan.Packages | Where-Object { -not $_.Done }).Count -eq 0 -and @($plan.DeploymentTypes | Where-Object { -not $_.Done }).Count -eq 0 -and $plan.ShareExists) { Write-Ok 'Nothing left to do.'; return }

    $blocking = @($plan.Warnings | Where-Object { $_ -like '*does not exist and this is not the site server*' })
    if ($blocking.Count -gt 0) { $null = Show-MessageDialog -Text ($blocking -join "`n") -Caption 'Move source root' -Icon 'Warning'; return }

    $text = "Move the source root?`n`n" + (Format-SourceRootMovePlan -Plan $plan) + "`nEvery deployment type gets a new content object; the site distributes it to the DPs by itself. Clients download a package again the next time they repair, uninstall or re-install it."
    $answer = Show-MessageDialog -Text $text -Caption 'Move source root' -Buttons 'YesNo' -Icon 'Question'
    if ($answer -ne 'Yes') { Write-Info 'Cancelled.'; return }

    Invoke-SourceRootMove -Plan $plan -Config $Config
}
