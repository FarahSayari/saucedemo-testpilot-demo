param([string]$Action)
if ($Action -ne 'Verify') { throw 'Deployment may only verify relays.' }
Write-Output 'Checking testpilot-demo-api'
throw 'Mock loopback connectivity failure.'
