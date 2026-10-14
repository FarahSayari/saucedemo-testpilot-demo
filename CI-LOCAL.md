# SauceDemo push-to-TestPilot laptop pipeline

Prepared on 2026-10-14. This project is separate from TestPilot. Nothing here
deploys TestPilot, migrates its database, edits approved assertions, publishes
the website to the internet, or installs/reconnects its relay containers.

## Verified targets

| Setting | Value |
| --- | --- |
| Fork | `FarahSayari/saucedemo-testpilot-demo` |
| TestPilot project | `23` — SauceDemo – Automated Regression Testing |
| TestPilot cycle | `21` — test cycle push |
| TestPilot environment | `59` — demosauce- QA, `http://127.0.0.1:3000/` |
| Case | `81` — login testing Demo |
| Current recording / approved script | `246` / `246` (v4) |
| Existing successful individual execution | `157`, PASSED, environment 59 |

These are the local-demo targets, not the public SauceDemo cycle 19/environment
50 used by the existing TestPilot repository workflow.

## What a workflow does

Push to `main` (or manual Run workflow on `main`) -> verify contracts -> build
the pushed SauceDemo source -> replace **only** `saucedemo-local` -> wait for
HTTP/health and verify the unchanged API/worker loopback relays -> request cycle
21 -> wait for the TestPilot result. Only PASSED produces a green job.

The deployment retains `127.0.0.1:3000`, the existing dedicated Docker network,
read-only root filesystem, tmpfs, resource limits, capability drop and
no-new-privileges setting. No host or TestPilot volume is mounted. Each image
and container is tied to the GitHub commit/run ID. A build failure does not stop
the live application. A launch/health/connectivity failure restores the prior
container. A business assertion failure **does not** silently roll back the
website or change tests: the faulty version remains available for diagnosis.

This is a local test-environment CI/CD integration demonstration, not a
production release pipeline. A controlled application regression needs a
separate explicit approval; it is not included in initial setup.

## Separate runner — operator setup

The existing `C:\actions-runner` runner belongs to the TestPilot repository.
Leave it untouched. The fork requires its separate runner:

- Folder: `C:\actions-runner-saucedemo`
- Name: `SAUCEDEMO-LOCAL`
- Labels: `self-hosted`, `Windows`, `X64`, `saucedemo-local`
- Windows service: Automatic startup

Runner 2.338.0 is staged from the official Windows x64 release. Archive digest:
`f48e0750a21812bca5f82de5f7f5aeae71abee647fab5a582f1742d07eba455f`.

On GitHub open the **fork's** Settings -> Actions -> Runners -> New self-hosted
runner -> Windows x64. Generate a fresh registration token, then in a local
**Administrator Windows PowerShell** run:

```powershell
Set-Location C:\Users\sayar\saucedemo-testpilot-demo
.\Setup-SauceDemoRunner.ps1
```

Enter the token only at the local config prompt. The new service defaults to
your current Windows account (which already has Docker Desktop access), not
the existing runner's NETWORK SERVICE account. If asked for its Windows
password, enter it locally; the Windows Hello PIN is not the account password.
Never send registration tokens or Windows passwords in chat. Do not register
again when clicking Run workflow.

The workflow deliberately uses installed Windows PowerShell 5.1 with a
**process-only** execution-policy override, not the per-user Store PowerShell
7 installation. It trusts only its checkout path for Git ownership checks.
The first workflow also verifies Docker daemon access under the actual service
account. If this fails, stop and diagnose the new service's account access;
do not broaden permissions or alter the existing TestPilot service.

Docker Desktop must be running; the laptop must remain awake and signed in
after reboot. Do not run `run.cmd` alongside the configured service.

## Fork repository settings — operator setup

Create a **separate project 23** TestPilot CI credential through Swagger as the
project QA Manager, with EXECUTE and READ_RESULTS scopes. Example name:
`GitHub Actions - Local SauceDemo push`. Keep the existing project's credential
for the TestPilot repository unchanged.

In this fork's Settings -> Secrets and variables -> Actions set:

| Repository variable | Value |
| --- | --- |
| `TESTPILOT_API_URL` | `http://127.0.0.1:8080` |
| `TESTPILOT_WEB_URL` | `http://localhost:4200` |
| `TESTPILOT_PROJECT_ID` | `23` |
| `TESTPILOT_CYCLE_ID` | `21` |
| `TESTPILOT_ENVIRONMENT_ID` | `59` |
| `TESTPILOT_POLL_INTERVAL_SECONDS` | `5` (optional) |
| `TESTPILOT_TIMEOUT_SECONDS` | `1800` (optional) |

Put the one-time credential in the repository **secret**
`TESTPILOT_CI_CREDENTIAL`, not a variable or source file. Its value is not a
login JWT or runner registration token. No SAUCE_USERNAME/SAUCE_ACCESS_KEY is
needed. The credential is available only to the deployment/regression step.

## Review before publishing

No commit or push is performed by the setup agent without approval of the
prepared changes. Publishing a push-enabled workflow to `main` can trigger
its first deployment immediately. Configure the runner and secret/variables
**before** publication. Enable Actions in this fork when ready.

Inherited upstream workflows are guarded with
`github.repository == 'saucelabs/sample-app-web'`. On this fork their jobs skip:
no Sauce Labs cloud tests and no GitHub Pages/CNAME deployment are attempted.
The new privileged workflow has **no pull_request/pull_request_target event**.
Restrict writes/manual runs on `main` to trusted operators: this runner has
Docker access to the laptop. Do not merge untrusted code into main.

Once published, show a baseline run before a controlled regression. A new
manual Run workflow has a new pipeline ID. Re-run jobs reuses its ID and is
intentionally refused if its retained deployment backup already exists: use a
new dispatch for a new deployment, not a blind re-run against different code.

## Serialization and interrupted runs

GitHub concurrency queues deployments rather than cancelling the active one.
A file lock also prevents overlapping local script invocations. Durable state
is outside the checkout at:
`C:\actions-runner-saucedemo\_work\_saucedemo-state`.

The client saves a TestPilot run ID immediately after a verified submission.
If a job is interrupted/times out, the next run checks the existing execution
through the authenticated API before changing the website. It refuses to
deploy while that run is QUEUED/RUNNING or its result is unknown. An interrupted
submission with no confirmed run ID requires operator inspection in TestPilot.
After confirming **no active cycle 21 execution**, an operator may remove only
the exact `pending.json` guard file in that state folder. Do not blindly clear
guards while Cypress might still be running. Never remove the folder recursively.

Do not manually restart/redeploy SauceDemo while a workflow is testing it.
Unrelated manual validations/executions in TestPilot are not managed by GitHub
concurrency; keep them idle during the presentation pipeline.

## Read-only preflight

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .github\scripts\Invoke-LocalPipeline.ps1 -ApiUrl http://127.0.0.1:8080 -PreflightOnly
```

This checks Docker, the currently running website, API and relays; it does not
build, deploy or submit a TestPilot execution.

## Rollback and cleanup

Successful deployment retains the old stopped container as
`saucedemo-local-before-<GitHub run ID>`. Automatic rollback is limited to a
failed local deployment, never a failed business test. For a later operator
rollback: first wait for all tests to finish, verify the exact backup in
`docker ps -a`, then stop/rename only the current `saucedemo-local`, rename the
chosen backup to `saucedemo-local` and start it. Relays remain unchanged because
they connect through the same host port. Verify with `Manage-LocalRelays.ps1
-Action Verify` afterward. Old images/backups are intentionally retained and
can consume disk; review exact names before removing any. No broad Docker prune
or automatic cleanup runs are used.

## Validation boundaries

Mock client tests cover pass, duplicate/idempotent submission, fail, forbidden,
malformed response, timeout and unavailable API without contacting TestPilot.
Deployment fixtures cover scope rejection, loopback/resource preservation,
build-before-stop, failed-build safety and failed-health rollback. Preparing or
passing these checks is not evidence that GitHub registration, a real deployment
or a real cycle submission has been completed. Those operator gates are reported
separately.
