param([string]$Action)
if ($Action -ne 'Verify') { throw 'Deployment may only verify relays.' }
# Match the real helper's success-stream output, including native Docker stdout.
# Using Write-Host here would hide deployment result contamination from tests.
Write-Output 'Checking testpilot-demo-api'
Write-Output 'PASS: http://127.0.0.1:3000/ -> HTTP 200, Swag Labs HTML'
Write-Output 'Checking testpilot-demo-worker'
Write-Output 'PASS: http://127.0.0.1:3000/ -> HTTP 200, Swag Labs HTML'
