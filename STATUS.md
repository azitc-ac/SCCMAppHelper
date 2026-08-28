# Project status

Working document for picking the project up again - in a new session, on another machine, or
after a break. `README.md` describes how the tool works; this file records **where it stands,
what has actually been tested, and which decisions are already settled**.

Last updated: 2026-08-28 (first run against a real site)

## Where it stands

Version 1.0, feature complete for the intended workflow: master list -> PSADT package ->
ConfigMgr application including collections, deployments, content distribution and
supersedence, plus a setup assistant and the collection maintenance tools.

The tool was written from scratch on 2026-08-27/28 as the ConfigMgr counterpart to
`IntuneWin32Helper`, replacing the older scripts under `Powershell\SCCM`
(`create-AppsInCM.ps1`, `add-NewMSIToAppsCSV.ps1`, `create-CollForOutdatedApps.ps1`,
`add-ServerRoleToAppCollections.ps1`, `update-ins.req.dev.cols.ps1`).

## Test status

The ConfigMgr layer has now been run against a real site. Everything in the AZI section below
was executed on the lab site on CM1 on 2026-08-28, under Windows PowerShell 5.1 with the
ConfigMgr console module and PSAppDeployToolkit 4.0.6.

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

### Verified on the AZI lab site (CM1, 2026-08-28)

Test application `SCCMAppHelper Testapp` in versions `1.0.0` and `2.0.0`, both rows added to
`Apps.csv`. First run with `distributeContent` and `createDeployments` off as the working
agreement prescribes, then both switched on and the run repeated. Every step was repeated at
least once to check idempotency.

* `New-ADTTemplate` against the real PSADT 4.0.6 - package folder, log path patch and
  metadata all as expected
* `New-CMApplication` including `IconLocationFile` - the icon ends up in the `SDMPackageXML`
* `Add-CMScriptDeploymentType`, and `Set-CMScriptDeploymentType` on the second run - install
  and uninstall command line, content location, `MaxExecuteTime` 120, `ExecuteTime` 15,
  execution context System, detection script as `ScriptType` 0 with 3387 characters
* `New-CMDeviceCollection` with `New-CMSchedule`, plus `Move-CMObject` and `New-CMFolderPath`
  into `collectionFolderPath` - both collections sit in `Deployment\Software`. Confirm this
  through `SMS_ObjectContainerItem`, not through the provider path: `Get-ChildItem` on
  `AZI:\DeviceCollection\Deployment\Software` does not list them even when they are there.
* `Start-CMContentDistribution` and `Update-CMDistributionPoint` - content for both test
  applications is on `\\CM1.home.local`, confirmed through `SMS_DPContentInfo`
* `New-CMApplicationDeployment` and `Get-CMApplicationDeployment` - Required and Available
  deployment on the two test collections, reported as already existing on the second run
* `Set-CMApplicationSupersedence` - exactly one `DeploymentTypeRule` on 2.0.0 pointing at the
  deployment type of 1.0.0, still exactly one after a repeat run. The cmdlet replaces the rule
  instead of updating it, so the `DTRule_<guid>` id changes on every call and every publish
  bumps the application revision even when nothing else changed - idempotent in effect, not in
  the stored id
* the generated `_Helper\deploy.ps1` run standalone with `-bulk`
* `Get-AppPackage` against the real share - the two tool packages as `Ready`, the packages
  built with the older scripts as `Not imported yet`
* `Update-AppCollections` - `Invoke-CMCollectionUpdate` over all 25 collections matching
  `ins-req-dev-*`, `flt-dev-*` and `rol-dev-*`
* `Update-OutdatedAppsCollection` - the SQL query runs against `CM_AZI`. The joins and the
  `OUTER APPLY` name match were checked separately: 14 of 16 client/application pairs resolve
  to an installed product, including `7-Zip 26.00 (x64 edition)` against `7-Zip`. Zero
  outdated clients is the correct answer here, not a broken query. The run created
  `flt-dev--Veraltete Apps`.
* the ConfigMgr cmdlets of `Edit-RoleCollectionMembership` - `Get-CMCollection` over the role
  and application patterns, `Get-`/`Add-`/`Remove-CMDeviceCollectionIncludeMembershipRule`,
  added against a test collection and removed again
* `supersedenceUninstall` does reach the rule. `-IsUninstall` is a `[bool]` parameter, not a
  switch, and it surfaces as the `Changeable` attribute of `DeploymentTypeReference` inside
  `<Supersedes>` - `$true` writes `Changeable="true"`, `$false` writes `Changeable="false"`.
  Measured on 2.0.0 as three consecutive states (baseline, `$false`, `$true`). An earlier note
  here claimed both values produce identical XML - that was a measurement error, the code in
  `Add-CMApplicationSupersedenceForOlderVersions` is correct.

`Get-CMDistributionTarget` was listed here as an untested ConfigMgr cmdlet. It is not one -
it is the tool's own function in `Functions\setup.ps1`.

### What the run changed in the code

* `check-prereqs` used `Get-InstalledModule`, which needs PowerShellGet and only reports
  modules installed through it. Started from a pwsh 7 terminal, Windows PowerShell inherits a
  `PSModulePath` containing the PowerShell 7 WindowsApps folder, PowerShellGet then fails to
  load, PSAppDeployToolkit is reported as missing and `Install-Module` hangs on the NuGet
  provider prompt - the tool never reaches the start dialog. Now `Get-Module -ListAvailable`.
* `Add-CMDeploymentTypeSupersedence` dumped the whole application object including the base64
  icon into the console and the transcript, is deprecated, and is not idempotent: every
  publish appended another identical rule. Replaced by `Set-CMApplicationSupersedence`.
* The remaining action cmdlets now get `$null =` for the same reason.
* The content branch decided between distributing and refreshing by asking whether the
  deployment type already existed. A package first published with `distributeContent` off -
  exactly what the working agreement prescribes - therefore never got its content: the
  existing deployment type sent it into `Update-CMDistributionPoint`, which only refreshes
  what is already assigned, and the deployments then failed with "There are no distribution
  points or distribution point groups in this application". Now `Start-CMContentDistribution`
  is always tried first and the refresh is the fallback.

### Still open on a real site

* The WPF selection dialogs were not driven end to end. The run called `New-AppPackage` and
  `Publish-CMApplication` directly, which is the code path `createApps` and `deployApps` use
  once a selection has been made. The start dialog itself came up correctly with the site in
  its title bar.
* `Edit-RoleCollectionMembership` was verified cmdlet by cmdlet, not through its dialogs.
* Publishing a package built with the older scripts (`Not imported yet`) was not tried,
  because each of them belongs to an application that already exists in the site.

## Open items

* **Retire workflow** - removing an outdated application version from ConfigMgr cleanly:
  application, its `ins-req-dev-*` / `ins-avl-dev-*` collections, its deployments and
  optionally the package folder. Deliberately left out because it is destructive. When
  building it, mirror `deployApps`: select from the existing applications, show exactly what
  will be deleted, confirm before removing anything.
* **Clean up the lab.** `SCCMAppHelper Testapp - 1.0.0` and `- 2.0.0`, their four `ins-*`
  collections, their deployments, the two `Apps.csv` rows and the two package folders under
  `C:\Sources\Applications` are still on AZI - they are the evidence for the run above.
  Removing them is exactly the case the retire workflow is for.
* `distributeContent` and `createDeployments` are back to `true` in `config.json` after the
  staged run. Set them to `false` again before the first publish against another new site.
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
| Lab | AZI | cm1.home.local | test system, tool runs on the server itself, packages under `C:\Sources\Applications`, single DP `CM1.home.local`, collection folder `Deployment\Software` |

`ins-avl-dev-ALLE APPS` from `globalDeployments` does not exist on AZI - the publish run skips
it with a warning, which is the intended behaviour for a collection that is not there.

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
