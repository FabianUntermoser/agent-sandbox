#!/usr/bin/env bash

# Static regression checks for preserving Chromium's normal sandbox in the image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail + 1)); }

if grep -Fq -- '--no-sandbox' "$ROOT/Dockerfile" "$ROOT/scripts/sandbox-browser.test.sh"; then
  bad 'the image/Playwright smoke test must not disable Chromium sandbox'
else
  ok 'the image and Playwright smoke test do not pass --no-sandbox'
fi

if grep -Fq 'AGENT_BROWSER_ARGS' "$ROOT/Dockerfile"; then
  bad 'the image must not globally override agent-browser launch flags'
else
  ok 'the image does not globally override agent-browser launch flags'
fi

if grep -Fq 'const args = ["--disable-dev-shm-usage"];' "$ROOT/scripts/sandbox-browser.test.sh"; then
  ok 'Playwright smoke test retains only the shared-memory workaround'
else
  bad 'Playwright smoke-test arguments are not the expected minimal set'
fi

if grep -Fq 'AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/chromium-headless-shell' "$ROOT/Dockerfile"; then
  ok 'the image browser executable remains configured'
else
  bad 'the image browser executable is not configured'
fi

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
