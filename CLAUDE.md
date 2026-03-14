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
| dev.marin.cr | code-server (IDE) | — | Planned |
| pgadmin.dev.marin.cr | pgAdmin | — | Planned |

## Architecture

Host-level services: SSH, Nginx (reverse proxy + TLS + Authentik forward auth), Cockpit, Let's Encrypt
Containerized services (on-demand): PostgreSQL, pgAdmin, Neo4j, Redis

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
| Nginx | Running (80, 443) | `/etc/nginx/sites-available/cockpit` |
| Let's Encrypt | Active (auto-renew) | `/etc/letsencrypt/live/admin.dev.marin.cr/` |
| UFW Firewall | Active (22, 80, 443 open) | `sudo ufw status` |

## Key Paths

- `/opt/infra/docs/` — Infrastructure documentation
- `/etc/nginx/sites-available/` — Nginx vhost configs
- `/etc/cockpit/cockpit.conf` — Cockpit configuration
- `/etc/systemd/system/cockpit.service.d/autologin.conf` — Cockpit --local-ssh mode override
- `/etc/systemd/system/cockpit.socket.d/listen.conf` — Cockpit localhost binding override
- `/etc/cockpit/machines.d/localhost.json` — Cockpit host registration
- `/etc/cockpit/.auto-auth` — Auto-login password (root-only)
- `/etc/cockpit/.auto-auth-header` — Base64-encoded auth header for Nginx (root-only)
- `/etc/letsencrypt/` — TLS certificates
