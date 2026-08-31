# Project status

Working document for picking the project up again - in a new session, on another machine, or
after a break. `README.md` describes how the tool works; this file records **where it stands,
what has actually been tested, and which decisions are already settled**.

Last updated: 2026-08-31 (a detection evaluated on a real client)

## Where it stands

Version 1.0, feature complete for the intended workflow: master list -> PSADT package ->
ConfigMgr application including collections, deployments, content distribution and
supersedence, plus a setup assistant and the collection maintenance tools.

As of 2026-08-31 the whole chain has been walked end to end on a real client: five
applications built from the master list, published, deployed to `rd3` and installed there,
with supersedence retiring the versions they replace.

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

### Publishing what the older scripts built (AZI, 2026-08-29)

The case that had been open longest, and it paid: three defects, none of them
reachable without a real legacy package in a real site.

* **The detection fingerprint ignored the operator.** A foreign clause comparing
  `ProductVersion Equals 11.24.0` looked identical to ours comparing `GreaterEquals
  11.24.0`, so the tool left the foreign detection alone and reported success. The two do not
  mean the same thing - `Equals` stops counting the product as installed the moment it is
  updated. Found on `PDF24 Creator - 11.24.0`, which is exactly that case.
* **The artifact folder leaked.** Cleanup sat after the publish block, so every refused package
  left a `SCCMAppHelper_<guid>` folder under `%TEMP%`. It is a `finally` now.
* **Legacy rows carry an empty `DetectionPattern`**, which used to mean "DisplayName like
  `<Name>*`". A native clause needs an exact key, so none of them could be published without
  filling one in by hand. Where the package ships a single MSI the ProductCode answers the
  question - it *is* the uninstall key of an MSI installed product - and that covers most of
  them.

What the run proved:

* `PDF24 Creator - 11.24.0`: foreign `Equals` clause replaced by ours, 1 setting and 1 rule
  reference before and after, `GreaterEquals` afterwards, `Detection unchanged` on the next
  run, nothing left in `%TEMP%`. The deployment type comment now carries the signature, so it
  reads as `Published (this tool)`.
* `7-Zip - 24.9.0.0` ships no MSI and its row holds no key: refused with a message saying so,
  and the deployment type was not touched at all - same setting count, comment still empty.
  A pattern still carrying a wildcard is refused the same way, because a native clause would
  take it without complaint and then match nothing.

That is also the third data point on replacing clauses: it worked here, it worked on
Notepad++, and it failed in the `4.0.0` experiment. Still no explanation for the difference,
which is why the tool verifies the rule count afterwards rather than trusting the call.

### The retire workflow, built and run (AZI, 2026-08-29)

Two levels. **Retire** removes the deployments and nothing else - application, collections,
content and supersedence all stay, and publishing again undoes it. **Remove** goes on to
dissolve the supersedence references, revoke the content, delete the two per-application
collections and finally the application; the package folder is optional. It lives in the tools
menu, not on the start dialog. `Apps.csv` is never touched at either level.

Run against the lab, which is now free of `SCCMAppHelper Testapp`: no applications, no
collections, no package folders. The five `Apps.csv` rows are still there, by design.

**Three defects the first run turned up**, one of which did damage:

* **Collections were derived from the deployments.** A collection with no deployment was
  therefore invisible, and `Remove` deleted nothing - which is exactly the state a `Retire`
  leaves behind, and the state `createDeployments = false` produces. They come from the
  configured name patterns now.
* **`Remove-CMContentDistribution` refuses to work from `-ApplicationName` alone.** It wants to
  be told which distribution point or group, like `Start-CMContentDistribution` does.
* **Dissolving a supersedence failed and the application was deleted anyway.** ConfigMgr does
  not enforce this: it deleted an application that four others supersede and left them pointing
  at something that no longer exists. Nothing can clean that up afterwards, because removing a
  supersedence needs the deployment type that was just deleted. `SCCMAppHelper Testapp - 5.0.0`
  carried two such orphaned rules until it was itself deleted. An application whose referrers
  cannot be dissolved is now left alone and reported, and the package folder stays as long as
  the application does.

**`Set-CMApplicationSupersedence -RemoveSupersedence` does not work.** It answers "object
reference not set to an instance of an object" in both parameter sets, by name and by object.
`Remove-CMDeploymentTypeSupersedence` does the job but warns that it is deprecated and points
at exactly that broken replacement. The tool keeps the deprecated cmdlet and suppresses the
warning; do not "fix" this without testing the replacement first.

### A detection evaluated on a real client (rd3, 2026-08-31)

The one thing that had never been shown: everything before this verified the clause ConfigMgr
*stores*, not that it matches the product on a machine. `7-Zip - 26.02.00.0` was distributed
and deployed to `rd3.home.local`, which had 26.00 installed.

From the client's own `AppEnforce.log`:

```
+++ Starting Install enforcement for App DT "7-Zip - 26.02.00.0"
    Performing detection ...  +++ Application not discovered.
    Executing: "Invoke-AppDeployToolkit.exe" -DeploymentType Install -DeployMode Silent
    Process 2268 terminated with exitcode: 0
    Performing detection ...  +++ Discovered application
++++++ App enforcement completed (12 seconds)
```

Both directions in one run: the clause said "not installed" with 26.00 present, and "installed"
after the install. Afterwards the machine holds `7-Zip 26.02 (x64 edition)` under
`{23170F69-40C1-2702-2602-000001000000}` - the ProductCode the clause checks - and `7z.exe`
reports 26.02. The site agrees: `enforcement=1000 compliance=1`.

**Supersedence with `supersedenceUninstall` does something after all.** Immediately before the
install the client uninstalled 26.00 on its own - `App enforcement completed (23 seconds) for
App DT "7-Zip - 26.00.00.0"`, then `Application not discovered`, and `ActionType - Uninstall`
in `AppDiscovery.log`. That is the `Changeable="true"` attribute from the very first
investigation of this session, finally shown to have an effect on a machine. 26.00 now reports
`enforcement=3000 compliance=2`.

Two things worth knowing for the next time:

* **The site lags the client badly.** The install finished at 13:07:18. The site still reported
  `enforcement=2000 (in progress)` more than ten minutes later, and hardware inventory still
  listed 26.00. Polling `SMS_AppDeploymentAssetDetails` is not a way to watch an installation -
  read `AppEnforce.log` on the client instead.
* `Invoke-CMClientNotification` only knows `RequestMachinePolicyNow` and `RequestUsersPolicyNow`.
  The one that matters is `Invoke-CMClientAction -ActionType ClientNotificationAppDeplEvalNow`,
  and there is a `ClientNotificationRequestHWInvNow` next to it.

### The file clause on a client, and the last detection method (2026-08-31)

`Notepad++ - 8.9.8` was deployed to rd3, which had no Notepad++ at all. `AppEnforce.log`:
`Application not discovered` before, exit code 0 after 16 seconds, `Discovered application`
after. The file ends up in `C:\Program Files\Notepad++\notepad++.exe` - the 64 bit view, which
only the `Is64Bit="true"` half of the pair matches. Before that fix there was one clause with
`Is64Bit="false"`, which would have looked in `Program Files (x86)` and never found it. So the
fix is shown on a machine rather than only in the XML.

**`DetectionMethod = Script` could never have worked.** Renaming the method from `Custom`
never reached `New-DetectionScript`, which still tested for `Custom` and then looked for a
template called `detection_template-Script.ps1` that does not exist. Both names are accepted
now. Verified with a throwaway package: `ScriptType` 0, the hand written script from
`Content\SupportFiles\detection.ps1` taken verbatim with the signature prepended, no enhanced
detection method at all, and a second publish overwrites rather than stacks - which is what
`ScriptText` does and clauses do not.

**Replacing a legacy script detection with a clause works.** `iX-Haus Client Setup - 20.25.0`
went from script detection to a native MSI clause (`Detection differs from the 0 rule(s)`) and
settled to `Detection unchanged` on the next run. It became an MSI clause rather than a
registry one because the package ships a single MSI with no PSADT metadata, so it counts as
zero-config.

The retire workflow removed the throwaway package completely - deployments, content,
collections, application, folder - which is the first time it ran on an application that had
all of them.

### Why the catalog has no product name search (measured, 2026-08-31)

The obvious fix - build an index of the repository once and search that - was measured and
dropped:

* `manifests/k` 3.9 MB in 18 s, 395 publisher/package pairs for 237 publishers - plausible
* `manifests/a` 12.5 MB in 44 s, 979 pairs - plausible
* `manifests/m` fails outright about half the time ("unexpected EOF", "connection closed
  unexpectedly"), and when it does answer returns **373 pairs for 562 publishers** - fewer
  pairs than publishers, which cannot be complete. `truncated` is `false` in that answer.

GitHub sends incomplete trees without saying so. A search built on that would quietly miss
packages, which is the same class of defect as the single-page directory listing already fixed
here. So: the curated list is the searchable part, a package id is resolved directly, the
repository search matches publishers, and a **Remember** button keeps whatever was found the
hard way. `Add-CatalogEntry` writes `catalog.json` by hand - `ConvertTo-Json` escapes every
apostrophe and angle bracket and explodes the layout, and that file is meant to be edited by
hand.

`Get-CMDistributionTarget` was listed here as an untested ConfigMgr cmdlet. It is not one -
it is the tool's own function in `Functions\setup.ps1`.

### Five applications deployed to a client, and what stood in the way (rd3, 2026-08-31)

Five applications were built with the tool, published, and deployed to `rd3`. All five are
installed and ConfigMgr agrees:

```
7-Zip                    26.02         Installed
PDF24 Creator            11.30.1       Installed   (11.24.0 and 11.29.1 NotInstalled)
Notepad++                8.9.8         Installed
Remote Desktop Manager   2026.2.18.0   Installed   (2025.1.25.0 NotInstalled)
SQL Server Mgmt Studio   22.9.2        Installed
```

The superseded versions report themselves as not installed, which is the supersedence chain
working the way it is supposed to.

Getting the last one there took most of an evening, because **four independent faults were
stacked on top of each other** and each one hid the next. Written down because the shape of
this is worth recognising again:

1. **The install command carried the wrong verb.** `vs_SSMS.exe` is a Visual Studio
   bootstrapper. Without a verb it performs `install`, and it refuses that over an existing
   instance in the same install path - exit 1 after 30 seconds, no `dd_*.log`, nothing in
   `AppEnforce` beyond the code. `rd3` already carried SSMS 22.3 in that path. A version change
   is `update`, so the package now asks `vswhere` what is there and picks the verb.
2. **The distribution point silently stopped accepting content.** It sat on source version 4
   from 18:12 while the deployment type had moved on to content version 7. Status message 2361,
   "gave up after 30 retries". Every correction after that reached the site and stopped there;
   the client kept running the old script from its cache. Re-triggering the distribution fixed
   it - the failure was transient, not structural. Path length was measured and ruled out: the
   longest UNC path in the package is 259 characters and every file opens.
3. **The client was a policy revision behind.** Revision 9 against CIVersion 11, so it kept
   asking for the previous content object.
4. **The client cache was full.** `Not enough space in Cache`, `CreateContentRequest failed`.
   Three identical 5.1 GB copies of the same package occupied 15.3 GB of a 20 GB cache under
   three different content IDs. That is the tool's own fault and is the finding worth keeping -
   see the `Update-CMDistributionPoint` entry below.

The lesson that cost the time: **check that what you publish actually arrives before correcting
the source again.** Three rounds of fixing the package went into a transport that was not
moving. Nothing in the console said so - source, application and deployment all looked correct.

Two more things surfaced on the way:

* **The tool redirects PSADT's log path.** `Set-ADTLogPath` rewrites `LogPath` in the package
  config to `C:\Windows\CCM\Logs\PSADT`. Logs are not in `C:\Windows\Logs\Software`, and
  looking for them there wastes time.
* **The installer can crash after succeeding.** The final SSMS run updated 22.3 to 22.9.2
  correctly and then died in its own post-install step - `ngen.exe` with `0xc00000fd`, a stack
  overflow, and `setup.exe_Visual Studio` faulting in `ntdll.dll`. `vs_SSMS.exe` returned
  `3221225725`, PSADT passed it on, ConfigMgr called the enforcement failed and left the
  application at `NotInstalled` for half an hour without re-evaluating. Triggering the
  deployment again resolved it: detection ran first, found SSMS present and flipped the state
  to `Installed` without installing anything a second time. The crash code was deliberately
  **not** added to the deployment type's success codes - that would swallow real crashes of
  this package from now on.

### What the run changed in the code

* **`Update-CMDistributionPoint` creates a new content object every time it runs**, not a new
  version of the existing one. Measured on `Notepad++ - 8.9.8`: the content ID changes across
  that call and does not change across `Set-CMScriptDeploymentType`. Clients treat a new
  content object as content they have never seen and download the whole package again. The
  tool called it on every publish, so publishing an unchanged 5 GB package three times left
  three complete copies in the client cache, filled it, and from then on every distribution
  failed with `0x87D01201` while the client quietly went on running the old content.
  The content folder now gets a cheap fingerprint - file count, total bytes, newest write time
  - kept in the deployment type comment, which `Set-CMScriptDeploymentType` writes without
  touching the content object. The refresh only runs when the fingerprint really differs.
  Both directions were measured: two unchanged publishes keep `Content_17d8c177`; adding a
  single file produces `Content_b93d4d06` and triggers the distribution.
  The comment comes back as `LocalizedDescription` on the deployment type object, and in the
  XML it is a `<Description>` below `<DeploymentType>` - not under `DisplayInfo`.
* **The install and uninstall commands follow `Apps.csv` on every build.** They used to be
  inserted once, when the template was created, and never again - because inserting twice
  would have produced the command twice. The package therefore silently outranked the master
  list: editing the row changed nothing, while `Set-ADTAppMetadata` rewrote the file on every
  build anyway, so the timestamp moved and the command did not. A wrong install command
  survived every attempt to correct it. `Set-PackageCommand` now writes into a marked block
  that can be rewritten safely. A package with no block is only written into when its section
  is empty; a hand written command stays and the difference is reported instead.
* **A bare `{GUID}` after `-ProductCode` is a script block to PowerShell, not a string.** An
  older version of the tool wrote `Start-ADTMsiProcess -Action 'Uninstall' -ProductCode
  {102DCD41-...}` into packages, and every uninstall failed with "Cannot evaluate parameter
  'ProductCode' because its argument is specified as a script block and there is no input" - a
  message that says nothing about the missing quotes. `Repair-CommandLine` restores them
  before the line is written; quotes that are already there are left alone.
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

* `Edit-RoleCollectionMembership` and the rest of the tools menu were verified cmdlet by
  cmdlet, not through their dialogs, and are not in `Test-Dialogs.ps1`.
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
* The `Registry` clause has not been watched evaluating on a client. `MSI` and `File` have
  been, in both directions. The registry pair is built by the same code as the file pair, and
  the file pair is what proved the `Is64Bit` fix, so the risk is small - but it is not the same
  as having seen it.
* The legacy packages whose CM application uses **script** detection rather than clauses were
  not tried - `Google Chrome`, `Microsoft Edge`, the Office packages and others. Replacing a
  script detection with a clause is a different operation from replacing a clause, and it has
  not been exercised.

## Open items

* **The lab is clean of `SCCMAppHelper Testapp`** - no applications, no collections, no package
  folders. The five `Apps.csv` rows are still there, which is what the workflow promises. They
  can go by hand whenever they are in the way.
* **A collection can outlive its application, and the retire workflow cannot see it then.**
  Selection is from the site's applications, so a collection whose application is already gone
  is unreachable. Four of them were left behind by the collection bug above and had to be
  deleted separately. Worth a small "orphaned collections" cleanup in the tools menu.
* **`Notepad++ - 8.9.8` and `7-Zip - 26.02` are real, not test objects**, and both are now
  deployed and installed on `rd3` along with PDF24, Remote Desktop Manager and SSMS. They
  should not be swept up by any lab cleanup.
* **Notepad++ is installed twice on `rd3`** - an EXE and an MSI installation side by side,
  under two uninstall keys (`Notepad++ (64-bit x64)` and `Notepad++ (x64)`), both reporting
  8.9.8. Cleanup was offered and not yet decided.
* **`Oracle_Database_Client-19cx64` cannot be published at all.** Its longest path is 285
  characters, past the 260 character limit, and no layout change gets it under. Nothing has
  been decided about it.
* **Nothing warns before publishing when a path is too long.** The SSMS package sits at 259
  characters over UNC, one character below the limit; the Oracle one is past it. A check
  before publishing was proposed and not built.
* `distributeContent` and `createDeployments` are `true` in `config.json`. The working
  agreement wants them `false` before a *first* publish against a **new** site - set them back
  if the tool is pointed somewhere else.
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
