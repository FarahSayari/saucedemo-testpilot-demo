param([string]$Action)
if ($Action -ne 'Verify') { throw 'Deployment may only verify relays.' }
Write-Host 'PASS: mock read-only relay verification.'
