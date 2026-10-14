# Local Sauce Demo

Fork: https://github.com/FarahSayari/saucedemo-testpilot-demo

Open http://127.0.0.1:3000/ in your browser.
Demo login: `standard_user` / `secret_sauce`.

The local setup uses a separate `saucedemo-local` container and dedicated Docker
network. Only `127.0.0.1:3000` is published. The container runs as a non-root user
with a read-only filesystem, temporary writable storage, no host mounts, and
limits of one CPU, 128 MiB RAM, and 128 processes.

For the separately prepared push-triggered pipeline, see [CI-LOCAL.md](CI-LOCAL.md).
That setup is not published or registered automatically; it has operator gates.

The original MIT license and Sauce Labs copyright remain in `LICENSE` and are
also included in the container at `/usr/share/nginx/html/LICENSE`.

## Stop and start

```powershell
docker stop saucedemo-local
docker start saucedemo-local
```

## Build and create on a fresh setup

Run from `C:\Users\sayar\saucedemo-testpilot-demo`. The network and container
creation commands are for a setup where these names do not already exist.

```powershell
docker build --file Dockerfile.local --tag saucedemo-local:latest .
docker network create --driver bridge --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 saucedemo-local
docker run --detach --name saucedemo-local --network saucedemo-local --publish 127.0.0.1:3000:8080 --restart unless-stopped --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges:true --cpus 1 --memory 128m --pids-limit 128 --log-opt max-size=10m --log-opt max-file=2 saucedemo-local:latest
```

## Check status

```powershell
docker ps --filter name=saucedemo-local
docker logs --tail 30 saucedemo-local
```

`Dockerfile.local` is separate because the original upstream Dockerfile uses
Node 14, while the current application requires Node 24. No GitHub Actions or
public deployment settings were configured for this setup.

## TestPilot loopback relays

Two separate relay containers let the existing TestPilot containers reach this
app through the absolute `http://127.0.0.1:3000/` URLs already recorded in their
environment, scenario, and Cypress script. No URL rewriting is required.

| Relay | Shares network namespace with | TCP forwarding |
| --- | --- | --- |
| `saucedemo-api-relay` | `testpilot-demo-api` | `127.0.0.1:3000` to `host.docker.internal:3000` |
| `saucedemo-worker-relay` | `testpilot-demo-worker` | `127.0.0.1:3000` to `host.docker.internal:3000` |

Each relay runs as non-root, publishes no host ports, and has no host or TestPilot
volume mounts. Its filesystem is read-only with a small temporary directory.
The relays use their own image, `saucedemo-loopback-relay:local`, and do not
change or restart any TestPilot container. TCP forwarding preserves HTTP headers
and the browser's original loopback URL.

From this repository folder, verify HTTP 200 and Swag Labs HTML from both
TestPilot containers:

```powershell
.\Manage-LocalRelays.ps1 -Action Verify
```

This checks connectivity and relay attachment; it does not run Cypress or write
TestPilot data.

Remove both relays, leaving SauceDemo and TestPilot running:

```powershell
.\Manage-LocalRelays.ps1 -Action Remove
```

To add them again:

```powershell
.\Manage-LocalRelays.ps1 -Action Install
```

If TestPilot's API or worker is recreated, its container ID and network namespace
change. Once the replacement container is running with the same name, recreate
only the corresponding relay to attach to that new namespace:

```powershell
# After testpilot-demo-api is recreated:
.\Manage-LocalRelays.ps1 -Action Reattach -Target API

# After testpilot-demo-worker is recreated:
.\Manage-LocalRelays.ps1 -Action Reattach -Target Worker

# If both were recreated:
.\Manage-LocalRelays.ps1 -Action Reattach
```

Reattachment removes and recreates only the selected relay, then verifies
connectivity from its TestPilot target. The script checks ownership labels
before removing a relay. It never recreates or restarts TestPilot containers.
The relays restart automatically unless stopped; run `Verify` after Docker or
TestPilot restarts and `Reattach` if a relay's attachment is stale.
