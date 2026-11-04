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

# Aggregate blocking findings across all images in this run. A repeated CVE/package/version tuple
# is reported once with every affected image, but every image is still evaluated by the policy.
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
blocking_jsonl="$tmp_dir/blocking-findings.jsonl"
: >"$blocking_jsonl"

# A report is readable only when it carries the shape Trivy writes. Anything else fails the gate,
# a valid JSON file with a result entry of an unexpected type included: a report nobody can
# validate must never collapse into a clean image. "Results": null is what Trivy writes for an
# image it found nothing in, and it stays a pass.
readable() { # <report>
	jq -e '
		type == "object"
		and (.SchemaVersion | type == "number")
		and has("Results")
		and (.Results == null or (.Results | type == "array"))
		and ([.Results[]?
			| select((type != "object")
				or ((.Vulnerabilities != null) and (.Vulnerabilities | type != "array")))] | length) == 0
		and ([.Results[]?.Vulnerabilities[]?
			| select((type != "object")
				or ((.VulnerabilityID | type) != "string")
				or ((.VulnerabilityID | length) == 0)
				or ((.Severity | type) != "string")
				or (.Severity != "UNKNOWN" and .Severity != "LOW" and .Severity != "MEDIUM" and .Severity != "HIGH" and .Severity != "CRITICAL")
				or ((.PkgName | type) != "string")
				or ((.PkgName | length) == 0)
				or ((.InstalledVersion | type) != "string")
				or ((.InstalledVersion | length) == 0)
				or ((.FixedVersion != null) and ((.FixedVersion | type) != "string")))] | length) == 0
	' "$1" >/dev/null 2>&1
}

manifest="$dir/scan-manifest.txt"
[ -s "$manifest" ] || die "no scan manifest under $dir, refusing to pass"
blocked=0
found=0
occurrences=0
declare -A seen=()
while IFS= read -r image || [ -n "$image" ]; do
	[[ "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid image name in scan manifest: $image"
	[ -z "${seen[$image]:-}" ] || die "duplicate image in scan manifest: $image"
	seen[$image]=1
	image_dir="$dir/$image"
	report="$image_dir/trivy.json"
	[ -d "$image_dir" ] || die "$image has no report directory, refusing to pass"
	[ -s "$report" ] || die "$image has no readable trivy report, refusing to pass"
	[ -s "$image_dir/scan-target.txt" ] || die "$image has no scan target metadata, refusing to pass"
	[ -s "$image_dir/scanner-versions.txt" ] || die "$image has no scanner version metadata, refusing to pass"
	sbom="$image_dir/syft.cdx.json"
	[ -s "$sbom" ] || die "$image has no Syft SBOM, refusing to pass"
	jq -e 'type == "object" and .bomFormat == "CycloneDX" and (.components | type == "array")' "$sbom" >/dev/null 2>&1 ||
		die "$image has an invalid CycloneDX SBOM, refusing to pass"
	found=1

	# An empty, truncated or unreadable file, and a report whose entries are not what the count
	# below expects, all land here.
	readable "$report" || die "$image has no readable trivy report, refusing to pass"

	fixable=$(jq -r '[.Results[]?.Vulnerabilities[]?
		| select((.Severity == "HIGH" or .Severity == "CRITICAL") and ((.FixedVersion // "") | length > 0))]
		| length' "$report")
	case "$fixable" in
	'' | *[!0-9]*) die "$image has an unreadable count from its report, refusing to pass" ;;
	esac
	severities=$(jq -r '[.Results[]?.Vulnerabilities[]? | .Severity]
		| group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$report")

	target=$(cat "$image_dir/scan-target.txt")

	printf '%s  target=%s\n' "$image" "$target"
	printf '  trivy  sev: %s  blocking: %s\n' "${severities:-none}" "$fixable"

	if [ "$fixable" -gt 0 ]; then
		blocked=1
		occurrences=$((occurrences + fixable))
		# Key findings by advisory plus package identity/version and fix version. Keep the app/image
		# on each row so the final report can deduplicate without hiding deployment exposure.
		jq -c --arg image "$image" '
			.Results[]?.Vulnerabilities[]?
			| select((.Severity == "HIGH" or .Severity == "CRITICAL") and ((.FixedVersion // "") | length > 0))
			| {
				key: ([.VulnerabilityID, (.PkgIdentifier.PURL // ((.PkgType // "") + ":" + .PkgName)), .PkgName, .InstalledVersion, (.FixedVersion // "")] | @json),
				severity: .Severity,
				id: .VulnerabilityID,
				package: .PkgName,
				installed: .InstalledVersion,
				fixed: (.FixedVersion // ""),
				image: $image
			}
		' "$report" >>"$blocking_jsonl"
	fi
done < "$manifest"

[ "$found" -eq 1 ] || die "no trivy report under $dir, refusing to pass"
for image_dir in "$dir"/*; do
	[ -d "$image_dir" ] || continue
	image=${image_dir##*/}
	[ -n "${seen[$image]:-}" ] || die "$image has artifacts but is absent from scan manifest"
done

if [ "$blocked" -ne 0 ]; then
	unique=$(jq -s 'group_by(.key) | length' "$blocking_jsonl")
	suppressed=$((occurrences - unique))
	printf 'Blocking findings: %s unique; %s image-level occurrences; %s duplicate occurrence(s) suppressed\n' \
		"$unique" "$occurrences" "$suppressed"
	jq -s -r '
		group_by(.key)
		| map({
			severity: (if any(.[]; .severity == "CRITICAL") then "CRITICAL" else "HIGH" end),
			id: .[0].id,
			package: .[0].package,
			installed: .[0].installed,
			fixed: .[0].fixed,
			images: (map({image, severity}) | unique_by(.image))
		})
		| sort_by(.severity, .id, .package)
		| .[]
		| "  \(.severity) \(.id) \(.package) \(.installed) -> \(.fixed) [images: \([.images[] | "\(.image) (\(.severity))"] | join(", "))]"
	' "$blocking_jsonl"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf 'Security gate: %s unique fixable HIGH/CRITICAL finding(s) across %s image-level occurrence(s); %s duplicate occurrence(s) suppressed.\n' \
			"$unique" "$occurrences" "$suppressed" >>"$GITHUB_STEP_SUMMARY"
	fi
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error title=Security gate::%s unique fixable HIGH/CRITICAL finding(s) across %s image-level occurrence(s)\n' \
			"$unique" "$occurrences"
	fi
	die "policy exceeded"
fi
printf '%s\n' 'gate: policy passed'
