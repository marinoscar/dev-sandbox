# Cockpit — Server Administration UI

## What & Why

Cockpit is a web-based server management tool providing real-time system monitoring, terminal access, service management, and filesystem browsing (via the Navigator plugin). It serves as the primary admin interface for this VPS, accessible at `https://admin.dev.marin.cr`.

## Architecture

```
Browser → Nginx (443/TLS, injects Basic auth) → Cockpit (http://127.0.0.1:9090, --local-ssh)
```

- Cockpit runs in `--local-ssh` mode — it authenticates users via SSH to localhost rather than PAM
- Nginx injects a `Basic` Authorization header on every request, so the browser never sees a login page
- Cockpit binds to **localhost only** — not directly exposed to the internet
- Nginx terminates TLS (Let's Encrypt) and reverse-proxies to Cockpit over plain HTTP
- WebSocket support is enabled for Cockpit's terminal feature
- **Authentication is currently handled via Nginx-injected credentials.** This will be replaced with Authentik SSO.

### Why `--local-ssh` instead of `--local-session`?

We tried `--local-session=cockpit-bridge` first (which skips authentication entirely and runs the bridge directly). While it worked for basic access, it bypasses Cockpit's normal host/session management — the dashboard showed "no-host" with no way to add the local machine. `--local-ssh` gives full Cockpit functionality (host overview, system stats, proper session handling) by connecting through SSH, which Cockpit's UI expects.

## Installed Packages

- `cockpit` (v314) — core server admin UI
- `cockpit-navigator` (v0.6.0) — filesystem browser plugin, installed from [45Drives GitHub releases](https://github.com/45Drives/cockpit-navigator/releases)

## Auto-Login Mechanism

Cockpit requires authentication even in `--local-ssh` mode. To skip the login page:

1. A dedicated password was generated and set for `marinoscar` via `chpasswd`
2. The Base64-encoded `marinoscar:<password>` credentials are stored in `/etc/cockpit/.auto-auth-header` (root-only, mode 600)
3. The plaintext password is stored in `/etc/cockpit/.auto-auth` (root-only, mode 600)
4. Nginx injects this as a `proxy_set_header Authorization "Basic <encoded>"` on every request to Cockpit
5. Cockpit's `--local-ssh` mode accepts the Basic auth and establishes an SSH session to localhost using the password

Additionally, an SSH key pair was generated for `marinoscar` (`~/.ssh/id_ed25519`) and authorized in `~/.ssh/authorized_keys` for localhost access.

**When Authentik is integrated**, the Nginx Authorization header injection will be removed and replaced with Authentik's forward auth proxy.

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
- **LoginTo = false**: Disables the "Connect to another server" option on the login page (security: prevents scanning internal network)
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

Nginx reverse proxy config for `admin.dev.marin.cr`:

```nginx
server {
    listen 443 ssl;
    server_name admin.dev.marin.cr;

    ssl_certificate /etc/letsencrypt/live/admin.dev.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/admin.dev.marin.cr/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization "Basic <encoded-credentials>";

        # WebSocket support (required for Cockpit terminal)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Disable buffering for real-time updates
        proxy_buffering off;
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
- `proxy_pass http://` (not https) — Cockpit runs with `--no-tls`
- `Authorization` header — auto-authenticates every request as `marinoscar`
- `Upgrade` / `Connection` headers — required for Cockpit's WebSocket-based terminal
- `proxy_buffering off` — ensures real-time system monitoring updates

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
- **Login page still showing**: Nginx must inject the `Authorization` header. Check `/etc/nginx/sites-available/cockpit` has the `proxy_set_header Authorization` line.
- **WebSocket errors in terminal**: Ensure Nginx config has `proxy_set_header Upgrade` and `Connection` headers
- **Certificate renewal failing**: Check port 80 is open (`sudo ufw status`) and Nginx is running
- **"Not allowed" error in Cockpit**: Check `Origins` in cockpit.conf matches `https://admin.dev.marin.cr` exactly

## Future

- Authentik SSO integration via auth.marin.cr — will replace the Nginx-injected Basic auth header with Authentik's forward auth proxy
