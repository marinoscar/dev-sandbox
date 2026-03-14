# Cockpit — Server Administration UI

## What & Why

Cockpit is a web-based server management tool providing real-time system monitoring, terminal access, service management, and filesystem browsing (via the Navigator plugin). It serves as the primary admin interface for this VPS, accessible at `https://admin.dev.marin.cr`.

## Architecture

```
Browser → Nginx (443/TLS) → Authentik forward auth check → Cockpit (http://127.0.0.1:9090)
```

1. User visits `https://admin.dev.marin.cr`
2. Nginx makes an `auth_request` subrequest to Authentik's outpost at `auth.marin.cr`
3. If unauthenticated → 302 redirect to Authentik login page
4. If authenticated → request passes through to Cockpit
5. Nginx injects a `Basic` Authorization header so Cockpit auto-logs in as `marinoscar` (Cockpit never shows its own login page)

### Why `--local-ssh` instead of `--local-session`?

We tried `--local-session=cockpit-bridge` first (which skips authentication entirely and runs the bridge directly). While it worked for basic access, it bypasses Cockpit's normal host/session management — the dashboard showed "no-host" with no way to add the local machine. `--local-ssh` gives full Cockpit functionality (host overview, system stats, proper session handling) by connecting through SSH, which Cockpit's UI expects.

## Installed Packages

- `cockpit` (v314) — core server admin UI
- `cockpit-navigator` (v0.6.0) — filesystem browser plugin, installed from [45Drives GitHub releases](https://github.com/45Drives/cockpit-navigator/releases)

## Authentik SSO Integration

Cockpit is protected by Authentik (`auth.marin.cr`) using Nginx's `auth_request` module. All unauthenticated requests are redirected to Authentik's login page before reaching Cockpit.

### Authentik Configuration (on auth.marin.cr)

**Provider:** `dev-sandbox-forward-auth`
- Type: Proxy Provider
- Mode: **Forward auth (single application)** — NOT domain-level (see pitfalls below)
- External host: `https://admin.dev.marin.cr`
- Authorization flow: `default-provider-authorization-implicit-consent`
- Token validity: 24 hours

**Application:** `Dev-Sandbox`
- Slug: `dev-sandbox`
- Provider: `dev-sandbox-forward-auth`

**Outpost:** authentik Embedded Outpost
- Type: Proxy
- Applications: `Dev-Sandbox` (and any other apps sharing the outpost)

### Critical Pitfalls Learned

#### 1. Forward auth mode: single-application vs domain-level

We initially used **Forward auth (domain level)** with cookie domain `dev.marin.cr`. This failed because a separate provider (`cockpit-forward-auth`, single-application mode for `admin.marin.cr`) was also on the same embedded outpost. When the outpost received a request with `Host: admin.dev.marin.cr` and couldn't match it to any provider's external host, it **defaulted to allowing the request** (200) instead of denying it.

**Fix:** Use **Forward auth (single application)** with external host `https://admin.dev.marin.cr`. This gives the outpost an exact host to match against.

**Rule of thumb:** When multiple providers share an outpost, use single-application mode to avoid ambiguous host matching.

#### 2. Host header in auth_request must be the Authentik server, not the application

The `auth_request` subrequest proxies to `https://auth.marin.cr/outpost.goauthentik.io/auth/nginx`. The `Host` header sent to Authentik must be `auth.marin.cr` (the actual Authentik server), **not** `$host` (which would be `admin.dev.marin.cr`).

When `Host: admin.dev.marin.cr` was sent to the outpost, it matched against the `cockpit-forward-auth` provider (which was for `admin.marin.cr`) and returned 200 because the domain matched close enough for session creation.

**Fix:** Set `proxy_set_header Host auth.marin.cr` in the auth locations, and pass the original host via `X-Forwarded-Host`.

#### 3. Strip the Authorization header from auth_request

Nginx's `auth_request` subrequest inherits headers from the main request context. Since the `location /` block injects a `Basic` Authorization header for Cockpit auto-login, this header would also be sent to Authentik in the auth subrequest. Authentik could interpret this as valid credentials and return 200.

**Fix:** Set `proxy_set_header Authorization ""` in the auth subrequest locations.

## Auto-Login Mechanism

Cockpit requires authentication even in `--local-ssh` mode. To skip the Cockpit login page after Authentik auth succeeds:

1. A dedicated password was generated and set for `marinoscar` via `chpasswd`
2. The Base64-encoded `marinoscar:<password>` credentials are stored in `/etc/cockpit/.auto-auth-header` (root-only, mode 600)
3. The plaintext password is stored in `/etc/cockpit/.auto-auth` (root-only, mode 600)
4. Nginx injects this as a `proxy_set_header Authorization "Basic <encoded>"` on every request to Cockpit (in the `location /` block only, NOT in the auth subrequest locations)
5. Cockpit's `--local-ssh` mode accepts the Basic auth and establishes an SSH session to localhost

Additionally, an SSH key pair was generated for `marinoscar` (`~/.ssh/id_ed25519`) and authorized in `~/.ssh/authorized_keys` for localhost access.

## Configuration Files

### `/etc/cockpit/cockpit.conf`

```ini
[WebService]
Origins = https://admin.dev.marin.cr
AllowUnencrypted = true
LoginTo = false
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
```

- **Origins**: Allows Cockpit to accept requests proxied from this domain
- **AllowUnencrypted**: Permits HTTP from localhost (Nginx handles TLS)
- **LoginTo = false**: Disables the "Connect to another server" option (security: prevents scanning internal network)
- **ProtocolHeader / ForwardedForHeader**: Tells Cockpit to trust Nginx's forwarded headers for correct HTTPS detection and client IP logging

### `/etc/systemd/system/cockpit.socket.d/listen.conf`

The localhost-only binding is enforced via a systemd socket override (not cockpit.conf):

```ini
[Socket]
ListenStream=
ListenStream=127.0.0.1:9090
```

- First `ListenStream=` (empty) clears the default `[::]:9090` binding
- Second line sets the actual listen address to localhost only
- After changes: `sudo systemctl daemon-reload && sudo systemctl restart cockpit.socket`

### `/etc/systemd/system/cockpit.service.d/autologin.conf`

Overrides the stock cockpit service to run in `--local-ssh` mode as `marinoscar`:

```ini
[Service]
ExecStart=
ExecStart=/usr/lib/cockpit/cockpit-ws --no-tls --port 9090 --local-ssh
User=marinoscar
Group=marinoscar
Environment=HOME=/home/marinoscar
ProtectHome=false
ProtectSystem=false
PrivateTmp=false
```

- `ExecStart=` (empty): Clears the stock `ExecStart` (required before overriding)
- `--no-tls`: Disables Cockpit's internal TLS (Nginx handles it)
- `--local-ssh`: Authenticates via SSH to localhost — provides full host management, system overview, and session handling
- `User/Group=marinoscar`: Runs cockpit-ws as marinoscar instead of the default `cockpit-ws` system user
- `Environment=HOME`: Required so cockpit-bridge can find `~/.local/share` for package manifests
- `ProtectHome=false`: The stock unit sets `ProtectHome=true`, which blocks the bridge from reading `~/.local/share` — must be overridden
- `ProtectSystem=false` / `PrivateTmp=false`: Relaxed since the bridge needs full system access for admin tasks

### `/etc/cockpit/machines.d/localhost.json`

Registers the local machine in Cockpit's host list:

```json
{
    "localhost": {
        "visible": true,
        "user": "marinoscar",
        "address": "localhost",
        "label": "dev.marin.cr",
        "color": "#0d6efd"
    }
}
```

### `/etc/nginx/sites-available/cockpit`

Full Nginx config with Authentik forward auth and Cockpit reverse proxy:

```nginx
server {
    listen 443 ssl;
    server_name admin.dev.marin.cr;

    ssl_certificate /etc/letsencrypt/live/admin.dev.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/admin.dev.marin.cr/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Internal location for auth_request subrequests
    # CRITICAL: Host must be auth.marin.cr (the Authentik server), NOT $host
    # CRITICAL: Authorization must be cleared to prevent Cockpit creds leaking to Authentik
    location = /outpost.goauthentik.io/auth/nginx {
        internal;
        proxy_pass              https://auth.marin.cr/outpost.goauthentik.io/auth/nginx;
        proxy_set_header        Host             auth.marin.cr;
        proxy_set_header        X-Original-URL   $scheme://$http_host$request_uri;
        proxy_set_header        X-Forwarded-Host $host;
        proxy_set_header        X-Forwarded-For  $remote_addr;
        proxy_set_header        X-Forwarded-Proto $scheme;
        proxy_set_header        Authorization    "";
        proxy_ssl_verify        off;
        proxy_pass_request_body off;
        proxy_set_header        Content-Length   "";
    }

    # Authentik outpost endpoints (start, callback, sign-out, etc.)
    location /outpost.goauthentik.io {
        proxy_pass              https://auth.marin.cr/outpost.goauthentik.io;
        proxy_set_header        Host             auth.marin.cr;
        proxy_set_header        X-Original-URL   $scheme://$http_host$request_uri;
        proxy_set_header        X-Forwarded-Host $host;
        proxy_set_header        X-Forwarded-For  $remote_addr;
        proxy_set_header        X-Forwarded-Proto $scheme;
        proxy_set_header        Authorization    "";
        proxy_ssl_verify        off;
    }

    location / {
        # Authentik auth check — returns 401 if not authenticated
        auth_request     /outpost.goauthentik.io/auth/nginx;
        error_page       401 = @goauthentik_proxy_signin;

        # Pass Authentik session cookie to browser
        auth_request_set $auth_cookie $upstream_http_set_cookie;
        add_header       Set-Cookie $auth_cookie;

        # Proxy to Cockpit
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization "Basic <encoded-credentials>";

        # WebSocket support (required for Cockpit terminal)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
    }

    # Redirect to Authentik login on 401
    location @goauthentik_proxy_signin {
        internal;
        add_header Set-Cookie $auth_cookie;
        return 302 /outpost.goauthentik.io/start?rd=$request_uri;
    }
}

server {
    if ($host = admin.dev.marin.cr) {
        return 301 https://$host$request_uri;
    }
    listen 80;
    server_name admin.dev.marin.cr;
    return 404;
}
```

Key details:
- Three location blocks handle Authentik: exact match for auth subrequest, prefix match for outpost UI endpoints, and a named location for the 302 redirect
- `proxy_pass http://` (not https) — Cockpit runs with `--no-tls`
- `Authorization "Basic <encoded>"` is set ONLY in `location /`, never in auth locations
- `proxy_ssl_verify off` — required because we're connecting to auth.marin.cr without local CA trust
- `proxy_pass_request_body off` + `Content-Length ""` — auth subrequest doesn't need the request body

### Auto-Login Credentials

| File | Purpose | Permissions |
|------|---------|-------------|
| `/etc/cockpit/.auto-auth` | Plaintext password for marinoscar's Cockpit login | root:root 600 |
| `/etc/cockpit/.auto-auth-header` | Base64-encoded `marinoscar:<password>` for Nginx header | root:root 600 |

### TLS / Let's Encrypt

- Certificate obtained via: `sudo certbot --nginx -d admin.dev.marin.cr -m oscar@marin.cr`
- Auto-renewal: handled by `certbot.timer` systemd timer
- Cert location: `/etc/letsencrypt/live/admin.dev.marin.cr/`
- Test renewal: `sudo certbot renew --dry-run`

## Firewall Rules (UFW)

| Port | Rule | Reason |
|------|------|--------|
| 22 | Allow | SSH access |
| 80 | Allow | HTTP (ACME challenge for cert renewal) |
| 443 | Allow | HTTPS (all public traffic) |
| 9090 | Deny (default) | Cockpit direct access blocked — localhost only |

## Service Management

```bash
# Cockpit
sudo systemctl status cockpit.socket
sudo systemctl restart cockpit
sudo systemctl daemon-reload    # after changing any systemd override

# Nginx
sudo systemctl status nginx
sudo nginx -t                   # test config before reload
sudo systemctl reload nginx

# TLS renewal
sudo certbot renew --dry-run
```

## Troubleshooting

- **502 Bad Gateway**: Cockpit not running — `sudo systemctl status cockpit` and check journal: `sudo journalctl -u cockpit -n 30`
- **"no-host" in dashboard**: Caused by using `--local-session` mode, which bypasses host management. Switch to `--local-ssh` mode instead.
- **PermissionError on `~/.local/share`**: The stock cockpit.service has `ProtectHome=true`. Ensure the autologin.conf override sets `ProtectHome=false`.
- **Cockpit login page showing instead of auto-login**: Nginx must inject the `Authorization` header. Check `location /` in `/etc/nginx/sites-available/cockpit` has the `proxy_set_header Authorization` line.
- **Authentik not blocking unauthenticated access (returns 200 instead of 401)**:
  1. Check `Host` header in auth locations is `auth.marin.cr`, NOT `$host`
  2. Check `Authorization` header is cleared (`""`) in auth locations
  3. Check the Authentik provider is set to **Forward auth (single application)** with exact external host
  4. If multiple providers share an outpost, avoid domain-level mode — use single-application to prevent ambiguous host matching
- **302 redirect loop with Authentik**: Check the `/outpost.goauthentik.io` prefix location is NOT set to `internal` — it must be accessible for the browser to complete the OAuth callback
- **WebSocket errors in terminal**: Ensure Nginx config has `proxy_set_header Upgrade` and `Connection` headers
- **Certificate renewal failing**: Check port 80 is open (`sudo ufw status`) and Nginx is running
- **"Not allowed" error in Cockpit**: Check `Origins` in cockpit.conf matches `https://admin.dev.marin.cr` exactly

## Nginx + Authentik Pattern for Future Services

When adding a new service behind Authentik (e.g., `dev.marin.cr` for code-server), replicate this Nginx pattern:

1. Create a new **Proxy Provider** in Authentik: Forward auth (single application), external host = `https://<subdomain>`
2. Create a new **Application** linked to the provider
3. Add the application to the **Embedded Outpost**
4. In the Nginx server block:
   - Add the `location = /outpost.goauthentik.io/auth/nginx` (internal, `Host: auth.marin.cr`)
   - Add the `location /outpost.goauthentik.io` (non-internal, `Host: auth.marin.cr`)
   - Add `auth_request` + `error_page 401` in the main `location /`
   - Add the `@goauthentik_proxy_signin` named location
