#!/usr/bin/env bash

# USAGE: public_ipv4 <address>  - true when the address is a public IPv4 destination
#        public_ipv4 --self-check   - run the cases below
#
# Sourced by the allowlist generator and by the firewall. A name that is resolved at start comes
# from whatever the resolver answers, so an address that reaches a private, loopback, link-local,
# carrier-grade NAT or reserved network must never enter an egress allowlist: that would let a
# poisoned or broken DNS answer widen the boundary the allowlist exists to draw.

public_ipv4() {
  local ip=$1 a b c d
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]}
  b=${BASH_REMATCH[2]}
  c=${BASH_REMATCH[3]}
  d=${BASH_REMATCH[4]}
  ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1

  case $a in
  0 | 10 | 127) return 1 ;;                                  # this network, private, loopback
  100) ((b >= 64 && b <= 127)) && return 1 ;;                # carrier-grade NAT 100.64/10
  169) ((b == 254)) && return 1 ;;                           # link-local, incl. cloud metadata
  172) ((b >= 16 && b <= 31)) && return 1 ;;                 # private 172.16/12
  192)
    ((b == 168)) && return 1                                 # private 192.168/16
    ((b == 0 && (c == 0 || c == 2))) && return 1             # 192.0.0/24, TEST-NET-1
    ;;
  198)
    ((b == 18 || b == 19)) && return 1                       # benchmarking 198.18/15
    ((b == 51 && c == 100)) && return 1                      # TEST-NET-2
    ;;
  203) ((b == 0 && c == 113)) && return 1 ;;                 # TEST-NET-3
  esac

  ((a >= 224)) && return 1                                   # multicast and reserved
  return 0
}

# Cases run with `public_ipv4 --self-check`, so a change here has to face them.
if [[ ${1:-} == --self-check ]]; then
  failed=0
  check() {
    local want=$1 ip=$2
    local got=no
    public_ipv4 "$ip" && got=yes
    if [[ $got == "$want" ]]; then
      printf '  ok    %-22s %s\n' "$ip" "$want"
    else
      printf '  FAIL  %-22s wanted %s, got %s\n' "$ip" "$want" "$got" >&2
      failed=1
    fi
  }

  echo "public addresses are admitted:"
  for ip in 1.1.1.1 8.8.8.8 104.18.40.45 172.15.255.255 172.32.0.1 192.167.1.1 198.20.0.1 223.255.255.255; do
    check yes "$ip"
  done

  echo "private, loopback, link-local, reserved and malformed are refused:"
  for ip in 10.0.0.1 10.255.255.255 127.0.0.1 169.254.169.254 172.16.0.1 172.31.255.255 192.168.1.1 \
    100.64.0.1 100.127.255.255 0.0.0.0 192.0.0.1 192.0.2.1 198.18.0.1 198.51.100.5 203.0.113.9 \
    224.0.0.1 239.1.1.1 240.0.0.1 255.255.255.255 999.1.1.1 1.2.3 1.2.3.4.5 2a06:98c1:58::f3; do
    check no "$ip"
  done

  [[ $failed == 0 ]] && echo "public-ip: ok"
  exit $failed
fi
