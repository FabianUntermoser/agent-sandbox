#!/usr/bin/env bash

# USAGE: public_ipv4 <address>  - true when the address is a public IPv4 destination
#        public_cidr <cidr>     - true when the whole range stays in public IPv4 space
#        public_ipv4 --self-check   - run the cases below
#
# Sourced by the allowlist generator and by the firewall. A name that is resolved at start comes
# from whatever the resolver answers, so an address that reaches a private, loopback, link-local,
# carrier-grade NAT or reserved network must never enter an egress allowlist: that would let a
# poisoned or broken DNS answer widen the boundary the allowlist exists to draw. The same holds
# for the ranges the GitHub meta API answers with, so the non-public space is one table here.

# Non-public IPv4 space, one entry per reserved purpose.
non_public_ipv4=(
  0.0.0.0/8       # this network
  10.0.0.0/8      # private
  100.64.0.0/10   # carrier-grade NAT
  127.0.0.0/8     # loopback
  169.254.0.0/16  # link-local, incl. cloud metadata
  172.16.0.0/12   # private
  192.0.0.0/24    # IETF protocol assignments
  192.0.2.0/24    # TEST-NET-1
  192.168.0.0/16  # private
  198.18.0.0/15   # benchmarking
  198.51.100.0/24 # TEST-NET-2
  203.0.113.0/24  # TEST-NET-3
  224.0.0.0/4     # multicast
  240.0.0.0/4     # reserved
)

# Parse <network>/<prefix> into _first and _last, the first and last address of the range as
# integers. Refuses a bare address, an absent, non-numeric or out-of-range prefix, junk after the
# prefix, an octet above 255, and anything that is not IPv4.
_cidr_bounds() {
  local cidr=${1:-} ip prefix a b c d
  local octet='25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9]'
  [[ $cidr == */* ]] || return 1
  ip=${cidr%%/*}
  prefix=${cidr#*/}
  [[ $prefix =~ ^(3[0-2]|[12][0-9]|[0-9])$ ]] || return 1
  prefix=${BASH_REMATCH[1]}
  [[ $ip =~ ^($octet)\.($octet)\.($octet)\.($octet)$ ]] || return 1
  a=${BASH_REMATCH[1]}
  b=${BASH_REMATCH[2]}
  c=${BASH_REMATCH[3]}
  d=${BASH_REMATCH[4]}
  local base=$(((a << 24) | (b << 16) | (c << 8) | d)) size=$((1 << (32 - prefix)))
  _first=$((base & ~(size - 1)))
  _last=$((base | (size - 1)))
}

# A range is refused when it overlaps a non-public block anywhere, not merely when its network
# address lands in one: 172.0.0.0/8 starts in public space and still covers 172.16.0.0/12.
public_cidr() {
  local cidr=${1:-} first last block bfirst blast
  _cidr_bounds "$cidr" || return 1
  first=$_first
  last=$_last
  for block in "${non_public_ipv4[@]}"; do
    _cidr_bounds "$block" || continue
    bfirst=$_first
    blast=$_last
    if ((first <= blast && bfirst <= last)); then
      return 1
    fi
  done
  return 0
}

public_ipv4() {
  public_cidr "${1:-}/32"
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
  check_cidr() {
    local want=$1 cidr=$2
    local got=no
    public_cidr "$cidr" && got=yes
    if [[ $got == "$want" ]]; then
      printf '  ok    %-22s %s\n' "$cidr" "$want"
    else
      printf '  FAIL  %-22s wanted %s, got %s\n' "$cidr" "$want" "$got" >&2
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

  echo "the GitHub meta API ranges are admitted:"
  for cidr in 140.82.112.0/20 192.30.252.0/22 185.199.108.0/22 143.55.64.0/20 4.148.0.0/16 \
    20.248.137.48/29 20.27.177.113/32; do
    check_cidr yes "$cidr"
  done

  echo "ranges that overlap non-public space, and malformed ranges, are refused:"
  for cidr in 0.0.0.0/0 128.0.0.0/1 10.0.0.0/8 10.0.0.0/7 172.0.0.0/8 172.16.0.0/12 192.0.0.0/8 \
    192.160.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 198.18.0.0/15 192.0.2.0/24 \
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32 10.0.0.0/32 "" 1.2.3.0 \
    1.2.3.0/ 1.2.3.0/33 1.2.3.0/24x 1.2.3.0/abc 999.0.0.0/8 2a06:98c1:58::f3/48; do
    check_cidr no "$cidr"
  done

  [[ $failed == 0 ]] && echo "public-ip: ok"
  exit $failed
fi
