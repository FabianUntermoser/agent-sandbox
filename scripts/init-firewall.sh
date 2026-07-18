#!/usr/bin/env bash

# USAGE: default-deny egress firewall for agent sandbox container
#
# Two correctness invariants are baked in here — do not "simplify" them away:
#  (1) Policies are reset to ACCEPT right after the flush so a re-run can still
#      reach the internet to rebuild the allowlist. A leftover -P OUTPUT DROP
#      from a previous run would otherwise block the github/dns fetches below and
#      abort under `set -e`, leaving a half-open firewall (everything blocked).
#  (2) Only the `filter` table is flushed. Flushing `nat` destroys Docker's
#      embedded DNS (127.0.0.11) → all egress dead. Never add `iptables -t nat -F`.
#
# Static domains are pre-resolved at build time into /etc/allowlist.sh.
# Only GitHub IP ranges (which change often) are fetched at runtime.

set -euo pipefail
IFS=$'\n\t'

## FLUSH

# Flush ONLY the filter table (invariant #2). Drop leftover ipset.
iptables -F
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

# Reset policies to ACCEPT so this run can rebuild the allowlist (invariant #1).
# DROP is re-applied at the end.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

## DNS + LOCAL

# DNS (incl. docker embedded resolver) + localhost
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p tcp --sport 53 -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

## ALLOWLIST

ipset create allowed-domains hash:net

# Pre-resolved static domains (built at image build time — no DNS at runtime)
source /etc/allowlist.sh

# GitHub IP ranges (web/api/git) from the meta API — fetched at runtime
# because they change frequently
gh_ranges=$(curl -fsSL https://api.github.com/meta 2>/dev/null)
echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | while read -r cidr; do
  [[ -z "$cidr" ]] && continue
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done

# Return traffic
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Local docker network
LOCAL_CIDR=$(ip route | grep -E "^[0-9.]+/[0-9]+ " | head -1 | cut -d' ' -f1 || true)
[[ -n "$LOCAL_CIDR" ]] && iptables -A OUTPUT -d "$LOCAL_CIDR" -j ACCEPT

# Allowlist
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Default deny (applied last, once the allowlist exists)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

## VERIFY

echo -e "  \e[1mnetwork:\e[0m OK" >&2

# Quick verify: blocked host fails, allowed host gets HTTP response
if curl -fsS --max-time 3 https://example.com >/dev/null 2>&1; then
  echo "  WARN: egress not blocked" >&2
fi
curl -s -o /dev/null -w '%{http_code}' --max-time 3 https://api.anthropic.com | grep -q 000 && echo "  WARN: anthropic unreachable" >&2 || true
