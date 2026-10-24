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
trust="$home/.pi/agent/trust.json"
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

jq_policy() { jq -r "$1" "$SRC/../config/pi-permission-policy.json" 2>/dev/null; }

## CASES

# The catalogue policy is still the sandbox's intended usability policy, but it is staged by
# sandbox-entrypoint.sh into a per-container PI_CODING_AGENT_DIR rather than written into the repo.
if jq -e . "$SRC/../config/pi-permission-policy.json" >/dev/null; then
  ok 'the installed policy is valid JSON'
else
  bad 'the installed policy is valid JSON'
fi
expect 'the sandbox policy has yolo enabled for unattended operation' yes test "$(jq_policy .yoloMode)" = true
expect 'destructive commands still have an ask guard' yes \
  test "$(jq_policy '.permission.bash["*rm -rf*"]')" = ask
expect 'pushes still have an ask guard' yes test "$(jq_policy '.permission.bash["git push *"]')" = ask
expect 'credential-changing commands have a deny guard' yes \
  test "$(jq_policy '.permission.bash["*--password*"]')" = deny

run pi
expect 'launching Pi does not seed a project-local permission policy' no test -e "$dest"
expect 'launching Pi does not create host Pi trust state' no test -e "$trust"

# Preserve an explicitly configured project policy and any existing host trust store.
mkdir -p "$(dirname "$dest")" "$(dirname "$trust")"
printf '{"yoloMode":false,"permission":{"*":"ask"}}\n' >"$dest"
printf '{"existing-project":true}\n' >"$trust"
cp "$dest" "$work/project-policy.before"
cp "$trust" "$work/trust.before"
run pi
expect 'an existing project-local policy is byte-for-byte unchanged' yes \
  cmp -s "$dest" "$work/project-policy.before"
expect 'existing host Pi trust is byte-for-byte unchanged' yes \
  cmp -s "$trust" "$work/trust.before"

rm -f "$dest"
run bash
expect 'a non-Pi session also leaves project policy absent' no test -e "$dest"
expect 'a non-Pi session leaves host trust unchanged' yes cmp -s "$trust" "$work/trust.before"

if [ "$failed" -eq 0 ]; then
	printf 'sandbox-permission-policy: ok\n'
else
	exit 1
fi
