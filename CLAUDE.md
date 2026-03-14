# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal development sandbox VPS running Ubuntu 24.04 LTS. This repository (`/opt/infra`) contains all infrastructure configuration, scripts, and documentation for managing the server.

## Environment

- **OS:** Ubuntu 24.04.4 LTS (Noble Numbat)
- **IP:** 144.126.129.254
- **User:** marinoscar (passwordless sudo)
- **Domain:** marin.cr
- **Auth:** Authentik SSO at auth.marin.cr (separate server)

## Domains

| Subdomain | Service | Status |
|---|---|---|
| admin.dev.marin.cr | Cockpit (server admin) | Configured |
| dev.marin.cr | code-server (IDE) | Planned |
| pgadmin.dev.marin.cr | pgAdmin | Planned |

## Architecture

Host-level services: SSH, Nginx (reverse proxy + TLS), Cockpit, CrowdSec, Let's Encrypt
Containerized services (on-demand): PostgreSQL, pgAdmin, Neo4j, Redis

All public traffic routes through Nginx with TLS via Let's Encrypt. Services bind to localhost and are proxied by Nginx.

## Documentation Rule

**Every infrastructure change MUST be documented in `/opt/infra/docs/`.** Each doc should cover: what was installed, how it's configured, why decisions were made, key file paths, and troubleshooting notes. Update this CLAUDE.md to reflect current server state after changes.

## Installed Services

| Service | Status | Config |
|---|---|---|
| Cockpit + Navigator | Running (localhost:9090, --local-ssh, auto-login via Nginx) | `/etc/cockpit/cockpit.conf`, `/etc/systemd/system/cockpit.service.d/autologin.conf`, `/etc/systemd/system/cockpit.socket.d/listen.conf` |
| Nginx | Running (80, 443) | `/etc/nginx/sites-available/cockpit` |
| Let's Encrypt | Active (auto-renew) | `/etc/letsencrypt/live/admin.dev.marin.cr/` |
| UFW Firewall | Active (22, 80, 443 open) | `sudo ufw status` |

## Key Paths

- `/opt/infra/docs/` — Infrastructure documentation
- `/etc/nginx/sites-available/` — Nginx vhost configs
- `/etc/cockpit/cockpit.conf` — Cockpit configuration
- `/etc/systemd/system/cockpit.service.d/autologin.conf` — Cockpit --local-ssh mode + auto-login override
- `/etc/systemd/system/cockpit.socket.d/listen.conf` — Cockpit localhost binding override
- `/etc/cockpit/machines.d/localhost.json` — Cockpit host registration
- `/etc/cockpit/.auto-auth` — Auto-login password (root-only)
- `/etc/cockpit/.auto-auth-header` — Base64-encoded auth header for Nginx (root-only)
- `/etc/letsencrypt/` — TLS certificates
