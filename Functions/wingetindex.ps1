<#
    SCCMAppHelper - the official winget index

    The winget client does not search GitHub either. It downloads a prebuilt
    index from Microsoft's CDN - source.msix, a package holding an SQLite
    database with every package id, name, moniker, version and publisher of
    the community repository - and searches that. So does this file.

        https://cdn.winget.microsoft.com/cache/source.msix
            -> Public\index.db  (SQLite)
            -> Config\winget-index\index.db, refreshed once a day

    That takes the search off the GitHub API and its 60 requests an hour: a
    search is a local query and answers in a moment, and resolving the newest
    version of a package needs no request at all. Only the manifests and the
    installer itself are still fetched, from raw.githubusercontent.com and the
    vendor, neither of which counts against the API limit.

    SQLite is read through winsqlite3.dll, which every Windows since 10 / Server
    2016 ships in System32 - so nothing has to be installed and no binary has
    to be carried in the repository. The few entry points used are the plain
    sqlite3_* C API, called through P/Invoke from a small C# helper.
#>

$script:WingetIndexUrl      = 'https://cdn.winget.microsoft.com/cache/source.msix'
$script:WingetIndexEntry    = 'Public/index.db'
$script:WingetIndexMaxAge   = [TimeSpan]::FromHours(24)
$script:WingetIndexSqlite   = $null   # the helper type, once compiled

#region ------------------------------------------------------------- sqlite

<#
    A reader for the handful of calls a SELECT needs, against winsqlite3.dll.
    Compiled once per session. Strings cross the boundary as UTF-8, which is
    what SQLite speaks and what the package names in the index are.
#>
function Initialize-WingetSqlite {
    if ($script:WingetIndexSqlite) { return $script:WingetIndexSqlite }

    $dll = Join-Path $env:SystemRoot 'System32\winsqlite3.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        throw "winsqlite3.dll is not on this machine ($dll) - it ships with Windows 10 / Server 2016 and later."
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WingetSqlite
{
    const string Lib = "winsqlite3.dll";
    const int SQLITE_OK = 0, SQLITE_ROW = 100, SQLITE_DONE = 101, SQLITE_OPEN_READONLY = 1;

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, out IntPtr tail);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_bytes(IntPtr stmt, int col);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);

    static byte[] Utf8(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    static string ReadUtf8(IntPtr p)
    {
        if (p == IntPtr.Zero) return "";
        int len = 0;
        while (Marshal.ReadByte(p, len) != 0) len++;
        byte[] buffer = new byte[len];
        Marshal.Copy(p, buffer, 0, len);
        return Encoding.UTF8.GetString(buffer);
    }

    // Every row as an array of strings, in column order. NULL comes back as "".
    public static List<string[]> Query(string path, string sql)
    {
        IntPtr db;
        int rc = sqlite3_open_v2(Utf8(path), out db, SQLITE_OPEN_READONLY, IntPtr.Zero);
        if (rc != SQLITE_OK) { string m = ReadUtf8(sqlite3_errmsg(db)); sqlite3_close(db); throw new Exception("sqlite open failed (" + rc + "): " + m); }

        var rows = new List<string[]>();
        try
        {
            IntPtr stmt, tail;
            rc = sqlite3_prepare_v2(db, Utf8(sql), -1, out stmt, out tail);
            if (rc != SQLITE_OK) throw new Exception("sqlite prepare failed (" + rc + "): " + ReadUtf8(sqlite3_errmsg(db)));
            try
            {
                int columns = sqlite3_column_count(stmt);
                while ((rc = sqlite3_step(stmt)) == SQLITE_ROW)
                {
                    var row = new string[columns];
                    for (int i = 0; i < columns; i++)
                    {
                        IntPtr p = sqlite3_column_text(stmt, i);
                        int len = sqlite3_column_bytes(stmt, i);
                        if (p == IntPtr.Zero || len <= 0) { row[i] = ""; continue; }
                        byte[] buffer = new byte[len];
                        Marshal.Copy(p, buffer, 0, len);
                        row[i] = Encoding.UTF8.GetString(buffer);
                    }
                    rows.Add(row);
                }
                if (rc != SQLITE_DONE) throw new Exception("sqlite step failed (" + rc + "): " + ReadUtf8(sqlite3_errmsg(db)));
            }
            finally { sqlite3_finalize(stmt); }
        }
        finally { sqlite3_close(db); }
        return rows;
    }
}
'@

    if (-not ('WingetSqlite' -as [type])) { Add-Type -TypeDefinition $source -ErrorAction Stop }
    $script:WingetIndexSqlite = [WingetSqlite]
    return $script:WingetIndexSqlite
}

function Invoke-WingetIndexQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [string]$Path = (Get-WingetIndexPath)
    )

    $sqlite = Initialize-WingetSqlite
    return @($sqlite::Query($Path, $Sql))
}

# A value on its way into a LIKE clause - the only thing that has to be escaped
# is the quote itself; % and _ are left to the user, who may well mean them.
function ConvertTo-WingetSqlLiteral {
    param([string]$Value)
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

#endregion

#region ----------------------------------------------------------- the index

function Get-WingetIndexFolder { return (Join-Path $rootDir 'Config\winget-index') }
function Get-WingetIndexPath   { return (Join-Path (Get-WingetIndexFolder) 'index.db') }

<#
    What is known about the local copy: when it was fetched and how many
    packages it holds. Nothing when there is none.
#>
function Get-WingetIndexInfo {
    $path = Get-WingetIndexPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $stamp = Join-Path (Get-WingetIndexFolder) 'index.json'
    $info = [pscustomobject]@{ Path = $path; Downloaded = (Get-Item -LiteralPath $path).LastWriteTime; Packages = 0; Schema = '' }
    if (Test-Path -LiteralPath $stamp) {
        try {
            $saved = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
            if ($saved.downloaded) { $info.Downloaded = [datetime]$saved.downloaded }
            if ($saved.packages)   { $info.Packages   = [int]$saved.packages }
            if ($saved.schema)     { $info.Schema     = [string]$saved.schema }
        }
        catch { }
    }
    return $info
}

<#
    Fetches source.msix and takes index.db out of it. The msix is a zip; the
    database sits at Public\index.db. Nothing in it is executed - it is data
    and nothing else.
#>
function Update-WingetIndex {
    Initialize-CatalogSecurity

    $folder = Get-WingetIndexFolder
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }

    $msix = Join-Path $folder 'source.msix'
    Write-Info "Downloading the winget index from $script:WingetIndexUrl"
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $script:WingetIndexUrl -OutFile $msix -UseBasicParsing -ErrorAction Stop `
            -Headers @{ 'User-Agent' = $script:CatalogUserAgent }
    }
    finally { $ProgressPreference = $progress }
    Write-Ok ("Downloaded source.msix ({0:n1} MB)" -f ((Get-Item -LiteralPath $msix).Length / 1MB))

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $target = Get-WingetIndexPath
    $fresh  = "$target.new"
    $zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $script:WingetIndexEntry -or $_.FullName -eq ($script:WingetIndexEntry -replace '/', '\') } | Select-Object -First 1
        if (-not $entry) { throw "source.msix holds no $script:WingetIndexEntry - the index format may have changed." }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $fresh, $true)
    }
    finally { $zip.Dispose() }
    Remove-Item -LiteralPath $msix -Force -ErrorAction SilentlyContinue

    # Read it once before it replaces the old one, so a broken download does
    # not take a working index with it.
    $count  = 0
    $schema = ''
    try {
        $count = [int](Invoke-WingetIndexQuery -Path $fresh -Sql 'SELECT COUNT(*) FROM ids')[0][0]
        $meta  = @(Invoke-WingetIndexQuery -Path $fresh -Sql "SELECT name, value FROM metadata WHERE name IN ('majorVersion', 'minorVersion')")
        $schema = (($meta | Sort-Object { $_[0] } -Descending | ForEach-Object { $_[1] }) -join '.')
    }
    catch {
        Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
        throw ("The downloaded index could not be read: {0}" -f $_.Exception.Message)
    }
    Move-Item -LiteralPath $fresh -Destination $target -Force

    [pscustomobject]@{ downloaded = (Get-Date).ToString('o'); packages = $count; schema = $schema; source = $script:WingetIndexUrl } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'index.json') -Encoding UTF8

    Write-Ok ("winget index ready: {0} packages, schema {1}" -f $count, $schema)
    return (Get-WingetIndexInfo)
}

<#
    The index, fetched or refreshed when it is missing or older than a day.
    Returns the info, or $null when there is no usable index and -Quiet was
    given; otherwise it throws, and the caller falls back to the GitHub walk.
#>
function Get-WingetIndex {
    param([switch]$Force)

    $info = Get-WingetIndexInfo
    $stale = (-not $info) -or $Force -or ((Get-Date) - $info.Downloaded) -gt $script:WingetIndexMaxAge

    if ($stale) {
        try { $info = Update-WingetIndex }
        catch {
            if ($info) { Write-Warn ("The winget index could not be refreshed - using the copy from {0:yyyy-MM-dd HH:mm}: {1}" -f $info.Downloaded, $_.Exception.Message) }
            else       { throw }
        }
    }
    return $info
}

function Test-WingetIndexTable {
    param([Parameter(Mandatory = $true)][string]$Name)
    $rows = @(Invoke-WingetIndexQuery -Sql ("SELECT name FROM sqlite_master WHERE type = 'table' AND name = {0}" -f (ConvertTo-WingetSqlLiteral $Name)))
    return ($rows.Count -gt 0)
}

<#
    Searches the index by package id, package name, moniker and publisher.

    The schema is the client's: one row per manifest in "manifest", pointing
    at the id, name, moniker and version tables by rowid; the normalised
    publisher ("igorpavlov") hangs off a map table in newer schema versions
    and is used when it is there. Returns one entry per package with its
    versions, newest first.
#>
function Search-WingetIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$Limit = 300
    )

    $null = Get-WingetIndex

    $needle = $Query.Trim()
    if ($needle.Length -lt 2) { throw 'Please search for at least two characters.' }
    $like = ConvertTo-WingetSqlLiteral ('%' + $needle + '%')
    $normalised = ConvertTo-WingetSqlLiteral ('%' + (($needle.ToLowerInvariant() -replace '[^a-z0-9]', '')) + '%')

    $where = @(
        "ids.id LIKE $like",
        "names.name LIKE $like",
        "monikers.moniker LIKE $like"
    )
    if (Test-WingetIndexTable -Name 'norm_publishers_map') {
        $where += "manifest.rowid IN (SELECT m.manifest FROM norm_publishers_map m JOIN norm_publishers p ON p.rowid = m.norm_publisher WHERE p.norm_publisher LIKE $normalised)"
    }

    $sql = @"
SELECT ids.id, names.name, versions.version
FROM manifest
JOIN ids ON ids.rowid = manifest.id
JOIN names ON names.rowid = manifest.name
JOIN versions ON versions.rowid = manifest.version
LEFT JOIN monikers ON monikers.rowid = manifest.moniker
WHERE $($where -join ' OR ')
"@

    $rows = @(Invoke-WingetIndexQuery -Sql $sql)

    $byId = [ordered]@{}
    foreach ($row in $rows) {
        $id = $row[0]
        if (-not $byId.Contains($id)) { $byId[$id] = [pscustomobject]@{ Name = $row[1]; PackageId = $id; Versions = @() } }
        $byId[$id].Versions += $row[2]
    }

    $results = @()
    foreach ($entry in $byId.Values) {
        $sorted = @(Sort-CatalogVersion -Version $entry.Versions)
        $results += [pscustomobject]@{
            Name        = $entry.Name
            PackageId   = $entry.PackageId
            Version     = $sorted[0]
            Versions    = $sorted
            Description = ''
        }
    }

    # Exact and prefix hits on the name first, then the rest by name.
    $lower = $needle.ToLowerInvariant()
    $results = @($results | Sort-Object `
        @{ Expression = { if ($_.Name.ToLowerInvariant() -eq $lower -or $_.PackageId.ToLowerInvariant() -eq $lower) { 0 } elseif ($_.Name.ToLowerInvariant().StartsWith($lower)) { 1 } else { 2 } } },
        @{ Expression = { $_.Name } })
    if ($results.Count -gt $Limit) { $results = @($results | Select-Object -First $Limit) }
    return $results
}

<#
    The versions of one package out of the index, newest first - or nothing,
    when the package is not in it, so the caller can ask GitHub instead.
#>
function Get-WingetIndexVersion {
    param([Parameter(Mandatory = $true)][string]$PackageIdentifier)

    $null = Get-WingetIndex
    $sql = @"
SELECT versions.version
FROM manifest
JOIN ids ON ids.rowid = manifest.id
JOIN versions ON versions.rowid = manifest.version
WHERE ids.id = $(ConvertTo-WingetSqlLiteral $PackageIdentifier)
"@
    $versions = @(Invoke-WingetIndexQuery -Sql $sql | ForEach-Object { $_[0] } | Where-Object { $_ })
    if ($versions.Count -eq 0) { return @() }
    return @(Sort-CatalogVersion -Version $versions)
}

#endregion
