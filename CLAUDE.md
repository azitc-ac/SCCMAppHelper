# Working notes for this repository

PowerShell/WinForms tool that turns rows of `Apps.csv` into PSADT packages and ConfigMgr
applications. Two documents carry the project, read them in this order:

1. `STATUS.md` - where it stands, what was actually run on a site and when, **Open items**
   (the backlog), **Settled decisions** (do not reopen without a reason), **Environments**
   and **Working agreements**. Every session that changes something appends a dated section
   there and moves the *Last updated* line.
2. `README.md` - how the tool works, for its users.

There is no separate backlog file: open work goes into `STATUS.md` under *Open items* or
*Still open on a real site*, finished work into a dated section above them.

## Hard rules

- **This repository is public.** No real server names, domains, site codes, client names or
  customer product names - in code, comments, docs or commit messages. Use the placeholders
  from `STATUS.md` (`CMSERVER`/`P01` for production, `LAB01`/`L01`/`CLIENT01` for the lab).
  The history was rewritten and the repository recreated once to get them out; do not put
  them back. `Config\config.json` is untracked for the same reason.
- Windows PowerShell 5.1 (`powershell.exe`), never pwsh 7 - the ConfigurationManager module
  needs it. Scripts are UTF-8 **with BOM**.
- Commit and push to `main` after every change - the lab server pulls this repository via
  `update.ps1`, so an unpushed change means testing a stale build there.
- Work against the lab site only. Ask before anything that creates deployments or changes
  existing ConfigMgr objects; creating an application is cheap, a deployment reaches machines.
- First publish against a new site with `distributeContent: false` and
  `createDeployments: false`.

## Things that look wrong but are not

- `git status` lists about twenty files as modified while `git diff` is empty: `core.autocrlf`
  noise (the index holds LF, the checkout CRLF). Only files with a real diff matter; a
  `.gitattributes` with `* text=auto` would end it and is an open item in `STATUS.md`.
- `Apps.csv` is tracked but also this machine's live master list, and the tool writes it.
  A changed row is a real change to review, not noise.
- `DEPLOYED-VERSION.txt`, `Logs\`, `Config\winget-index\` are per machine and ignored.
