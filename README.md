# SCCMAppHelper

Quickly create and publish Configuration Manager applications using PSADT - the ConfigMgr
counterpart to [IntuneWin32Helper](../IntuneWin32Helper).

```
Apps.csv  ->  PSADT package on the source share  ->  ConfigMgr application
                                                     + collections
                                                     + deployments
                                                     + content distribution
                                                     + supersedence
```

## Start

```powershell
.\start-SCCMAppHelper.ps1
```

Windows PowerShell 5.1 with the ConfigMgr console installed.

### First run on a new server

Nothing has to be filled into `config.json` by hand. If no site is configured - or the
configured site server cannot be resolved, which is what happens after cloning the repo into
a different environment - the setup assistant starts and reads the site itself:

1. **Server**: prefilled with the FQDN of the local machine. Running the tool on the site
   server means clicking OK.
2. **Discovery**: site code and provider from `SMS_ProviderLocation`, SQL server and database
   from the site server registry (falling back to `CM_<SiteCode>`).
3. **Package share**: pick from the shares of the site server, including their first level of
   subfolders - that fills the UNC path and the local path in one step. If no share exists
   yet, the assistant asks for the paths and offers to create the folder.
4. **Distribution point** or distribution point group, and the limiting collection
   (read from `SMS00001`, whatever it is named locally).
5. **Check and save** into the `sites` array of `config.json`, followed by an end to end test.

The assistant is also available later under **Tools -> Add ConfigMgr site**, and
**Tools -> Check site configuration** re-runs the test at any time.

The start dialog offers:

| Tile | What it does |
| --- | --- |
| **Create packages** | Creates PSADT packages for the selected rows of `Apps.csv` |
| **Create and publish** | Same, and publishes each package as a ConfigMgr application |
| **Publish packages** | Publishes existing packages (again) |
| **Tools** | Collection maintenance helpers |

The gear icon opens the settings editor for `Config\config.json`.

## The master list: Apps.csv

`Apps.csv` (semicolon separated) is the single source of truth for naming. `Name` and
`Version` form the application name `Name - Version`, which is also the folder name, the
deployment type name and the base for every collection name.

| Column | Meaning |
| --- | --- |
| `Publisher` | Manufacturer, ends up in the ConfigMgr application and in PSADT |
| `Name` | Product name, exactly as it appears in Programs and Features |
| `Version` | Product version |
| `DetectionMethod` | `Registry` (default), `MSI`, `File` or `Script` |
| `DetectionPattern` | `Registry`: uninstall key (empty = the ProductCode) - `File`: full path of the file to check |
| `ProductCode` | MSI ProductCode for `DetectionMethod = MSI` |
| `InstallCmd` | Optional PSADT code for the install section |
| `UninstallCmd` | Optional PSADT code for the uninstall section |
| `Notes` | Free text, used as the application description |

Only `Publisher`, `Name` and `Version` are required - an older three column `apps.csv` is
upgraded automatically on first use.

In the app list dialog, **New** / **Duplicate** / **Edit** open an editor with two prefill
buttons:

* **From MSI...** reads ProductName, ProductVersion, Manufacturer and ProductCode from an
  MSI and switches the detection to `MSI`.
* **From EXE...** reads the version resource of a setup EXE.
* **From catalog...** picks the file first - see below - and then reads it the same way.

That replaces `add-NewMSIToAppsCSV.ps1` and keeps the naming unambiguous.

`InstallCmd` and `UninstallCmd` are written into the PSADT script inside a marked block:

```powershell
## <Perform Installation tasks here>
        # --- SCCMAppHelper Install begin - rewritten from Apps.csv on every build ---
        Start-ADTProcess -FilePath "setup.exe" -ArgumentList '--quiet --norestart --wait'
        # --- SCCMAppHelper Install end ---
```

The block is rewritten on every build, so correcting a row reaches the package. Without it the
code could only be inserted once - inserting twice would have produced the command twice - and
the package quietly outranked the master list: editing the row changed nothing, while the file
was rewritten for its metadata anyway, so the timestamp moved and the command did not.

A package built before this has no block. It is written into only when its section is still
empty; a command somebody put there by hand stays, and the difference is reported instead.

A GUID in braces is a script block to PowerShell, not a string, so
`-ProductCode {102DCD41-...}` fails on the client with a message about script blocks and no
input that says nothing about the missing quotes. The quotes are put back before the line is
written; quotes that are already there are left alone.

`DetectionMethod` is a list rather than a free text field, and what `DetectionPattern` has to
contain depends on it - so the hint under the field follows the method, and the field is
disabled where nothing belongs in it:

| Method | `DetectionPattern` | Install commands |
| --- | --- | --- |
| `MSI` | nothing - the ProductCode column, or the single MSI in `.\Files` | empty, PSADT deploys the MSI itself |
| `Registry` | the uninstall key | yours |
| `File` | the full path of the installed file | yours |
| `Script` | nothing - `Content\SupportFiles\detection.ps1` | yours |

## From catalog

The third prefill source in the record editor, next to **From MSI...** and **From EXE...**:
where those read a file you picked, this one finds the file first. Fetches the usual suspects
without hunting for a download link. The source is the manifest
repository behind winget, [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs),
read directly over HTTPS - the `winget` client itself is **not** used, because it is a per
user MSIX and is missing on Windows Server 2022.

### Finding a package

The repository is keyed by **publisher** - `manifests/<letter>/<Publisher>/<Package>` - so it
cannot be searched by product name. KeePass sits under `DominikReichl`, Visual Studio Code
under `Microsoft`. Building an index of it does not work either: GitHub answers the tree API
intermittently and returns incomplete trees without setting its own `truncated` flag.

So there are three ways in, in the order the dialog tries them:

1. The **curated list** in `Config\catalog.json` - searched by product name, no request needed.
2. The **full package id** - anything containing a dot is resolved directly.
3. The **repository search**, which matches publishers.

Whatever is found the hard way can be kept: **Remember** writes it into `catalog.json`, so it
is found by name next time. The list is meant to grow.

### What the dialog then does

1. **Pick** from `Config\catalog.json`, or search the repository for anything else.
2. **Resolve** the newest version, and say which versions of it `Apps.csv` already holds.
3. **Confirm** - the dialog names the installer, the URL and the SHA256. Nothing is
   downloaded before this.
4. **Download** into `<sourceRoot>\_DL\<Name> - <Version>\`, checked against the hash in the
   manifest. A file that does not match is deleted.
5. **Read** the file the same way the **From MSI...** button does, and report its Authenticode
   signer.
6. **Fill in** the record you already have open - publisher, name, version, detection method
   and ProductCode - and leave the rest to `OK`.

Where a manifest offers several installers, an MSI wins over an EXE: it carries a ProductCode,
which means native detection and PSADT's zero-config MSI deployment, so nothing has to be
maintained by hand. For an EXE the uninstall key comes from `AppsAndFeaturesEntries` in the
manifest - for 7-Zip that is literally `7-Zip`, which is exactly what `DetectionPattern`
wants.

It is a record source, not a workflow of its own - which is why it sits in the editor rather
on the start menu. That also means it can lift an **existing** row onto a newer version, not
just create one. The download waits in `_DL` under the same `<Name> - <Version>` name the
package folder will have; packaging and publishing stay with **Create packages** and
**Publish packages**.

Nothing that is downloaded is ever executed. GitHub allows 60 unauthenticated API requests an
hour, which is why the curated list stores the package id - resolving a version from it costs
a single request.

## Package layout

```
<sourceRoot>\<Name> - <Version>\      <- PSADT v4 root, and the ConfigMgr content location
    Invoke-AppDeployToolkit.ps1
    Files\
    Config\config.psd1                <- log path patched to psadtLogPath
    SupportFiles\
        detection.ps1                 <- optional, only for DetectionMethod = Script
        logo.png                      <- optional, wins over Logos\
```
A package holds its PSADT content and nothing else. The application icon and,
where one is needed, the detection script are rendered into a temporary folder
at publish time and removed again afterwards - so a fix in the tool reaches
packages built with an earlier version without touching them.

That is why the content sits in the package folder itself rather than a `Content`
subfolder. The subfolder existed to keep the tool's own files - the old `_Helper` - out of
what goes to the distribution points; with those gone it wrapped a single folder for no
reason, and cost eight characters of path length. Which is not academic: the deepest path in
an SQL Server Management Studio package reaches 259 characters over UNC, one below the limit,
and the subfolder pushed six of its files past it. ConfigMgr then reports "Could not find
file", which points nowhere near the cause.

`packageLayout = Subfolder` restores the old shape. Either way the layout of an existing
package is read from the package itself, so both keep working and nothing has to be moved.

### Where the logs are

Every package gets `LogPath` in its `Config\config.psd1` rewritten to `psadtLogPath`, which is
`C:\Windows\CCM\Logs\PSADT` by default. **Not** `C:\Windows\Logs\Software`, where PSADT would
put them and where you will otherwise look for them in vain. They sit next to the ConfigMgr
client logs on purpose - `AppEnforce.log`, `AppDiscovery.log` and the PSADT log of the same
run are then in one folder and one CMTrace window.

Packages built before this, or by hand, keep whatever their own config says.

### Importing existing packages

Every folder below `sourceRoot` that contains an `Invoke-AppDeployToolkit.ps1` counts as a
package - that is the only condition. The status column asks ConfigMgr rather than the share:

| Status | Meaning |
| --- | --- |
| `Not published` | no application `<Name> - <Version>` in the site |
| `Published (this tool)` | its deployment type carries the tool signature |
| `Published (foreign)` | it exists but was created by hand or by the older scripts - publishing overwrites its detection |

Publishing a package the master list does not know yet takes it over first:

* name and version come from the folder name (`<Name> - <Version>`, split at the last
  separator)
* publisher and detection settings come from `Apps.csv` if a row with that name and version
  exists, otherwise from `AppVendor` in the PSADT script - only if both are missing does the
  tool ask
* an existing `SupportFiles\logo.png` is reused as the application icon
* apps that were not in `Apps.csv` are appended to it, so the master list stays complete

### Where the metadata lives

There is no separate metadata file - a package describes itself:

| Value | Source |
| --- | --- |
| Name, version | the folder name `<Name> - <Version>` - the naming convention is the key |
| Publisher | `AppVendor` in the `$adtSession` block of `Invoke-AppDeployToolkit.ps1` |
| Author, date | `AppScriptAuthor` / `AppScriptDate` in the same block |
| Description | `Notes` of the matching `Apps.csv` row, otherwise the name |
| Detection | the `Apps.csv` row - rendered into clauses or a script at publish time |

**MSI packages** are the deliberate exception. When `DetectionMethod` is `MSI`, the tool
leaves `AppVendor`, `AppName` and `AppVersion` empty so PSADT runs its zero-config MSI
deployment and takes them from the MSI itself. Publisher and ProductCode are then read
straight out of the single MSI in `.\Files` - nothing has to be maintained by hand, and
detection is by ProductCode.

`$adtSession` is read through the PowerShell AST, so reformatting or double quotes do not
break it.

## Detection

Detection is native wherever ConfigMgr can evaluate it itself - the client checks a clause
directly, with no script host, no execution context and no timeout involved.

| `DetectionMethod` | Clause | `DetectionPattern` holds |
| --- | --- | --- |
| `MSI` | Windows Installer, ProductCode, `ProductVersion >= Version` | nothing - the ProductCode column, or the single MSI in `.\Files` |
| `Registry` | `DisplayVersion >= Version` below the uninstall key | the uninstall key |
| `File` | file version `>= Version`, existence when the version is not comparable | the full path of the file |
| `Script` | a PowerShell script | nothing |

For `Registry`, a bare name is taken below
`SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, a value already starting with
`SOFTWARE\` is used as it is, and an empty pattern falls back to the ProductCode - which is
exactly the uninstall key of an MSI installed product. Both registry views are checked and
connected with **Or**, because a 32 bit product on a 64 bit client registers below
`Wow6432Node`.

For `File`, the pattern is the full path of the installed file, environment variables included
- `%ProgramFiles%\Notepad++\notepad++.exe`. A path holding a variable gets both views as well,
again connected with **Or**: the client resolves `%ProgramFiles%` and `%SystemRoot%\System32`
differently depending on which one the clause asks for, and the 32 bit view alone would look
in `Program Files (x86)` and never find an x64 application. A literal path gets a single
clause, because there is nothing left to redirect.

A version that does not parse as a `[version]` (`19c` and the like) turns the clause into an
existence check.

### When a clause is not enough

`DetectionMethod = Script` reads `Content\SupportFiles\detection.ps1` from the package, so
hand written detection travels with the content. The tool copies it verbatim and only
prepends its signature. ConfigMgr script detection evaluates:

| Result | Meaning |
| --- | --- |
| exit code 0 + output on STDOUT | application **is** installed |
| exit code 0 + no output | application is **not** installed |
| exit code <> 0 | detection failed |

The templates in `Templates\` follow that contract - they only write to STDOUT when the
application really is detected, and they log every decision to `psadtLogPath`. `Custom` is
still accepted as the former name of this method.

### Changing the detection of a published application

Detection clauses can only be added, never replaced: a clause created together with the
deployment type cannot be removed again - `Set-CMScriptDeploymentType` reports it as "not
found" and leaves it in place. The tool therefore compares the detection first and only
touches it when it really differs, and verifies the result afterwards. If a deployment type
is left with more rules than it should have, the tool says so - correct it in the console.

## Configuration

`Config\config.json` has two parts: the `sites` array holds everything that differs between
ConfigMgr environments, all remaining keys are shared across sites.

### Sites

```json
"activeSite": "",
"sites": [
    { "name": "CREM (CCL)", "siteCode": "CCL", "siteServer": "VMSCCM", ... },
    { "name": "Lab (LAB)",  "siteCode": "LAB", "siteServer": "VMLAB",  ... }
]
```

| Key | Meaning |
| --- | --- |
| `name` | Display name in the site picker |
| `siteCode`, `siteServer` | ConfigMgr site - the site drive is created on demand |
| `sqlServer`, `database` | Used by the outdated-apps report; empty `database` means `CM_<siteCode>` |
| `sourceRoot` | UNC path of the package share - used as the content location |
| `sourceRootLocal` | Local path of the same share, used when the tool runs on the site server |
| `distributionPointName` / `distributionPointGroupName` | Distribution target (group wins if both are set) |
| `limitingCollectionName` | Limiting collection for new collections |
| `applicationFolderPath`, `collectionFolderPath` | Optional console folders for new applications and collections. `Apps` is enough - site code and root node are filled in (`<siteCode>:\Application\Apps` and `<siteCode>:\DeviceCollection\Apps`), and missing folders are created. Empty means the console root. |

With a single site nothing is asked. With several sites the tool asks once per session and
remembers the choice; **Tools -> Switch ConfigMgr site** changes it, and `activeSite`
(name or site code) pins a default so the question never appears. The active site is shown
in the title bar of the start dialog.

A config without a `sites` array still works - its top level keys are then treated as one
site.

### Shared keys

| Key | Meaning |
| --- | --- |
| `installCommand`, `uninstallCommand` | Deployment type command lines |
| `collections` | Collections created per application. Each entry has a `namePattern` where `{App}` becomes `Name - Version`, a `deployPurpose` (`Required` or `Available`) and a `userNotification` |
| `globalDeployments` | Deployments to existing collections, e.g. an "all apps" catalog collection. Each entry names its `collectionName` and its `deployPurpose` |
| `supersedeOlderVersions` | Wire the new application as superseding older versions of the same product |
| `supersedenceUninstall` | Uninstall the old version when superseding |
| `distributeContent`, `createDeployments` | Switch off to only create the application |
| `openExplorerOnCreate`, `openEditorOnCreate` | Interactive steps during packaging |
| `packageAuthor` | Author written into the PSADT script, empty = current user |
| `packageLayout` | `Flat` or `Subfolder` - see **Package layout** |
| `psadtLogPath` | Where the packages write their PSADT logs. Patched into every package's `Config\config.psd1` |
| `maximumRuntimeMins`, `estimatedRuntimeMins` | Runtime on the deployment type |
| `editor` | Program that **Edit script** opens the PSADT script with, empty = `notepad` |
| `removeExistingPackageDirOnEachRun` | Delete an existing package folder before rebuilding it. `false`, and it should stay that way unless you mean it |

Everything is idempotent: existing applications get their deployment type and detection
updated, existing collections and deployments are reused.

**The content is only sent to the distribution points when it really changed.** Publishing an
unchanged package prints `Content already distributed and unchanged - nothing to send`. That
is not laziness: `Update-CMDistributionPoint` creates a *new content object* on every call,
never a new version of the existing one, and every client then downloads the whole package
again. Three publishes of a five gigabyte package are enough to fill a 20 GB client cache, and
once it is full every further distribution fails with `0x87D01201` **while the client goes on
running the old content without reporting anything**. The tool therefore keeps a fingerprint
of the content folder - file count, total bytes, newest write time - in the deployment type
comment and compares it before refreshing.

To force a refresh anyway, change something in the content folder, or update the content by
hand in the console.

## Tools

* **Update collections** - triggers a membership update for all patterns in `collectionUpdatePatterns`.
* **Rebuild outdated apps** - refills `outdatedAppsCollectionName` with clients running a
  version older than the one deployed as required (SQL based).
* **Role collection membership** - adds or removes a role collection (`rol-dev-*`) as an
  include rule of the application collections (`ins-*`).
* **Switch ConfigMgr site** - work against another site of the `sites` list.
* **Add ConfigMgr site** - the setup assistant described above.
* **Check site configuration** - tests provider, package share, console module, SQL and the
  collections of the active site and prints a report.

## Logos

`Logos\<App>.png` becomes the icon of the ConfigMgr application, scaled down to 250x250 if
needed. A file named exactly like the `Name` column always wins; beyond that the tool falls
back in this order:

1. the name without a bracketed suffix or trailing version - `7-Zip.png` covers
   `7-Zip 26.02 (x64 edition)` and `Notepad++.png` covers `Notepad++ (x64)`
2. the longest logo name that is a prefix of the app name
3. the longest logo name that starts with the app name - `Oracle_Database_Client.png` covers
   `Oracle`

Only spaces and underscores count as a boundary, so `PDF` never picks up
`PDF-XChange Editor.png`. Without a match, `defaultlogo.png` is used.

## Tests

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Tests\Test-Dialogs.ps1
```

Starts the tool and operates it from a second process through UI Automation:
presses the tiles, checks the dialog behind each one, and cancels back out. Nothing is
created, published or downloaded - every path ends on Cancel. It does need a reachable site,
because the package list asks ConfigMgr for its status column.

Two constraints shaped the dialogs and are worth keeping in mind when adding one:

* **Address a window by its `AutomationId`, not its title.** WPF derives a window's automation
  name from its content, so a window whose content is a single control reports that control's
  name instead of the caption.
* **Use `Show-MessageDialog`, not `[System.Windows.MessageBox]`.** A Win32 control is driven by
  posting it a window message, and User Interface Privilege Isolation blocks that across
  processes - its buttons advertise the Invoke pattern and then throw when it is used. A
  MessageBox in the middle of a workflow makes that workflow impossible to test.

## Notes

`STATUS.md` records what has been tested where, which items are still open and which design
decisions are already settled - start there when picking the project up again.

Author: alexander@zarenko.net - https://blog.zarenko.net
