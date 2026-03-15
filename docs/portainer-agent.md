# Portainer Agent

## Overview

The Portainer Agent allows the remote Portainer instance at `portainer.marin.cr` (195.26.247.169) to manage the Docker Engine on this server.

## What Was Installed

- **Portainer Agent** container (`portainer/agent:latest`) listening on port 9001
- Firewall rules restricting port 9001 to the Portainer server IP only

## How It's Configured

### Container

```bash
docker run -d -p 9001:9001 --name portainer_agent --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/volumes:/var/lib/docker/volumes \
  portainer/agent:latest
```

The agent mounts the Docker socket to communicate with the local Docker Engine, and the volumes directory so Portainer can browse volume contents.

### Firewall

Port 9001 is restricted at two levels:

1. **UFW:** `sudo ufw allow from 195.26.247.169 to any port 9001 proto tcp`
2. **DOCKER-USER iptables chain** (in `/opt/infra/scripts/docker-firewall.sh`): Accepts traffic on port 9001 from `195.26.247.169`, `127.0.0.1`, and `172.16.0.0/12` (Docker networks); drops everything else.

Both layers are necessary because Docker bypasses UFW.

## Portainer Connection

In the Portainer UI at `portainer.marin.cr`:

1. **Environments** → **Add environment**
2. Select **Docker** → **Agent**
3. Environment address: `144.126.129.254:9001`
4. Name: e.g., "dev-vps"
5. Click **Connect**

## Key Paths

| Path | Purpose |
|---|---|
| `/opt/infra/scripts/docker-firewall.sh` | DOCKER-USER iptables rules (restricts port 9001) |
| `/etc/systemd/system/docker-firewall.service` | Persists firewall rules across reboots |

## Troubleshooting

- **Agent not reachable from Portainer:** Check `sudo iptables -L DOCKER-USER -n -v` and `sudo ufw status` to verify 195.26.247.169 is allowed on port 9001.
- **Agent container not running:** `docker ps -a --filter name=portainer_agent` — restart with `docker start portainer_agent`.
- **Portainer server IP changed:** Update both UFW (`sudo ufw delete allow from <old_ip> ...` then re-add) and `/opt/infra/scripts/docker-firewall.sh`, then re-run the script.
