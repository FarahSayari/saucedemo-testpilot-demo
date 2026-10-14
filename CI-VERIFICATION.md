# Local pipeline preparation checks — 2026-10-14

## Passed

- Read-only database inspection confirmed cycle **21**, project **23**,
  environment **59**, case **81**, approved script **246** (v4). Existing case
  execution **157** is PASSED. No case/assertion/credential record was modified.
- Windows PowerShell 5.1 client tests: **7 scenarios passed** (success,
  idempotent duplicate, failed regression, forbidden credential, malformed
  response, timeout, unavailable API). Fixture credentials were not exposed.
  Timeout retained the run ID; uncertain POST failure retained unknown status.
- Deployment contract fixtures passed for **success**, **build failure**,
  **launch failure**, and **health failure/rollback**. No real container was
  replaced by those fixtures. Scope checks rejected a TestPilot container,
  a non-loopback port binding and unexpected mounts. Build-before-stop,
  retained resource/security settings and interrupted output recovery passed.
- Read-only live preflight passed: Docker accessible from the current operator,
  SauceDemo HTML/health valid, TestPilot API healthy, and both unchanged relays
  connected to their current API/worker network namespaces.
- `Dockerfile.local` built successfully to the separate verification tag
  `saucedemo-local:ci-preflight-20261014`, without replacing `saucedemo-local`.
- Browser smoke test passed against that image in a **temporary, separately
  loopback-published container**: login, inventory, add/cart contents and logout.
  Browser-state checks wait for the rendered page before asserting. The first
  smoke attempt checked cart contents too early; adding the rendered-state
  wait fixed the check, with no website or application-test changes.
- The temporary smoke containers were stopped/auto-removed; no host mounts or
  application data were involved. The verification image is retained.
- PowerShell parsing and Git whitespace checks passed.
- Separate official GitHub runner **2.338.0** downloaded to
  `C:\actions-runner-saucedemo`, SHA256 verified against the release digest,
  extracted, and configuration-help flags checked. No registration token or
  Windows password was read or stored by the agent.

## Preserved

The live application remains the original `saucedemo-local:latest` container
(`5a68cd99468e25fabe9dbfc6e1d0444116c36e201157152d04e35edac4726112`).
TestPilot's API, worker, other application containers, data, existing GitHub
runner and relay containers were not restarted, reconfigured or replaced.

No SauceDemo business regression was introduced. No files were committed or
pushed to GitHub. No GitHub repository secret/variable was created, no pipeline
was dispatched, no TestPilot cycle was submitted and no CI credential was
created/revoked.

## Still requires operator completion and publication approval

- Register the **separate** runner/service for the fork using
  `Setup-SauceDemoRunner.ps1` in an elevated local shell. Actual service-account
  Docker access must be verified; operator-side access does not prove it.
- Create/enter the fork's project CI secret and repository variables from
  `CI-LOCAL.md`. Do not disclose secrets in chat.
- Review the new workflow/scripts and inherited-workflow guards before
  approving publication. A push to main may immediately start deployment.
- After publication, verify a real baseline build/deployment/TestPilot cycle
  and then a new push trigger. The preparation checks are **not** a claim that
  this end-to-end GitHub pipeline has already run.
