#!/usr/bin/env bash

# USAGE: scan-digests.sh <outdir> [Dockerfile]

# The images this repository pulls instead of building: every base image its Dockerfile pins by
# digest. The build pulls the same reference, so the scan usually reads an image the daemon
# already holds. A FROM line without a digest is a floating reference and is never scanned, it
# fails the run instead: a report about whatever the tag pointed at that morning names nothing.

set -euo pipefail

out=${1:?usage: scan-digests.sh <outdir> [Dockerfile]}
dockerfile=${2:-}

here=$(cd "$(dirname "$0")" && pwd)
[ -n "$dockerfile" ] || dockerfile=$here/../Dockerfile
[ -f "$dockerfile" ] || {
	printf 'scan-digests: %s not found\n' "$dockerfile" >&2
	exit 1
}

command -v docker >/dev/null || {
	printf 'scan-digests: docker is required\n' >&2
	exit 1
}

mkdir -p "$out"
out=$(cd "$out" && pwd)

## RESOLVE

# The build arg defaults, then the FROM line that reads them. The pinned reference is the FROM
# line itself, so nothing has to be kept in step by hand.
declare -A args=()
while IFS= read -r line; do
	args[${line%%=*}]=${line#*=}
done < <(sed -n 's/^ARG \([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)$/\1=\2/p' "$dockerfile")

from=$(awk '/^FROM /{ sub(/^FROM /, ""); print; exit }' "$dockerfile")
[ -n "$from" ] || {
	printf 'scan-digests: no FROM line in %s\n' "$dockerfile" >&2
	exit 1
}

ref=$from
while [[ $ref =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
	name=${BASH_REMATCH[1]}
	ref=${ref//\$\{$name\}/${args[$name]:-}}
done

case "$ref" in
*@sha256:*) ;;
*)
	printf 'scan-digests: %s has no digest on its FROM line (%s), refusing to scan a tag\n' \
		"$dockerfile" "$from" >&2
	exit 1
	;;
esac

# node:22-bookworm@sha256:... reads as node-base in the artifact tree, named for the image rather
# than for the variable that holds it.
slug=${ref%%@*}
slug=${slug%%:*}
slug=${slug##*/}-base

## SCAN

printf 'scan-digests: %s -> %s\n' "$slug" "$ref"
docker pull -q "$ref" >/dev/null
"$here/scan.sh" "$ref" "$out/$slug"
# the daemon only held a pulled reference to be scanned
docker image rm "$ref" >/dev/null 2>&1 || true
