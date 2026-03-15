#!/usr/bin/env bash
# Restrict Docker-published ports via the DOCKER-USER iptables chain.
# Docker bypasses UFW, so this chain is the correct place to filter
# traffic to container-published ports.
#
# This script is idempotent — it flushes DOCKER-USER before adding rules.

set -euo pipefail

iptables -F DOCKER-USER

# PostgreSQL (5432): allow from pgadmin.marin.cr, localhost, and Docker networks
iptables -A DOCKER-USER -p tcp --dport 5432 -s 195.26.247.169 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 5432 -s 127.0.0.1 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 5432 -s 172.16.0.0/12 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 5432 -j DROP

# Portainer Agent (9001): allow from portainer.marin.cr, localhost, and Docker networks
iptables -A DOCKER-USER -p tcp --dport 9001 -s 195.26.247.169 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9001 -s 127.0.0.1 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9001 -s 172.16.0.0/12 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 9001 -j DROP

# Default: allow everything else through (don't break other containers)
iptables -A DOCKER-USER -j RETURN
