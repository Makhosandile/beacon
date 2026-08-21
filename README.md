# Fleet Pull Agent

A minimal pull-based management system for intermittently connected Windows machines. GitHub is the control plane and artifact store; machines poll once a day (and at every startup) and apply whatever new work targets them. No inbound connections, no always-on server.

## Repo layout

```
fleet-repo/
├── manifest.json              # the contract: what to run, where, when
├── Publish-FleetTask.ps1      # operator helper: lint, hash, version-bump
├── scripts/                   # standalone .ps1 tasks
│   └── Invoke-DiskReclaim.ps1
├── packages/                  # zipped software releases
│   └── qureapi-tools/1.4.2/payload.zip
└── agent/
    ├── Fleet-Agent.ps1        # runs on every machine
    └── Install-FleetAgent.ps1 # one-time setup per machine
```

## How it works

1. `Install-FleetAgent.ps1` (run once per machine, as admin) copies the agent to `C:\ProgramData\FleetAgent` and registers a scheduled task: daily at 02:00 with up to an hour of random jitter, plus an at-startup trigger so machines that were off catch up the moment they come online.
2. Each run, the agent identifies itself (site/project from `localhost:7000/config`, falling back to `startup.json`), fetches `manifest.json`, and walks the task list.
3. For each task it checks, in order: already applied? targets this machine? inside its time window? Only then does it download the artifact, **verify its SHA-256 against the manifest**, and execute it in a child process with a timeout.
4. Every outcome (started / success / failed / timeout / error) is POSTed to your reporting endpoint, along with a daily heartbeat carrying the manifest version — which is how you spot machines falling behind.
5. Successful `run_once` tasks are recorded in `C:\ProgramData\FleetAgent\state.json`, so daily polling never repeats work.

## Deploying something new

```powershell
# 1. Drop your script into scripts/ (or a zip into packages/)
# 2. Add a task entry to manifest.json (copy an existing one)
# 3. Validate, hash, and bump the version:
.\Publish-FleetTask.ps1
# 4. Ship it:
git add -A ; git commit -m "Deploy disk reclaim v3" ; git push
```

Every machine picks it up within 24 hours of next being online. Rollback is `git revert` plus a re-publish.

## Task fields

| Field             | Meaning                                                        |
|-------------------|----------------------------------------------------------------|
| `id`              | Unique name; the idempotency key. New version = new id.        |
| `type`            | `script` (single .ps1) or `package` (zip with an installer).   |
| `source`          | Path within the repo.                                          |
| `sha256`          | Filled in by `Publish-FleetTask.ps1`. Verified before running. |
| `targets`         | `projects` and `sites` lists; `"*"` matches everything.        |
| `window`          | e.g. `"01:00-05:00"`. Empty = any time. Deferred tasks retry.  |
| `run_once`        | `true` = apply once ever; `false` = run on every agent cycle.  |
| `timeout_minutes` | Task is killed past this; agent survives and reports it.       |

## Before going to production

- Set `$RepoBase` and `$ReportUrl` at the top of `Fleet-Agent.ps1`.
- For a **private** repo, raw URLs need a token — switch `Get-VerifiedFile` and the manifest fetch to the GitHub API with an `Authorization` header, using a fine-grained read-only PAT.
- Consider pinning the agent's outbound calls behind your existing Apps Script endpoint if machines sit behind restrictive site firewalls.
