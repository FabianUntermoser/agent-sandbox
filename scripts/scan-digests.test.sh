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
mkdir -p "$stub/security"
cp "$SRC/../security/scan-digests.sh" "$stub/security/scan-digests.sh"
cat >"$stub/security/scan.sh" <<EOF
printf '%s\n' "\$1" >>"$work/scanned"
mkdir -p "\$2"
printf '{"SchemaVersion":2,"Results":[]}\n' >"\$2/trivy.json"
printf '%s commit build\n' "\$1" >"\$2/scan-target.txt"
printf 'Trivy test\nSyft test\n' >"\$2/scanner-versions.txt"
printf '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"components":[]}\n' >"\$2/syft.cdx.json"
EOF
chmod +x "$stub/security/scan.sh"

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
	rm -rf "$work/out"
	rm -f "$work/pulled" "$work/scanned"
	set +e
	out=$(cd "$work" && PATH="$stub:$PATH" "$stub/security/scan-digests.sh" "$work/out" "$work/Dockerfile" 2>&1)
	status=$?
	set -e
	# no pull at all is the expected shape of a failed run, so the file may not exist
	pulled=""
	if [ -f "$work/pulled" ]; then
		pulled=$(sort -u "$work/pulled" | tr '\n' ' ')
		pulled=${pulled% }
	fi
	scanned=""
	if [ -f "$work/scanned" ]; then
		scanned=$(sort -u "$work/scanned" | tr '\n' ' ')
		scanned=${scanned% }
	fi
}

expect() { # <label> <want-pulled> <want-status: ok|fail>
	local label=$1 want=$2 want_status=$3 got_status=ok manifest_count=0 want_count=0
	[ "$status" -eq 0 ] || got_status=fail
	if [ -f "$work/out/scan-manifest.txt" ]; then
		manifest_count=$(grep -c . "$work/out/scan-manifest.txt")
	fi
	if [ "$want_status" = ok ]; then
		want_count=$(wc -w <<<"$want")
	fi
	if [ "$pulled" = "$want" ] && [ "$scanned" = "$want" ] && [ "$got_status" = "$want_status" ] && [ "$manifest_count" -eq "$want_count" ]; then
		printf '  ok    %s\n' "$label"
	else
		printf '  FAIL  %s: wanted pull/scan %s/%s, got %s/%s (%s)\n' "$label" "$want" "$want" "$pulled" "$scanned" "$got_status" >&2
		printf '        status %s, manifest lines %s/%s, last lines:\n' "$status" "$manifest_count" "$want_count" >&2
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

run "FROM alpine AS alpine"
expect 'a self-named unpinned external image cannot masquerade as an earlier stage' '' fail

run "FROM alpine@sha256:$hex AS alpine" "FROM alpine"
expect 'a pinned external base is scanned before its same-named stage alias is reused' "alpine@sha256:$hex" ok

run "FROM node:22@sha256:$hex  AS  build"
expect 'white space around AS does not reach the reference' "node:22@sha256:$hex" ok

run "FROM --platform=\$BUILDPLATFORM node:22@sha256:$hex AS build"
expect 'the platform flag is not the reference' "node:22@sha256:$hex" ok

run "ARG NODE=22" "ARG DIGEST=sha256:$hex" 'FROM node:${NODE}@${DIGEST}'
expect 'build arg defaults resolve' "node:22@sha256:$hex" ok

# Reusing an output directory must not retain a prior base image or its manifest entry.
run "FROM alpine@sha256:$hex"
expect 'initial base scan creates its manifest' "alpine@sha256:$hex" ok
printf 'stale-base\n' >>"$work/out/scan-manifest.txt"
mkdir -p "$work/out/stale-base"
printf 'stale report\n' >"$work/out/stale-base/trivy.json"
printf 'FROM busybox@sha256:%s\n' "$hex" >"$work/Dockerfile"
rm -f "$work/pulled" "$work/scanned"
set +e
out=$(cd "$work" && PATH="$stub:$PATH" "$stub/security/scan-digests.sh" "$work/out" "$work/Dockerfile" 2>&1)
status=$?
set -e
pulled=""
scanned=""
[ ! -f "$work/pulled" ] || pulled=$(sort -u "$work/pulled" | tr '\n' ' ')
[ ! -f "$work/scanned" ] || scanned=$(sort -u "$work/scanned" | tr '\n' ' ')
manifest=$(cat "$work/out/scan-manifest.txt")
if [ "$status" -eq 0 ] && [ "$pulled" = "busybox@sha256:$hex " ] && [ "$scanned" = "busybox@sha256:$hex " ] && [ "$manifest" = "busybox-base" ] && [ ! -e "$work/out/stale-base" ] && [ ! -e "$work/out/alpine-base" ]; then
	printf '  ok    a rerun replaces the expected-image manifest and clears stale base artifacts\n'
else
	printf '  FAIL  a rerun left stale manifest/artifacts (manifest=%s, status=%s)\n' "$manifest" "$status" >&2
	tail -4 <<<"$out" | sed 's/^/        /' >&2
	failed=1
fi

printf '  shapes the workflow combines\n'
# The workflow scans the built image itself and writes its line into the same manifest before the
# base scan runs. A rewrite that drops that line leaves an image the run did scan unlisted, and the
# gate then refuses a run whose reports are complete.
run "FROM alpine@sha256:$hex"
printf 'agent-sandbox\n' >>"$work/out/scan-manifest.txt"
mkdir -p "$work/out/agent-sandbox"
printf 'agent report\n' >"$work/out/agent-sandbox/trivy.json"
printf 'FROM busybox@sha256:%s\n' "$hex" >"$work/Dockerfile"
rm -f "$work/pulled" "$work/scanned"
set +e
out=$(cd "$work" && PATH="$stub:$PATH" "$stub/security/scan-digests.sh" "$work/out" "$work/Dockerfile" 2>&1)
status=$?
set -e
manifest=''
[ ! -f "$work/out/scan-manifest.txt" ] || manifest=$(tr '\n' ' ' <"$work/out/scan-manifest.txt")
if [ "$status" -eq 0 ] && [ "$manifest" = 'agent-sandbox busybox-base ' ] && [ -f "$work/out/agent-sandbox/trivy.json" ] && [ ! -e "$work/out/alpine-base" ]; then
	printf '  ok    the built image keeps its manifest line and artifacts while bases are replaced\n'
else
	printf '  FAIL  the built image entry did not survive the base scan (manifest=%s, status=%s)\n' "$manifest" "$status" >&2
	tail -4 <<<"$out" | sed 's/^/        /' >&2
	failed=1
fi

# The gate reads a directory absent from the manifest as unlisted, so this is the whole pipeline:
# a built image, a base scan over the same directory, and a policy that sees both.
run "FROM alpine@sha256:$hex"
rm -rf "$work/out"
mkdir -p "$work/out/agent-sandbox"
printf 'agent-sandbox\n' >"$work/out/scan-manifest.txt"
printf '{"SchemaVersion":2,"Results":[]}\n' >"$work/out/agent-sandbox/trivy.json"
printf 'sha256:%s commit build\n' "$hex" >"$work/out/agent-sandbox/scan-target.txt"
printf 'Trivy test\nSyft test\n' >"$work/out/agent-sandbox/scanner-versions.txt"
printf '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"components":[]}\n' >"$work/out/agent-sandbox/syft.cdx.json"
rm -f "$work/pulled" "$work/scanned"
set +e
out=$(cd "$work" && PATH="$stub:$PATH" "$stub/security/scan-digests.sh" "$work/out" "$work/Dockerfile" 2>&1)
status=$?
if [ "$status" -eq 0 ]; then
	gate_out=$("$SRC/../security/gate.sh" "$work/out" 2>&1)
	status=$?
else
	gate_out=$out
fi
set -e
manifest=''
[ ! -f "$work/out/scan-manifest.txt" ] || manifest=$(tr '\n' ' ' <"$work/out/scan-manifest.txt")
if [ "$status" -eq 0 ] \
	&& [ "$manifest" = 'agent-sandbox alpine-base ' ] \
	&& grep -q '^agent-sandbox  target=' <<<"$gate_out" \
	&& grep -q '^alpine-base  target=' <<<"$gate_out"; then
	printf '  ok    the gate evaluates the built image and every base in one run\n'
else
	printf '  FAIL  the gate did not evaluate both images (manifest=%s, status=%s)\n' "$manifest" "$status" >&2
	tail -6 <<<"$gate_out" | sed 's/^/        /' >&2
	failed=1
fi

run "arg NODE=22" "arg DIGEST=sha256:$hex" 'from node:${NODE}@${DIGEST} as first' "ARG NODE=20" 'FROM alpine:${NODE}@${DIGEST}'
expect 'stage-scoped ARG cannot override the global FROM default' "alpine:22@sha256:$hex node:22@sha256:$hex" ok

run 'ARG NODE' "ARG DIGEST=sha256:$hex" 'FROM node:${NODE}@${DIGEST}'
expect 'a FROM variable without a global default fails closed' '' fail

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
