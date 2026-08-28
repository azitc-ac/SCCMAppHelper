# Project status

Working document for picking the project up again - in a new session, on another machine, or
after a break. `README.md` describes how the tool works; this file records **where it stands,
what has actually been tested, and which decisions are already settled**.

Last updated: 2026-08-28

## Where it stands

Version 1.0, feature complete for the intended workflow: master list -> PSADT package ->
ConfigMgr application including collections, deployments, content distribution and
supersedence, plus a setup assistant and the collection maintenance tools.

The tool was written from scratch on 2026-08-27/28 as the ConfigMgr counterpart to
`IntuneWin32Helper`, replacing the older scripts under `Powershell\SCCM`
(`create-AppsInCM.ps1`, `add-NewMSIToAppsCSV.ps1`, `create-CollForOutdatedApps.ps1`,
`add-ServerRoleToAppCollections.ps1`, `update-ins.req.dev.cols.ps1`).

## Test status

This matters most: the ConfigMgr layer has never been executed by the author of the code.

### Verified locally (Windows PowerShell 5.1, no ConfigMgr, no PSADT installed)

* every script parses
* detection scripts run against the real registry - hit, too-old version and absent app all
  produce the correct ConfigMgr semantics (exit 0 plus output only when detected), including
  app names containing `+` and brackets
* all WPF dialogs build and run under STA
* `Apps.csv` schema upgrade from the legacy three column file, idempotent
* settings round trip, command injection into the PSADT script
* multi-site resolution: single site, `activeSite`, session override, legacy flat config
* console folder path resolution, all nine variants
* logo fallback chain including the false positive probes
* import of packages built outside the tool: flat layout, with and without
  `SupportFiles\logo.png`, with and without an `Apps.csv` row
* metadata model: normal package and zero-config MSI package against a real MSI, `$adtSession`
  parsing with single and double quotes

### Reported working on cm1 by Alex

* setup assistant: discovery and the dialog sequence

### Never executed anywhere

Everything from `Import-Module ConfigurationManager` onwards. The cmdlet calls follow the
documentation and the old scripts, but parameter sets differ between ConfigMgr versions, so
this is where the remaining bugs are expected:

`New-CMApplication`, `Add-CMScriptDeploymentType`, `Set-CMScriptDeploymentType`,
`Start-CMContentDistribution`, `Update-CMDistributionPoint`, `New-CMDeviceCollection`,
`New-CMApplicationDeployment`, `Get-CMApplicationDeployment`,
`Add-CMDeploymentTypeSupersedence`, `Move-CMObject`, `New-CMFolderPath`,
`Get-CMDistributionTarget`, `Get-CMDefaultLimitingCollection`, the SQL query behind
`Update-OutdatedAppsCollection`, and `Edit-RoleCollectionMembership`.

`New-ADTTemplate` has also never run here - PSADT is not installed on the development
machine, so package creation was always tested against a faked PSADT folder.

## Open items

* **Retire workflow** - removing an outdated application version from ConfigMgr cleanly:
  application, its `ins-req-dev-*` / `ins-avl-dev-*` collections, its deployments and
  optionally the package folder. Deliberately left out because it is destructive. When
  building it, mirror `deployApps`: select from the existing applications, show exactly what
  will be deleted, confirm before removing anything.
* **Verification pass on cm1** for the cmdlet list above.
* Packages created before 2026-08-28 may still contain a leftover `_Helper\package.json`.
  It is ignored; it can be deleted.

## Settled decisions

Do not re-litigate these without a reason.

* **`dev` in collection names means device collection**, not a deployment ring. There is no
  dev/test/prod staging. The prefixes encode purpose: `ins-req` install required, `ins-avl`
  install available, `rol` role, `flt` filter.
* **No separate metadata file.** A package describes itself: name and version from the folder
  name, publisher and author from `$adtSession` in `Invoke-AppDeployToolkit.ps1`, detection
  from the rendered `_Helper\detection.ps1`. `package.json` was removed on 2026-08-28.
* **MSI packages keep their PSADT metadata empty** on purpose, so PSADT runs its zero-config
  MSI deployment. Publisher and ProductCode are read from the single MSI in `.\Files`.
* **The folder name is authoritative** for name and version - it is the naming convention the
  whole workflow rests on and it is what the ConfigMgr application is named after.
* **`deploy.ps1` inside a package stays thin.** All logic lives in the tool, so fixes reach
  packages created earlier.
* **Detection scripts write to STDOUT only when the application is detected.** The old
  `detection_v3.ps1` always wrote output, which made ConfigMgr consider every app installed.
* Environment specific values belong in `sites[]` of `config.json`, conventions belong in the
  shared keys next to it.

## Environments

| | Site | Server | Notes |
| --- | --- | --- | --- |
| Production | CCL | VMSCCM | packages under `\\VMSCCM\Sources\Applications` |
| Lab | discovered by the assistant | cm1.home.local | test system, tool runs on the server itself |

## Working agreements

* **Commit and push to `main` after every change**, without asking - the ConfigMgr server
  pulls from `azitc-ac/SCCMAppHelper` (private), so unpushed changes mean testing a stale
  version there.
* When working on the server: **cm1 only**, never directly on VMSCCM.
* First publish run on a new site with `distributeContent: false` and
  `createDeployments: false` - that creates only the application and its deployment type and
  reaches no client. Switch them on afterwards, step by step.
* Ask before anything that creates deployments or modifies existing ConfigMgr objects.
  Creating is cheap, a deployment has an effect on real machines.
* The tool needs Windows PowerShell 5.1 (`powershell.exe`), not pwsh 7 - the
  ConfigurationManager module requires it.
