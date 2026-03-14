# Docker Engine — Container Runtime

## What & Why

Docker Engine provides the container runtime for all optional services on this VPS (PostgreSQL, Neo4j, Redis, project-specific containers). It is installed on the host, not containerized itself, following the architecture principle that Docker supports the workstation rather than replaces it.

Installed from **Docker's official apt repository** (not Ubuntu's snap or distro package) because the official repo provides the latest engine, Compose v2 plugin, and Buildx plugin as a unified package set.

## Installed Packages

| Package | Version | Purpose |
|---|---|---|
| `docker-ce` | 29.3.0 | Docker Engine |
| `docker-ce-cli` | 29.3.0 | Docker CLI |
| `containerd.io` | 2.2.2 | Container runtime |
| `docker-buildx-plugin` | 0.31.1 | Build extension |
| `docker-compose-plugin` | 5.1.0 | Docker Compose v2 (`docker compose`) |

## User Access

`marinoscar` is a member of the `docker` group, allowing Docker commands without `sudo`. This was added via:

```bash
sudo usermod -aG docker marinoscar
```

A re-login (or `newgrp docker`) is required after the group change for it to take effect in existing sessions.

## Key Paths

| Path | Purpose |
|---|---|
| `/var/lib/docker/` | Docker data (images, volumes, containers) |
| `/etc/docker/daemon.json` | Docker daemon config (not customized — defaults are fine) |
| `/etc/apt/sources.list.d/docker.list` | Docker apt repository |
| `/etc/apt/keyrings/docker.asc` | Docker GPG key |

## Docker Network Strategy

A named bridge network `devnet` is used for all container services. This allows containers to resolve each other by container name (e.g., a future service connects to PostgreSQL via hostname `postgres`). Future services (Neo4j, Redis) should join this same network by referencing it as an external network:

```yaml
networks:
  devnet:
    external: true
```

## Operational Commands

```bash
# Running containers
docker ps

# All containers (including stopped)
docker ps -a

# Disk usage
docker system df

# Clean up unused images, containers, networks
docker system prune

# Follow container logs
docker logs -f <container-name>

# Compose commands (run from compose file directory)
docker compose up -d
docker compose down
docker compose ps
docker compose logs
```

## Docker and UFW Interaction

Docker manipulates iptables directly, which can bypass UFW rules. For services that should not be public, use `127.0.0.1:` prefix in port mappings (e.g., `127.0.0.1:8080:80`). For services that need remote access (e.g., PostgreSQL from pgadmin.marin.cr), use the `DOCKER-USER` iptables chain to restrict which IPs can connect — see `/opt/infra/scripts/docker-firewall.sh` and `/opt/infra/docs/postgres.md` for the pattern.

## Log Rotation

Docker defaults to the `json-file` log driver with no rotation. For a dev sandbox with `restart: unless-stopped` containers, logs can grow over time. If this becomes a concern, add to `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Then restart Docker: `sudo systemctl restart docker`
