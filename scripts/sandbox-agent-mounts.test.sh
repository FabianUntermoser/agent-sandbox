#!/usr/bin/env bash

# USAGE: cases for the mount an agent-directory symlink gets, run by make check
#
# No container is started: docker is stubbed and records the arguments of the run, so a case
# asserts the -v pairs the script would hand docker. The home is a throwaway tree and the checkout
# it points at lives outside it, which is the shape the host has.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0

work="$(mktemp -d)"
stub="$(mktemp -d)"
trap 'rm -rf "$work" "$stub"' EXIT

home="$work/home"
farm="$work/farm"
mkdir -p "$home/.pi/agent/skills" "$farm/pi/agent/skills/first" "$farm/pi/agent/extensions" "$home/notes"

# the checkout the links point at: the two files pi cannot start without, a skills directory
# that only the link names, and a package file no link reaches
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

cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
[ "\$1" = run ] || exit 0
printf '%s\n' "\$@" >>"$work/args"
exit 0
EOF
chmod +x "$stub/docker"

printf 'dir   ~/.pi\n' >"$work/base.conf"
printf 'AGENTS="pi"\n' >"$work/.sandbox.conf"

rm -f "$work/args"
(cd "$work" && HOME="$home" BASE_CONF="$work/base.conf" PATH="$stub:$PATH" \
	"$SRC/sandbox.sh" --stdio --new true) >"$work/out" 2>&1 || true

expect() {
	local want=$1 got=$2 label=$3
	if [[ $got == "$want" ]]; then
		printf '  ok    %s\n' "$label"
	else
		printf '  FAIL  %s: wanted %s, got %s\n' "$label" "$want" "$got" >&2
		sed 's/^/        /' "$work/out" >&2
		failed=1
	fi
}

mount() { grep -Fxq -- "$1" "$work/args" 2>/dev/null && echo yes || echo no; }

grep -q . "$work/args" || { printf '  FAIL  the run never reached docker\n' >&2; exit 1; }

expect yes "$(mount "$farm/pi/agent/models.json:/home/node/.pi/agent/models.json")" \
	'a linked file arrives at the guest path the link occupies'
expect yes "$(mount "$farm/pi/agent/auth.json:/home/node/.pi/agent/auth.json")" \
	'and so does the second one'
expect yes "$(mount "$farm/pi/agent/skills/first:/home/node/.pi/agent/skills/first")" \
	'a linked directory does too'
expect yes "$(mount "$home/.pi:/home/node/.pi")" \
	'the directory itself is still mounted, so its own files arrive'

expect no "$(mount "$farm/pi/agent/models.json:$farm/pi/agent/models.json")" \
	'the checkout is not mounted at its own path'
expect no "$(mount "$farm/pi/agent/extensions/whole-package.json:/home/node/.pi/agent/extensions/whole-package.json")" \
	'a package file no link reaches stays out of the container'
expect no "$(mount "$home/notes:/home/node/.pi/agent/notes")" \
	'a link into the vault is refused'
expect no "$(mount "$farm/pi/agent/models.json:/home/node/.pi/agent/deep/one/two/models.json")" \
	'a link past the followed depth is not mounted'

exit "$failed"
