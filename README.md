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

Windows PowerShell 5.1 with the ConfigMgr console installed. The start dialog offers:

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
| `DetectionMethod` | `Registry` (default), `MSI`, `File` or `Custom` |
| `DetectionPattern` | `Registry`: DisplayName pattern (default `Name*`) - `File`: full path of the file to check |
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

## Package layout

```
<sourceRoot>\<Name> - <Version>\
    Content\                     <- PSADT v4 root, this is the ConfigMgr content location
        Invoke-AppDeployToolkit.ps1
        Files\
        Config\config.psd1       <- log path patched to psadtLogPath
    _Helper\                     <- tool files, not part of the content
        deploy.ps1               <- publishes this package to ConfigMgr
        detection.ps1            <- generated detection script
        logo.png                 <- application icon, resized to max. 250x250
        package.json             <- package metadata
```

Legacy packages whose PSADT root is the package folder itself are detected and handled as
well (`packageLayout = Flat`).

`deploy.ps1` is intentionally thin: it only calls `Publish-CMApplication` from the tool, so
fixes in the tool also apply to packages created earlier.

## Detection scripts

ConfigMgr script detection evaluates:

| Result | Meaning |
| --- | --- |
| exit code 0 + output on STDOUT | application **is** installed |
| exit code 0 + no output | application is **not** installed |
| exit code <> 0 | detection failed |

All templates in `Templates\` follow that contract - they only write to STDOUT when the
application really is detected, and they log every decision to `psadtLogPath`.

`DetectionMethod = Custom` keeps an existing `_Helper\detection.ps1` untouched, so hand
written detection logic survives a re-run.

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
| `applicationFolderPath`, `collectionFolderPath` | Optional console folders, with or without the site drive: `Application\Apps` is expanded to `<siteCode>:\Application\Apps` |

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

## Notes

Author: alexander@zarenko.net - https://blog.zarenko.net
