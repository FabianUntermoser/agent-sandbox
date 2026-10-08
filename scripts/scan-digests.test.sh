#!/usr/bin/env bash

# USAGE: cases for the FROM parse in security/scan-digests.sh, run by make check
#
# Nothing is pulled: docker is stubbed and records the references the run asked it for, so a case
# asserts what the parse decided. The rule every case serves: a valid Dockerfile is either scanned
# with every base stage, or the run fails. It never passes with a stage left unread.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0

work="$(mktemp -d)"
stub="$(mktemp -d)"
hex=$(printf 'a%.0s' {1..64})
zhex=$(printf 'z%.0s' {1..64})
trap 'rm -rf "$work" "$stub"' EXIT

cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
pull) shift; [ "\${1:-}" = -q ] && shift; printf '%s\n' "\$*" >>"$work/pulled" ;;
esac
exit 0
EOF
chmod +x "$stub/docker"

# run <line>...: writes those lines as the Dockerfile and runs the parse over it
run() {
	printf '%s\n' "$@" >"$work/Dockerfile"
	rm -f "$work/pulled"
	set +e
	out=$(cd "$work" && PATH="$stub:$PATH" "$SRC/../security/scan-digests.sh" "$work/out" "$work/Dockerfile" 2>&1)
	status=$?
	set -e
	# no pull at all is the expected shape of a failed run, so the file may not exist
	pulled=""
	if [ -f "$work/pulled" ]; then
		pulled=$(sort -u "$work/pulled" | tr '\n' ' ')
		pulled=${pulled% }
	fi
}

expect() { # <label> <want-pulled> <want-status: ok|fail>
	local label=$1 want=$2 want_status=$3 got_status=ok
	[ "$status" -eq 0 ] || got_status=fail
	if [ "$pulled" = "$want" ] && [ "$got_status" = "$want_status" ]; then
		printf '  ok    %s\n' "$label"
	else
		printf '  FAIL  %s: wanted %s/%s, got %s/%s\n' "$label" "$want" "$want_status" "$pulled" "$got_status" >&2
		printf '        status %s, last lines:\n' "$status" >&2
		tail -4 <<<"$out" | sed 's/^/        /' >&2
		failed=1
	fi
}

printf '  shapes Docker accepts\n'
run "FROM node:22@sha256:$hex AS build" "FROM node:22-bookworm@sha256:$hex"
expect 'two stages are two references' "node:22-bookworm@sha256:$hex node:22@sha256:$hex" ok

run "FROM node:22@sha256:$hex" "from alpine@sha256:$hex"
expect 'a lower case instruction is read' "alpine@sha256:$hex node:22@sha256:$hex" ok

run "FROM node:22@sha256:$hex" "   FROM alpine@sha256:$hex"
expect 'an indented instruction is read' "alpine@sha256:$hex node:22@sha256:$hex" ok

run "FROM node:22@sha256:$hex" "$(printf 'FROM\talpine@sha256:%s' "$hex")"
expect 'a tab after the instruction is read' "alpine@sha256:$hex node:22@sha256:$hex" ok

run "FROM node:22@sha256:$hex As build" "FROM build"
expect 'a mixed case alias is read, and its stage reused' "node:22@sha256:$hex" ok

run "FROM node:22@sha256:$hex  AS  build"
expect 'white space around AS does not reach the reference' "node:22@sha256:$hex" ok

run "FROM --platform=\$BUILDPLATFORM node:22@sha256:$hex AS build"
expect 'the platform flag is not the reference' "node:22@sha256:$hex" ok

run "ARG NODE=22" "ARG DIGEST=sha256:$hex" 'FROM node:${NODE}@${DIGEST}'
expect 'build arg defaults resolve' "node:22@sha256:$hex" ok

run "# FROM node:22@sha256:$hex" "FROM alpine@sha256:$hex"
expect 'a commented instruction is not one' "alpine@sha256:$hex" ok

run "FROM scratch" "FROM alpine@sha256:$hex"
expect 'a scratch stage carries no base image' "alpine@sha256:$hex" ok

printf '  shapes that must fail the run\n'
run "FROM node:22@\${DIGEST}"
expect 'an arg with no default stops the run' '' fail

run "FROM node:22@sha256:abc123"
expect 'a short digest stops the run' '' fail

run "FROM node:22@sha256:$zhex"
expect 'a digest that is not hex stops the run' '' fail

run "FROM node:22"
expect 'a tag with no digest stops the run' '' fail

run "FROM"
expect 'an instruction with no image stops the run' '' fail

run "FROM node:22@sha256:$hex AS build extra"
expect 'an unreadable tail stops the run' '' fail

if [ "$failed" -eq 0 ]; then
	printf 'scan-digests: ok\n'
else
	exit 1
fi
