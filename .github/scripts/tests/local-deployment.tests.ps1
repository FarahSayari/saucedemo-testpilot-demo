#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\LocalDeployment.ps1')
$script:sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:initial=[pscustomobject]@{
    Name='/saucedemo-local';Image='old-image';Mounts=@();Config=[pscustomobject]@{User='101'}
    State=[pscustomobject]@{Running=$true;Health=[pscustomobject]@{Status='healthy'}}
    HostConfig=[pscustomobject]@{
        NetworkMode='saucedemo-local';ReadonlyRootfs=$true;CapDrop=@('ALL');SecurityOpt=@('no-new-privileges:true')
        PortBindings=[pscustomobject]@{'8080/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='3000'})}
        RestartPolicy=[pscustomobject]@{Name='unless-stopped'};Tmpfs=[pscustomobject]@{'/tmp'='rw,noexec,nosuid,size=16m'}
        Memory=134217728;NanoCpus=1000000000;PidsLimit=128;ShmSize=67108864
        LogConfig=[pscustomobject]@{Config=[pscustomobject]@{'max-size'='10m';'max-file'='2'}}
    }
}
function Assert-True { param([bool]$Condition,[string]$Message) if (!$Condition) { throw $Message } }
function Assert-Rejected { param([scriptblock]$Action) $rejected=$false; try { & $Action } catch { $rejected=$true }; Assert-True $rejected 'Unsafe deployment scope was accepted.' }
Assert-LocalApplicationScope $script:initial
$bad=$script:initial | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$bad.Name='/testpilot-demo-api'
Assert-Rejected { Assert-LocalApplicationScope $bad }
$bad.Name='/saucedemo-local';$bad.HostConfig.PortBindings.'8080/tcp'[0].HostIp='0.0.0.0'
Assert-Rejected { Assert-LocalApplicationScope $bad }
$bad.HostConfig.PortBindings.'8080/tcp'[0].HostIp='127.0.0.1';$bad.Mounts=@([pscustomobject]@{Type='volume'})
Assert-Rejected { Assert-LocalApplicationScope $bad }
$arguments=New-ApplicationLaunchArguments $script:initial 'candidate' $script:sha '7001'
Assert-True ($arguments -contains '127.0.0.1:3000:8080') 'Loopback port is not preserved.'
Assert-True ($arguments -contains '--read-only' -and $arguments -contains 'ALL') 'Security hardening is missing.'
Assert-True ($arguments -contains '--user' -and $arguments -contains '101') 'Unprivileged application user is not preserved.'
Assert-True (!($arguments -contains '--mount') -and !($arguments -contains '--volume')) 'A host or application mount was introduced.'

# Fake Docker and HTTP: these tests never touch running containers or TestPilot.
function Invoke-DemoDocker {
    param([string[]]$Arguments)
    [void]$script:trace.Add(($Arguments -join ' '))
    switch ($Arguments[0]) {
        'ps' { return @($script:names) }
        'build' { if ($script:mode -eq 'build-failure') { throw 'mock build failure' }; return 'mock build complete' }
        'image' { return ([pscustomobject]@{Id='new-image';Config=[pscustomobject]@{Labels=[pscustomobject]@{'org.opencontainers.image.revision'=$script:sha}}} | ConvertTo-Json -Depth 10) }
        'inspect' {
            if ($Arguments -contains '--format') {
                if ($script:mode -eq 'health-failure') { return 'unhealthy' }
                return 'healthy'
            }
            $container=$script:initial | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            if ($script:launched) { $container.Image='new-image' }
            return ($container | ConvertTo-Json -Depth 20)
        }
        'rename' {
            Assert-True ($script:names.Contains($Arguments[1])) 'Mock rename source does not exist.'
            [void]$script:names.Remove($Arguments[1]);[void]$script:names.Add($Arguments[2]);return ''
        }
        'run' {
            if ($script:mode -eq 'launch-failure') { throw 'mock launch failure' }
            $script:launched=$true;[void]$script:names.Add('saucedemo-local');return 'mock-container-id'
        }
        'start' { $script:launched=$false; return 'mock restored' }
        default { return '' }
    }
}
function Invoke-WebRequest {
    param([switch]$UseBasicParsing,[string]$Uri,[int]$TimeoutSec)
    return [pscustomobject]@{StatusCode=200;Content='<title>Swag Labs</title>'}
}
$fixtureRoot=Join-Path $PSScriptRoot 'fixtures'
foreach ($mode in @('success','build-failure','launch-failure','health-failure')) {
    $script:mode=$mode;$script:launched=$false;$script:trace=[Collections.Generic.List[string]]::new()
    $script:names=[Collections.Generic.List[string]]::new()
    foreach ($name in @('saucedemo-local','testpilot-demo-api','testpilot-demo-worker')) { [void]$script:names.Add($name) }
    $failed=$false
    try { $result=Deploy-LocalApplication $fixtureRoot $script:sha '7001' } catch { $failed=$true }
    if ($mode -eq 'success') {
        Assert-True (!$failed) 'Successful deployment fixture failed.'
        Assert-True ($result.ImageId -eq 'new-image') 'Incorrect image provenance.'
        $build=$script:trace.FindIndex([Predicate[string]]{param($value) $value.StartsWith('build ')})
        $stop=$script:trace.FindIndex([Predicate[string]]{param($value) $value.StartsWith('stop ')})
        Assert-True ($build -ge 0 -and $stop -gt $build) 'Live website stopped before build finished.'
    } elseif ($mode -eq 'build-failure') {
        Assert-True $failed 'Build failure did not fail the job.'
        Assert-True (@($script:trace | Where-Object { $_ -match '^(stop|rename|run) ' }).Count -eq 0) 'Build failure disturbed the live application.'
    } else {
        Assert-True $failed 'Health failure did not fail the job.'
        Assert-True ($script:trace -contains 'rename saucedemo-local-before-7001 saucedemo-local') 'Rollback did not restore the prior application name.'
        Assert-True ($script:trace -contains 'start saucedemo-local') 'Rollback did not start the prior application.'
    }
    Assert-True (@($script:trace | Where-Object { $_ -match '^(stop|rename|run|rm|start) ' -and $_ -match '(?:^|\s)testpilot-demo-(?:api|worker)(?:\s|$)' }).Count -eq 0) 'Deployment modified a TestPilot container.'
    Assert-True (@($script:trace | Where-Object { $_ -match '^rm ' }).Count -eq 0) 'Deployment deleted a retained container.'
    Write-Host "PASS: $mode deployment fixture."
}
$outputFixture=Join-Path ([IO.Path]::GetTempPath()) ('saucedemo-output-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    @('run_id=701','status=QUEUED','status=PASSED') | Set-Content -LiteralPath $outputFixture -Encoding UTF8
    $values=Read-CycleOutput $outputFixture
    Assert-True ($values.run_id -eq '701' -and $values.status -eq 'PASSED') 'Interrupted/final cycle output cannot be recovered.'
} finally { Remove-Item -LiteralPath $outputFixture -ErrorAction SilentlyContinue }
Write-Host 'PASS: scoped deployment, loopback/security preservation, rollback and output recovery contracts.'
