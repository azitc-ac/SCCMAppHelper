# Project status

Working document for picking the project up again - in a new session, on another machine, or
after a break. `README.md` describes how the tool works; this file records **where it stands,
what has actually been tested, and which decisions are already settled**.

Last updated: 2026-08-29 (the dialogs driven through UI Automation)

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

### Verified on the AZI lab site (CM1, 2026-08-28, native detection)

Second run, after detection moved from a PowerShell script to native ConfigMgr clauses and
the `_Helper` folder was removed. Test applications `SCCMAppHelper Testapp - 3.0.0`, `4.0.0`
and `5.0.0`, all with `DetectionMethod = Registry`, `distributeContent` and
`createDeployments` off.

* `New-CMDetectionClauseRegistryKeyValue` twice per application, 64 bit and 32 bit view -
  key, `DisplayVersion`, `Is64Bit` and the `GreaterEquals` constant all as expected in the
  `SDMPackageXML`
* `-Comment` on `Add-`/`Set-CMScriptDeploymentType` carries `SCCMAppHelper 1.0` and comes
  back as `LocalizedDescription` - that is the tool signature, since a native clause has no
  script that could hold one
* `Get-AppPackage` against the real site: the five test applications as
  `Published (this tool)`, the applications from the older scripts as `Published (foreign)`,
  `Oracle-19c` as `Not published` because its folder name does not follow `<Name> - <Version>`
* three publishes of `5.0.0` in a row leave the deployment type at 2 settings, 2 rule
  references and operator `Or`; the second and third report `Detection unchanged`
* the package folder holds nothing but `Content`, and the temporary artifact folder below
  `%TEMP%` is gone afterwards

### Verified against the manifest repository (2026-08-28)

**New from catalog** reads https://github.com/microsoft/winget-pkgs over HTTPS. The `winget`
client is deliberately not used - it is a per user MSIX and is missing on Windows Server 2022,
which is a supported target.

* the hand written YAML reader against the real `7zip.7zip` 26.02 installer manifest: all six
  installers, all keys, including the nested `InstallerSwitches`, `AppsAndFeaturesEntries` and
  `InstallationMetadata` maps
* manifest path derivation for `7zip.7zip`, `Google.Chrome`, `Notepad++.Notepad++` and the
  four part `Adobe.Acrobat.Reader.64-bit`
* version listing and descending sort - 26.02 ahead of 26.01, 26.00, 25.01
* installer ranking picks x64 `wix` over x64 `exe`, which is what makes the row come out as
  `DetectionMethod = MSI` with the ProductCode instead of a registry lookup
* the row built from manifest plus installer: `Igor Pavlov / 7-Zip / MSI /
  {23170F69-40C1-2702-2602-000001000000}`
* the EXE variant of the same manifest carries `ProductCode: 7-Zip` - the uninstall key the
  native registry detection needs, so the EXE case usually needs no guessing either
* a real download: `7z2602-x64.msi`, 1.9 MB, into `C:\Sources\Applications\_DL\7-Zip - 26.02\`.
  The SHA256 matches the manifest, and the MSI reads back as `7-Zip 26.02 (x64 edition) /
  26.02.00.0 / Igor Pavlov / {23170F69-40C1-2702-2602-000001000000}` - the same ProductCode the
  manifest states.
* the hash check was tested from the failing side too: the same download with a wrong expected
  hash is rejected and the file deleted, nothing left behind
* `Find-CatalogPackage` for `notepad`: `Notepad++.Notepad++` and `Notepad2mod.Notepad2mod`, 2.9
  seconds
* **the 7-Zip MSI is not Authenticode signed** (`NotSigned`). The very first package tried is
  already one where enforcing a signature would have blocked a legitimate download - reporting
  the signer and leaving the decision to the person at the dialog is the right call, and the
  warning does fire.

### The whole chain, end to end (AZI, 2026-08-28)

`7-Zip - 26.02.00.0` was carried from the catalog download all the way into the site: row into
`Apps.csv`, package created, MSI copied into `Content\Files`, published twice. This is the
first real application the tool created - everything before it was a `SCCMAppHelper Testapp`.
`distributeContent` and `createDeployments` were off, so nothing reached a client.

* **the native MSI clause**, which had never been published before: one rule,
  `SettingSourceType = MSI`, `PropertyPath = ProductVersion`, `Method = Value`,
  `GreaterEquals`, constant `26.02.00.0` as `Version`. No registry lookup reproducing what the
  ProductCode already says.
* the deployment type comment reads `SCCMAppHelper 1.0`, so `Get-AppPackage` reports the new
  application as `Published (this tool)` while `7-Zip - 24.9.0.0` and `- 26.00.00.0` stay
  `Published (foreign)` - the status column doing its job on real data rather than on test
  objects
* **supersedence stayed at exactly two rules after two publishes**, one for each older version,
  both `Changeable="true"` from `supersedenceUninstall`. That is the case the earlier
  `Add-CMDeploymentTypeSupersedence` got wrong.
* the detection was left alone on the second pass (`Detection unchanged`), so the clause
  stacking cannot happen here either
* zero-config PSADT held: `AppVendor`, `AppName` and `AppVersion` are empty in
  `Invoke-AppDeployToolkit.ps1`, only the author is stamped, and the single MSI sits in
  `Content\Files`
* the logo fallback picked `Logos\7-Zip.png` for the app named `7-Zip`
* the package folder contains `Content` and nothing else

### File detection: `Notepad++ - 8.9.8` (AZI, 2026-08-28)

Taken from the catalog the same way, but deliberately with the x64 `nullsoft` installer rather
than the MSI: no ProductCode, so detecting the installed file is the natural choice. Detection
was set to `File` with `%ProgramFiles%\Notepad++\notepad++.exe`, the silent switch went into
`InstallCmd`, and `distributeContent` / `createDeployments` stayed off.

* `New-CMDetectionClauseFile` and the `Path` / `FileName` split of `DetectionPattern`:
  `<Path>%ProgramFiles%\Notepad++</Path><Filter>notepad++.exe</Filter>`, compared as
  `Version GreaterEquals 8.9.8`. The environment variable survives into the clause.
* `Insert-Commands` put both PSADT calls into the script, and the metadata was filled in
  rather than left empty - this is not a zero-config MSI package
* the logo fallback picked `Logos\Notepad++.png` for an application whose name contains `++`
* the **"Detection differs" branch**, which had never run: after the `Is64Bit` fix the
  republish reported `Detection differs from the 1 rule(s) - replacing it` and ended at exactly
  2 settings, 2 rule references and operator `Or`. The replacement was clean, and the
  verification afterwards found nothing to complain about.

**Two bugs this run found**, both invisible without publishing for real:

* The version came out as `8.98`. `ConvertTo-CatalogAppRow` preferred the version resource of
  the downloaded file over the manifest, which is right for an MSI - it states what it will
  register - but wrong for an EXE installer, where the resource describes the installer and is
  regularly malformed. As a `[version]`, `8.98` sorts *above* `8.9.8`, so this would have
  poisoned the application name, the detection constant and the supersedence at once. The
  manifest now wins for anything that is not an MSI.
* The file clause was written with `Is64Bit="false"`, the 32 bit view, so the client would have
  resolved `%ProgramFiles%` to `Program Files (x86)` and never found an x64 application. Same
  class of mistake as the two registry views, just not carried over to files. A path containing
  an environment variable now gets both views connected with `Or`; a literal path still gets a
  single clause, because there is nothing left to redirect.

### The dialogs, driven for real (2026-08-29)

Every WPF dialog here had only ever been reasoned about; the runs called the functions behind
them. That is closed now, because the start menu tiles became real controls.

They used to be `Border` elements with one `PreviewMouseLeftButtonUp` handler on the container
that walked the visual tree to work out which card was hit. That answers a mouse and nothing
else: no Tab focus, no Space to press, nothing for a screen reader, and no way to drive the
dialog except by moving a pointer. They are `Button`s now with a `ControlTemplate` that keeps
the card look, each carrying its return value as `AutomationId`; `Open-SelectDialog` and
`Show-CatalogDialog` got ids on their grids, search box and buttons.

Driven from a second process through `System.Windows.Automation`:

* the start dialog comes up, all five tiles are found by id and report `invokable=True` and
  `IsKeyboardFocusable=True` - the keyboard part is new, a `Border` could never do it
* pressing **Publish packages** produces the selection dialog with 25 rows carrying the real
  status column (`7-Zip 26.02.00.0 -> Published (this tool)`, `26.00.00.0 -> Published
  (foreign)`), so `deployApps` was exercised through its dialog rather than around it
* cancelling returns to the start dialog, and cancelling that ends the tool cleanly

Match windows on their `AutomationId`, not their title: WPF derives a window's automation name
from its content, and a window whose content is a single control reports that control's name.

### The dialogs have a test now (2026-08-29)

`Tests\Test-Dialogs.ps1` starts the tool and drives it from a second process. 40 assertions,
all passing: the start dialog and its five tiles, **Publish packages** through the selection
dialog with its status column, **Create packages** through the app list, the record editor
with all nine columns, and the message dialog. Every path ends on Cancel, so the test creates
nothing.

Two things had to change before that was possible, and both are improvements in their own
right rather than test scaffolding:

* The tiles were `Border`s with one mouse handler on the container. They are `Button`s with a
  `ControlTemplate` now - same card look, plus Tab focus, Space to press and a name for a
  screen reader, none of which a `Border` can do.
* `[System.Windows.MessageBox]` had to go. A Win32 control is invoked by posting it a window
  message, and User Interface Privilege Isolation blocks that across processes: the button
  advertises the Invoke pattern, reports `IsEnabled = True`, and then throws
  "Operation is not valid due to the current state of the object". `SendKeys` is refused as
  well. All 17 call sites now use `Show-MessageDialog`, a WPF window whose automation peer runs
  inside the owning process.

The record editor was rebuilt at the same time: label and value share a row instead of
stacking, which is what made a nine column record run past the bottom of the screen.

### The catalog is a record source, not a tile (2026-08-29)

**New from catalog** was a fifth tile on the start menu. It sat at the wrong level: the other
tiles run a workflow over a selection, while the catalog produces one row of the master list -
which is what `New`, `Duplicate` and `Edit` already do. It is now **From catalog...** in the
record editor, the third button next to **From MSI...** and **From EXE...**, and the three are
the same pattern: three sources, one record. `Read-CatalogPackage` returns the record and
writes nothing; the editor's OK does the writing, like it does for every other row. As a side
effect the catalog can now lift an existing row onto a newer version, which the tile could not.

`Tests\Test-Dialogs.ps1` runs the whole thing, download included: 55 assertions, all passing.
Picking PuTTY writes `Simon Tatham / PuTTY / 0.84.0.0 / MSI /
{FEE89B49-1A47-476C-864C-1D5076FC2891}` into `Apps.csv` and leaves the MSI in
`_DL\PuTTY - 0.84.0.0\`.

**19 of the 20 catalog ids were checked against the repository and resolve.** The twentieth,
`TimKosse.FileZilla.Client`, was guessed and does not exist - there is no such publisher under
`manifests/t`, and nothing FileZilla shaped under `manifests/f` either. The entry was removed
rather than guessed at again.

Two defects in the catalog came out of looking for it:

* `Get-CatalogDirectory` read one page. The contents API returns at most 100 entries and then
  simply stops - no error, no marker - so any listing of a busy letter described a fraction of
  the tree and every search over it quietly missed things. It pages through now.
* The search can only ever match publishers, because that is how the repository is organised.
  Searching for a product whose vendor is named differently cannot work by walking the tree,
  and walking all of it is out of the question at 60 requests an hour. A query that looks like
  a package id is now resolved directly instead, and the limitation is written down in both
  the function and the README rather than left to be rediscovered.

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
* `-DetectionClauseConnector` together with `-GroupDetectionClauses` does not work. It is what
  the documentation suggests, it raises no error, and it silently leaves the rule operator at
  `And` - which for the 64 bit and the 32 bit registry view would mean the key had to exist in
  both at once, so nothing would ever be detected. The connector belongs on the clause object:
  set `Connector` to `Or` on each clause.
* Detection clauses are only ever added, and removing them is unreliable. Re-applying the same
  clauses on every publish stacks another copy on top and the rule ends up referencing all of
  them - measured on `3.0.0`, two more rules per publish, up to 14.
  `Set-CMScriptDeploymentType -RemoveDetectionClause` sometimes reports a clause as "not found"
  and silently leaves it in place: in the `4.0.0` experiment neither of the two clauses created
  together with the deployment type could be removed, while clauses added by a later `Set-` call
  went away. On `Notepad++ - 8.9.8` the same operation worked - one clause created with the
  deployment type was replaced cleanly by two. What separates the two cases was not pinned
  down; a plausible reading is that the pool there already held clauses identical in
  everything but their logical name. Treat removal as "usually works, sometimes silently does
  not".
  The tool therefore compares the detection first and only touches it when it really differs,
  and verifies the rule count afterwards instead of trusting the call. Do not try to fix this
  with a `-ScriptText` reset - that switches the detection method but leaves the clause pool
  untouched.
* `Get-CMDeploymentTypeDetectionClause` has been seen disagreeing with the `SDMPackageXML`
  (0 clauses reported where the XML held 8). The rule of the enhanced detection method is the
  ground truth; a mismatch between the two is treated as "not what we want".
* The content branch decided between distributing and refreshing by asking whether the
  deployment type already existed. A package first published with `distributeContent` off -
  exactly what the working agreement prescribes - therefore never got its content: the
  existing deployment type sent it into `Update-CMDistributionPoint`, which only refreshes
  what is already assigned, and the deployments then failed with "There are no distribution
  points or distribution point groups in this application". Now `Start-CMContentDistribution`
  is always tried first and the refresh is the fallback.

### Still open on a real site

* `Edit-RoleCollectionMembership` was verified cmdlet by cmdlet, not through its dialogs.
* The confirmation boxes of `newFromCatalog` were not driven. `Show-CatalogDialog` now carries
  automation ids, but the `MessageBox` prompts in front of the download are Win32 dialogs
  rather than WPF, so they need a different handle.
* `catalog.json` holds 20 package ids and only `7zip.7zip` and `Notepad++.Notepad++` were
  confirmed against the repository. A wrong id fails with "Not found in the manifest
  repository" and is a one line fix, but they are not verified.
* **A pure winget path is missing.** Everything here downloads a fixed version and deploys it
  the traditional way. `IntuneWin32Helper` can also build version independent packages that
  call winget on the client and install whatever is current; the same is wanted here. Two
  things will need solving: winget in the **SYSTEM context** - `winget.exe` is a per user MSIX
  alias and is not on SYSTEM's PATH, so the real binary under
  `C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\` has to be
  resolved - and detection, which cannot compare a version it does not know in advance. That
  is exactly what `DetectionMethod = Script` is for.
* `Registry`, `MSI` and `File` are all verified against the site. `Script` is the only
  detection method that has not been run since the rewrite - what is untested there is the
  `CustomSource` branch reading `Content\SupportFiles\detection.ps1` and the signature header
  it prepends.
* None of the published applications was ever installed on a client, so no detection has been
  observed *evaluating*. What is verified is the clause ConfigMgr stores, not that it matches
  the product once it is on a machine. The `Is64Bit` bug is the reminder: the clause looked
  right and would still have found nothing.
* Publishing a package built with the older scripts (`Published (foreign)`) was not tried,
  because each of them belongs to an application that already exists in the site. That is now
  the interesting case: such an application has a script or clause detection the tool did not
  write, and the clause replacement is exactly what cannot be done reliably. Expect the
  "Detection differs" warning and the verification afterwards to fire.

## Open items

* **Retire workflow** - removing an outdated application version from ConfigMgr cleanly:
  application, its `ins-req-dev-*` / `ins-avl-dev-*` collections, its deployments and
  optionally the package folder. Deliberately left out because it is destructive. When
  building it, mirror `deployApps`: select from the existing applications, show exactly what
  will be deleted, confirm before removing anything.
* **Clean up the lab.** `SCCMAppHelper Testapp` in `1.0.0`, `2.0.0`, `3.0.0`, `4.0.0` and
  `5.0.0`, their `ins-*` collections, the deployments of 1.0.0 and 2.0.0, the five `Apps.csv`
  rows and the five package folders under `C:\Sources\Applications` are still on AZI - they
  are the evidence for the runs above. Removing them is exactly the case the retire workflow
  is for. Note that `3.0.0` (14 rules) and `4.0.0` (4 rules) carry deliberately stacked
  detection from the clause experiments; `5.0.0` is the clean one.
* **`Notepad++ - 8.9.8` is real too**, same situation as 7-Zip below: application, two `ins-*`
  collections, package, `Apps.csv` row and the download in `_DL\Notepad++ - 8.9.8\`. No content,
  no deployment. The site had no Notepad++ before, so nothing is superseded.
* **`7-Zip - 26.02.00.0` is real, not a test object.** The catalog run created the application,
  its two `ins-*` collections, the package under `C:\Sources\Applications\7-Zip - 26.02.00.0`,
  the `Apps.csv` row and the download in `_DL\7-Zip - 26.02\`. It has no content on any
  distribution point and no deployment, and it supersedes `26.00.00.0` and `24.9.0.0`. Decide
  whether it stays: it is a genuinely newer version than what the site holds, so finishing it
  is a matter of switching `distributeContent` and `createDeployments` on and publishing again.
  It should not be swept up by the lab cleanup.
* `distributeContent` and `createDeployments` are `false` in `config.json` - that is where the
  working agreement wants them before a first publish against a new site. Switch them on
  again for a real run.
* Packages created before 2026-08-28 may still contain a leftover `_Helper` folder. It is
  ignored; it can be deleted.

## Settled decisions

Do not re-litigate these without a reason.

* **`dev` in collection names means device collection**, not a deployment ring. There is no
  dev/test/prod staging. The prefixes encode purpose: `ins-req` install required, `ins-avl`
  install available, `rol` role, `flt` filter.
* **No separate metadata file, and nothing beside the content.** A package describes itself:
  name and version from the folder name, publisher and author from `$adtSession` in
  `Invoke-AppDeployToolkit.ps1`, detection from its `Apps.csv` row. `package.json` was removed
  on 2026-08-28, the `_Helper` folder with it - the icon and, for `DetectionMethod = Script`,
  the detection script are rendered into `%TEMP%` at publish time and removed again. That is
  what kept `deploy.ps1` thin, and it now applies to everything.
* **Detection is native wherever ConfigMgr can evaluate it itself** - MSI by ProductCode,
  Registry by an exact uninstall key, File by path. A script is only for the hard nuts, and it
  lives in `Content\SupportFiles\detection.ps1` so it travels with the package. Script
  detection was the default until 2026-08-28 and proved unreliable, and it reproduced an MSI
  ProductCode through a registry lookup for no reason.
* **The tool signature lives in the deployment type comment** (`SCCMAppHelper <version>`).
  It used to sit in the header of the generated detection script, which stops working the
  moment detection is a native clause. `Get-AppPackage` reads it back to tell
  `Published (this tool)` from `Published (foreign)`.
* **MSI packages keep their PSADT metadata empty** on purpose, so PSADT runs its zero-config
  MSI deployment. Publisher and ProductCode are read from the single MSI in `.\Files`.
* **The folder name is authoritative** for name and version - it is the naming convention the
  whole workflow rests on and it is what the ConfigMgr application is named after.
* **`deploy.ps1` inside a package stays thin.** All logic lives in the tool, so fixes reach
  packages created earlier.
* **Detection scripts write to STDOUT only when the application is detected.** The old
  `detection_v3.ps1` always wrote output, which made ConfigMgr consider every app installed.
  Still true for `DetectionMethod = Script`.
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
