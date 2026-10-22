#!/usr/bin/env bash

# USAGE: cases for the tools a manifest grants from tools.d, run by make check
#
# No container is started: docker is stubbed and records the arguments of the run, so a case asserts
# the -v pairs the script hands docker. The tool catalogue is a throwaway directory, which is what
# proves a new tool is a new file: the same script grants a tool it has never heard of.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0

work="$(mktemp -d)"
stub="$(mktemp -d)"
trap 'rm -rf "$work" "$stub"' EXIT

home="$work/home"
farm="$work/farm"
mkdir -p "$home/.agents/skills" "$farm/skills/linear/scripts" "$home/.agent-secrets" "$work/tools.d" "$work/run"
: >"$farm/skills/linear/SKILL.md"
printf '#!/bin/sh\necho viewer\n' >"$farm/skills/linear/scripts/linear-api.sh"
chmod +x "$farm/skills/linear/scripts/linear-api.sh"
# the skill is a stow-farm link, which is what a resolved mount has to survive
ln -s "$farm/skills/linear" "$home/.agents/skills/linear"
printf 'LINEAR_CLIENT_ID=fixture\n' >"$home/.agent-secrets/linear-app.env"

# A tool the script has never seen: nothing but this file makes it exist.
mkdir -p "$farm/other"
printf 'placeholder\n' >"$farm/other/data"

cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
[ "\$1" = run ] || exit 0
printf '%s\n' "\$@" >>"$work/args"
exit 0
EOF
chmod +x "$stub/docker"

cat >"$work/base.conf" <<EOF
# nothing inherited from the host in these cases
EOF

tool() { # <name> <key=value...>
	local name=$1
	shift
	printf '%s\n' "$@" >"$work/tools.d/$name.conf"
}

# One refusal must not shadow the next: the catalogue is walked whole, so a broken file left in it
# would stop every case after it.
only() { # <name> <key=value...>
	local name=$1
	rm -f "$work"/tools.d/*.conf
	tool "$@"
}

tool linear \
	"OPT_IN=true" \
	"SKILL_HOST=$home/.agents/skills/linear" \
	"SKILL_CONTAINER=/home/node/.agents/skills/linear" \
	"CRED_HOST=$home/.agent-secrets/linear-app.env" \
	"CRED_CONTAINER=/home/node/.agent-secrets/linear-app.env" \
	"CLI_HOST=$home/.agents/skills/linear/scripts/linear-api.sh" \
	"CLI_CONTAINER=/usr/local/bin/linear-api.sh" \
	"HOSTS=api.linear.app:443"

run() { # <manifest lines...>
	printf '%s\n' "$@" >"$work/.sandbox.conf"
	rm -f "$work/args" "$work/run"/agent-sandbox/* 2>/dev/null || true
	set +e
	out=$(cd "$work" && HOME="$home" XDG_RUNTIME_DIR="$work/run" BASE_CONF="$work/base.conf" \
		TOOLS_DIR="$work/tools.d" PATH="$stub:$PATH" "$SRC/sandbox.sh" --stdio --new true 2>&1)
	status=$?
	set -e
	printf '%s\n' "$out" >"$work/out"
	grants="$(cat "$work"/run/agent-sandbox/* 2>/dev/null || true)"
}

expect() { # <label> <want: yes|no> <mount spec>
	local want=$2 got=no
	grep -Fxq -- "$3" "$work/args" 2>/dev/null && got=yes
	if [ "$got" = "$want" ] && [ "$status" -eq 0 ]; then
		printf '  ok    %s\n' "$1"
	else
		printf '  FAIL  %s: wanted %s, got %s (status %s)\n' "$1" "$want" "$got" "$status" >&2
		sed 's/^/        /' "$work/out" >&2
		failed=1
	fi
}

expect_says() { # <label> <substring>
	if grep -Fq -- "$2" "$work/out"; then
		printf '  ok    %s\n' "$1"
	else
		printf '  FAIL  %s: no %s in the output\n' "$1" "$2" >&2
		sed 's/^/        /' "$work/out" >&2
		failed=1
	fi
}

expect_stopped() { # <label> <substring>
	if [ "$status" -ne 0 ] && grep -Fq -- "$2" "$work/out"; then
		printf '  ok    %s\n' "$1"
	else
		printf '  FAIL  %s: status %s without %s\n' "$1" "$status" "$2" >&2
		sed 's/^/        /' "$work/out" >&2
		failed=1
	fi
}

printf '  a tool the catalogue holds but the manifest does not name\n'
run 'TOOLS=""'
expect "the skill stays out" no "$farm/skills/linear:/home/node/.agents/skills/linear:ro"
expect "the credential stays out" no "$home/.agent-secrets/linear-app.env:/home/node/.agent-secrets/linear-app.env:ro"
expect "its egress is not granted" no "api.linear.app:443"

printf '  the tool named\n'
run 'TOOLS="linear"'
expect "the skill mounts at its resolved path" yes "$farm/skills/linear:/home/node/.agents/skills/linear:ro"
expect "the credential mounts read-only" yes "$home/.agent-secrets/linear-app.env:/home/node/.agent-secrets/linear-app.env:ro"
expect "the CLI mounts read-only" yes "$farm/skills/linear/scripts/linear-api.sh:/usr/local/bin/linear-api.sh:ro"
if grep -Fxq "api.linear.app:443" <<<"$grants"; then
	printf '  ok    the egress reaches the grant file the firewall reads\n'
else
	printf '  FAIL  the egress did not reach the grant file: %s\n' "${grants:-<empty>}" >&2
	failed=1
fi

printf '  a second tool, as files only\n'
mkdir -p "$farm/second"
printf 'second\n' >"$farm/second/SKILL.md"
tool second \
	"OPT_IN=true" \
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=/home/node/.agents/skills/second" \
	"HOSTS=api.example.test:443"
run 'TOOLS="second"'
expect "a tool the script has never heard of mounts its skill" yes "$farm/second:/home/node/.agents/skills/second:ro"
expect "and the first tool is not carried along" no "$farm/skills/linear:/home/node/.agents/skills/linear:ro"

printf '  a tool that says it is not opt-in\n'
tool always \
	"OPT_IN=false" \
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=/home/node/.agents/skills/always"
run 'TOOLS=""'
expect "arrives without being named" yes "$farm/second:/home/node/.agents/skills/always:ro"

printf '  refusals\n'
run 'TOOLS="nope"'
expect_stopped "a name the catalogue does not hold stops the run" "unknown tool 'nope'"
expect_says "and it lists what the catalogue has" "linear"

run 'TOOLS="../escape"'
expect_stopped "a name that is a path stops the run" "a tool name takes lowercase letters"

mkdir -p "$work/tools.d/dircred"
only dircred \
	"OPT_IN=true" \
	"CRED_HOST=$home/.agent-secrets" \
	"CRED_CONTAINER=/home/node/.agent-secrets"
run 'TOOLS="dircred"'
expect_stopped "a credential that is a directory stops the run" "the credential is not a regular file"

only halfpair \
	"OPT_IN=true" \
	"CLI_HOST=$farm/skills/linear/scripts/linear-api.sh"
run 'TOOLS="halfpair"'
expect_stopped "a host path without a destination stops the run" "needs both a host path and a destination"

only badhost \
	"OPT_IN=true" \
	"HOSTS=api.linear.app"
run 'TOOLS="badhost"'
expect_stopped "an egress entry without a port stops the run" "is not a <host>:<port> egress grant"

only badkey \
	"OPT_IN=true" \
	"SKILLHOST=$farm/second"
run 'TOOLS="badkey"'
expect_stopped "an unknown key stops the run" "unknown key 'SKILLHOST'"

only nooptin \
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=/home/node/.agents/skills/nooptin"
run 'TOOLS="nooptin"'
expect_stopped "a missing OPT_IN stops the run" "OPT_IN must be true or false"

[[ $failed == 0 ]] && echo "sandbox-tools: ok"
exit $failed
