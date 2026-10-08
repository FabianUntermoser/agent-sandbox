#!/usr/bin/env bash

# USAGE: scan.sh <image-ref> <outdir>

# <image-ref> is anything the local Docker daemon resolves: the image id a build just produced, or
# a repo@sha256:... digest that was pulled. Never a tag, which can move between the pull and the
# scan and leaves a report about an image nobody can name afterwards.

set -euo pipefail

ref=${1:?usage: scan.sh <image-ref> <outdir>}
out=${2:?usage: scan.sh <image-ref> <outdir>}

# Pinned by digest. The tag beside it is a comment for the reader, and a scanner that moves under
# the gate is a scanner whose verdict means nothing.
trivy_image=${TRIVY_IMAGE:-aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa}
syft_image=${SYFT_IMAGE:-anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa}

socket=/var/run/docker.sock

log() { printf '== %s ==\n' "$*"; }
die() { printf 'scan: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is required"
command -v jq >/dev/null || die "jq is required"
[ -S "$socket" ] || die "$socket not found, the scanners reach the image through it"

mkdir -p "$out"
out=$(cd "$out" && pwd)

report() { # <label> <seconds> <cold|warm>
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$out/timings.txt"
	printf '%s: %ss (%s)\n' "$1" "$2" "$3"
}

run_to() { # <label> <cold|warm> <target|-> <cmd...>
	local label=$1 first=$2 target=$3 start
	shift 3
	start=$(date +%s)
	if [ "$target" = - ]; then
		"$@"
	else
		"$@" >"$target"
	fi
	report "$label" "$(( $(date +%s) - start ))" "$first"
}

## SCAN

# Both scanners reach the image through the daemon socket they were built or pulled into, and
# print their report to stdout. The redirects below carry that report into this job's own
# filesystem: mounting the output directory into a scanner container resolves it on the daemon
# host instead, and the report misses the artifact upload.
#
# The Trivy database gets a scratch volume, so a run over several images fetches it once instead
# of once per image. A caller that hands in TRIVY_DB_VOLUME keeps it across its own scans; without
# one the volume belongs to this run and dies with it.
trivy_db=${TRIVY_DB_VOLUME:-sec-trivy-db-$$}
docker volume inspect "$trivy_db" >/dev/null 2>&1 || docker volume create "$trivy_db" >/dev/null
if [ -z "${TRIVY_DB_VOLUME:-}" ]; then
	trap 'docker volume rm "$trivy_db" >/dev/null 2>&1 || true' EXIT INT TERM
fi

# Versions land in the job log and in the artifact, so a report identifies its own tooling.
{
	docker run --rm "$trivy_image" --version
	docker run --rm "$syft_image" version
} >"$out/scanner-versions.txt" 2>&1

# What was scanned, and the image id it was read as. A caller with more context, the commit for a
# build, writes this before calling here and keeps it: the file is rewritten only when it does not
# carry the id this scan just read, so a second run into the same directory cannot leave a report
# labelled with the image of the first one.
id=$(docker image inspect --format '{{.Id}}' "$ref")
if [ ! -f "$out/scan-target.txt" ] || ! grep -qF -- "$id" "$out/scan-target.txt"; then
	printf '%s %s\n' "$ref" "$id" >"$out/scan-target.txt"
fi

log scanning "$ref"
cat "$out/scanner-versions.txt"

log trivy
# A large image needs more than the five minute analysis deadline Trivy ships with, and a scan
# that gives up leaves the image unscanned.
run_to trivy cold "$out/trivy.json" docker run --rm \
	-v "$socket:$socket" -v "$trivy_db:/root/.cache/trivy" "$trivy_image" \
	image --image-src docker --scanners vuln --quiet --timeout 30m --format json "$ref"

log syft
run_to syft cold "$out/syft.cdx.json" docker run --rm -v "$socket:$socket" "$syft_image" \
	"docker:$ref" -q -o cyclonedx-json

log summary
components=$(jq '.components | length' "$out/syft.cdx.json")
severities=$(jq -r '[.Results[]?.Vulnerabilities[]? | .Severity]
	| group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$out/trivy.json")
printf 'syft components: %s\n' "$components"
printf 'trivy severities: %s\n' "${severities:-none}"
printf '%s\n' 'trivy findings:'
jq -r '.Results[]?.Vulnerabilities[]?
	| "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName) \(.InstalledVersion)\tfix: \(.FixedVersion // "none")"' \
	"$out/trivy.json" | sort -u

# A GitHub run gets the same numbers in its summary, where a reviewer reads them without opening
# the artifact.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		printf '### %s\n\n' "$(cat "$out/scan-target.txt")"
		printf '| scanner | report |\n| --- | --- |\n'
		printf '| Trivy | %s |\n' "${severities:-none}"
		printf '| Syft | %s components |\n\n' "$components"
	} >>"$GITHUB_STEP_SUMMARY"
fi
