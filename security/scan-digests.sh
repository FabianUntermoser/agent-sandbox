#!/usr/bin/env bash

# USAGE: scan-digests.sh <outdir> [Dockerfile]

# The images this repository pulls instead of building: every base image the Dockerfile pins by
# digest, one per build stage. The build pulls the same references, so a scan usually reads an
# image the daemon already holds. A FROM line without a digest is a floating reference and is
# never scanned, it fails the run instead: a report about whatever the tag pointed at that morning
# names nothing.

set -euo pipefail

out=${1:?usage: scan-digests.sh <outdir> [Dockerfile]}
dockerfile=${2:-}

here=$(cd "$(dirname "$0")" && pwd)
[ -n "$dockerfile" ] || dockerfile=$here/../Dockerfile

die() {
	printf 'scan-digests: %s\n' "$*" >&2
	exit 1
}

[ -f "$dockerfile" ] || die "$dockerfile not found"
command -v docker >/dev/null || die "docker is required"

mkdir -p "$out"
out=$(cd "$out" && pwd)

## RESOLVE

# The build arg defaults, then every FROM line that reads them, in file order. Each stage pins its
# own base, and each one is scanned.
declare -A args=()
while IFS= read -r line; do
	args[${line%%=*}]=${line#*=}
done < <(sed -n 's/^ARG \([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)$/\1=\2/p' "$dockerfile")

declare -A stages=()  # aliases named by `AS <name>`, matched case-insensitively as Docker does
declare -A seen=()    # one scan per distinct reference
declare -A taken=()   # one artifact directory per slug
refs=()
slugs=()

while IFS= read -r raw; do
	from=${raw#FROM }
	stage=""
	case $from in
	*' AS '* | *' as '*)
		stage=${from##*[Aa][Ss] }
		from=${from% [Aa][Ss] *}
		;;
	esac
	# a later FROM reads the stage a name was given to, which its own FROM already pinned
	[ -z "$stage" ] || stages[${stage,,}]=1
	case $from in
	--*) from=${from#* } ;; # --platform=...
	esac
	if [ -n "${stages[${from,,}]:-}" ]; then
		printf 'scan-digests: %s builds on stage %s, already scanned\n' "$raw" "$from" >&2
		continue
	fi
	case $from in
	scratch) printf 'scan-digests: %s has no base image, skipping\n' "$raw" >&2; continue ;;
	esac

	# the pinned reference is the FROM line itself, so nothing has to be kept in step by hand
	ref=$from
	while [[ $ref =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
		name=${BASH_REMATCH[1]}
		ref=${ref//\$\{$name\}/${args[$name]:-}}
	done

	case "$ref" in
	*@sha256:*) ;;
	*) die "$dockerfile has no digest on $raw, refusing to scan a tag" ;;
	esac
	[ -z "${seen[$ref]:-}" ] || continue
	seen[$ref]=1

	# node:22-bookworm@sha256:... reads as node-base in the artifact tree, named for the image
	# rather than for the variable that holds it. A second stage on another digest of the same
	# image gets the next number.
	base=${ref%%@*}
	base=${base%%:*}
	base=${base##*/}
	slug=$base-base
	next=2
	while [ -n "${taken[$slug]:-}" ]; do
		slug=$base-base-$next
		next=$((next + 1))
	done
	taken[$slug]=1

	refs+=("$ref")
	slugs+=("$slug")
done < <(awk '/^FROM /{ sub(/^FROM /, ""); print }' "$dockerfile")

[ "${#refs[@]}" -gt 0 ] || die "$dockerfile has no base image to scan"

## SCAN

for i in "${!refs[@]}"; do
	printf 'scan-digests: %s -> %s\n' "${slugs[$i]}" "${refs[$i]}"
	docker pull -q "${refs[$i]}" >/dev/null
	"$here/scan.sh" "${refs[$i]}" "$out/${slugs[$i]}"
	# the daemon only held a pulled reference to be scanned
	docker image rm "${refs[$i]}" >/dev/null 2>&1 || true
done
