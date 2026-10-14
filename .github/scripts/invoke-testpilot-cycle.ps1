#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiUrl,

    [string]$WebUrl,

    [Parameter(Mandatory = $true)]
    [long]$ProjectId,

    [Parameter(Mandatory = $true)]
    [long]$CycleId,

    [Parameter(Mandatory = $true)]
    [long]$EnvironmentId,

    [ValidateRange(1, 300)]
    [int]$PollIntervalSeconds = 5,

    [ValidateRange(1, 21600)]
    [int]$TimeoutSeconds = 1800,

    [string]$PipelineId = $env:GITHUB_RUN_ID,

    [string]$JobId = $env:GITHUB_JOB,

    [string]$CommitSha = $env:GITHUB_SHA,

    [string]$Branch = $env:GITHUB_REF_NAME,

    [string]$IdempotencyKey,

    [string]$Credential = $env:TESTPILOT_CI_CREDENTIAL,

    [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY,

    [string]$OutputPath = $env:GITHUB_OUTPUT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Require-Text {
    param(
        [string]$Value,
        [string]$Name,
        [int]$MaximumLength
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required configuration '$Name' is missing."
    }
    $normalized = $Value.Trim()
    if ($normalized.Length -gt $MaximumLength) {
        throw "Configuration '$Name' exceeds its maximum length of $MaximumLength characters."
    }
    if ($normalized -match '[\x00-\x1F\x7F]') {
        throw "Configuration '$Name' contains an unsupported control character."
    }
    return $normalized
}

function Get-RequiredProperty {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Context
    )

    if ($null -eq $Object) {
        throw "TestPilot returned a malformed $Context response."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "TestPilot returned a malformed $Context response: '$Name' is missing."
    }
    return $property.Value
}

function Get-OptionalProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertFrom-SafeJson {
    param(
        [string]$Content,
        [string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw "TestPilot returned an empty $Context response."
    }
    try {
        return $Content | ConvertFrom-Json
    }
    catch {
        throw "TestPilot returned malformed JSON for $Context."
    }
}

function ConvertTo-SafeMessage {
    param(
        [object]$Value,
        [int]$MaximumLength = 300
    )

    $message = [string]$Value
    $message = ($message -replace '[\x00-\x1F\x7F]+', ' ').Trim()
    if ($message.Length -gt $MaximumLength) {
        return $message.Substring(0, $MaximumLength) + '...'
    }
    return $message
}

function Get-ApiFailureMessage {
    param(
        [int]$StatusCode,
        [string]$Content,
        [string]$Operation
    )

    $baseMessage = switch ($StatusCode) {
        400 { "$Operation was rejected because the request was invalid" }
        401 { "$Operation was rejected because the API credential is invalid or expired" }
        403 { "$Operation was rejected because the API credential lacks the required scope or project access" }
        404 { "$Operation could not find the configured TestPilot resource" }
        409 { "$Operation conflicted with an existing execution or Idempotency-Key" }
        429 { "$Operation was rate limited by TestPilot" }
        default {
            if ($StatusCode -ge 500) {
                "$Operation failed because TestPilot is temporarily unavailable"
            }
            else {
                "$Operation failed with HTTP $StatusCode"
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        try {
            $errorBody = $Content | ConvertFrom-Json
            foreach ($propertyName in @('message', 'detail', 'error')) {
                $detail = Get-OptionalProperty -Object $errorBody -Name $propertyName
                if (-not [string]::IsNullOrWhiteSpace([string]$detail)) {
                    return "${baseMessage}: $(ConvertTo-SafeMessage $detail)"
                }
            }
        }
        catch {
            # Raw error bodies are intentionally not printed.
        }
    }
    return "$baseMessage."
}

function Invoke-TestPilotRequest {
    param(
        [object]$Client,
        [string]$Method,
        [Uri]$Uri,
        [string]$JsonBody,
        [string]$RequestIdempotencyKey
    )

    $httpMethod = if ($Method -eq 'POST') {
        [System.Net.Http.HttpMethod]::Post
    }
    else {
        [System.Net.Http.HttpMethod]::Get
    }
    $request = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $Uri)
    try {
        if (-not [string]::IsNullOrWhiteSpace($RequestIdempotencyKey)) {
            $added = $request.Headers.TryAddWithoutValidation('Idempotency-Key', $RequestIdempotencyKey)
            if (-not $added) {
                throw 'The Idempotency-Key header could not be created.'
            }
        }
        if ($Method -eq 'POST') {
            $request.Content = [System.Net.Http.StringContent]::new(
                $JsonBody,
                [System.Text.Encoding]::UTF8,
                'application/json'
            )
        }

        try {
            $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        }
        catch {
            throw "Unable to reach TestPilot at '$($Uri.GetLeftPart([System.UriPartial]::Authority))'. Check API availability and runner networking."
        }

        try {
            $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Content = $content
            }
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $request.Dispose()
    }
}

function ConvertTo-DurationText {
    param([object]$DurationMs)

    if ($null -eq $DurationMs) {
        return 'N/A'
    }
    $milliseconds = 0L
    if (-not [long]::TryParse([string]$DurationMs, [ref]$milliseconds) -or $milliseconds -lt 0) {
        return 'N/A'
    }
    $duration = [TimeSpan]::FromMilliseconds($milliseconds)
    if ($duration.TotalMinutes -ge 1) {
        return '{0}m {1:0.0}s' -f [Math]::Floor($duration.TotalMinutes), $duration.Seconds + ($duration.Milliseconds / 1000)
    }
    return '{0:0.0}s' -f $duration.TotalSeconds
}

function ConvertTo-MarkdownValue {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'N/A'
    }
    return ((ConvertTo-SafeMessage -Value $Value -MaximumLength 500) -replace '\|', '\|')
}

function Write-GitHubOutput {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $Value) {
        return
    }
    $text = ConvertTo-SafeMessage -Value $Value -MaximumLength 1000
    Add-Content -LiteralPath $Path -Value "$Name=$text" -Encoding UTF8
}

function Write-TestPilotSummary {
    param(
        [string]$Path,
        [string]$Outcome,
        [object]$RunId,
        [string]$Status,
        [object]$ResultResponse,
        [string]$FailureMessage,
        [string]$ReportLink,
        [int]$ReportArtifactCount
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $result = Get-OptionalProperty -Object $ResultResponse -Name 'result'
    $duration = Get-OptionalProperty -Object $ResultResponse -Name 'durationMs'
    $summaryLines = @(
        '## TestPilot cycle execution',
        '',
        '| Field | Value |',
        '| --- | --- |',
        "| GitHub outcome | $(ConvertTo-MarkdownValue $Outcome) |",
        "| Run ID | $(ConvertTo-MarkdownValue $RunId) |",
        "| Status | $(ConvertTo-MarkdownValue $Status) |",
        "| Total cases | $(ConvertTo-MarkdownValue (Get-OptionalProperty $result 'totalCases')) |",
        "| Passed | $(ConvertTo-MarkdownValue (Get-OptionalProperty $result 'passedCases')) |",
        "| Failed | $(ConvertTo-MarkdownValue (Get-OptionalProperty $result 'failedCases')) |",
        "| Skipped | $(ConvertTo-MarkdownValue (Get-OptionalProperty $result 'skippedCases')) |",
        "| Environment errors | $(ConvertTo-MarkdownValue (Get-OptionalProperty $result 'environmentErrors')) |",
        "| Duration | $(ConvertTo-MarkdownValue (ConvertTo-DurationText $duration)) |",
        "| Durable report artifacts | $ReportArtifactCount |"
    )
    if (-not [string]::IsNullOrWhiteSpace($ReportLink)) {
        $summaryLines += ''
        $summaryLines += "[Open this cycle in TestPilot]($ReportLink)"
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureMessage)) {
        $summaryLines += ''
        $summaryLines += "**Failure:** $(ConvertTo-MarkdownValue $FailureMessage)"
    }
    Add-Content -LiteralPath $Path -Value ($summaryLines -join [Environment]::NewLine) -Encoding UTF8
}

$client = $null
$runId = $null
$statusUrl = $null
$finalResponse = $null
$finalStatus = 'NOT_SUBMITTED'
$outcome = 'FAILED'
$failureMessage = $null
$reportLink = $null
$reportArtifactCount = 0
$exitCode = 1

try {
    if ($ProjectId -le 0 -or $CycleId -le 0 -or $EnvironmentId -le 0) {
        throw 'Project, cycle and environment IDs must be positive integers.'
    }
    $PipelineId = Require-Text $PipelineId 'GITHUB_RUN_ID/pipelineId' 128
    $JobId = Require-Text $JobId 'GITHUB_JOB/jobId' 128
    $CommitSha = Require-Text $CommitSha 'GITHUB_SHA/commitSha' 128
    if ($CommitSha -notmatch '^[A-Fa-f0-9]+$') {
        throw 'GITHUB_SHA/commitSha must be a hexadecimal commit identifier.'
    }
    $Branch = Require-Text $Branch 'GITHUB_REF_NAME/branch' 255
    $Credential = Require-Text $Credential 'TESTPILOT_CI_CREDENTIAL' 160

    $apiUri = $null
    if (-not [Uri]::TryCreate($ApiUrl.Trim(), [UriKind]::Absolute, [ref]$apiUri) -or
        $apiUri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrEmpty($apiUri.UserInfo)) {
        throw 'TESTPILOT_API_URL must be an absolute HTTP(S) URL without embedded credentials.'
    }
    $normalizedApiUrl = $apiUri.AbsoluteUri.TrimEnd('/')

    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        $IdempotencyKey = 'gha-{0}-{1}-p{2}-c{3}-e{4}' -f (
            $PipelineId,
            $JobId,
            $ProjectId,
            $CycleId,
            $EnvironmentId
        )
    }
    $IdempotencyKey = Require-Text $IdempotencyKey 'Idempotency-Key' 200

    if (-not [string]::IsNullOrWhiteSpace($WebUrl)) {
        $webUri = $null
        if (-not [Uri]::TryCreate($WebUrl.Trim(), [UriKind]::Absolute, [ref]$webUri) -or
            $webUri.Scheme -notin @('http', 'https') -or
            -not [string]::IsNullOrEmpty($webUri.UserInfo)) {
            throw 'TESTPILOT_WEB_URL must be an absolute HTTP(S) URL without embedded credentials.'
        }
        $reportLink = '{0}/test-management/test-cycles/{1}' -f $webUri.AbsoluteUri.TrimEnd('/'), $CycleId
    }

    $httpHandler = [System.Net.Http.HttpClientHandler]::new()
    if ($apiUri.IsLoopback) {
        $httpHandler.UseProxy = $false
    }
    $client = [System.Net.Http.HttpClient]::new($httpHandler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $client.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Credential)
    $client.DefaultRequestHeaders.Accept.Add(
        [System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json')
    )

    $requestBody = @{
        environmentId = $EnvironmentId
        pipelineId = $PipelineId
        jobId = $JobId
        commitSha = $CommitSha
        branch = $Branch
    } | ConvertTo-Json -Compress -Depth 5

    $submissionUri = [Uri](
        '{0}/api/v1/projects/{1}/test-cycles/{2}/executions' -f
            $normalizedApiUrl,
            $ProjectId,
            $CycleId
    )
    Write-Host "Submitting TestPilot project $ProjectId, cycle $CycleId, environment $EnvironmentId."
    # A network interruption after POST may still leave an accepted run. The
    # local deployment guard must not treat this as a known rejection.
    $finalStatus = 'SUBMISSION_UNKNOWN'
    $submissionResult = Invoke-TestPilotRequest `
        -Client $client `
        -Method 'POST' `
        -Uri $submissionUri `
        -JsonBody $requestBody `
        -RequestIdempotencyKey $IdempotencyKey
    if ($submissionResult.StatusCode -ne 202) {
        if ($submissionResult.StatusCode -lt 500) { $finalStatus = 'NOT_SUBMITTED' }
        throw (Get-ApiFailureMessage $submissionResult.StatusCode $submissionResult.Content 'TestPilot submission')
    }

    $submission = ConvertFrom-SafeJson $submissionResult.Content 'submission'
    $runIdValue = Get-RequiredProperty $submission 'runId' 'submission'
    if (-not [long]::TryParse([string]$runIdValue, [ref]$runId) -or $runId -le 0) {
        throw "TestPilot returned a malformed submission response: 'runId' is invalid."
    }
    $submissionStatus = [string](Get-RequiredProperty $submission 'status' 'submission')
    $statusUrlValue = [string](Get-RequiredProperty $submission 'statusUrl' 'submission')

    $baseUri = [Uri]($normalizedApiUrl + '/')
    $statusUrl = [Uri]::new($baseUri, $statusUrlValue)
    if ($statusUrl.Scheme -ne $baseUri.Scheme -or
        $statusUrl.Host -ne $baseUri.Host -or
        $statusUrl.Port -ne $baseUri.Port -or
        $statusUrl.AbsolutePath -ne "/api/v1/execution-runs/$runId") {
        throw 'TestPilot returned an unsafe or malformed statusUrl.'
    }

    $finalStatus = $submissionStatus.Trim().ToUpperInvariant()
    # Persist the run ID before polling, so an interrupted job cannot silently
    # redeploy a different application while this TestPilot run is active.
    Write-GitHubOutput -Path $OutputPath -Name 'run_id' -Value $runId
    Write-GitHubOutput -Path $OutputPath -Name 'status' -Value $finalStatus
    Write-GitHubOutput -Path $OutputPath -Name 'status_url' -Value $statusUrl
    Write-Host "TestPilot accepted run #$runId with status $finalStatus."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLoggedStatus = $null
    $activeStatuses = @('QUEUED', 'RUNNING')

    while ($true) {
        $pollResult = Invoke-TestPilotRequest `
            -Client $client `
            -Method 'GET' `
            -Uri $statusUrl `
            -JsonBody $null `
            -RequestIdempotencyKey $null
        if ($pollResult.StatusCode -ne 200) {
            throw (Get-ApiFailureMessage $pollResult.StatusCode $pollResult.Content 'TestPilot polling')
        }

        $finalResponse = ConvertFrom-SafeJson $pollResult.Content 'execution status'
        $responseRunId = [long](Get-RequiredProperty $finalResponse 'runId' 'execution status')
        $responseProjectId = [long](Get-RequiredProperty $finalResponse 'projectId' 'execution status')
        $responseCycleId = [long](Get-RequiredProperty $finalResponse 'cycleId' 'execution status')
        $responseEnvironmentId = [long](Get-RequiredProperty $finalResponse 'environmentId' 'execution status')
        $responseTrigger = [string](Get-RequiredProperty $finalResponse 'trigger' 'execution status')
        if ($responseRunId -ne $runId -or
            $responseProjectId -ne $ProjectId -or
            $responseCycleId -ne $CycleId -or
            $responseEnvironmentId -ne $EnvironmentId -or
            $responseTrigger -ne 'CI_CD') {
            throw 'TestPilot returned an execution response that does not match the submitted project, cycle, environment and CI_CD trigger.'
        }

        $metadata = Get-RequiredProperty $finalResponse 'metadata' 'execution status'
        if ([string](Get-RequiredProperty $metadata 'pipelineId' 'execution metadata') -ne $PipelineId -or
            [string](Get-RequiredProperty $metadata 'jobId' 'execution metadata') -ne $JobId -or
            [string](Get-RequiredProperty $metadata 'commitSha' 'execution metadata') -ne $CommitSha -or
            [string](Get-RequiredProperty $metadata 'branch' 'execution metadata') -ne $Branch) {
            throw 'TestPilot returned execution metadata that does not match this GitHub job.'
        }

        $finalStatus = ([string](Get-RequiredProperty $finalResponse 'status' 'execution status')).Trim().ToUpperInvariant()
        if ($finalStatus -ne $lastLoggedStatus) {
            Write-Host "TestPilot run #$runId status: $finalStatus"
            $lastLoggedStatus = $finalStatus
        }
        if ($finalStatus -notin $activeStatuses) {
            break
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "TestPilot run #$runId did not finish within $TimeoutSeconds seconds; last status was $finalStatus."
        }
        $remainingSeconds = $TimeoutSeconds - [int][Math]::Floor($stopwatch.Elapsed.TotalSeconds)
        Start-Sleep -Seconds ([Math]::Min($PollIntervalSeconds, [Math]::Max(1, $remainingSeconds)))
    }

    $result = Get-RequiredProperty $finalResponse 'result' 'terminal execution status'
    $cases = Get-OptionalProperty $result 'cases'
    if ($null -ne $cases) {
        foreach ($case in @($cases)) {
            $artifacts = Get-OptionalProperty $case 'artifacts'
            if (-not [string]::IsNullOrWhiteSpace([string](Get-OptionalProperty $artifacts 'report'))) {
                $reportArtifactCount++
            }
        }
    }

    if ($finalStatus -eq 'PASSED') {
        $outcome = 'PASSED'
        $exitCode = 0
        Write-Host "TestPilot run #$runId passed."
    }
    else {
        $outcome = 'FAILED'
        $technicalFailure = Get-OptionalProperty $finalResponse 'technicalFailure'
        $technicalCode = Get-OptionalProperty $technicalFailure 'code'
        $technicalMessage = Get-OptionalProperty $technicalFailure 'message'
        if (-not [string]::IsNullOrWhiteSpace([string]$technicalCode) -or
            -not [string]::IsNullOrWhiteSpace([string]$technicalMessage)) {
            $failureMessage = ConvertTo-SafeMessage "$technicalCode $technicalMessage"
        }
        else {
            $failureMessage = "TestPilot finished with unsuccessful status $finalStatus."
        }
        $exitCode = 1
    }
}
catch {
    $outcome = 'FAILED'
    $exitCode = 1
    $failureMessage = ConvertTo-SafeMessage $_.Exception.Message
}
finally {
    if ($null -ne $client) {
        $client.Dispose()
    }
    Write-TestPilotSummary `
        -Path $StepSummaryPath `
        -Outcome $outcome `
        -RunId $runId `
        -Status $finalStatus `
        -ResultResponse $finalResponse `
        -FailureMessage $failureMessage `
        -ReportLink $reportLink `
        -ReportArtifactCount $reportArtifactCount
    Write-GitHubOutput -Path $OutputPath -Name 'run_id' -Value $runId
    Write-GitHubOutput -Path $OutputPath -Name 'status' -Value $finalStatus
    Write-GitHubOutput -Path $OutputPath -Name 'status_url' -Value $statusUrl
    Write-GitHubOutput -Path $OutputPath -Name 'report_url' -Value $reportLink
}

if ($exitCode -ne 0) {
    Write-Error $failureMessage
}
exit $exitCode
