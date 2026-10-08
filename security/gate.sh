#!/usr/bin/env bash

# USAGE: gate.sh <security-out-dir>

# Policy: block when Trivy reports a HIGH or CRITICAL that carries a fixed version, because that
# is the finding someone can act on. Unfixed findings and UNKNOWN severities report only. A
# report this cannot read is a failure, not a pass.

set -euo pipefail

dir=${1:?usage: gate.sh <security-out-dir>}

err() { printf 'gate: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command -v jq >/dev/null || die "jq is required"

blocked=0
found=0
total=0
for report in "$dir"/*/trivy.json; do
	[ -f "$report" ] || continue
	found=1
	image=${report%/*}
	image=${image##*/}

	# An empty or truncated file yields an empty or zero count, and neither one is a clean image.
	jq -e 'has("SchemaVersion") and has("Results")' "$report" >/dev/null 2>&1 ||
		die "$image has no readable trivy report, refusing to pass"

	fixable=$(jq -r '[.Results[]?.Vulnerabilities[]?
		| select((.Severity == "HIGH" or .Severity == "CRITICAL") and ((.FixedVersion // "") | length > 0))]
		| length' "$report")
	case "$fixable" in
	'' | *[!0-9]*) die "$image has an unreadable count from its report, refusing to pass" ;;
	esac
	severities=$(jq -r '[.Results[]?.Vulnerabilities[]? | .Severity]
		| group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$report")

	target=unknown
	[ ! -f "$dir/$image/scan-target.txt" ] || target=$(cat "$dir/$image/scan-target.txt")

	printf '%s  target=%s\n' "$image" "$target"
	printf '  trivy  sev: %s  blocking: %s\n' "${severities:-none}" "$fixable"

	if [ "$fixable" -gt 0 ]; then
		printf '%s\n' '  blocked:'
		jq -r '.Results[]?.Vulnerabilities[]?
			| select((.Severity == "HIGH" or .Severity == "CRITICAL") and ((.FixedVersion // "") | length > 0))
			| "    \(.Severity) \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' "$report"
		blocked=1
		total=$((total + fixable))
	fi
done

# A gate with nothing to read has not passed, it has failed to look. The scan job runs before this
# one, so a missing report is a broken artifact and never a clean image.
[ "$found" -eq 1 ] || die "no trivy report under $dir, refusing to pass"

if [ "$blocked" -ne 0 ]; then
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf 'Security gate: %s fixable high-severity finding(s), listed above in the job log.\n' \
			"$total" >>"$GITHUB_STEP_SUMMARY"
	fi
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error title=Security gate::%s fixable high-severity finding(s)\n' "$total"
	fi
	die "policy exceeded"
fi
printf '%s\n' 'gate: policy passed'
