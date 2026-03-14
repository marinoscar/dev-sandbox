# Development Sandbox Architecture for `dev.marin.cr`

## Purpose

This VPS is **not** a production server and **not** just a generic Ubuntu box.
It is a **personal remote development sandbox** designed to let you build, run, test, and manage multiple software projects from anywhere in the world.

The goal is for this machine to behave like:

* a personal cloud laptop
* a secure remote coding workstation
* a flexible multi-project development environment
* a safe sandbox for trying ideas, running local stacks, and testing services without affecting production
* a persistent place to keep repositories, tools, scripts, and development workflows available from any device

This document is intentionally written for a **development sandbox**, not a typical production VPS server.

---

## VPS Capacity

* **CPU:** 6 cores
* **RAM:** 12 GB
* **Disk:** 200 GB SSD
* **OS:** Ubuntu Linux
* **Primary use:** remote development, Git-based workflows, multi-project software development, local service hosting, experimentation, and testing

This is enough for a very capable dev workstation, but it should be structured carefully so that always-on platform services stay light and heavier project-specific services can be started only when needed.

---

## Core Design Principle

The architecture should split the server into two layers:

### 1. Host-level workstation layer

These are the components that should make the server feel like **your actual machine**:

* SSH access
* Linux user environment
* Git
* Node.js
* TypeScript toolchains
* Python
* Docker Engine
* code-server
* Nginx
* Cockpit
* CrowdSec
* Let’s Encrypt automation

### 2. Optional containerized service layer

These are services that support development work and should exist **only if a project requires them**:

* PostgreSQL
* pgAdmin
* Neo4j
* Redis
* project-specific APIs or web apps
* Python sandbox containers for isolated execution
* test databases
* supporting services used only when needed

This split gives the best balance of:

* workstation-like behavior
* security
* flexibility
* reproducibility
* low operational friction
* support for multiple independent projects on the same sandbox

---

## High-Level Architecture

```text
Internet
  │
  ▼
DNS records for dev.marin.cr subdomains
  │
  ▼
UFW firewall
  │
  ▼
CrowdSec remediation / log-based protection
  │
  ▼
Nginx reverse proxy on host
  │
  ├── code.marin.cr           → code-server (host service, Authentik SSO)
  ├── admin.dev.marin.cr      → Cockpit (host service, Authentik SSO)
  ├── *.dev.marin.cr           → wildcard HTTPS proxy (subdomain → port map)
  │     ├── knecta.dev.marin.cr   → 127.0.0.1:8319 (Knecta)
  │     ├── newapp.dev.marin.cr   → 127.0.0.1:8320 (future project)
  │     └── (one line per project in Nginx map block)
  └── pgadmin.dev.marin.cr    → pgAdmin (container, only when used)
          │
          ▼
Authentik integration via Nginx forward auth / proxy auth
          │
          ▼
Host workstation services + optional Docker services
```

---

## Development-Sandbox First Mindset

This architecture is optimized for **development speed and flexibility**, not for production-style rigidity.

That means this server is expected to support patterns such as:

* running multiple apps at the same time
* using temporary high ports for development servers
* starting and stopping supporting containers based on what a project needs
* editing code directly in a persistent remote workspace
* testing unfinished apps and APIs without treating them as polished public services

A production VPS would usually minimize ad hoc port usage and avoid casual multi-app dev workflows.
This sandbox is intentionally designed to support them.

---

## Domain Layout

### Main workstation entry point

* **`dev.marin.cr`**
* Purpose: primary browser entry point to your coding environment
* Backend: **code-server running on the host**
* Access model: HTTPS through Nginx, protected by Authentik

### Admin interface

* **`admin.dev.marin.cr`**
* Purpose: Cockpit web interface for server administration
* Backend: **Cockpit running on the host**
* Access model: HTTPS through Nginx, protected by Authentik

### Database administration

* **`pgadmin.dev.marin.cr`**
* Purpose: web UI for PostgreSQL management when PostgreSQL is in use
* Backend: **pgAdmin in Docker**
* Access model: HTTPS through Nginx, protected by Authentik

### Project subdomains (wildcard HTTPS proxy)

All web apps are served via HTTPS subdomains under `*.dev.marin.cr` using a wildcard reverse proxy. A single wildcard DNS record and wildcard SSL certificate cover all subdomains. Each project is mapped to a local port via one line in the Nginx config.

Currently active:
* `knecta.dev.marin.cr` → port 8319

To add a new project, edit the map block in `/etc/nginx/sites-available/dev-wildcard` and reload Nginx. See `/opt/infra/docs/web-app-hosting.md` for the full procedure.

---

## Critical Requirement: Concurrent Development Servers on Different Ports

This is an **important part of the design**.

This sandbox must support running **multiple active development apps at the same time**, especially apps using stacks such as:

* Node.js
* TypeScript
* Vite
* React or similar frontend frameworks

Typical examples:

* `dev.marin.cr:1983` → one app running in dev mode
* `dev.marin.cr:8978` → another app running in dev mode
* `dev.marin.cr:3000` → an API server
* `dev.marin.cr:5173` → a default Vite dev server
* other high ports for additional project-specific dev sessions

This behavior is **not accidental** and **not a side case**.
It is a **core requirement** of the sandbox.

### Why this matters

You want one remote machine that can behave like your personal development laptop in the cloud.
That means you may have several repositories open and several apps running simultaneously while you test, compare, or integrate them.

### Design implication

The sandbox should be configured so that:

* multiple apps can listen on different ports concurrently
* port-based access is acceptable for active development
* project dev servers can be started and stopped independently
* the server can support a mix of browser-based IDE usage and direct app-preview usage

### Practical guidance

* keep a simple internal convention for assigning dev ports
* document common ports per project to avoid confusion
* use direct port access for fast development cycles
* optionally place frequently used apps behind Nginx hostnames later if you want cleaner URLs

This port-based workflow is normal and expected for this machine.

---

## What Runs on the Host

The following should be installed directly on Ubuntu.

### 1. code-server

**Why on host:**
Because this server should feel like your personal cloud laptop.
You want direct access to:

* your real home directory
* your Git repositories
* SSH config and keys
* local shell tools
* Docker CLI
* build tools
* language runtimes
* Node.js + TypeScript + Vite workflows

Installing code-server directly on the host avoids the friction of container file mounts, UID/GID issues, and Docker socket permission problems.

### 2. Cockpit

**Why on host:**
Cockpit is a machine administration layer and works best as a host-level service.
It should not be exposed directly to the Internet. Instead, it should be available only through Nginx and Authentik.

### 3. Nginx

**Why on host:**
This server is acting as a personal dev workstation, so host-level Nginx simplifies TLS, routing, Authentik integration, and service exposure.

### 4. CrowdSec

**Why on host:**
CrowdSec should inspect host and Nginx logs directly and apply protection at the server edge.

### 5. Docker Engine and Docker Compose

**Why on host:**
Docker is required because some projects will need supporting services or isolated runtimes.
The machine should support containerized dependencies and isolated services, but Docker should support the workstation rather than replace it.

### 6. Node.js, Git, Python, and dev tooling

**Why on host:**
These are part of the workstation experience and should be readily available from your shell and code-server terminal.

---

## What Runs in Containers

These components are **optional** and should be used only when a specific project requires them.

### 1. PostgreSQL

Use this when a project needs a relational database.
Containerized PostgreSQL should be persistent, backed by Docker volumes, and reachable only through private/internal networking.

### 2. pgAdmin

Use this when PostgreSQL is in use and a browser-based management tool is helpful.
It belongs naturally next to the PostgreSQL service.

### 3. Neo4j

Use this only when a project requires a graph database.
It is a strong candidate for containerization because it is service-like and isolated.

### 4. Redis

Use this only when a project requires caching, queues, or fast ephemeral data storage.

### 5. Project-specific service components

As different projects evolve, their backend or auxiliary services can run in containers without polluting the host OS.

### 6. Python execution sandbox

Any code execution environment used by a project for dynamic Python execution should remain isolated from the main workstation.
That should stay containerized by design when needed.

---

## Final Host vs Container Split

### Host-installed

* Ubuntu
* SSH
* Git
* Node.js
* TypeScript toolchains
* Python
* Docker Engine
* Docker Compose
* Nginx
* code-server
* Cockpit
* CrowdSec
* Let’s Encrypt automation

### Containerized when needed

* PostgreSQL
* pgAdmin
* Neo4j
* Redis
* project-specific backend services
* Python sandbox containers
* experimental supporting services

---

## Networking Model

### Publicly exposed ports

Only these ports should be reachable from the Internet by default:

* `22` → SSH
* `80` → HTTP for Let’s Encrypt challenges and redirect to HTTPS
* `443` → HTTPS for web apps and proxied services

### Development ports

This sandbox may also intentionally use additional ports for active development sessions.
Examples include:

* `1983`
* `3000`
* `5173`
* `8978`
* other project-specific ports

These ports are acceptable in this design **when you deliberately use them for active development workflows**.

### Do not expose publicly by default

These should **not** be exposed directly to the Internet unless you intentionally choose to do so for a development reason:

* PostgreSQL `5432`
* Cockpit native port `9090`
* pgAdmin container port
* code-server direct port
* Neo4j ports
* Redis ports

Everything web-based that should be stable or secured should go through:

1. Nginx
2. TLS
3. Authentik
4. optional Nginx rate limiting
5. CrowdSec protection

---

## Authentication and Access Control

### Primary access layer

Use **Authentik** at `auth.marin.cr` as the main authentication provider for:

* `dev.marin.cr`
* `admin.dev.marin.cr`
* `pgadmin.dev.marin.cr`
* any optional project hostnames you later expose through Nginx

### Recommended pattern

Use Nginx integrated with Authentik forward-auth or proxy-auth so that the public entry point is protected before the request reaches the internal service.

### Secondary local auth

For particularly sensitive services, keep native local auth enabled as a backup or second layer where appropriate.

Recommended examples:

* code-server: keep its own password/token enabled initially
* Cockpit: local Linux account auth still exists behind the proxy
* pgAdmin: keep pgAdmin credentials as well

This gives defense in depth.

---

## TLS and Certificate Strategy

Use Let’s Encrypt for all public subdomains that you expose.

Active certificates:

* `code.marin.cr` — individual cert (HTTP-01 challenge)
* `admin.dev.marin.cr` — individual cert (HTTP-01 challenge)
* `*.dev.marin.cr` + `dev.marin.cr` — **wildcard cert** (DNS-01 challenge via Route 53)

The wildcard cert covers all project subdomains. New projects do **not** need new certificates.

Wildcard cert renewal requires AWS credentials at `/root/.aws/credentials` with Route 53 permissions. See `/opt/infra/docs/web-app-hosting.md` for details.

All public services redirect HTTP to HTTPS. Certbot’s systemd timer handles automatic renewal.

---

## Server File and Directory Strategy

Use a clean and explicit filesystem layout.

### Recommended top-level structure

```text
/opt/infra/
  proxy/
  containers/
    pgadmin/
    postgres/
    neo4j/
    redis/
    shared-services/
  scripts/
  backups/

/home/<dev-user>/
  repos/
    project-a/
    project-b/
    project-c/
  .ssh/
  .gitconfig
  .config/
  workspace/
```

### Key idea

* `/home/<dev-user>` is your real workstation space
* `/opt/infra` is operational infrastructure
* project repos live in your user home, not buried in Docker folders
* containers exist to support projects, not to define your whole development experience

This keeps development natural and operations organized.

---

## Recommended Linux User Model

Create a dedicated non-root development user, for example:

* `sandvoxuser`

That user should:

* own your repos
* own your workspace
* run code-server
* use Git normally
* use SSH keys normally
* have Docker group membership if needed
* use sudo when required

Avoid doing development as `root`.

Use root only for:

* system administration
* package installs
* service setup
* security configuration

---

## code-server Role in the Architecture

`code-server` is the centerpiece of the sandbox.

It should serve as:

* your remote IDE
* your file browser
* your terminal
* your Git workstation
* your launcher for project development tasks
* your place to edit infrastructure and app code

### code-server should have easy access to

* your repos under `/home/<dev-user>/repos`
* GitHub over SSH
* Node.js tools
* TypeScript toolchains
* Vite dev workflows
* Python tools
* Docker CLI
* local and containerized development tools
* shell scripts

### code-server should not be treated like

* a disposable app appliance
* a locked-down sandbox container
* a replacement for Dockerized supporting services

It is your **developer desktop in the cloud**.

---

## PostgreSQL Role in the Architecture

Recommended default approach when a project needs PostgreSQL:

* run PostgreSQL in Docker
* attach it to a private Docker network
* do not expose it publicly by default
* persist data with named volumes or bind mounts
* use pgAdmin through the browser when needed
* allow project services to connect internally
* optionally allow local CLI access from the host when needed

Why this works well:

* keeps the workstation layer cleaner
* keeps database lifecycle separate from the host OS
* makes backup, migration, and replacement easier
* supports multiple projects sharing a common local database service when appropriate
* keeps pgAdmin and PostgreSQL grouped together operationally

If a project does not need PostgreSQL, it simply does not need to use this service.

---

## Docker’s Role in the Architecture

Docker is still required and still important.

Its purpose on this sandbox is **not** to containerize your entire workstation.
Its purpose is to run:

* isolated project dependencies
* supporting services
* experimental services
* execution sandboxes
* services that should be reproducible and disposable
* optional infrastructure components that only exist because a particular project needs them

This keeps the host clean while preserving the full-machine feel of your development environment.

---

## Operational Modes

### Always-on services

These should start automatically and remain available:

* Nginx
* CrowdSec
* Cockpit
* code-server
* Let’s Encrypt renewal automation

### Optional always-on services

These may remain running if they are broadly useful across your projects:

* PostgreSQL container
* pgAdmin container

### On-demand services

These should be started only when needed:

* Neo4j when required by a project
* Redis when required by a project
* project-specific backend containers
* Python sandbox containers when required by a project
* experimental services

This prevents your 12 GB server from becoming sluggish.

---

## Security Model

### 1. Minimize exposure

Only expose what is truly needed on the public Internet.

### 2. Put every web UI behind HTTPS and Authentik

No direct public access to backend admin ports unless you intentionally accept that for a dev workflow.

### 3. Use CrowdSec on the host

Monitor SSH and Nginx logs and block abusive IPs.

### 4. Use UFW

Allow only the essential ports and any deliberate dev ports you choose to open.

### 5. Use a non-root dev user

Do not do daily work as root.

### 6. Keep secrets out of Git

Use environment files or a secret-management pattern later if needed.

### 7. Use Git as the sync and recovery layer

The machine is your remote workstation, but your source of truth for code should still be Git.

---

## Multi-Project Development Fit

This sandbox is especially well suited for a workflow where you are actively building and testing multiple projects over time.

### Workstation side

* editing code
* running Node.js and TypeScript tooling
* running Vite development servers
* managing Git branches across multiple repos
* using terminals and scripts
* testing APIs and web apps locally

### Service side

* PostgreSQL when needed
* pgAdmin when PostgreSQL is in use
* optional Neo4j
* optional Redis
* isolated Python execution when needed
* Docker-based auxiliary services

That means projects can evolve on this box without turning the host itself into a mess.

---

## Recommended Final Architecture Statement

The development sandbox should be implemented as a **host-centric remote workstation** with an **optional containerized supporting service layer**.

### Final decision summary

#### Host

* Ubuntu
* Nginx
* code-server
* Cockpit
* CrowdSec
* Docker Engine
* Git / Node / Python / dev tooling
* Let’s Encrypt automation

#### Docker when needed

* PostgreSQL
* pgAdmin
* Neo4j
* Redis
* project-specific services
* isolated sandbox containers
* experimental support components

#### Public domains

* `code.marin.cr` → code-server
* `admin.dev.marin.cr` → Cockpit
* `*.dev.marin.cr` → wildcard HTTPS proxy for all project subdomains
* `pgadmin.dev.marin.cr` → pgAdmin when in use

#### Development access model

* stable browser access for the workstation via `https://code.marin.cr`
* each web app project gets an HTTPS subdomain (e.g., `https://knecta.dev.marin.cr`)
* adding a new project requires editing one line in the Nginx map block — no DNS or SSL changes
* OAuth providers (Google, Microsoft) work correctly because all apps are served over HTTPS

#### Security front door

* TLS via Let’s Encrypt
* Authentik at `auth.marin.cr`
* Nginx reverse proxy
* CrowdSec and UFW on host

---

## Build Sequence

The recommended implementation sequence is:

1. Base OS hardening and updates
2. Create non-root dev user
3. Install Docker Engine and Compose
4. Install Nginx
5. Set up DNS records
6. Set up Let’s Encrypt and HTTPS
7. Install CrowdSec
8. Install Cockpit and proxy it via Nginx
9. Integrate Authentik with Nginx routes
10. Install code-server on host and proxy it via Nginx
11. Prepare workspace directories and Git repos
12. Deploy PostgreSQL in Docker if needed
13. Deploy pgAdmin in Docker if needed
14. Add other project-specific containers later as needed

---

## What This Architecture Optimizes For

This design optimizes for:

* remote development from anywhere
* low friction across laptop, work machine, and tablet
* secure web access
* workstation-like behavior
* support for multiple evolving project stacks
* clean operational boundaries
* reduced risk of overcomplicating the server too early
* the ability to run multiple active development apps at the same time

---

## Next Step

The next document should define the **implementation blueprint**, including:

* exact DNS records
* directory layout
* hostnames and local ports
* dev-port usage guidance
* Nginx routing map
* Authentik integration points
* Docker Compose layout for optional containerized services
* install order with exact commands
