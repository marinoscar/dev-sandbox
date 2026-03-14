# Web App Hosting — Wildcard HTTPS Reverse Proxy

## What & Why

This VPS hosts multiple web applications simultaneously, each accessible via its own HTTPS subdomain under `*.dev.marin.cr`. This setup was created because:

1. **Google OAuth (and most OAuth providers) require HTTPS** for redirect URIs with sensitive scopes — plain `http://` is rejected
2. **Port-based access (`dev.marin.cr:8319`)** doesn't work with HTTPS unless each port has its own SSL listener
3. **Subdomain-based routing** solves both problems: one wildcard SSL cert, one Nginx config, unlimited projects

Each project gets a clean URL like `https://knecta.dev.marin.cr` instead of `http://dev.marin.cr:8319`.

## Architecture

```text
Browser (https://knecta.dev.marin.cr)
  │
  ▼
Route 53 DNS
  *.dev.marin.cr → 144.126.129.254 (wildcard A record)
  │
  ▼
UFW Firewall (port 443 allowed)
  │
  ▼
Host Nginx (port 443)
  │
  ├── Wildcard cert: /etc/letsencrypt/live/dev.marin.cr/
  ├── Config: /etc/nginx/sites-available/dev-wildcard
  │
  ├── map $host → $backend_port
  │     knecta.dev.marin.cr  → 127.0.0.1:8319
  │     app2.dev.marin.cr    → 127.0.0.1:8320
  │     (add one line per project)
  │
  ▼
Project's Docker Compose stack (listening on mapped port)
  │
  ├── Project Nginx container (port 8319:80) → routes /api and / internally
  ├── API container
  ├── Web container
  └── Other project services
```

### Key distinction: Two Nginx layers

There are **two separate Nginx instances** in this architecture:

| Layer | What | Where | Purpose |
|---|---|---|---|
| **Host Nginx** | System-level reverse proxy | `/etc/nginx/sites-available/dev-wildcard` | SSL termination, subdomain routing, maps `*.dev.marin.cr` to local ports |
| **Project Nginx** | Per-project container | Inside Docker Compose (e.g., `compose-nginx-1`) | Routes `/api` to the API container and `/` to the web container within the project |

The host Nginx handles HTTPS and picks the right project. The project Nginx handles internal routing within that project's container stack.

## Components

### 1. DNS — Route 53 Wildcard Record

A single wildcard `A` record handles all subdomains:

| Record | Type | Value |
|---|---|---|
| `*.dev.marin.cr` | A | `144.126.129.254` |

Explicit records (like `admin.dev.marin.cr`) take priority over the wildcard — they are not affected.

### 2. Wildcard SSL Certificate — Let's Encrypt via DNS-01

A single wildcard certificate covers all `*.dev.marin.cr` subdomains. It was issued using Certbot with the Route 53 DNS-01 challenge (HTTP-01 cannot issue wildcard certs).

**Certificate location:**
```
/etc/letsencrypt/live/dev.marin.cr/fullchain.pem
/etc/letsencrypt/live/dev.marin.cr/privkey.pem
```

**Covers:** `*.dev.marin.cr` and `dev.marin.cr`

**Auto-renewal:** Certbot's systemd timer handles renewal automatically. The DNS-01 plugin uses AWS credentials at `/root/.aws/credentials` to create the validation TXT record in Route 53.

**How it was issued:**
```bash
# Install the Route 53 plugin
sudo apt-get install -y python3-certbot-dns-route53

# Configure AWS credentials for root (certbot runs as root)
sudo mkdir -p /root/.aws
sudo tee /root/.aws/credentials > /dev/null << EOF
[default]
aws_access_key_id = YOUR_ACCESS_KEY
aws_secret_access_key = YOUR_SECRET_KEY
EOF
sudo chmod 600 /root/.aws/credentials

# Issue the wildcard certificate
sudo certbot certonly --dns-route53 \
  -d "*.dev.marin.cr" \
  -d "dev.marin.cr" \
  --non-interactive \
  --agree-tos \
  --email your-email@example.com
```

**AWS IAM permissions required:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "route53:ListHostedZones",
      "route53:GetChange",
      "route53:ChangeResourceRecordSets"
    ],
    "Resource": "*"
  }]
}
```

### 3. Host Nginx — Wildcard Reverse Proxy

**Config file:** `/etc/nginx/sites-available/dev-wildcard`
**Symlink:** `/etc/nginx/sites-enabled/dev-wildcard`

The config uses an Nginx `map` block to route subdomains to local ports:

```nginx
# Map subdomain → backend port
map $host $backend_port {
    knecta.dev.marin.cr    8319;
    # app2.dev.marin.cr    8320;
    # app3.dev.marin.cr    8321;
}

server {
    listen 443 ssl;
    server_name *.dev.marin.cr;

    ssl_certificate /etc/letsencrypt/live/dev.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dev.marin.cr/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Reject unmapped subdomains
    if ($backend_port = "") {
        return 444;
    }

    location / {
        proxy_pass http://127.0.0.1:$backend_port;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
    }
}

# HTTP → HTTPS redirect
server {
    listen 80;
    server_name *.dev.marin.cr;
    return 301 https://$host$request_uri;
}
```

**How it works:**
1. A request to `https://knecta.dev.marin.cr` arrives at Nginx on port 443
2. The `map` block resolves `knecta.dev.marin.cr` to port `8319`
3. Nginx proxies the request to `http://127.0.0.1:8319`
4. Port 8319 is the project's Docker Compose Nginx container, which routes internally
5. Unmapped subdomains get a `444` (connection closed, no response)

### 4. Docker Network — devnet

Project containers that need to reach host-level services (like PostgreSQL) join the external `devnet` Docker network. This network was created once and is shared across all projects:

```bash
docker network create devnet
```

Projects reference it in their `docker-compose.yml`:
```yaml
networks:
  devnet:
    external: true
```

The PostgreSQL container at `/opt/infra/containers/postgres/` runs on this network with container name `postgres`, so any project can connect using `POSTGRES_HOST=postgres`.

### 5. UFW Firewall — Docker Container Access

Docker containers on custom networks (like `compose_app-network`) cannot reach the host's published ports by default because UFW's INPUT policy is DROP. To allow containers to reach host services like PostgreSQL, a UFW rule was added:

```bash
sudo ufw allow from 172.16.0.0/12 to any port 5432 proto tcp \
  comment "Allow Docker containers to reach host PostgreSQL"
```

This covers all Docker network subnets (`172.16.0.0/12`).

---

## How to Add a New Project

This is the step-by-step process for making a new project available at `https://newapp.dev.marin.cr`.

### Step 1: Assign a port

Pick an unused port for the project's Docker Compose stack. Check what's in use:

```bash
# See all ports currently in use by Docker
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep -v "^$"

# See the current Nginx map
grep -E '^\s+\S+\.dev\.marin\.cr' /etc/nginx/sites-available/dev-wildcard
```

Common convention:
| Project | Port |
|---|---|
| knecta | 8319 |
| (next project) | 8320 |
| (next project) | 8321 |

### Step 2: Add the subdomain to Nginx

Edit the map block in the wildcard config:

```bash
sudo nano /etc/nginx/sites-available/dev-wildcard
```

Add one line to the `map` block:
```nginx
map $host $backend_port {
    knecta.dev.marin.cr    8319;
    newapp.dev.marin.cr    8320;   # ← add this line
}
```

Test and reload:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

**That's it for infrastructure.** No DNS changes needed (wildcard covers it). No SSL changes needed (wildcard cert covers it).

### Step 3: Configure the project

In the project's Docker Compose, ensure the entry-point service (usually Nginx or a dev server) publishes to the assigned port:

```yaml
# In the project's compose file
services:
  nginx:  # or whatever the entry service is
    ports:
      - "8320:80"  # maps to the port you assigned
```

Set the project's environment variables to use the HTTPS URL:
```bash
# In the project's .env
APP_URL=https://newapp.dev.marin.cr
```

### Step 4: Configure OAuth (if applicable)

If the project uses Google OAuth (or any OAuth provider):

1. **Project `.env`:**
   ```
   APP_URL=https://newapp.dev.marin.cr
   GOOGLE_CALLBACK_URL=https://newapp.dev.marin.cr/api/auth/google/callback
   ```

2. **Google Cloud Console:**
   - Add `https://newapp.dev.marin.cr/api/auth/google/callback` to **Authorized redirect URIs**
   - Add `https://newapp.dev.marin.cr` to **Authorized JavaScript origins**

3. **Ensure `APP_URL` is passed to the API container** in the compose file:
   ```yaml
   environment:
     - APP_URL=${APP_URL}
   ```

### Step 5: Connect to PostgreSQL (if needed)

If the project needs the shared PostgreSQL instance:

1. **Add the `devnet` network** to the API service in the compose file:
   ```yaml
   services:
     api:
       networks:
         - app-network   # project's internal network
         - devnet         # external network for PostgreSQL access

   networks:
     app-network:
       driver: bridge
     devnet:
       external: true
   ```

2. **Set the database host** in the project's `.env`:
   ```
   POSTGRES_HOST=postgres
   ```

3. **Create a database** for the project:
   ```bash
   psql -h 127.0.0.1 -U admin -d devdb -c "CREATE DATABASE newapp;"
   ```

### Step 6: Configure Vite allowedHosts (if using Vite)

Vite blocks requests from unrecognized hostnames. Add the subdomain to `vite.config.ts`:

```typescript
export default defineConfig({
  server: {
    allowedHosts: ['.dev.marin.cr'],  // leading dot = all subdomains
  },
});
```

### Step 7: Start the project

```bash
cd /path/to/project
docker compose -f base.compose.yml -f dev.compose.yml up -d
```

Verify:
```bash
curl -s https://newapp.dev.marin.cr/api/health/live
```

---

## Complete Example: Adding "newapp" from Zero

Here is every command, in order, to make `https://newapp.dev.marin.cr` work:

```bash
# 1. Add to Nginx map (edit the file, add one line)
sudo nano /etc/nginx/sites-available/dev-wildcard
#    Add: newapp.dev.marin.cr    8320;

# 2. Reload Nginx
sudo nginx -t && sudo systemctl reload nginx

# 3. Create a database (if needed)
psql -h 127.0.0.1 -U admin -d devdb -c "CREATE DATABASE newapp;"

# 4. Configure the project's .env
cd /home/marinoscar/git/NewApp/infra/compose
cat > .env << EOF
APP_URL=https://newapp.dev.marin.cr
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=newapp
GOOGLE_CALLBACK_URL=https://newapp.dev.marin.cr/api/auth/google/callback
EOF

# 5. Update Google Cloud Console
#    - Add redirect URI: https://newapp.dev.marin.cr/api/auth/google/callback
#    - Add JS origin: https://newapp.dev.marin.cr

# 6. Start the project
docker compose -f base.compose.yml -f dev.compose.yml up -d

# 7. Verify
curl -s https://newapp.dev.marin.cr/api/health/live
```

**Total infrastructure work: edit one line in Nginx, reload. Everything else is project-level.**

---

## Removing a Project

```bash
# 1. Stop the project
cd /path/to/project/infra/compose
docker compose -f base.compose.yml -f dev.compose.yml down

# 2. Remove from Nginx map
sudo nano /etc/nginx/sites-available/dev-wildcard
#    Delete or comment out the line

# 3. Reload Nginx
sudo nginx -t && sudo systemctl reload nginx

# 4. Optionally drop the database
psql -h 127.0.0.1 -U admin -d devdb -c "DROP DATABASE newapp;"
```

---

## Currently Hosted Projects

| Subdomain | Port | Project | Repo Path |
|---|---|---|---|
| `knecta.dev.marin.cr` | 8319 | Knecta | `/home/marinoscar/git/Knecta` |

---

## Key File Locations

| File | Purpose |
|---|---|
| `/etc/nginx/sites-available/dev-wildcard` | Wildcard Nginx config (subdomain → port map) |
| `/etc/nginx/sites-enabled/dev-wildcard` | Symlink to enable the config |
| `/etc/letsencrypt/live/dev.marin.cr/` | Wildcard SSL certificate and key |
| `/root/.aws/credentials` | AWS credentials for Certbot Route 53 DNS-01 renewal |
| `/opt/infra/containers/postgres/` | Shared PostgreSQL container |

## Troubleshooting

### "Blocked request. This host is not allowed" (Vite)
Vite blocks unrecognized hostnames. Add `.dev.marin.cr` (with leading dot) to `server.allowedHosts` in `vite.config.ts`, then rebuild the web container.

### OAuth redirects to localhost
The `APP_URL` environment variable is either not set or not passed to the API container. Check:
1. `APP_URL` is set in the project's `.env` (e.g., `https://knecta.dev.marin.cr`)
2. `APP_URL` is listed in the compose file's `environment:` section
3. The container was recreated after the change: `docker compose up -d api`

### 502 Bad Gateway
The project's containers aren't running or haven't finished starting. Check:
```bash
docker compose ps    # Are containers up?
docker logs <api>    # Any startup errors?
```

### SSL certificate errors
The wildcard cert covers `*.dev.marin.cr`. If you see cert errors:
```bash
# Check cert status
sudo certbot certificates

# Force renewal (if expired)
sudo certbot renew --force-renewal --cert-name dev.marin.cr
```

### Can't reach PostgreSQL from container
Ensure the project's compose file includes the `devnet` external network on the API service, and `POSTGRES_HOST=postgres`. Verify connectivity:
```bash
docker exec <api-container> bash -c "timeout 3 bash -c 'echo > /dev/tcp/postgres/5432' && echo OK || echo FAILED"
```

### DNS not resolving for new subdomain
The wildcard `*.dev.marin.cr` record handles all subdomains. If a specific subdomain doesn't resolve, check:
```bash
dig +short newapp.dev.marin.cr
```
If empty, wait for DNS propagation (TTL is 300 seconds) or verify the wildcard record exists in Route 53.
