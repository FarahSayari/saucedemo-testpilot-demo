#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [string]$WebUrl='http://localhost:4200',
    [long]$ProjectId=23,[long]$CycleId=21,[long]$EnvironmentId=59,
    [int]$PollIntervalSeconds=5,[int]$TimeoutSeconds=1800,
    [string]$CommitSha=$env:GITHUB_SHA,[string]$RunId=$env:GITHUB_RUN_ID,
    [string]$StateDirectory='C:\actions-runner-saucedemo\_work\_saucedemo-state',
    [switch]$PreflightOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'LocalDeployment.ps1')
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ($ProjectId -ne 23 -or $CycleId -ne 21 -or $EnvironmentId -ne 59) { throw 'This demo is scoped to project 23, cycle 21, environment 59. Review the script explicitly before selecting another target.' }
if ($ApiUrl.TrimEnd('/') -ne 'http://127.0.0.1:8080') { throw 'This workflow is scoped to the local TestPilot API only.' }
if ($env:GITHUB_REPOSITORY -and $env:GITHUB_REPOSITORY -ne 'FarahSayari/saucedemo-testpilot-demo') { throw 'Unexpected workflow repository.' }
if ($env:GITHUB_REF -and $env:GITHUB_REF -ne 'refs/heads/main') { throw 'This deployment is limited to the trusted main branch.' }
if ([string]::IsNullOrWhiteSpace($env:TESTPILOT_CI_CREDENTIAL) -and !$PreflightOnly) { throw 'Set the fork repository secret TESTPILOT_CI_CREDENTIAL before running the deployment.' }
Invoke-DemoDocker @('version','--format','{{.Server.Version}}') | Out-Host
$app=Get-LocalApplication
Assert-LocalWebsite $app.Image
$health=Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/actuator/health" -TimeoutSec 15
if ($health.status -ne 'UP') { throw 'The existing TestPilot API is not healthy.' }
& (Join-Path $root 'Manage-LocalRelays.ps1') -Action Verify
if ($PreflightOnly) { Write-Host 'PASS: read-only local application, Docker, API and relay preflight.'; return }
$head=(& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $CommitSha) { throw 'The source checkout is not the requested GitHub commit.' }
$sourceChanges=@(& git -C $root status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $sourceChanges.Count -gt 0) { throw 'Tracked or untracked source changes exist after checkout; refusing to label them as the pushed commit.' }
$stateRoot=[IO.Path]::GetFullPath($StateDirectory)
if ($stateRoot -ne 'C:\actions-runner-saucedemo\_work\_saucedemo-state') { throw 'Unexpected durable deployment-state location.' }
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$lockPath=Join-Path $stateRoot 'deployment.lock'
$intentPath=Join-Path $stateRoot 'pending.json'
$outputPath=Join-Path $stateRoot 'cycle-output.txt'
$lock=$null
try {
    # File share denial also protects against overlapping local/manual invocations.
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if (Test-Path -LiteralPath $intentPath) {
        $prior=Get-Content -LiteralPath $intentPath -Raw | ConvertFrom-Json
        if ($prior.projectId -ne 23 -or $prior.cycleId -ne 21 -or $prior.environmentId -ne 59) { throw 'Unexpected prior execution guard. Inspect it manually.' }
        $priorOutput=Read-CycleOutput $outputPath
        if (!$priorOutput.ContainsKey('run_id') -or $priorOutput.run_id -notmatch '^[1-9][0-9]*$') {
            throw 'A prior job ended during submission without a confirmed TestPilot run ID. Inspect TestPilot before clearing the pending guard; deployment is blocked.'
        }
        $status=Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/api/v1/execution-runs/$($priorOutput.run_id)" `
            -Headers @{Authorization="Bearer $env:TESTPILOT_CI_CREDENTIAL"} -TimeoutSec 20
        if ($status.projectId -ne 23 -or $status.cycleId -ne 21 -or $status.environmentId -ne 59 -or
            $status.metadata.pipelineId -ne [string]$prior.pipelineId -or $status.metadata.commitSha -ne $prior.commitSha) {
            throw 'Prior execution metadata does not match its deployment guard.'
        }
        if ($status.status -notin @('PASSED','FAILED','PARTIAL','ENVIRONMENT_ERROR','CANCELLED')) {
            throw "Prior TestPilot run #$($priorOutput.run_id) is $($status.status). Wait for it to finish before deploying another commit."
        }
        Remove-Item -LiteralPath $intentPath
    }
    $deployed=Deploy-LocalApplication $root $CommitSha $RunId
    if ($env:GITHUB_STEP_SUMMARY) {
        @("## Local SauceDemo deployment",'',"Commit: ``$CommitSha``","Image: ``$($deployed.Image)``",
          'Address: http://127.0.0.1:3000/',"Rollback container: ``$($deployed.Backup)``",'') |
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8
    }
    if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath }
    @{version=1;projectId=23;cycleId=21;environmentId=59;pipelineId=$RunId;commitSha=$CommitSha;image=$deployed.Image} |
        ConvertTo-Json | Set-Content -LiteralPath $intentPath -Encoding UTF8
    # Credential inherited through the process environment only, never command arguments.
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'invoke-testpilot-cycle.ps1') `
        -ApiUrl $ApiUrl -WebUrl $WebUrl -ProjectId $ProjectId -CycleId $CycleId -EnvironmentId $EnvironmentId `
        -PollIntervalSeconds $PollIntervalSeconds -TimeoutSeconds $TimeoutSeconds -OutputPath $outputPath
    $clientExit=$LASTEXITCODE
    $result=Read-CycleOutput $outputPath
    if ($result.ContainsKey('status') -and $result.status -in @('PASSED','FAILED','PARTIAL','ENVIRONMENT_ERROR','CANCELLED','NOT_SUBMITTED')) {
        Remove-Item -LiteralPath $intentPath
    }
    if ($env:GITHUB_OUTPUT) {
        foreach ($key in $result.Keys) { "$key=$($result[$key])" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8 }
    }
    # An assertion failure is kept visible; it does not roll back the website or edit the test.
    if ($clientExit -ne 0) { throw 'TestPilot regression did not pass. See the cycle summary; an active/unknown run keeps the redeployment guard.' }
    if (!$result.ContainsKey('status') -or $result.status -ne 'PASSED') { throw 'The regression client did not return a verified PASSED result.' }
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
