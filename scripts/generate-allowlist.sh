#!/usr/bin/env bash

# USAGE: generate ipset allowlist from ALLOWED_DOMAINS at build time
# Outputs a shell snippet that init-firewall.sh sources, no DNS at runtime.

set -euo pipefail

## DEFAULTS

ALLOWED_DOMAINS=(
  api.anthropic.com
  statsig.anthropic.com
  downloads.claude.ai
  # The tunnel client behind a bridge instance dials the OpenAI control plane, and codex talks to
  # the same host, so it belongs in the generic list rather than in a per-project grant.
  api.openai.com
  raw.githubusercontent.com
  codeload.github.com
  objects.githubusercontent.com
  github.com
  gitlab.com
  registry.npmjs.org
  pypi.org
  files.pythonhosted.org
  crates.io
  static.crates.io
  proxy.golang.org
  sum.golang.org
  api.atlassian.com
  id.atlassian.com
  auth.atlassian.com
  joaia.atlassian.net
  ollama.com
  registry.ollama.ai
  api.ollama.ai
  mcp.linear.app
  mcp.posthog.com
)

for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(dig +short A "$domain" | grep -E '^[0-9.]+$' || true)
  for ip in $ips; do
    echo "ipset -exist add allowed-domains $ip"
  done
done

# One domain per line, for the firewall to resolve again at start: a CDN host moves.
if [ -n "${DOMAINS_FILE:-}" ]; then
  printf '%s\n' "${ALLOWED_DOMAINS[@]}" >"$DOMAINS_FILE"
fi
