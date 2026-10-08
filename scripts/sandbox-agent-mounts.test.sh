#!/usr/bin/env bash

# USAGE: cases for the mounts an agent-directory symlink earns, run by make check
#
# No container is started: docker is stubbed and records the arguments of the run, so a case asserts
# the -v pairs the script would hand docker. The home is a throwaway tree and the checkout it points
# at lives outside it, which is the shape the host has.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0

work="$(mktemp -d)"
stub="$(mktemp -d)"
trap 'rm -rf "$work" "$stub"' EXIT

home="$work/home"
farm="$work/farm"
mkdir -p "$home/.pi/agent/skills" "$farm/pi/agent/skills/first" "$farm/pi/agent/extensions" "$home/notes" "$home/.config/gh"

# the checkout the links point at: the two files pi cannot start without, a skills directory that
# only the link names, and a package file no link reaches
: >"$farm/pi/agent/models.json"
: >"$farm/pi/agent/auth.json"
: >"$farm/pi/agent/extensions/whole-package.json"

ln -s "$farm/pi/agent/models.json" "$home/.pi/agent/models.json"
ln -s "$farm/pi/agent/auth.json" "$home/.pi/agent/auth.json"
ln -s "$farm/pi/agent/skills/first" "$home/.pi/agent/skills/first"
# one level past the depth a run follows, so it must not arrive
mkdir -p "$home/.pi/agent/deep/one/two"
ln -s "$farm/pi/agent/models.json" "$home/.pi/agent/deep/one/two/models.json"
# the vault, which no grant hands over
ln -s "$home/notes" "$home/.pi/agent/notes"
# a forge token, which a grant for pi's config directory does not name. The sandbox writes this
# directory, so a link planted here would otherwise carry the token into the next run.
: >"$home/.config/gh/hosts.yml"
ln -s "$home/.config/gh/hosts.yml" "$home/.pi/agent/forge"

cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
[ "\$1" = run ] || exit 0
printf '%s\n' "\$@" >>"$work/args"
exit 0
EOF
chmod +x "$stub/docker"

baseconf() { printf '%s\n' "$@" >"$work/base.conf"; }

# run: writes the project manifest, then runs the base loop over it
run() {
	printf 'AGENTS="pi"\n' >"$work/.sandbox.conf"
	rm -f "$work/args"
	set +e
	out=$(cd "$work" && HOME="$home" BASE_CONF="$work/base.conf" PATH="$stub:$PATH" \
		"$SRC/sandbox.sh" --stdio --new true 2>&1)
	status=$?
	set -e
	printf '%s\n' "$out" >"$work/out"
}

expect() { # <label> <want: yes|no> <mount> <want-status: ok|fail>
	local label=$1 want=$2 spec=$3 want_status=$4 got=no got_status=ok
	grep -Fxq -- "$spec" "$work/args" 2>/dev/null && got=yes
	[ "$status" -eq 0 ] || got_status=fail
	if [ "$got" = "$want" ] && [ "$got_status" = "$want_status" ]; then
		printf '  ok    %s\n' "$label"
	else
		printf '  FAIL  %s: wanted %s/%s, got %s/%s\n' "$label" "$want" "$want_status" "$got" "$got_status" >&2
		tail -3 <<<"$out" | sed 's/^/        /' >&2
		failed=1
	fi
}

expect_says() { # <label> <substring>
	if grep -Fq -- "$2" "$work/out"; then
		printf '  ok    %s\n' "$1"
	else
		printf '  FAIL  %s: no line matching %s\n' "$1" "$2" >&2
		tail -3 <<<"$out" | sed 's/^/        /' >&2
		failed=1
	fi
}

baseconf "follow $farm    grant=AGENTS" 'dir   ~/.pi'
run

expect 'a linked file arrives at the guest path the link occupies' yes \
	"$farm/pi/agent/models.json:/home/node/.pi/agent/models.json" ok
expect 'and so does the second one' yes \
	"$farm/pi/agent/auth.json:/home/node/.pi/agent/auth.json" ok
expect 'a linked directory does too' yes \
	"$farm/pi/agent/skills/first:/home/node/.pi/agent/skills/first" ok
expect 'the directory itself is still mounted, so its own files arrive' yes \
	"$home/.pi:/home/node/.pi" ok

expect 'the checkout is not mounted at its own path' no \
	"$farm/pi/agent/models.json:$farm/pi/agent/models.json" ok
expect 'a package file no link reaches stays out of the container' no \
	"$farm/pi/agent/extensions/whole-package.json:/home/node/.pi/agent/extensions/whole-package.json" ok
expect 'a link into the vault is refused' no \
	"$home/notes:/home/node/.pi/agent/notes" ok
expect 'a link past the followed depth is not mounted' no \
	"$farm/pi/agent/models.json:/home/node/.pi/agent/deep/one/two/models.json" ok
expect 'a link outside every follow root is not mounted' no \
	"$home/.config/gh/hosts.yml:/home/node/.pi/agent/forge" ok
expect_says 'and the run says why it was left out' 'link not followed (outside every follow root): agent/forge'

baseconf 'dir   ~/.pi'
run
expect 'with no follow root declared, no link under the directory is followed' no \
	"$farm/pi/agent/models.json:/home/node/.pi/agent/models.json" ok
expect_says 'and the run says the catalogue declares none' 'declares no follow root'

baseconf "follow $farm    grant=LOCAL_BIN" 'dir   ~/.pi'
run
expect 'a follow root whose grant is off is not in force' no \
	"$farm/pi/agent/models.json:/home/node/.pi/agent/models.json" ok
expect_says 'and the run says the grant is off' 'grant off (LOCAL_BIN)'

if [ "$failed" -eq 0 ]; then
	printf 'sandbox-agent-mounts: ok\n'
else
	exit 1
fi
