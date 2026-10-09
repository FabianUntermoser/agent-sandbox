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

# Every FROM Docker reads, whatever its case, its indentation and its spacing: the instruction name
# is case-insensitive and a line may be indented. This parse refuses a FROM it cannot read, because a
# stage left out is a base nobody scans, and a green run that covered less than the build did is
# worse than a red one. The instruction allows no continuation, so one line is one FROM.
while IFS= read -r raw; do
	# the capture keeps the whitespace that followed the instruction, and a message that starts with
	# a space reads as a typo
	read -r raw <<<"$raw"
	# FROM [--platform=<value>] <image> [AS <name>]
	rest=$raw
	while :; do
		read -r head tail <<<"$rest"
		case $head in
		--*) rest=$tail ;;
		*) break ;;
		esac
	done
	read -r image kw as_name extra <<<"$rest"
	[ -n "$image" ] || die "$dockerfile has a FROM line with no image: $raw"
	stage=""
	if [ -n "$kw" ]; then
		[ "${kw,,}" = as ] && [ -n "$as_name" ] && [ -z "$extra" ] ||
			die "$dockerfile has a FROM line this parse cannot read: $raw"
		stage=$as_name
	fi
	# a later FROM reads the stage a name was given to, which its own FROM already pinned
	[ -z "$stage" ] || stages[${stage,,}]=1
	if [ -n "${stages[${image,,}]:-}" ]; then
		printf 'scan-digests: %s builds on stage %s, already scanned\n' "$raw" "$image" >&2
		continue
	fi
	case $image in
	scratch) printf 'scan-digests: %s has no base image, skipping\n' "$raw" >&2; continue ;;
	esac

	# the pinned reference is the FROM line itself, so nothing has to be kept in step by hand
	ref=$image
	while [[ $ref =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
		name=${BASH_REMATCH[1]}
		ref=${ref//\$\{$name\}/${args[$name]:-}}
	done

	case "$ref" in
	*@sha256:*) digest=${ref##*@sha256:} ;;
	*) die "$dockerfile has no digest on $raw, refusing to scan a tag" ;;
	esac
	# a digest-shaped tail on a tag is not a digest: docker resolves the tag, and the report then names
	# an image nobody can pull again. 64 hex characters after the prefix, or the run stops here.
	case $digest in
	*[!0-9a-fA-F]*) die "$dockerfile has a malformed digest on $raw: $digest" ;;
	esac
	[ "${#digest}" -eq 64 ] || die "$dockerfile has a ${#digest} character digest on $raw, expected 64"
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
done < <(sed -n 's/^[[:space:]]*[Ff][Rr][Oo][Mm]\([[:space:]].*\)\?$/\1/p' "$dockerfile")

[ "${#refs[@]}" -gt 0 ] || die "$dockerfile has no base image to scan"

## SCAN

for i in "${!refs[@]}"; do
	printf 'scan-digests: %s -> %s\n' "${slugs[$i]}" "${refs[$i]}"
	docker pull -q "${refs[$i]}" >/dev/null
	"$here/scan.sh" "${refs[$i]}" "$out/${slugs[$i]}"
	# the daemon only held a pulled reference to be scanned
	docker image rm "${refs[$i]}" >/dev/null 2>&1 || true
done
