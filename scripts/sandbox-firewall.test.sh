#!/usr/bin/env bash

# USAGE: cases for the egress firewall and its host-service grant, run by make check
#
# No container and no root: iptables, ipset, ip, dig, curl and sudo are fakes on PATH that log their
# argv to one file, in call order. A case asserts the rules the script would have written, and the
# order they came in, because a policy applied late is the gap this guards.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

command -v jq >/dev/null 2>&1 || { echo "  FAIL  jq is required, the firewall parses the GitHub ranges with it" >&2; exit 1; }

pass=0
fail=0
ok() { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted [$3] got [$2]"; fi; }

mkdir -p "$T/bin"
for tool in iptables ipset ip dig curl sudo; do
	cat >"$T/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >>"$T/calls"
STUB
done
cat >>"$T/bin/sudo" <<'STUB'
exec "$@"
STUB
cat >>"$T/bin/ipset" <<'STUB'
[ "${1:-}" = create ] && [ -n "${FAKE_IPSET_FAIL:-}" ] && exit 1
exit 0
STUB
cat >>"$T/bin/ip" <<'STUB'
case "${1:-}" in
route) if printenv FAKE_NO_GW >/dev/null; then :; else echo "default via 172.18.0.1 dev eth0"; fi ;;
-4) echo "2: eth0    inet 172.18.0.5/16 brd 172.18.255.255 scope global eth0" ;;
esac
STUB
cat >>"$T/bin/dig" <<STUB
awk -v n="\${@: -1}" '\$1 == n {print \$2}' "$T/dns"
STUB
cat >>"$T/bin/curl" <<STUB
case " \$* " in
*" https://api.github.com/meta "*)
	[ -n "\${FAKE_GH_FAIL:-}" ] && exit 22
	cat "$T/meta.json" ;;
*" https://example.com "*) exit 7 ;;
*) printf 200 ;;
esac
STUB
chmod +x "$T/bin/"*

cat >"$T/dns" <<'EOF'
cdn.example 104.18.40.45
svc.example 8.8.4.4
tail.example 100.100.1.2
own.example 172.18.0.9
sib.example 172.30.0.4
lo.example 127.0.0.1
meta.example 169.254.169.254
EOF
printf '{"web":["140.82.112.0/20"],"api":["192.30.252.0/22"],"git":["2a0a:a440::/29"]}\n' >"$T/meta.json"
printf 'ipset -exist add allowed-domains 1.2.3.4\n' >"$T/allowlist.sh"
printf 'cdn.example\n' >"$T/domains"

fw() { # <services line ...> -- <argv ...>: run the firewall as the launcher would
	: >"$T/services"
	while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
		printf '%s\n' "$1" >>"$T/services"
		shift
	done
	[ "$#" -gt 0 ] && shift
	: >"$T/calls"
	set +e
	# shellcheck disable=SC2024 # the sudo here is the fake, the output is the test's own
	PATH="$T/bin:$PATH" PUBLIC_IP_LIB="$SRC/public-ip.sh" ALLOWLIST_FILE="$T/allowlist.sh" \
		ALLOWLIST_DOMAINS="$T/domains" SERVICES="$T/services" \
		sudo "$SRC/init-firewall.sh" "$@" >"$T/out" 2>&1
	rc=$?
	set -e
}

ipt() { sed -n 's/^iptables //p' "$T/calls"; }
count() { ipt | grep -cxF -- "$1" || true; }
DROP='-P INPUT DROP|-P FORWARD DROP|-P OUTPUT DROP|'
after_flush() { ipt | sed -n '/^-F$/{n;p;n;p;n;p;q;}' | tr '\n' '|'; }
last_policies() { ipt | tail -3 | tr '\n' '|'; }
never_accept() { ipt | grep -c -- '^-P .* ACCEPT$' || true; }
says() { grep -qF -- "$1" "$T/out" && echo yes || echo no; }
# The line of the first flush against the last network lookup: the lookups have to come first.
fetched_before_flush() {
	local flush last
	flush=$(grep -n '^iptables -F$' "$T/calls" | head -1 | cut -d: -f1)
	last=$(grep -nE '^(dig |curl .*api\.github\.com/meta)' "$T/calls" | tail -1 | cut -d: -f1)
	[ -n "$flush" ] && [ -n "$last" ] && [ "$last" -lt "$flush" ] && echo yes || echo no
}

printf '  a domain list read one name per line\n'
# A name is a name even when it carries a quote or a backslash: the list is read line by line, so
# neither can swallow the names after it. Each of the three lines gets its own lookup.
printf 'one.example\nquo"ted.example\ntwo.example\n' >"$T/domains"
fw
chk "every line is looked up, quoted or not" "$(grep -c '^dig ' "$T/calls" || true)" "3"
chk "and the run still succeeds" "$rc" "0"
printf 'cdn.example\n' >"$T/domains"

printf '  a granted public name\n'
fw svc.example:8317
chk "the run succeeds" "$rc" "0"
chk "one rule opens that address on that port" "$(count '-A OUTPUT -d 8.8.4.4 -p tcp --dport 8317 -j ACCEPT')" "1"
chk "and no other rule names that port" "$(ipt | grep -c -- '--dport 8317' || true)" "1"
chk "the DROP policies are the first calls after the flush" "$(after_flush)" "$DROP"
chk "and the last calls on the way out" "$(last_policies)" "$DROP"
chk "no policy is ever set to ACCEPT" "$(never_accept)" "0"
chk "the network lookups happen before the flush" "$(fetched_before_flush)" "yes"
chk "the resolved domain is added" "$(grep -c '^ipset add allowed-domains 104.18.40.45$' "$T/calls" || true)" "1"
chk "the GitHub ranges are added" "$(grep -cE '^ipset add allowed-domains (140\.82\.112\.0/20|192\.30\.252\.0/22)$' "$T/calls" || true)" "2"
chk "the allowlist rule is in place" "$(count '-A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT')" "1"
chk "the run reports the network" "$(says 'network:')" "yes"

printf '  a granted name that answers in tailnet space\n'
fw tail.example:8317
chk "the run succeeds" "$rc" "0"
chk "one rule opens that address on that port" "$(count '-A OUTPUT -d 100.100.1.2 -p tcp --dport 8317 -j ACCEPT')" "1"

printf '  a syntactically valid host that does not resolve\n'
fw missing.example:8317
chk "the grant fails closed" "$rc" "1"
chk "the error identifies the unresolved service" "$(says "host service 'missing.example:8317' did not resolve")" "yes"
chk "resolution fails before the filter table is flushed" "$(ipt | grep -c -- '^-F$' || true)" "0"
chk "the EXIT trap leaves DROP policies in place" "$(last_policies)" "$DROP"
chk "nothing was opened for the unresolved host" "$(ipt | grep -c -- '--dport 8317' || true)" "0"

printf '  a host grant, which names the gateway itself\n'
fw -- host:1313
chk "the run succeeds" "$rc" "0"
chk "the gateway is opened on that port" "$(count '-A OUTPUT -d 172.18.0.1 -p tcp --dport 1313 -j ACCEPT')" "1"
chk "and on no other port" "$(ipt | grep -c -- '--dport 1313' || true)" "1"
chk "no name is resolved for the grant" "$(grep -c '^dig host' "$T/calls" || true)" "0"
chk "the DROP policies are the first calls after the flush" "$(after_flush)" "$DROP"
chk "and the last calls on the way out" "$(last_policies)" "$DROP"
chk "no policy is ever set to ACCEPT" "$(never_accept)" "0"

printf '  a published container TCP port\n'
fw published:3000
chk "the firewall run succeeds" "$rc" "0"
chk "the declared port accepts publisher traffic from the bridge gateway" "$(count '-A INPUT -s 172.18.0.1 -p tcp --dport 3000 -j ACCEPT')" "1"
chk "the port is not opened to arbitrary sibling-container sources" "$(count '-A INPUT -p tcp --dport 3000 -j ACCEPT')" "0"
chk "no other service port is opened inbound" "$(ipt | grep -c -- '--dport 3001' || true)" "0"

printf '  a published port without a gateway\n'
FAKE_NO_GW=1 fw published:3000
chk "the run fails closed when no container gateway can be determined" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
chk "no firewall rule set is flushed before the refusal" "$(grep -c '^iptables -F$' "$T/calls" || true)" "0"
chk "the refusal explains the missing gateway" "$(says 'cannot determine the container gateway for published ports')" "yes"

printf '  a host grant with a bad port\n'
for bad in host:0 host:70000 host:abc host:; do
	fw -- "$bad"
	chk "$bad: the run fails" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
	chk "$bad: nothing is opened" "$(ipt | grep -c -- '172.18.0.1' || true)" "0"
	chk "$bad: the policies end at DROP" "$(last_policies)" "$DROP"
done

printf '  answers a grant may not reach\n'
for refused in own.example:172.18.0.9 sib.example:172.30.0.4 lo.example:127.0.0.1 meta.example:169.254.169.254; do
	name=${refused%%:*}
	addr=${refused#*:}
	fw closed=172.30.0.0/16 "$name:8317"
	chk "$addr: the run succeeds" "$rc" "0"
	chk "$addr: nothing is opened" "$(ipt | grep -c -- "-d $addr" || true)" "0"
	chk "$addr: the run warns" "$(says "WARN: host service '$name:8317' resolved to no address")" "yes"
	chk "$addr: the policies end at DROP" "$(last_policies)" "$DROP"
done

printf '  an entry the checks refuse\n'
for case in 'malformed entry|no-port-here|' 'bad CIDR|closed=10.0.0.0/33|' 'bad published port|published:abc|' 'out-of-range published port|published:65536|' 'zero published port|published:0|' 'unknown argv token||proxy.example:80'; do
	label=${case%%|*}
	rest=${case#*|}
	line=${rest%%|*}
	arg=${rest#*|}
	if [ -n "$arg" ]; then fw -- "$arg"; else fw "$line"; fi
	chk "$label: the run fails" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
	chk "$label: no rule, flush or chain call is made" "$(ipt | grep -vc -- '^-P .* DROP$' || true)" "0"
	chk "$label: the trap still leaves the policies at DROP" "$(last_policies)" "$DROP"
	chk "$label: nothing reached the network" "$(grep -cE '^(dig|curl|ipset) ' "$T/calls" || true)" "0"
done

printf '  the GitHub fetch fails\n'
FAKE_GH_FAIL=1 fw svc.example:8317
chk "the run still succeeds" "$rc" "0"
chk "and says so" "$(says 'WARN: GitHub meta fetch failed')" "yes"
chk "the DROP policies are the first calls after the flush" "$(after_flush)" "$DROP"
chk "and the last calls on the way out" "$(last_policies)" "$DROP"
chk "no policy is ever set to ACCEPT" "$(never_accept)" "0"
chk "the baked list is still the floor" "$(grep -c '^ipset -exist add allowed-domains 1.2.3.4$' "$T/calls" || true)" "1"
chk "and the grant still opens" "$(count '-A OUTPUT -d 8.8.4.4 -p tcp --dport 8317 -j ACCEPT')" "1"

printf '  a later step aborts\n'
FAKE_IPSET_FAIL=1 fw svc.example:8317
chk "the run fails" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
chk "the DROP policies are the first calls after the flush" "$(after_flush)" "$DROP"
chk "and the trap applies them again on the way out" "$(last_policies)" "$DROP"
chk "no policy is ever set to ACCEPT" "$(never_accept)" "0"

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo "sandbox-firewall: ok"
