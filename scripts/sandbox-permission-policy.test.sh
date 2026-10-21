#!/usr/bin/env bash

# USAGE: cases for the permission policy a sandboxed pi starts with, run by make check
#
# No container is started: docker is stubbed, and the cases assert the file the run leaves in the
# project. The policy itself is checked against the extension's own schema shape, since a policy
# that does not load fails closed and would ask for every call instead of none.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0

work="$(mktemp -d)"
stub="$(mktemp -d)"
trap 'rm -rf "$work" "$stub"' EXIT

home="$work/home"
proj="$work/proj"
dest="$proj/.pi/extensions/pi-permission-system/config.json"
mkdir -p "$home/.config/agent-sandbox" "$proj"
cp "$SRC/../config/base.conf" "$home/.config/agent-sandbox/base.conf"
cp "$SRC/../config/pi-permission-policy.json" "$home/.config/agent-sandbox/pi-permission-policy.json"
git -C "$proj" init -q

cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub/docker"

ok() { printf '  ok    %s\n' "$1"; }
bad() {
	printf '  FAIL  %s\n' "$1" >&2
	failed=1
}

expect() { # <label> <yes|no> <condition...>
	local label=$1 want=$2
	shift 2
	if "$@"; then got=yes; else got=no; fi
	if [ "$got" = "$want" ]; then ok "$label"; else bad "$label: wanted $want, got $got"; fi
}

run() { # <session>: runs the launcher with a stubbed docker
	printf 'AGENTS=""\n' >"$proj/.sandbox.conf"
	(cd "$proj" && HOME="$home" PATH="$stub:$PATH" "$SRC/sandbox.sh" "$1" true >/dev/null 2>&1) || true
}

jq_policy() { jq -r "$1" "$dest" 2>/dev/null; }

## CASES

run pi
expect 'a pi run seeds the project policy' yes test -f "$dest"
expect 'the policy is the installed one' yes cmp -s "$dest" "$SRC/../config/pi-permission-policy.json"
expect 'and it turns yolo on' yes test "$(jq_policy .yoloMode)" = true
expect 'with a universal allow as the floor' yes test "$(jq_policy '.permission["*"]')" = allow
expect 'and destructive commands still stop to ask' yes \
	test "$(jq_policy '.permission.bash["*rm -rf*"]')" = ask
expect 'while a plain commit does not' yes \
	test "$(jq_policy '.permission.bash["git commit *"]')" = allow
expect 'a push does' yes test "$(jq_policy '.permission.bash["git push *"]')" = ask
expect 'a credential change is refused' yes \
	test "$(jq_policy '.permission.bash["*--password*"]')" = deny

# A project that narrows itself keeps its own file, never overwritten.
printf '{"yoloMode": false, "permission": {"*": "ask"}}\n' >"$dest"
run pi
expect 'an existing project policy is left alone' yes \
	test "$(jq_policy .yoloMode)" = false

rm -f "$dest"
run bash
expect 'a non-pi session seeds nothing' no test -f "$dest"

if [ "$failed" -eq 0 ]; then
	printf 'sandbox-permission-policy: ok\n'
else
	exit 1
fi
