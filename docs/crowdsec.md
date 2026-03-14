# CrowdSec — Intrusion Detection & Prevention

## What & Why

CrowdSec is an open-source security tool that reads log files in real time, detects malicious behavior (brute force, SQL injection, path traversal, CVE exploits, etc.), and bans the attacker's IP via iptables before traffic reaches any application. Think of it as a modern fail2ban with broader detection and community threat intelligence.

CrowdSec runs on the **host** (not Docker), following the same pattern as Cockpit and Nginx. There is no self-hosted web UI — management is via `cscli` on the command line, with an optional cloud dashboard at https://app.crowdsec.net.

### How it differs from UFW

- **UFW** controls which ports are open
- **CrowdSec** controls which IPs are allowed to connect to those ports
- CrowdSec's iptables rules are evaluated **before** UFW's rules — banned IPs are dropped before UFW even sees them

## Architecture

```
Attacker connects
    │
    ▼
┌──────────────────────┐
│ iptables             │ Is IP in CrowdSec ipset?
│ (CROWDSEC_CHAIN)     │── YES → DROP (silently refused)
└──────────┬───────────┘
           │ NO
           ▼
┌──────────────────────┐
│ UFW                  │ Is this port allowed?
└──────────┬───────────┘
           │ YES
           ▼
┌──────────────────────┐
│ Nginx / SSH          │ Request served, logs written
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ CrowdSec Agent       │ Reads log, detects attack
│                      │── Match → BAN IP (added to ipset)
└──────────────────────┘
```

### Three Components

1. **Agent + LAPI** (`crowdsec.service`) — reads logs, matches attack patterns, stores alerts/decisions. LAPI listens on `127.0.0.1:8080` (localhost only)
2. **Firewall Bouncer** (`crowdsec-firewall-bouncer.service`) — polls LAPI for ban decisions, maintains iptables ipset blocklist. Banned IPs are silently dropped at the kernel level
3. **CrowdSec Console** (optional, cloud) — web dashboard at https://app.crowdsec.net for alerts, decisions, and community blocklists

### Why host-level (not Docker)

- Firewall bouncer needs direct iptables access — cannot work from inside a container
- Agent needs to read `/var/log/auth.log` (SSH) and `/var/log/nginx/` (Nginx) directly
- On a single VPS, containerization adds overhead with zero benefit

## What Is Monitored

| Attack Surface | Log File | What CrowdSec Detects |
|---|---|---|
| **SSH** (port 22) | `/var/log/auth.log` | Brute force (fast and slow), password spraying |
| **All web traffic** (80/443) | `/var/log/nginx/access.log` | SQL injection, XSS, path traversal, sensitive file access (`.env`, `.git`), WordPress scanning, bad user agents, aggressive crawling, CVE exploits |
| **All web traffic** (80/443) | `/var/log/nginx/error.log` | Server errors caused by attacks |
| **System** | journald/syslog | OS-level security events |

### Installed Detection Collections

| Collection | What It Detects |
|---|---|
| `crowdsecurity/sshd` | SSH brute force (fast and slow) |
| `crowdsecurity/nginx` | Nginx log parsing (enables all HTTP detection) |
| `crowdsecurity/base-http-scenarios` | SQL injection, XSS, path traversal, sensitive file access, bad user agents, admin panel probing |
| `crowdsecurity/http-cve` | Log4j, Spring4Shell, Fortinet VPN exploits, dozens of other CVEs |
| `crowdsecurity/linux` | OS-level threats |
| `crowdsecurity/whitelist-good-actors` | Whitelists Googlebot, Bingbot, etc. to prevent false positives |

## Ban Duration Policy

Configured in `/etc/crowdsec/profiles.yaml` with escalating bans.

### SSH brute force (scenarios starting with `crowdsecurity/ssh`)

| Offense | Duration |
|---------|----------|
| 1st | 24 hours |
| 2nd | 48 hours |
| 3rd | 72 hours |
| 4th | 96 hours |
| 5th+ | **1 year** (effectively permanent) |

SSH is the most sensitive surface — after 5 offenses, the IP has demonstrated persistent malicious intent.

### All other attacks (HTTP probing, CVE exploits, etc.)

| Offense | Duration |
|---------|----------|
| 1st | 24 hours |
| 2nd | 48 hours |
| Nth | N × 24 hours |

HTTP attacks escalate in 24-hour increments without a permanent cap, because web-facing IPs are more likely to be reassigned to legitimate users.

### How it works technically

Profiles are evaluated in order. The SSH profile is listed first and matches scenarios starting with `crowdsecurity/ssh`. If it matches, `on_success: break` stops evaluation. Otherwise, the default profile handles it. `duration_expr` uses `GetDecisionsCount()` to check prior bans and calculate the new duration.

## Configuration Files

### `/etc/crowdsec/profiles.yaml`

```yaml
# SSH — escalating, permanent after 5th
name: ssh_escalating_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip" && Alert.GetScenario() startsWith "crowdsecurity/ssh"
decisions:
 - type: ban
duration_expr: >-
  GetDecisionsCount(Alert.GetValue()) >= 5 ? "8760h" : Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 24)
on_success: break
---
# All other — escalating 24h increments
name: default_ip_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
 - type: ban
duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 24)
on_success: break
---
name: default_range_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
 - type: ban
duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 24)
on_success: break
```

**Important:** `duration_expr` must be at the **profile level** (same indentation as `decisions`), NOT inside the `decisions` list. Putting it inside `decisions` causes a YAML unmarshal error.

### `/etc/crowdsec/acquis.d/nginx.yaml`

```yaml
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
labels:
  type: nginx
```

Since Nginx runs on the host (not Docker), logs are at the standard `/var/log/nginx/` location. No custom log plumbing needed.

### Other config files

| File | Purpose |
|---|---|
| `/etc/crowdsec/config.yaml` | Main CrowdSec configuration |
| `/etc/crowdsec/acquis.yaml` | Default acquisition sources (SSH, syslog) |
| `/etc/crowdsec/acquis.d/nginx.yaml` | Nginx log acquisition |
| `/etc/crowdsec/profiles.yaml` | Ban duration policy (escalating) |
| `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` | Firewall bouncer config |
| `/var/lib/crowdsec/data/` | CrowdSec database (alerts, decisions, GeoIP) |

### Log rotation

Handled by the `nginx` package's default logrotate config at `/etc/logrotate.d/nginx`:
- Daily rotation, 14 days retention, compressed
- Signals Nginx to reopen log files after rotation

## CrowdSec Console

This server is enrolled in the CrowdSec Console at https://app.crowdsec.net.

### What the console provides

- **Alerts** — visual view of detected attacks with geolocation
- **Decisions** — currently banned IPs and reasons
- **Blocklists** — subscribe to community threat intelligence (IPs detected by other CrowdSec users worldwide are pre-emptively blocked on your server)
- **Security Engines** — confirms your agent is online

### Console features enabled

| Feature | Direction | Purpose |
|---|---|---|
| `custom` | Server → Console | Forward alerts from custom scenarios |
| `manual` | Server → Console | Forward manual decisions |
| `tainted` | Server → Console | Forward alerts from modified scenarios |
| `context` | Server → Console | Forward additional context with alerts |
| `console_management` | Console → Server | **Receive community blocklist decisions** |

All five are enabled. `console_management` is critical — without it, community blocklists are not enforced.

### Check status

```bash
cscli console status
# All five should show ✅
```

### Re-enrollment (if needed)

1. Log in to https://app.crowdsec.net → Settings → Enrollment Keys
2. Copy the key
3. `sudo cscli console enroll <key>`
4. Accept the instance in the console
5. `sudo cscli console enable console_management`
6. `sudo systemctl restart crowdsec`

## UFW Coexistence

CrowdSec and UFW both use iptables but do not conflict:
- CrowdSec creates its own chain (`CROWDSEC_CHAIN`) inserted at the **top** of the INPUT chain, **before** UFW's rules
- Evaluation order: CrowdSec → UFW → application
- A banned IP is blocked from **all** ports (SSH, HTTP, everything)
- No configuration changes needed to either CrowdSec or UFW

## Operational Commands

```bash
# Current bans
sudo cscli decisions list

# Detected attacks
sudo cscli alerts list

# Processing metrics (verify logs are being read)
sudo cscli metrics

# Service status
sudo systemctl status crowdsec
sudo systemctl status crowdsec-firewall-bouncer

# Manual ban/unban
sudo cscli decisions add --ip 1.2.3.4 --reason "manual ban" --duration 24h
sudo cscli decisions delete --ip 1.2.3.4

# View iptables blocklist
sudo iptables -L CROWDSEC_CHAIN -n
sudo ipset list crowdsec-blacklists-0

# Follow logs
sudo journalctl -u crowdsec -f
sudo journalctl -u crowdsec-firewall-bouncer -f

# Update detection scenarios
sudo cscli hub update && sudo cscli hub upgrade && sudo systemctl restart crowdsec

# List installed collections/scenarios
sudo cscli collections list
sudo cscli scenarios list
```

## Troubleshooting

- **CrowdSec not detecting Nginx attacks**: Check `cscli metrics` — `/var/log/nginx/access.log` should appear in Acquisition Metrics. If not, verify `/etc/crowdsec/acquis.d/nginx.yaml` exists and restart CrowdSec.
- **Firewall bouncer not blocking**: Check `systemctl status crowdsec-firewall-bouncer`, `cscli bouncers list` (should show Valid ✔️), and `iptables -L CROWDSEC_CHAIN -n`.
- **profiles.yaml parse error**: `duration_expr` must be at profile level, NOT nested inside `decisions`. Check with `journalctl -u crowdsec -n 10`.
- **Legitimate IP banned**: `sudo cscli decisions delete --ip X.X.X.X`. For permanent whitelisting, create `/etc/crowdsec/parsers/s02-enrich/my-whitelists.yaml`.
- **Services not starting after reboot**: `sudo systemctl reset-failed crowdsec && sudo systemctl restart crowdsec`
- **Console showing "No Security Engine"**: Enable console management: `sudo cscli console enable console_management && sudo systemctl restart crowdsec`

## Differences from the marin-server-infra Reference

This setup differs from the other server (`marin-server-infra`) in these ways:

| Aspect | marin-server-infra | This server (dev-sandbox) |
|---|---|---|
| Nginx | Docker container (`nginx:1.27-alpine`) | Host-level (`apt install nginx`) |
| Nginx logs | Custom volume mount to `/opt/infra/proxy/nginx/logs/` | Standard `/var/log/nginx/` |
| Log rotation | Custom `/etc/logrotate.d/nginx-proxy` with `docker exec` postrotate | Stock `/etc/logrotate.d/nginx` from nginx package |
| Log plumbing | Required custom `nginx.conf` mount to redirect Docker stdout to files | No extra setup needed — host Nginx writes files by default |
| CrowdSec acquis | Points to `/opt/infra/proxy/nginx/logs/` | Points to `/var/log/nginx/` |

The host-level Nginx on this server is simpler — no Docker log plumbing needed.
