#Requires -Version 5.1
[CmdletBinding()]
param([string]$WindowsAccount=[Security.Principal.WindowsIdentity]::GetCurrent().Name)
$ErrorActionPreference='Stop'
$principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script yourself in an Administrator PowerShell. No window is opened automatically.'
}
$runnerDirectory='C:\actions-runner-saucedemo'
if (Test-Path -LiteralPath (Join-Path $runnerDirectory '.runner')) { throw 'This separate runner is already registered. Do not re-register it for normal workflow runs.' }
if (!(Test-Path -LiteralPath (Join-Path $runnerDirectory 'config.cmd'))) { throw 'Verified runner binaries are not staged. See CI-LOCAL.md.' }
docker version --format '{{.Server.Version}}'
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop must be running and accessible to this account.' }
Write-Host 'Use a fresh registration token from the SauceDemo fork Settings > Actions > Runners.'
Write-Host 'Enter it only at the local config prompt. Never send it or your Windows password in chat.'
Write-Host "The separate service will use $WindowsAccount, which must have Docker Desktop access."
Push-Location $runnerDirectory
try {
    & .\config.cmd --url https://github.com/FarahSayari/saucedemo-testpilot-demo `
        --name SAUCEDEMO-LOCAL --labels saucedemo-local --work _work --runasservice --windowslogonaccount $WindowsAccount
    if ($LASTEXITCODE -ne 0) { throw 'Registration did not complete; do not publish the workflow until the runner is online.' }
} finally { Pop-Location }
Get-Service 'actions.runner.FarahSayari-saucedemo-testpilot-demo.*' | Select-Object Name,Status,StartType
