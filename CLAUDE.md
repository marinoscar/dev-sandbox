# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal development sandbox VPS running Ubuntu 24.04 LTS. This repository (`/opt/infra`) contains all infrastructure configuration, scripts, and documentation for managing the server.

## Environment

- **OS:** Ubuntu 24.04.4 LTS (Noble Numbat)
- **IP:** 144.126.129.254
- **User:** marinoscar (passwordless sudo via `/etc/sudoers.d/marinoscar`)
- **Domain:** marin.cr
- **Auth:** Authentik SSO at auth.marin.cr (separate server)

## Domains

| Subdomain | Service | Auth | Status |
|---|---|---|---|
| admin.dev.marin.cr | Cockpit (server admin) | Authentik SSO | Active |
| code.marin.cr | code-server (IDE) | Authentik SSO | Active |
| knecta.dev.marin.cr | Knecta web app (port 8319) | Google OAuth | Active |
| *.dev.marin.cr | Wildcard reverse proxy | Per-project | Active |

## Architecture

Host-level services: SSH, Nginx (reverse proxy + TLS + Authentik forward auth), Cockpit, code-server, CrowdSec, Docker Engine, Let's Encrypt
Containerized services (running): PostgreSQL, Portainer Agent
Containerized services (on-demand): Neo4j, Redis

All public traffic routes through Nginx with TLS via Let's Encrypt. Services bind to localhost and are proxied by Nginx. Authentik at auth.marin.cr provides SSO via Nginx `auth_request`.

## Documentation Rule

**Every infrastructure change MUST be documented in `/opt/infra/docs/`.** Each doc should cover: what was installed, how it's configured, why decisions were made, key file paths, and troubleshooting notes. Update this CLAUDE.md to reflect current server state after changes.

## Authentik Integration Pattern

When adding new services behind Authentik, use **Forward auth (single application)** mode (not domain-level). See `/opt/infra/docs/cockpit.md` section "Nginx + Authentik Pattern for Future Services" and "Critical Pitfalls Learned" for detailed guidance. Key rules:
- `Host` header to Authentik must be `auth.marin.cr`, not `$host`
- `Authorization` header must be cleared in auth subrequest locations
- Use single-application mode when multiple providers share the same outpost

## Installed Services

| Service | Status | Config |
|---|---|---|
| Cockpit + Navigator | Running (localhost:9090, --local-ssh, Authentik SSO + auto-login) | `/etc/cockpit/cockpit.conf`, systemd overrides |
| code-server | Running (localhost:8081, auth: none, Authentik SSO) | `/home/marinoscar/.config/code-server/config.yaml` |
| Nginx | Running (80, 443) | `/etc/nginx/sites-available/{cockpit,code-server,dev-wildcard}` |
| Let's Encrypt | Active (auto-renew) | `/etc/letsencrypt/live/{admin.dev,code,dev}.marin.cr/` |
| Wildcard HTTPS Proxy | Active (*.dev.marin.cr → per-project ports) | `/etc/nginx/sites-available/dev-wildcard` |
| CrowdSec | Active (agent + firewall bouncer, escalating bans) | `/etc/crowdsec/profiles.yaml`, `/etc/crowdsec/acquis.d/nginx.yaml` |
| Portainer Agent | Running (container, 0.0.0.0:9001, restricted to portainer.marin.cr) | `/opt/infra/docs/portainer-agent.md` |
| UFW Firewall | Active (22, 80, 443, 5432 from pgadmin.marin.cr, 9001 from portainer.marin.cr) | `sudo ufw status` |
| Docker Engine | Running (29.3.0 + Compose v5.1.0) | `/etc/docker/`, Docker official apt repo |
| PostgreSQL | Running (17.9, container, 0.0.0.0:5432) | `/opt/infra/containers/postgres/docker-compose.yml` |
| Docker Firewall | Active (DOCKER-USER iptables, restricts 5432) | `/opt/infra/scripts/docker-firewall.sh` |

## Key Paths

- `/opt/infra/docs/` — Infrastructure documentation
- `/etc/nginx/sites-available/` — Nginx vhost configs
- `/etc/cockpit/cockpit.conf` — Cockpit configuration
- `/etc/systemd/system/cockpit.service.d/autologin.conf` — Cockpit --local-ssh mode override
- `/etc/systemd/system/cockpit.socket.d/listen.conf` — Cockpit localhost binding override
- `/etc/cockpit/machines.d/localhost.json` — Cockpit host registration
- `/etc/cockpit/.auto-auth` — Auto-login password (root-only)
- `/etc/cockpit/.auto-auth-header` — Base64-encoded auth header for Nginx (root-only)
- `/etc/crowdsec/profiles.yaml` — CrowdSec ban duration policy
- `/etc/crowdsec/acquis.d/nginx.yaml` — CrowdSec Nginx log acquisition
- `/etc/letsencrypt/` — TLS certificates
- `/opt/infra/containers/postgres/docker-compose.yml` — PostgreSQL compose file
- `/opt/infra/containers/postgres/.env` — Database credentials (chmod 600, gitignored)
- `/opt/infra/scripts/docker-firewall.sh` — DOCKER-USER iptables rules (restricts ports 5432, 9001)
- `/etc/systemd/system/docker-firewall.service` — Persists Docker firewall rules across reboots
- `/home/marinoscar/.config/code-server/config.yaml` — code-server configuration
- `/etc/nginx/sites-available/code-server` — code-server Nginx vhost config
- `/etc/nginx/sites-available/dev-wildcard` — Wildcard reverse proxy for *.dev.marin.cr (subdomain → port map)
- `/etc/letsencrypt/live/dev.marin.cr/` — Wildcard SSL certificate for *.dev.marin.cr
- `/root/.aws/credentials` — AWS credentials for Certbot Route 53 DNS-01 renewal

## Web App Hosting

Projects are hosted via HTTPS subdomains under `*.dev.marin.cr`. See `/opt/infra/docs/web-app-hosting.md` for full details.

**To add a new project:** Edit the `map` block in `/etc/nginx/sites-available/dev-wildcard`, add one line mapping subdomain to port, reload Nginx. No DNS or SSL changes needed — the wildcard covers everything.
