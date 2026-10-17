#!/usr/bin/env bash

# USAGE: default-deny egress firewall for agent sandbox container
#
# Optional arg carries a fixed token only: ollama. Host:port grants and the closed=<cidr> networks
# arrive in $SERVICES, a read-only file the launcher wrote, because the user inside the container
# has sudo for this script and anything in the argv would be its own.
#
# Two correctness invariants are baked in here, do not "simplify" them away:
#  (1) Egress is never open on purpose. The user inside the container can re-run this script, so
#      everything the network gives (the domains resolved again, the GitHub ranges, the grant
#      answers) is collected first, while the old ruleset still allows it. The DROP policies are
#      the first call after the flush, and an EXIT trap applies them again, so a failed fetch or a
#      `set -e` abort ends closed instead of open. A failed GitHub fetch keeps the baked list.
#  (2) Only the `filter` table is flushed. Flushing `nat` destroys Docker's
#      embedded DNS (127.0.0.11) → all egress dead. Never add `iptables -t nat -F`.
#
# Static domains are pre-resolved at build time into /etc/allowlist.sh, and resolved again when a
# sandbox starts from /etc/allowlist-domains, because a CDN host moves.
# Only GitHub IP ranges (which change often) are fetched at runtime.

set -euo pipefail
IFS=$'\n\t'

# Overridable so the cases in sandbox-firewall.test.sh can run without the image.
PUBLIC_IP_LIB="${PUBLIC_IP_LIB:-/usr/local/lib/public-ip.sh}"
ALLOWLIST_FILE="${ALLOWLIST_FILE:-/etc/allowlist.sh}"
ALLOWLIST_DOMAINS="${ALLOWLIST_DOMAINS:-/etc/allowlist-domains}"

close_egress() {
  iptables -P INPUT DROP || true
  iptables -P FORWARD DROP || true
  iptables -P OUTPUT DROP || true
}
trap close_egress EXIT

# The public-address predicate is shared with the generator at build time.
# shellcheck source=public-ip.sh
source "$PUBLIC_IP_LIB"

## ARGS

# Checked before the firewall is touched, so a run with an entry that is refused stops with the
# ruleset it already had, and the trap closes its policies.
#
# The argv carries fixed tokens only. The user inside the container has sudo for this script, so a
# dynamic grant in an argument would let it widen its own egress; a host:port entry arrives in a
# read-only file instead.
SERVICES=${SERVICES:-/etc/agent-sandbox-host-services}
grants=()
closed_nets=()
if [[ -f $SERVICES ]]; then
  while read -r entry; do
    case "$entry" in '' | \#*) continue ;; esac
    if [[ $entry == closed=* ]]; then
      if ! valid_cidr "${entry#closed=}"; then
        echo "error: closed network '$entry' in $SERVICES is not a CIDR" >&2
        exit 1
      fi
      closed_nets+=("${entry#closed=}")
      continue
    fi
    svc_port=${entry##*:}
    if ! [[ ${entry%:*} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $svc_port =~ ^[0-9]{1,5}$ ]] ||
      ((10#$svc_port < 1 || 10#$svc_port > 65535)); then
      echo "error: host service '$entry' in $SERVICES is not a <host>:<port> entry" >&2
      exit 1
    fi
    grants+=("$entry")
  done <"$SERVICES"
fi

for svc in "$@"; do
  case "$svc" in
  ollama) ;;
  *) echo "error: unknown argument '$svc', the grant comes from $SERVICES" >&2
     exit 1 ;;
  esac
done

## COLLECT

# Everything the network answers is gathered here, before the flush (invariant #1). The answers are
# filtered where they are added below.

# Resolved again at start, because a CDN host moves and a stale entry hangs with nothing in the
# log. The baked list stays as the floor for when DNS is unavailable.
domain_ips=
if [[ -f $ALLOWLIST_DOMAINS ]]; then
  while read -r domain; do
    [[ -n "$domain" ]] || continue
    domain_ips+=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' || true)$'\n'
  done < "$ALLOWLIST_DOMAINS"
fi

# GitHub IP ranges (web/api/git) from the meta API, fetched at runtime because they change
# frequently. IPv6 ranges are left out here because the set is IPv4 (hash:net); an IPv6 entry
# never reached it either way.
gh_cidrs=
if gh_ranges=$(curl -fsSL https://api.github.com/meta 2>/dev/null); then
  gh_cidrs=$(echo "$gh_ranges" | jq -r '(.web + .api + .git)[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$"))' 2>/dev/null) || gh_cidrs=
else
  echo "  WARN: GitHub meta fetch failed, only the baked allowlist applies" >&2
fi

# The answer behind a granted name moves, so it is resolved at every start rather than in the
# allowlist.
grant_ips=()
for svc in "${grants[@]}"; do
  grant_ips+=("$(dig +short A "${svc%:*}" 2>/dev/null | grep -E '^[0-9.]+$' || true)")
done

## FLUSH

# Flush ONLY the filter table (invariant #2), then deny before any rule exists (invariant #1).
# Drop leftover ipset.
iptables -F
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

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

# Pre-resolved static domains (built at image build time, no DNS at runtime)
# shellcheck source=/dev/null
source "$ALLOWLIST_FILE"

for ip in $domain_ips; do
  # A resolver answering with a private or reserved address must not widen the boundary.
  public_ipv4 "$ip" || continue
  ipset add allowed-domains "$ip" 2>/dev/null || true
done

# The meta API response is not trusted: a range that reaches private or reserved space must not
# widen the boundary, so it is counted and reported instead of added.
gh_refused=0
while read -r cidr; do
  [[ -n "$cidr" ]] || continue
  public_cidr "$cidr" || {
    gh_refused=$((gh_refused + 1))
    continue
  }
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done <<< "$gh_cidrs"
if ((gh_refused > 0)); then
  echo "  WARN: refused $gh_refused non-public GitHub CIDR(s)" >&2
fi

# Return traffic
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Host services are opt-in: a granted name opens its port on this container's own gateway, a
# granted <host>:<port> entry opens the addresses the name answers with, on that port alone. An
# answer inside a network this container may not reach is refused: its own links, and every docker
# network of the host, which the launcher lists in the services file because this container cannot
# enumerate them. A grant then names a service off the network, never a sibling container.
on_closed_net() {
  local net
  for net in "${closed_nets[@]}"; do
    if in_cidr "$1" "$net"; then
      return 0
    fi
  done
  while read -r net; do
    [[ -n "$net" ]] || continue
    if in_cidr "$1" "$net"; then
      return 0
    fi
  done < <(ip -4 -o addr show scope global | awk '{print $4}')
  return 1
}

GW=$(ip route | awk '/^default/ {print $3; exit}')
svc_refused=0
for svc in "$@"; do
  case "$svc" in
  ollama)
    if [[ -n "$GW" ]]; then
      iptables -A OUTPUT -d "$GW" -p tcp --dport 11434 -j ACCEPT
    fi
    ;;
  esac
done

for i in "${!grants[@]}"; do
  # Only a public or private destination is opened, so a poisoned answer cannot aim the grant at
  # loopback or at the link-local metadata service.
  svc=${grants[i]}
  svc_port=$((10#${svc##*:}))
  opened=0
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    if on_closed_net "$ip"; then
      svc_refused=$((svc_refused + 1))
      continue
    fi
    if ! public_ipv4 "$ip" && ! private_ipv4 "$ip"; then
      svc_refused=$((svc_refused + 1))
      continue
    fi
    iptables -A OUTPUT -d "$ip" -p tcp --dport "$svc_port" -j ACCEPT
    opened=$((opened + 1))
  done <<< "${grant_ips[i]}"
  if ((opened == 0)); then
    echo "  WARN: host service '$svc' resolved to no address that may be opened" >&2
  fi
done
if ((svc_refused > 0)); then
  echo "  WARN: refused $svc_refused host service address(es) on a network this container may not reach, or outside public and private space" >&2
fi

# Allowlist
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

## VERIFY

echo -e "  \e[1mnetwork:\e[0m OK" >&2

# Quick verify: blocked host fails, allowed host gets HTTP response
if curl -fsS --max-time 3 https://example.com >/dev/null 2>&1; then
  echo "  WARN: egress not blocked" >&2
fi
curl -s -o /dev/null -w '%{http_code}' --max-time 3 https://api.anthropic.com | grep -q 000 && echo "  WARN: anthropic unreachable" >&2 || true
