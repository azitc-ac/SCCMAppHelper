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
| **New from catalog** | Downloads an installer from the winget-pkgs manifests and adds it to `Apps.csv` |
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
| `InstallCmd` | Optional PSADT code inserted into the install section |
| `UninstallCmd` | Optional PSADT code inserted into the uninstall section |
| `Notes` | Free text, used as the application description |

Only `Publisher`, `Name` and `Version` are required - an older three column `apps.csv` is
upgraded automatically on first use.

In the app list dialog, **New** / **Duplicate** / **Edit** open an editor with two prefill
buttons:

* **From MSI...** reads ProductName, ProductVersion, Manufacturer and ProductCode from an
  MSI and switches the detection to `MSI`.
* **From EXE...** reads the version resource of a setup EXE.

That replaces `add-NewMSIToAppsCSV.ps1` and keeps the naming unambiguous.

## New from catalog

Fetches the usual suspects without hunting for a download link. The source is the manifest
repository behind winget, [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs),
read directly over HTTPS - the `winget` client itself is **not** used, because it is a per
user MSIX and is missing on Windows Server 2022.

1. **Pick** from `Config\catalog.json`, or search the repository for anything else.
2. **Resolve** the newest version, and say which versions of it `Apps.csv` already holds.
3. **Confirm** - the dialog names the installer, the URL and the SHA256. Nothing is
   downloaded before this.
4. **Download** into `<sourceRoot>\_DL\<Name> - <Version>\`, checked against the hash in the
   manifest. A file that does not match is deleted.
5. **Read** the file the same way the **From MSI...** button does, and report its Authenticode
   signer.
6. **Check** the finished row in the usual editor, then it goes into `Apps.csv`.

Where a manifest offers several installers, an MSI wins over an EXE: it carries a ProductCode,
which means native detection and PSADT's zero-config MSI deployment, so nothing has to be
maintained by hand. For an EXE the uninstall key comes from `AppsAndFeaturesEntries` in the
manifest - for 7-Zip that is literally `7-Zip`, which is exactly what `DetectionPattern`
wants.

The flow deliberately stops there. Packaging and publishing stay with **Create packages** and
**Publish packages**; the download waits in `_DL` under the same `<Name> - <Version>` name the
package folder will have.

Nothing that is downloaded is ever executed. GitHub allows 60 unauthenticated API requests an
hour, which is why the curated list stores the package id - resolving a version from it costs
a single request.

## Package layout

```
<sourceRoot>\<Name> - <Version>\
    Content\                     <- PSADT v4 root, this is the ConfigMgr content location
        Invoke-AppDeployToolkit.ps1
        Files\
        Config\config.psd1       <- log path patched to psadtLogPath
        SupportFiles\
            detection.ps1        <- optional, only for DetectionMethod = Script
            logo.png             <- optional, wins over Logos\
```
A package holds its PSADT content and nothing else. The application icon and,
where one is needed, the detection script are rendered into a temporary folder
at publish time and removed again afterwards - so a fix in the tool reaches
packages built with an earlier version without touching them.

Legacy packages whose PSADT root is the package folder itself are detected and handled as
well (`packageLayout = Flat`).

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
| `collections` | Collections created per application, `{App}` is replaced by `Name - Version` |
| `globalDeployments` | Deployments to existing collections, e.g. an "all apps" catalog collection |
| `supersedeOlderVersions` | Wire the new application as superseding older versions of the same product |
| `supersedenceUninstall` | Uninstall the old version when superseding |
| `distributeContent`, `createDeployments` | Switch off to only create the application |
| `openExplorerOnCreate`, `openEditorOnCreate` | Interactive steps during packaging |
| `packageAuthor` | Author written into the PSADT script, empty = current user |

Everything is idempotent: existing applications get their deployment type and detection
updated plus a content refresh, existing collections and deployments are reused.

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
