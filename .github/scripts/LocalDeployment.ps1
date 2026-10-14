#Requires -Version 5.1
# Functions only: loading this file never changes Docker state.
Set-StrictMode -Version Latest

function Invoke-DemoDocker {
    param([string[]]$Arguments)
    $result = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker '$($Arguments[0])' failed. No TestPilot container is changed by this script." }
    return $result
}

function Assert-LocalApplicationScope {
    param([object]$Container)
    if ($Container.Name -ne '/saucedemo-local') { throw 'Only saucedemo-local may be deployed.' }
    if (!$Container.State.Running) { throw 'The existing local SauceDemo must be running before deployment.' }
    if ($Container.HostConfig.NetworkMode -ne 'saucedemo-local') { throw 'Unexpected local application network.' }
    if ($Container.Config.User -ne '101') { throw 'Unexpected local application user; deployment requires the existing unprivileged UID 101.' }
    $ports = @($Container.HostConfig.PortBindings.PSObject.Properties)
    if ($ports.Count -ne 1 -or $ports[0].Name -ne '8080/tcp' -or $ports[0].Value.Count -ne 1 -or
        $ports[0].Value[0].HostIp -ne '127.0.0.1' -or $ports[0].Value[0].HostPort -ne '3000') {
        throw 'Local application must retain only 127.0.0.1:3000 -> 8080.'
    }
    if (@($Container.Mounts | Where-Object Type -ne 'tmpfs').Count -ne 0) { throw 'Unexpected application volume or host mount.' }
    if (!$Container.HostConfig.ReadonlyRootfs -or 'ALL' -notin $Container.HostConfig.CapDrop -or
        'no-new-privileges:true' -notin $Container.HostConfig.SecurityOpt) { throw 'Local application security settings changed.' }
}

function Get-LocalApplication {
    $raw = Invoke-DemoDocker @('inspect','saucedemo-local')
    $container = ($raw | ConvertFrom-Json)[0]
    Assert-LocalApplicationScope $container
    return $container
}

function New-ApplicationLaunchArguments {
    param([object]$Previous,[string]$Image,[string]$CommitSha,[string]$RunId)
    $arguments = @('run','--detach','--name','saucedemo-local','--network','saucedemo-local',
        '--publish','127.0.0.1:3000:8080','--restart',$Previous.HostConfig.RestartPolicy.Name,
        '--user','101',
        '--read-only','--cap-drop','ALL','--security-opt','no-new-privileges:true',
        '--label','io.saucedemo.scope=local-testpilot-demo',
        '--label',"io.saucedemo.commit=$CommitSha",'--label',"io.saucedemo.github-run=$RunId")
    foreach ($entry in $Previous.HostConfig.Tmpfs.PSObject.Properties) { $arguments += @('--tmpfs',"$($entry.Name):$($entry.Value)") }
    if ($Previous.HostConfig.Memory) { $arguments += @('--memory',[string]$Previous.HostConfig.Memory) }
    if ($Previous.HostConfig.NanoCpus) { $arguments += @('--cpus',($Previous.HostConfig.NanoCpus / 1000000000).ToString([Globalization.CultureInfo]::InvariantCulture)) }
    if ($Previous.HostConfig.PidsLimit) { $arguments += @('--pids-limit',[string]$Previous.HostConfig.PidsLimit) }
    $arguments += @('--shm-size',[string]$Previous.HostConfig.ShmSize)
    foreach ($entry in $Previous.HostConfig.LogConfig.Config.PSObject.Properties) { $arguments += @('--log-opt',"$($entry.Name)=$($entry.Value)") }
    $arguments += $Image
    return $arguments
}

function Assert-LocalWebsite {
    param([string]$ExpectedImageId)
    $container = Get-LocalApplication
    if ($container.Image -ne $ExpectedImageId) { throw 'The deployed image does not match the newly built commit.' }
    if ($container.State.Health.Status -ne 'healthy') { throw 'Local application is not healthy.' }
    $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3000/' -TimeoutSec 10
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>Swag Labs</title>') { throw 'The application is not the expected SauceDemo website.' }
}

function Restore-LocalApplication {
    param([string]$BackupName,[string]$FailedName)
    # Exact names established by this deployment only; no volumes or images removed.
    $names = @(Invoke-DemoDocker @('ps','-a','--format','{{.Names}}'))
    if ('saucedemo-local' -in $names) {
        Invoke-DemoDocker @('stop','--time','10','saucedemo-local') | Out-Null
        Invoke-DemoDocker @('rename','saucedemo-local',$FailedName) | Out-Null
    }
    Invoke-DemoDocker @('rename',$BackupName,'saucedemo-local') | Out-Null
    Invoke-DemoDocker @('start','saucedemo-local') | Out-Null
}

function Deploy-LocalApplication {
    param([string]$RepositoryRoot,[string]$CommitSha,[string]$RunId)
    if ($CommitSha -notmatch '^[a-fA-F0-9]{40,64}$' -or $RunId -notmatch '^[0-9]+$') { throw 'Invalid GitHub commit or run identity.' }
    $previous = Get-LocalApplication
    $backup = "saucedemo-local-before-$RunId"
    $failed = "saucedemo-local-failed-$RunId"
    $names = @(Invoke-DemoDocker @('ps','-a','--format','{{.Names}}'))
    if ($backup -in $names -or $failed -in $names) { throw 'Deployment backup already exists. Start a new workflow run rather than re-running a deployment.' }
    $image = "saucedemo-local:commit-$CommitSha-run-$RunId"
    Write-Host "Building SauceDemo commit $CommitSha. The running website remains available during build."
    Invoke-DemoDocker @('build','--file',(Join-Path $RepositoryRoot 'Dockerfile.local'),
        '--label',"org.opencontainers.image.revision=$CommitSha",
        '--label','org.opencontainers.image.source=https://github.com/FarahSayari/saucedemo-testpilot-demo',
        '--tag',$image,$RepositoryRoot) | Out-Host
    $candidate = ((Invoke-DemoDocker @('image','inspect',$image)) | ConvertFrom-Json)[0]
    if ($candidate.Config.Labels.'org.opencontainers.image.revision' -ne $CommitSha) { throw 'Candidate image has incorrect provenance.' }
    # Build completed successfully before the live application is stopped.
    $renamed = $false
    try {
        Invoke-DemoDocker @('stop','--time','15','saucedemo-local') | Out-Null
        Invoke-DemoDocker @('rename','saucedemo-local',$backup) | Out-Null
        $renamed = $true
        $arguments = New-ApplicationLaunchArguments $previous $image $CommitSha $RunId
        Invoke-DemoDocker $arguments | Out-Null
        $ready = $false
        for ($attempt=0; $attempt -lt 45; $attempt++) {
            $status = Invoke-DemoDocker @('inspect','saucedemo-local','--format','{{.State.Health.Status}}')
            if ($status -eq 'healthy') { $ready=$true; break }
            if ($status -eq 'unhealthy') { throw 'The candidate application health check failed.' }
            Start-Sleep -Seconds 2
        }
        if (!$ready) { throw 'The candidate application did not become healthy.' }
        Assert-LocalWebsite $candidate.Id
        # Read-only checks: never Install, Remove or Reattach TestPilot relays here.
        & (Join-Path $RepositoryRoot 'Manage-LocalRelays.ps1') -Action Verify
        Write-Host "Deployed $image at http://127.0.0.1:3000/. Previous container retained as $backup."
    } catch {
        $failure=$_.Exception.Message
        if ($renamed) { Restore-LocalApplication $backup $failed }
        else { Invoke-DemoDocker @('start','saucedemo-local') | Out-Null }
        throw "Local deployment failed; previous website restored. $failure"
    }
    return [pscustomobject]@{Image=$image;ImageId=$candidate.Id;Backup=$backup;Commit=$CommitSha;RunId=$RunId}
}

function Read-CycleOutput {
    param([string]$Path)
    $values=@{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^(run_id|status|status_url|report_url)=(.*)$') { $values[$matches[1]]=$matches[2] }
        }
    }
    return $values
}
