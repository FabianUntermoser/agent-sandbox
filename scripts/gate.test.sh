#!/usr/bin/env bash

# Synthetic Trivy reports; no image scan or Docker operation is performed.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null || { printf 'gate.test: jq is required\n' >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
counter=0

check() { # <label> <pass|fail> <json>
  local label=$1 wanted=$2 json=$3 status got=pass out
  counter=$((counter + 1))
  local dir="$T/case-$counter"
  mkdir -p "$dir/report"
  printf '%s\n' "$json" >"$dir/report/trivy.json"
  set +e
  out=$("$SRC/../security/gate.sh" "$dir" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || got=fail
  if [ "$got" = "$wanted" ]; then
    printf '  ok    %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s: expected %s, got %s (exit %s)\n' "$label" "$wanted" "$got" "$status" >&2
    printf '%s\n' "$out" | tail -4 | sed 's/^/        /' >&2
    fail=$((fail + 1))
  fi
}

empty='{"SchemaVersion":2,"Results":[]}'
base='{"SchemaVersion":2,"Results":[{"Target":"base","Vulnerabilities":[]}]}'
valid_high='{"SchemaVersion":2,"Results":[{"Target":"base","Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"HIGH","PkgName":"openssl","InstalledVersion":"1.1.1","FixedVersion":"1.1.2"}]}]}'

printf 'gate: valid report shapes\n'
check 'empty Results array passes' pass "$empty"
check 'null Results passes as a clean scan' pass '{"SchemaVersion":2,"Results":null}'
check 'empty vulnerability list passes' pass "$base"
check 'unfixed high severity is informational under policy' pass '{"SchemaVersion":2,"Results":[{"Target":"base","Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"HIGH","PkgName":"openssl","InstalledVersion":"1.1.1","FixedVersion":null}]}]}'
check 'low severity with a fix is non-blocking' pass '{"SchemaVersion":2,"Results":[{"Target":"base","Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"LOW","PkgName":"openssl","InstalledVersion":"1.1.1","FixedVersion":"1.1.2"}]}]}'
check 'UNKNOWN severity with a fix is non-blocking' pass '{"SchemaVersion":2,"Results":[{"Target":"base","Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"UNKNOWN","PkgName":"openssl","InstalledVersion":"1.1.1","FixedVersion":"1.1.2"}]}]}'

printf 'gate: malformed report shapes fail closed\n'
check 'missing SchemaVersion fails' fail '{"Results":[]}'
check 'missing Results fails' fail '{"SchemaVersion":2}'
check 'object instead of Results array fails' fail '{"SchemaVersion":2,"Results":{}}'
check 'scalar result entry fails' fail '{"SchemaVersion":2,"Results":["not an object"]}'
check 'non-array Vulnerabilities fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":{}}]}'
check 'empty vulnerability object fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{}]}]}'
check 'missing VulnerabilityID fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"Severity":"LOW","PkgName":"openssl","InstalledVersion":"1.1.1"}]}]}'
check 'empty VulnerabilityID fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"","Severity":"LOW","PkgName":"openssl","InstalledVersion":"1.1.1"}]}]}'
check 'missing Severity fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","PkgName":"openssl","InstalledVersion":"1.1.1"}]}]}'
check 'non-enumerated Severity fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"SEVERE","PkgName":"openssl","InstalledVersion":"1.1.1"}]}]}'
check 'numeric Severity fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":4,"PkgName":"openssl","InstalledVersion":"1.1.1"}]}]}'
check 'missing PkgName fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"LOW","InstalledVersion":"1.1.1"}]}]}'
check 'empty PkgName fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"LOW","PkgName":"","InstalledVersion":"1.1.1"}]}]}'
check 'missing InstalledVersion fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"LOW","PkgName":"openssl"}]}]}'
check 'empty InstalledVersion fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"LOW","PkgName":"openssl","InstalledVersion":""}]}]}'
check 'numeric FixedVersion fails' fail '{"SchemaVersion":2,"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2026-12345","Severity":"LOW","PkgName":"openssl","InstalledVersion":"1.1.1","FixedVersion":12}]}]}'
check 'malformed JSON fails' fail '{broken'
check 'HIGH severity with a fix blocks policy' fail "$valid_high"

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
