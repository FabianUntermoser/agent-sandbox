#!/usr/bin/env bash

# USAGE: cases for the manifest a run names, run by make check
#
# No container is started: docker is stubbed, so a case that reaches the stub got past the manifest,
# and a case that stops before it was stopped by the manifest. A manifest is bash that the script
# sources, so a manifest that writes a file proves it was read.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0

work="$(mktemp -d)"
stub="$(mktemp -d)"
external="$(mktemp)"
marker="$work/sourced"
reached="$work/reached"

trap 'rm -rf "$work" "$stub" "$external"' EXIT

cat >"$external" <<EOF
: >"$marker"
MOUNTS=()
EOF

# docker answers everything the script asks before the run, and records that the run was reached.
cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
run) echo "docker-run" >>"$reached" ;;
esac
exit 0
EOF
chmod +x "$stub/docker"

run() {
	rm -f "$reached" "$marker"
	(cd "$work" && PATH="$stub:$PATH" "$SRC/sandbox.sh" --stdio --new "$@" true) >"$work/out" 2>&1
}

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

flag() { [[ -f "$1" ]] && echo yes || echo no; }

printf '  project without a manifest\n'
rm -f "$work/.sandbox.conf"
run || true
expect yes "$(flag "$reached")" "the default manifest may be absent"

printf '  manifest named but not there\n'
if run --manifest "$work/missing.conf"; then
	expect stopped ran "a named manifest that is missing stops the run"
else
	expect yes "$(grep -q 'manifest not found or unreadable' "$work/out" && echo yes || echo no)" "it stopped with the manifest message"
	expect no "$(flag "$reached")" "and before docker"
fi

printf '  manifest outside the project\n'
run --manifest "$external" || true
sourced="$(flag "$marker")"
expect yes "$(flag "$reached")" "a named manifest outside the project is used"
expect yes "$sourced" "and it was sourced"

printf '  manifest inside the project\n'
printf ': >%s\nMOUNTS=()\n' "$marker" >"$work/.sandbox.conf"
run || true
sourced="$(flag "$marker")"
expect yes "$(flag "$reached")" "the project's own manifest is used"
expect yes "$sourced" "and it was sourced"
rm -f "$work/.sandbox.conf"

[[ $failed == 0 ]] && echo "sandbox-manifest: ok"
exit $failed
