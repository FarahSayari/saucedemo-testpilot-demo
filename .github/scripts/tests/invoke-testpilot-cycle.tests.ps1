#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$clientScript = Join-Path $repositoryRoot '.github\scripts\invoke-testpilot-cycle.ps1'
$mockScript = Join-Path $PSScriptRoot 'mock-testpilot-api.js'

function Invoke-Scenario {
    param(
        [string]$Mode,
        [int]$Port,
        [int]$ExpectedExitCode,
        [bool]$Replay = $false,

        [bool]$StartMockApi = $true
    )

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'testpilot-github-action-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $serverOutput = Join-Path $temporaryRoot 'server.out'
    $serverError = Join-Path $temporaryRoot 'server.err'
    $clientOutput = Join-Path $temporaryRoot 'client.out'
    $clientError = Join-Path $temporaryRoot 'client.err'
    $summaryPath = Join-Path $temporaryRoot 'summary.md'
    $outputPath = Join-Path $temporaryRoot 'output.txt'
    $server = $null

    try {
        if ($StartMockApi) {
            $server = Start-Process `
                -FilePath 'node' `
                -ArgumentList @($mockScript, [string]$Port, $Mode) `
                -WorkingDirectory $repositoryRoot `
                -WindowStyle Hidden `
                -RedirectStandardOutput $serverOutput `
                -RedirectStandardError $serverError `
                -PassThru

            $deadline = (Get-Date).AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 100
                $ready = if (Test-Path $serverOutput) {
                    Get-Content $serverOutput -ErrorAction SilentlyContinue
                }
                else {
                    $null
                }
            } while (-not ($ready -match '^READY') -and (Get-Date) -lt $deadline)
            if (-not ($ready -match '^READY')) {
                throw "Mock API '$Mode' did not start."
            }
            if ($server.HasExited) {
                throw "Mock API '$Mode' exited unexpectedly: $(Get-Content -Raw $serverError)"
            }
            $probe = [System.Net.Sockets.TcpClient]::new()
            try {
                $probe.Connect('127.0.0.1', $Port)
            }
            finally {
                $probe.Dispose()
            }
        }
        else {
            $occupiedPort = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
            if ($null -ne $occupiedPort) {
                throw "Unavailable-API test port $Port is unexpectedly in use."
            }
        }

        $env:TESTPILOT_CI_CREDENTIAL = 'local-test-credential'
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $clientScript,
            '-ApiUrl', "http://127.0.0.1:$Port",
            '-WebUrl', 'http://testpilot.local',
            '-ProjectId', '5',
            '-CycleId', '2',
            '-EnvironmentId', '42',
            '-PollIntervalSeconds', '1',
            '-TimeoutSeconds', $(if ($Mode -eq 'timeout') { '2' } else { '10' }),
            '-PipelineId', '9001',
            '-JobId', 'execute-testpilot-cycle',
            '-CommitSha', '0123456789abcdef0123456789abcdef01234567',
            '-Branch', 'main',
            '-StepSummaryPath', $summaryPath,
            '-OutputPath', $outputPath
        )

        $attempts = if ($Replay) { 2 } else { 1 }
        $exitCodes = @()
        for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
            $client = Start-Process `
                -FilePath 'powershell.exe' `
                -ArgumentList $arguments `
                -WorkingDirectory $repositoryRoot `
                -WindowStyle Hidden `
                -RedirectStandardOutput $clientOutput `
                -RedirectStandardError $clientError `
                -Wait `
                -PassThru
            $exitCodes += $client.ExitCode
        }

        if (@($exitCodes | Where-Object { $_ -ne $ExpectedExitCode }).Count -gt 0) {
            $safeError = if (Test-Path $clientError) {
                (Get-Content -Raw $clientError) -replace 'local-test-credential', '[REDACTED]'
            }
            else {
                'No error output was captured.'
            }
            $serverDiagnostic = "serverExited=$($server.HasExited)"
            if (Test-Path $serverError) {
                $serverDiagnostic += " serverError=$(Get-Content -Raw $serverError)"
            }
            $safeOutput = if (Test-Path $clientOutput) {
                (Get-Content -Raw $clientOutput) -replace 'local-test-credential', '[REDACTED]'
            }
            else {
                'No standard output was captured.'
            }
            throw "Scenario '$Mode' returned unexpected exit codes $($exitCodes -join ','). $serverDiagnostic $safeOutput $safeError"
        }

        $combinedLog = @(
            if (Test-Path $clientOutput) { Get-Content -Raw $clientOutput }
            if (Test-Path $clientError) { Get-Content -Raw $clientError }
        ) -join [Environment]::NewLine
        if ($combinedLog -match 'local-test-credential') {
            throw "Scenario '$Mode' exposed the API credential."
        }

        $summary = if (Test-Path $summaryPath) { Get-Content -Raw $summaryPath } else { '' }
        if ($summary -notmatch '## TestPilot cycle execution') {
            throw "Scenario '$Mode' did not write a GitHub job summary."
        }
        if ($Mode -eq 'success') {
            if ($summary -notmatch 'Run ID \| 701' -or
                $summary -notmatch 'Total cases \| 2' -or
                $summary -notmatch 'Duration \| 12.5s' -or
                $summary -notmatch 'Open this cycle in TestPilot') {
                throw 'Success summary is missing its run, totals, duration or report link.'
            }
            $runOutputs = @(
                Get-Content $outputPath |
                    Where-Object { $_ -eq 'run_id=701' }
            ).Count
            # The run ID is deliberately written once immediately after
            # acceptance and once on completion, including idempotent replay.
            $otherRunIds = @(Get-Content $outputPath | Where-Object { $_ -match '^run_id=' -and $_ -ne 'run_id=701' }).Count
            if ($runOutputs -ne (2 * $attempts) -or $otherRunIds -ne 0) {
                throw 'Idempotent replay did not return the original run ID.'
            }
        }
        elseif ($Mode -eq 'failure' -and $summary -notmatch 'Status \| FAILED') {
            throw 'Failed TestPilot execution did not produce a failed summary.'
        }
        elseif ($Mode -eq 'timeout' -and $combinedLog -notmatch 'did\s+not\s+finish\s+within\s+2\s+seconds') {
            throw 'Timeout scenario did not report a clear timeout.'
        }
        elseif ($Mode -eq 'malformed' -and $combinedLog -notmatch 'malform\s*ed\s+JSON') {
            throw 'Malformed-response scenario did not report malformed JSON.'
        }
        elseif ($Mode -eq 'forbidden' -and $combinedLog -notmatch 'lacks the required scope or project access') {
            throw 'HTTP-error scenario did not report the authorization failure safely.'
        }
        elseif ($Mode -eq 'unavailable' -and $combinedLog -notmatch 'Unable to reach TestPilot') {
            throw 'Unavailable-API scenario did not report the connectivity failure clearly.'
        }
        if ($Mode -eq 'timeout' -and (Get-Content -Raw $outputPath) -notmatch 'run_id=701') {
            throw 'Timed-out execution lost its durable run ID.'
        }
        if ($Mode -eq 'unavailable' -and (Get-Content -Raw $outputPath) -notmatch 'status=SUBMISSION_UNKNOWN') {
            throw 'Interrupted submission was incorrectly marked safe to redeploy.'
        }

        [pscustomobject]@{
            Scenario = if ($Replay) { 'duplicate' } else { $Mode }
            ExitCodes = $exitCodes -join ','
            CredentialExposed = $false
            Passed = $true
        }
    }
    finally {
        Remove-Item Env:TESTPILOT_CI_CREDENTIAL -ErrorAction SilentlyContinue
        if ($null -ne $server -and -not $server.HasExited) {
            $server.Kill()
            $server.WaitForExit()
        }
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$workflowPath = Join-Path $repositoryRoot '.github\workflows\testpilot-local-regression.yml'
$workflow = Get-Content -Raw -LiteralPath $workflowPath
if ($workflow -notmatch '(?ms)^on:\s*\r?\n\s+push:\s*\r?\n\s+branches: \[main\]\s*\r?\n\s+workflow_dispatch:') {
    throw 'Workflow must trigger on pushes to main and retain workflow_dispatch.'
}
if ($workflow -match '(?m)^\s+pull_request(?:_target)?:') {
    throw 'Privileged workflow must not run for pull requests.'
}
if ($workflow -notmatch '(?m)^\s+runs-on: \[self-hosted, Windows, X64, saucedemo-local\]\r?$') {
    throw 'Execution job must target the registered Windows self-hosted labels.'
}
if ($workflow -match '(?i)\bpsql\b|db/manual|flyway|migrat(?:e|ion)') {
    throw 'Workflow must not apply or invoke database upgrades.'
}
if ($workflow -notmatch 'cancel-in-progress: false' -or
    $workflow -notmatch 'ExecutionPolicy Bypass -File \{0\}' -or
    $workflow -notmatch 'GIT_CONFIG_KEY_0: safe.directory') {
    throw 'Local pipeline requires serialization, process-only PowerShell policy and scoped checkout trust.'
}

$results = @(
    Invoke-Scenario -Mode 'success' -Port 18081 -ExpectedExitCode 0
    Invoke-Scenario -Mode 'success' -Port 18082 -ExpectedExitCode 0 -Replay $true
    Invoke-Scenario -Mode 'failure' -Port 18083 -ExpectedExitCode 1
    Invoke-Scenario -Mode 'forbidden' -Port 18084 -ExpectedExitCode 1
    Invoke-Scenario -Mode 'malformed' -Port 18085 -ExpectedExitCode 1
    Invoke-Scenario -Mode 'timeout' -Port 18086 -ExpectedExitCode 1
    Invoke-Scenario -Mode 'unavailable' -Port 18087 -ExpectedExitCode 1 -StartMockApi $false
)

$results | Format-Table -AutoSize
"PASS: workflow trigger/security checks and $($results.Count) GitHub-to-TestPilot scenarios."
