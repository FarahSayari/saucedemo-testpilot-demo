[CmdletBinding()]
param(
    [ValidateSet('Install', 'Remove', 'Reattach', 'Verify')]
    [string]$Action = 'Verify',
    [ValidateSet('All', 'API', 'Worker')]
    [string]$Target = 'All'
)

$ErrorActionPreference = 'Stop'
$relayImage = 'saucedemo-loopback-relay:local'
$ownerLabel = 'io.saucedemo.scope'
$ownerValue = 'loopback-relay'
$targets = @(
    @{ Key = 'API'; Container = 'testpilot-demo-api'; Relay = 'saucedemo-api-relay' },
    @{ Key = 'Worker'; Container = 'testpilot-demo-worker'; Relay = 'saucedemo-worker-relay' }
) | Where-Object { $Target -eq 'All' -or $_.Key -eq $Target }

function Invoke-Docker {
    param([string[]]$DockerArgs)
    $output = & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed: $($DockerArgs[0])"
    }
    return $output
}

function Get-OwnedRelay {
    param([hashtable]$Mapping)
    $found = Invoke-Docker -DockerArgs @('ps', '-a', '--filter', "name=^$($Mapping.Relay)$", '--format', '{{.Names}}')
    if (-not $found) { return $null }
    $relay = (Invoke-Docker -DockerArgs @('inspect', $Mapping.Relay) | ConvertFrom-Json)[0]
    if ($relay.Config.Labels.$ownerLabel -ne $ownerValue -or
        $relay.Config.Labels.'io.saucedemo.target' -ne $Mapping.Container) {
        throw "Refusing to change $($Mapping.Relay): ownership labels do not match."
    }
    return $relay
}

if ($Action -in @('Install', 'Reattach')) {
    # Preflight every selected target before removing or creating any relay.
    foreach ($mapping in $targets) {
        $parent = (Invoke-Docker -DockerArgs @('inspect', $mapping.Container) | ConvertFrom-Json)[0]
        if (-not $parent.State.Running) { throw "$($mapping.Container) must already be running." }
        $mapping.ParentId = $parent.Id
        $mapping.Existing = Get-OwnedRelay -Mapping $mapping
        if ($Action -eq 'Install' -and $mapping.Existing -and
            $mapping.Existing.HostConfig.NetworkMode -ne "container:$($parent.Id)") {
            throw "$($mapping.Relay) is attached to an older container. Use -Action Reattach -Target $($mapping.Key)."
        }
    }
    Invoke-Docker -DockerArgs @('build', '--file', (Join-Path $PSScriptRoot 'Dockerfile.relay'), '--tag', $relayImage, $PSScriptRoot)
    foreach ($mapping in $targets) {
        if ($Action -eq 'Reattach' -and $mapping.Existing) {
            Invoke-Docker -DockerArgs @('rm', '--force', $mapping.Relay)
            $mapping.Existing = $null
        }
        if (-not $mapping.Existing) {
            Invoke-Docker -DockerArgs @(
                'run', '--detach', '--name', $mapping.Relay,
                '--network', "container:$($mapping.ParentId)",
                '--label', "$ownerLabel=$ownerValue",
                '--label', "io.saucedemo.target=$($mapping.Container)",
                '--restart', 'unless-stopped', '--read-only',
                '--tmpfs', '/tmp:rw,noexec,nosuid,size=8m',
                '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                '--cpus', '0.25', '--memory', '32m', '--pids-limit', '32',
                '--log-opt', 'max-size=5m', '--log-opt', 'max-file=2', $relayImage
            )
        }
    }
}

if ($Action -eq 'Remove') {
    # Verify ownership for all selected names before removing anything.
    foreach ($mapping in $targets) { $mapping.Existing = Get-OwnedRelay -Mapping $mapping }
    foreach ($mapping in $targets) {
        if ($mapping.Existing) { Invoke-Docker -DockerArgs @('rm', '--force', $mapping.Relay) }
    }
    return
}

$probe = @'
const http = require('http');
const url = 'http://127.0.0.1:3000/';
async function check() {
  for (let attempt = 1; attempt <= 20; attempt++) {
    try {
      const result = await new Promise((resolve, reject) => {
        const req = http.get(url, {timeout: 3000}, res => {
          let body = ''; res.setEncoding('utf8');
          res.on('data', chunk => body += chunk);
          res.on('end', () => resolve({status:res.statusCode, body}));
          res.on('error', reject);
        });
        req.on('timeout', () => req.destroy(new Error('Timeout')));
        req.on('error', reject);
      });
      if (result.status !== 200 || !result.body.includes('<title>Swag Labs</title>')) {
        throw new Error('Expected SauceDemo HTTP 200, got ' + result.status);
      }
      console.log('PASS: ' + url + ' -> HTTP 200, Swag Labs HTML');
      return;
    } catch (error) {
      if (attempt === 20) throw error;
      await new Promise(resolve => setTimeout(resolve, 250));
    }
  }
}
check().catch(error => { console.error(error.message); process.exitCode = 1; });
'@

foreach ($mapping in $targets) {
    $parent = (Invoke-Docker -DockerArgs @('inspect', $mapping.Container) | ConvertFrom-Json)[0]
    $relay = Get-OwnedRelay -Mapping $mapping
    if (-not $relay -or -not $relay.State.Running -or
        $relay.HostConfig.NetworkMode -ne "container:$($parent.Id)") {
        throw "$($mapping.Relay) must be running and attached to the current $($mapping.Container)."
    }
    Write-Output "Checking $($mapping.Container)"
    $probe | & docker exec -i $mapping.Container node
    if ($LASTEXITCODE -ne 0) { throw "Loopback connectivity failed in $($mapping.Container)." }
}
