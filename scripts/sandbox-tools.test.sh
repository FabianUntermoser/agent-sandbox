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
# a key and the vault: the two trees a grant may never reach
mkdir -p "$home/.ssh" "$home/notes/2AREAS"
: >"$home/.ssh/id_ed25519"
: >"$home/notes/2AREAS/private.md"

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

# One refusal must not shadow the next: the catalogue is read by name, but a broken file left in it
# would still be read by the case that names it.
only() { # <name> <key=value...>
	local name=$1
	rm -f "$work"/tools.d/*.conf
	tool "$@"
}

tool linear \
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

printf '  a broken catalogue entry nobody names\n'
printf 'SKILLHOST=typo\n' >"$work/tools.d/unused-broken.conf"
run 'TOOLS="linear"'
expect "does not stop the run" yes "$farm/skills/linear:/home/node/.agents/skills/linear:ro"
rm -f "$work/tools.d/unused-broken.conf"

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
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=/home/node/.agents/skills/second" \
	"HOSTS=api.example.test:443"
run 'TOOLS="second"'
expect "a tool the script has never heard of mounts its skill" yes "$farm/second:/home/node/.agents/skills/second:ro"
expect "and the first tool is not carried along" no "$farm/skills/linear:/home/node/.agents/skills/linear:ro"

printf '  refusals\n'
run 'TOOLS="nope"'
expect_stopped "a name the catalogue does not hold stops the run" "unknown tool 'nope'"
expect_says "and it lists what the catalogue has" "linear"

run 'TOOLS="../escape"'
expect_stopped "a name that is a path stops the run" "a tool name takes lowercase letters"

only dircred \
	"CRED_HOST=$home/.agent-secrets" \
	"CRED_CONTAINER=/home/node/.agent-secrets"
run 'TOOLS="dircred"'
expect_stopped "a credential that is a directory stops the run" "the credential is not a regular file"

only halfpair \
	"CLI_HOST=$farm/skills/linear/scripts/linear-api.sh"
run 'TOOLS="halfpair"'
expect_stopped "a host path without a destination stops the run" "needs both a host path and a destination"

only badhost \
	"HOSTS=api.linear.app"
run 'TOOLS="badhost"'
expect_stopped "an egress entry without a port stops the run" "is not a <host>:<port> egress grant"

only zeroport \
	"HOSTS=api.linear.app:0"
run 'TOOLS="zeroport"'
expect_stopped "a port the firewall would refuse stops the run here" "needs a TCP port from 1 to 65535"

only bigport \
	"HOSTS=api.linear.app:65536"
run 'TOOLS="bigport"'
expect_stopped "a port above 65535 stops the run" "needs a TCP port from 1 to 65535"

only dashedhost \
	"HOSTS=-api.linear.app:443"
run 'TOOLS="dashedhost"'
expect_stopped "a host the firewall cannot resolve stops the run" "does not name a host the firewall can resolve"

only badkey \
	"SKILLHOST=$farm/second"
run 'TOOLS="badkey"'
expect_stopped "an unknown key stops the run" "unknown key 'SKILLHOST'"

only relative \
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=skills/second"
run 'TOOLS="relative"'
expect_stopped "a destination that is not absolute stops the run" "is not an absolute path"

only colon \
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=/home/node/skills:second"
run 'TOOLS="colon"'
expect_stopped "a destination carrying a colon stops the run" "carries a colon"

only parent \
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=/home/node/.agents/../secrets"
run 'TOOLS="parent"'
expect_stopped "a destination carrying a parent segment stops the run" "carries a parent segment"

only emptyvalue \
	"SKILL_HOST="
run 'TOOLS="emptyvalue"'
expect_stopped "a key present with no value stops the run" "SKILL_HOST has no value"

only key \
	"CRED_HOST=$home/.ssh/id_ed25519" \
	"CRED_CONTAINER=/home/node/.ssh/id_ed25519"
run 'TOOLS="key"'
expect_stopped "a key as a credential stops the run" "one the sandbox may not see"

only vault \
	"SKILL_HOST=$home/notes/2AREAS" \
	"SKILL_CONTAINER=/home/node/.agents/skills/vault"
run 'TOOLS="vault"'
expect_stopped "a vault layer as a skill stops the run" "one the sandbox may not see"

# An agent directory granted by AGENTS puts a link target at its own guest path, writable as a
# directory, and a tool naming that same file is the grant already in place. The tool's request is
# read-only, so the mount that survives is the read-only one: the writable view is what a sandbox
# could edit the dots checkout through.
printf 'follow %s  grant=AGENTS\ndir   %s\n' "$farm" "$home/.agents" >"$work/base.conf"
tool sameplace \
	"SKILL_HOST=$home/.agents/skills/linear" \
	"SKILL_CONTAINER=/home/node/.agents/skills/linear"
printf 'AGENTS="pi"\nTOOLS="sameplace"\n' >"$work/.sandbox.conf"
rm -f "$work/args" "$work/run"/agent-sandbox/* 2>/dev/null || true
set +e
out=$(cd "$work" && HOME="$home" XDG_RUNTIME_DIR="$work/run" BASE_CONF="$work/base.conf" \
	TOOLS_DIR="$work/tools.d" PATH="$stub:$PATH" "$SRC/sandbox.sh" --stdio --new true 2>&1)
status=$?
set -e
printf '%s\n' "$out" >"$work/out"
if [ "$status" -ne 0 ]; then
	printf '  FAIL  the same grant counted as a collision (status %s)\n' "$status" >&2
	sed 's/^/        /' "$work/out" >&2
	failed=1
elif grep -Fxq "$farm/skills/linear:/home/node/.agents/skills/linear:ro" "$work/args" \
	&& ! grep -Fxq "$farm/skills/linear:/home/node/.agents/skills/linear" "$work/args"; then
	printf '  ok    a grant an agent directory already holds arrives read-only, not writable\n'
else
	printf '  FAIL  the tool grant did not narrow the writable agent mount\n' >&2
	grep -F "$farm/skills/linear:" "$work/args" | sed 's/^/        /' >&2
	failed=1
fi
rm -f "$work/tools.d/sameplace.conf"

# base.conf already holds the tree the tool wants, which is the shape a collision takes
printf 'dir   %s/skills  ro\n' "$home/.agents" >"$work/base.conf"
only collision \
	"SKILL_HOST=$farm/second" \
	"SKILL_CONTAINER=/home/node/.agents/skills"
run 'TOOLS="collision"'
expect_stopped "a destination another grant already holds stops the run" "that destination already holds"
printf '# nothing inherited from the host in these cases\n' >"$work/base.conf"

[[ $failed == 0 ]] && echo "sandbox-tools: ok"
exit $failed
