#!/bin/bash
# Canonical default-deny egress firewall for an agent sandbox container.
#
# Two correctness invariants are baked in here — do not "simplify" them away:
#  (1) Policies are reset to ACCEPT right after the flush so a re-run can still
#      reach the internet to rebuild the allowlist. A leftover -P OUTPUT DROP
#      from a previous run would otherwise block the github/dns fetches below and
#      abort under `set -e`, leaving a half-open firewall (everything blocked).
#  (2) Only the `filter` table is flushed. Flushing `nat` destroys Docker's
#      embedded DNS (127.0.0.11) → all egress dead. Never add `iptables -t nat -F`.
#
# Tune ALLOWED_DOMAINS for the project's stack. Keep everything else.
set -euo pipefail
IFS=$'\n\t'

# --- allowlist: edit this for the project ----------------------------------
ALLOWED_DOMAINS=(
  # Claude Code
  api.anthropic.com
  statsig.anthropic.com
  downloads.claude.ai
  # raw/codeload for git installs (GitHub IP ranges added separately below)
  raw.githubusercontent.com
  codeload.github.com
  objects.githubusercontent.com
  # git remote
  github.com
  gitlab.com
  # npm
  registry.npmjs.org
  # python
  pypi.org
  files.pythonhosted.org
  # rust
  crates.io
  static.crates.io
  # go
  proxy.golang.org
  sum.golang.org
  # atlassian (acli)
  api.atlassian.com
  id.atlassian.com
  auth.atlassian.com
  joaia.atlassian.net
  # ollama (cloud models + integration sign-in; local models use loopback, no allowlist)
  ollama.com
  registry.ollama.ai
)
# ---------------------------------------------------------------------------

# Flush ONLY the filter table (invariant #2). Drop leftover ipset.
iptables -F
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

# Reset policies to ACCEPT so this run can rebuild the allowlist (invariant #1).
# DROP is re-applied at the end.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# DNS (incl. docker embedded resolver) + localhost
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p tcp --sport 53 -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

# GitHub IP ranges (web/api/git) from the meta API
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -fsSL https://api.github.com/meta)
echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | while read -r cidr; do
  [[ -z "$cidr" ]] && continue
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done

# Resolve + allow each allowlisted domain
for domain in "${ALLOWED_DOMAINS[@]}"; do
  echo "Resolving $domain..."
  ips=$(dig +short A "$domain" | grep -E '^[0-9.]+$' || true)
  for ip in $ips; do
    ipset add allowed-domains "$ip" 2>/dev/null || true
  done
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

echo "Firewall configured. Verifying..."
if curl -fsS --max-time 5 https://example.com >/dev/null 2>&1; then
  echo "WARNING: example.com reachable — firewall not blocking as expected." >&2
else
  echo "OK: blocked host unreachable."
fi
# 401/404 are fine — any HTTP response means the connection got through
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://api.anthropic.com || echo 000)
if [[ "$code" != "000" ]]; then
  echo "OK: api.anthropic.com reachable (HTTP $code)."
else
  echo "WARNING: api.anthropic.com unreachable — allowlist may be incomplete." >&2
fi
