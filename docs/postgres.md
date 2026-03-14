# PostgreSQL — Database Service

## What & Why

PostgreSQL is the relational database for development projects. It runs as a Docker container following the architecture principle that supporting services are containerized while the workstation layer stays on the host.

PostgreSQL is managed remotely via the existing pgAdmin instance at `pgadmin.marin.cr` (a separate server at `195.26.247.169`). There is no local pgAdmin on this VPS.

## Architecture

```
pgadmin.marin.cr (195.26.247.169)
  │
  ▼ (TCP 5432, allowed via DOCKER-USER iptables)
PostgreSQL container (0.0.0.0:5432)
  ▲
  │
Host CLI (psql -h 127.0.0.1)
```

## Version

| Component | Version | Image |
|---|---|---|
| PostgreSQL | 17.9 | `postgres:17` |

## Configuration Files

### `/opt/infra/containers/postgres/docker-compose.yml`

Defines the PostgreSQL service, volume, and network.

Key design decisions:
- **`5432:5432`** — PostgreSQL accessible from host and from the remote pgAdmin server
- **`restart: unless-stopped`** — container starts on boot unless explicitly stopped ("optional always-on" per architecture)
- **Named volume** (`pgdata`) — survives container recreation
- **`devnet` bridge network** — future containers can connect to PostgreSQL by container name

### `/opt/infra/containers/postgres/.env`

Contains credentials (chmod 600, excluded from Git via `.gitignore`):
- `POSTGRES_USER` — database superuser name
- `POSTGRES_PASSWORD` — database superuser password
- `POSTGRES_DB` — default database name

### `/opt/infra/scripts/docker-firewall.sh`

Iptables rules applied to the `DOCKER-USER` chain to restrict who can reach PostgreSQL. Docker bypasses UFW by manipulating iptables directly, so UFW rules alone are not sufficient — the `DOCKER-USER` chain is the correct place to filter traffic to container-published ports.

Allowed sources for port 5432:
- `195.26.247.169` — pgadmin.marin.cr
- `127.0.0.1` — localhost (host CLI access)
- `172.16.0.0/12` — Docker internal networks (container-to-container)

All other sources are dropped.

### `/etc/systemd/system/docker-firewall.service`

Systemd oneshot service that runs `/opt/infra/scripts/docker-firewall.sh` after Docker starts, ensuring the iptables rules persist across reboots.

## Connecting to PostgreSQL

### From host CLI

```bash
psql -h 127.0.0.1 -U admin -d devdb
```

### From pgAdmin at pgadmin.marin.cr

Add a server connection in pgAdmin:
- **Host:** `144.126.129.254` (this VPS's public IP)
- **Port:** `5432`
- **Username:** value of `POSTGRES_USER` from `.env`
- **Password:** value of `POSTGRES_PASSWORD` from `.env`

### From other Docker containers

Connect to `postgres:5432` on the `devnet` network. Add the network to your service's compose file:

```yaml
networks:
  devnet:
    external: true
```

## Operational Commands

```bash
# Start service
cd /opt/infra/containers/postgres && docker compose up -d

# Stop service
cd /opt/infra/containers/postgres && docker compose down

# View status
docker compose -f /opt/infra/containers/postgres/docker-compose.yml ps

# View logs
docker logs postgres --tail 50

# PostgreSQL shell
psql -h 127.0.0.1 -U admin -d devdb

# Create a new database
psql -h 127.0.0.1 -U admin -d devdb -c "CREATE DATABASE myproject;"

# Backup a database
docker exec postgres pg_dump -U admin devdb > backup.sql

# Restore a database
cat backup.sql | docker exec -i postgres psql -U admin -d devdb

# Backup all databases
docker exec postgres pg_dumpall -U admin > all_databases.sql

# Reload firewall rules
sudo systemctl restart docker-firewall

# View current DOCKER-USER rules
sudo iptables -L DOCKER-USER -n --line-numbers
```

## Volume

| Volume | Purpose |
|---|---|
| `postgres_pgdata` | PostgreSQL data directory — all databases, tables, indexes |

To inspect:
```bash
docker volume inspect postgres_pgdata
```

## Firewall Details

### Why DOCKER-USER instead of UFW

Docker inserts its own iptables rules that bypass UFW entirely. When a container publishes a port (e.g., `5432:5432`), Docker adds DNAT rules in the `DOCKER` chain that forward traffic directly to the container, skipping the INPUT chain where UFW operates. The `DOCKER-USER` chain is the only iptables chain that Docker guarantees will be evaluated before its own rules — it is the correct place to restrict access to published container ports.

### Adding a new allowed IP

Edit `/opt/infra/scripts/docker-firewall.sh` to add a new `iptables -A DOCKER-USER -p tcp --dport 5432 -s <IP> -j ACCEPT` line before the DROP rule, then:

```bash
sudo systemctl restart docker-firewall
```

## Troubleshooting

- **PostgreSQL not starting:** Check `docker logs postgres`. Common issue: volume permissions after Docker upgrade. Try `docker compose down && docker compose up -d`.
- **Can't connect from host:** Verify port mapping: `docker compose ps` should show `0.0.0.0:5432->5432/tcp`. Try `psql -h 127.0.0.1 -U admin -d devdb`.
- **Can't connect from pgadmin.marin.cr:** Check DOCKER-USER rules: `sudo iptables -L DOCKER-USER -n`. Ensure `195.26.247.169` has an ACCEPT rule. Check the firewall script ran: `sudo systemctl status docker-firewall`.
- **Connection refused after reboot:** Ensure `docker-firewall.service` is enabled: `sudo systemctl is-enabled docker-firewall`. Ensure Docker started: `sudo systemctl status docker`.
- **Data loss after `docker compose down`:** Named volumes persist across `down`/`up` cycles. Data is only lost if you explicitly remove volumes with `docker compose down -v` or `docker volume rm`.
