# code-server — Remote IDE

## What & Why

code-server is VS Code running in the browser, providing a full remote IDE accessible at `https://code.marin.cr`. It's the centerpiece development tool for this VPS, enabling coding from any device with a browser.

## Architecture

```
Browser → Nginx (443/TLS) → Authentik forward auth check → code-server (http://127.0.0.1:8081)
```

1. User visits `https://code.marin.cr`
2. Nginx makes an `auth_request` subrequest to Authentik's outpost at `auth.marin.cr`
3. If unauthenticated → 302 redirect to Authentik login page
4. If authenticated → request passes through to code-server
5. code-server runs with `auth: none` — Authentik handles all authentication

### Why port 8081?

CrowdSec's local API already occupies `127.0.0.1:8080`, so code-server binds to 8081 instead.

### Why `auth: none`?

Authentik SSO via Nginx forward-auth handles all authentication. code-server's built-in password auth would be redundant and would require a second login after Authentik.

## Installed Version

- code-server v4.111.0 (installed via official install script from `code-server.dev/install.sh`)
- Uses the system's packaged systemd template: `code-server@.service`

## Authentik SSO Integration

Identical pattern to Cockpit (see `/opt/infra/docs/cockpit.md` "Nginx + Authentik Pattern for Future Services"). Key difference: no `Authorization` header is injected in `location /` since code-server uses `auth: none`.

### Authentik Configuration (on auth.marin.cr)

**Provider:** `code-server-forward-auth`
- Type: Proxy Provider
- Mode: **Forward auth (single application)**
- External host: `https://code.marin.cr`

**Application:** `Code Server`
- Slug: `code-server`
- Provider: `code-server-forward-auth`

**Outpost:** authentik Embedded Outpost
- Add `Code Server` application to the existing outpost

## Configuration Files

### `/home/marinoscar/.config/code-server/config.yaml`

```yaml
bind-addr: 127.0.0.1:8081
auth: none
cert: false
```

- **bind-addr**: Localhost only — Nginx handles external access
- **auth: none**: Authentik SSO handles authentication
- **cert: false**: Nginx handles TLS

### `/etc/nginx/sites-available/code-server`

```nginx
server {
    listen 443 ssl;
    server_name code.marin.cr;

    ssl_certificate /etc/letsencrypt/live/code.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/code.marin.cr/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Authentik auth subrequest
    # CRITICAL: Host must be auth.marin.cr, NOT $host
    # CRITICAL: Authorization must be cleared in auth locations
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

    # Authentik outpost endpoints (start, callback, etc.)
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

    # Proxy to code-server
    location / {
        auth_request     /outpost.goauthentik.io/auth/nginx;
        error_page       401 = @goauthentik_proxy_signin;

        auth_request_set $auth_cookie $upstream_http_set_cookie;
        add_header       Set-Cookie $auth_cookie;

        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support (required for terminal, extensions, etc.)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
    }

    # Authentik sign-in redirect
    location @goauthentik_proxy_signin {
        internal;
        add_header Set-Cookie $auth_cookie;
        return 302 /outpost.goauthentik.io/start?rd=$request_uri;
    }
}

server {
    listen 80;
    server_name code.marin.cr;
    return 301 https://$host$request_uri;
}
```

Key details:
- Three Authentik location blocks replicate the Cockpit pattern exactly
- No `Authorization` header in `location /` (unlike Cockpit, which injects Basic auth for auto-login)
- WebSocket support via `Upgrade` and `Connection` headers — required for terminal, extensions, and live reload
- `proxy_buffering off` — prevents buffering issues with streaming responses

### TLS / Let's Encrypt

- Certificate obtained via: `sudo certbot certonly --nginx -d code.marin.cr`
- Auto-renewal: handled by `certbot.timer` systemd timer
- Cert location: `/etc/letsencrypt/live/code.marin.cr/`

## Service Management

```bash
# code-server
sudo systemctl status code-server@marinoscar
sudo systemctl restart code-server@marinoscar
sudo journalctl -u code-server@marinoscar -n 30

# Nginx
sudo nginx -t
sudo systemctl reload nginx

# TLS renewal
sudo certbot renew --dry-run
```

## Troubleshooting

- **502 Bad Gateway**: code-server not running — `sudo systemctl status code-server@marinoscar` and check journal
- **WebSocket errors (terminal not working)**: Ensure Nginx config has `proxy_set_header Upgrade` and `Connection` headers, and `proxy_http_version 1.1`
- **Authentik not blocking unauthenticated access**: See Cockpit doc pitfalls — same rules apply (Host header, Authorization clearing, single-application mode)
- **code-server login page appearing**: Verify `auth: none` in `~/.config/code-server/config.yaml` and restart the service
- **Port conflict on 8080**: CrowdSec's LAPI uses 8080 — code-server must use 8081
- **Extensions not installing**: Check code-server has internet access and sufficient disk space
- **Certificate renewal failing**: Check port 80 is open (`sudo ufw status`) and Nginx is running
