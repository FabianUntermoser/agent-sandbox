#!/usr/bin/env bash

# USAGE: default-deny egress firewall for agent sandbox container
#
# The argv carries fixed tokens only. A host:port grant and the closed=<cidr> networks arrive in
# $SERVICES, a read-only file the launcher wrote, because the user inside the container has sudo
# for this script.
#
# Two invariants, do not "simplify" them away:
#  (1) Egress is never open on purpose: the network is read before the flush, DROP is the first call
#      after it, and an EXIT trap closes a run that fails. The user inside can re-run this script.
#  (2) Only the `filter` table is flushed. Flushing `nat` destroys Docker's embedded DNS
#      (127.0.0.11) and every egress dies with it. Never add `iptables -t nat -F`.
#
# Domains are pre-resolved at build time into /etc/allowlist.sh and resolved again at start, because
# a CDN host moves. Only the GitHub ranges, which change often, are fetched at runtime.

set -euo pipefail
IFS=$'\n\t'

# Overridable for the cases in sandbox-firewall.test.sh.
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

# Checked before the firewall is touched, so a refused entry leaves the ruleset it already had.
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

# Resolved again at start, because a CDN host moves; the baked list is the floor.
#
# The names are resolved together, not one at a time. On a cold resolver each lookup costs from half
# a second to one and a half, and twenty five of them in a row is fourteen to thirty seconds: past
# the window a launcher waits for the container to come up, so the start was reported as a bridge
# that never arrived and the retry, on a warm resolver, took sixteen seconds. Eight at a time with a
# bounded deadline turns that into about a second. Nothing else about the list changes: only public
# IPv4 answers reach the set, and an entry that answers nothing is still simply not added.
domain_ips=
if [[ -f $ALLOWLIST_DOMAINS ]]; then
  # -d reads one name per line, so a quote or a backslash in a name is a character and not an
  # instruction to xargs: without it an unmatched quote abandons every name after that line.
  domain_ips=$(xargs -r -d '\n' -P 8 -n 1 dig +short +time=2 +tries=1 A 2>/dev/null <"$ALLOWLIST_DOMAINS" |
    grep -E '^[0-9.]+$' || true)
fi

# Fetched because they change often. IPv6 is left out: the set is IPv4.
gh_cidrs=
if gh_ranges=$(curl -fsSL https://api.github.com/meta 2>/dev/null); then
  gh_cidrs=$(echo "$gh_ranges" | jq -r '(.web + .api + .git)[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$"))' 2>/dev/null) || gh_cidrs=
else
  echo "  WARN: GitHub meta fetch failed, only the baked allowlist applies" >&2
fi

# A granted name moves too, so its answer is resolved at every start.
grant_ips=()
for svc in "${grants[@]}"; do
  addresses=$(dig +short A "${svc%:*}" 2>/dev/null | grep -E '^[0-9.]+$' || true)
  if [[ -z $addresses ]]; then
    echo "error: host service '${svc}' did not resolve to an IPv4 address; refusing the grant" >&2
    exit 1
  fi
  grant_ips+=("$addresses")
done

## FLUSH

# Flush ONLY the filter table (invariant #2), then deny before any rule exists (invariant #1).
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
  public_ipv4 "$ip" || continue
  ipset add allowed-domains "$ip" 2>/dev/null || true
done

# A range that reaches private space is counted and reported, never added.
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

# A granted name opens its port on this container's own gateway; a host:port entry opens its
# answers on that port alone. An answer on the container's own links, or on a docker network of the
# host, is refused: that is a sibling container, not a service.
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
  # Only a public or private destination, so a poisoned answer cannot aim it at loopback or metadata.
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
