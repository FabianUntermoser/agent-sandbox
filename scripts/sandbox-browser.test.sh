#!/usr/bin/env bash

# USAGE: browser QA in the shipped image: render a served fixture, click it, shoot it
#
# Runs a real container from the image and needs no network: the fixture is served inside the
# container from a read-only mount. Both Playwright and agent-browser must launch, render,
# interact with the fixture, and write a screenshot for this check to pass.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-agent-sandbox}"

failed=0
ok() { printf '  ok    %s\n' "$1"; }
nok() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
SHOTS="${SHOTS:-$(mktemp -d /tmp/sandbox-browser.XXXXXX)}"
mkdir -p "$SHOTS"
# The container user is uid 1000, which need not be the invoking user.
chmod 777 "$SHOTS"

cat >"$T/index.html" <<'EOF'
<!doctype html>
<html>
  <body>
    <h1 id="title">fixture</h1>
    <button id="go" onclick="document.getElementById('title').textContent='clicked'">go</button>
  </body>
</html>
EOF

# The container runs as uid 1000, which is not the invoking user on every host, so the fixture
# has to be readable by any uid or the served response is a 404 about listing the directory.
chmod 755 "$T"
chmod 644 "$T/index.html"

in_image() { # <script>: run it inside a fresh container of the image
	docker run --rm -v "$T:/fixture:ro" -v "$SHOTS:/shots" --entrypoint /bin/bash "$IMAGE" -c "$1"
}

read -r -d '' PROBE <<'PROBE' || true
set -u
python3 -m http.server 8123 --directory /fixture >/tmp/http.log 2>&1 &
server=$!
ready=no
for _ in $(seq 1 40); do
  if curl -fsS -o /dev/null http://127.0.0.1:8123/ 2>/dev/null; then ready=yes; break; fi
  sleep 0.25
done
echo "server-ready=$ready"
echo "server-log=$(tr "\n" " " </tmp/http.log | tail -c 200)"
export NODE_PATH=/home/node/.npm-global/lib/node_modules
node -e '
const { chromium } = require("playwright");
const fs = require("fs");
(async () => {
  const args = ["--disable-dev-shm-usage"];
  console.log("launch-args=" + args.join(" "));
  const browser = await chromium.launch({ args });
  const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text().slice(0, 80)); });
  const response = await page.goto("http://127.0.0.1:8123/", { waitUntil: "load", timeout: 15000 });
  console.log("response-status=" + (response ? response.status() : "none"));
  console.log("final-url=" + page.url());
  console.log("body-text=" + (await page.evaluate(() => document.body.innerText.replace(/\s+/g, " ").slice(0, 120))));
  console.log("content=" + (await page.textContent("#title")));
  await page.click("#go");
  console.log("after-click=" + (await page.textContent("#title")));
  await page.screenshot({ path: "/shots/playwright.png" });
  console.log("screenshot=" + fs.statSync("/shots/playwright.png").size);
  console.log("page-errors=" + errors.length + (errors.length ? " " + errors.join("; ").slice(0, 160) : ""));
  await browser.close();
})().catch((e) => { console.log("playwright-error=" + String(e).slice(0, 200)); process.exit(1); });
'
kill "$server" 2>/dev/null || true
PROBE

out="$(in_image "$PROBE" 2>&1 || true)"
field() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | tail -1; }

if printf '%s\n' "$out" | grep -q '^playwright-error='; then
	nok "the render failed: $(field playwright-error)"
else
	[ "$(field content)" = "fixture" ] && ok "the page renders its content" || nok "content: wanted fixture, got [$(field content)]"
	[ "$(field after-click)" = "clicked" ] && ok "a click changes the page" || nok "after-click: wanted clicked, got [$(field after-click)]"
	bytes="$(field screenshot)"
	if [ -n "$bytes" ] && [ "$bytes" -gt 5000 ]; then
		ok "a screenshot is written ($bytes bytes)"
	else
		nok "screenshot: wanted more than 5000 bytes, got [$bytes]"
	fi
	[ "$(field page-errors)" = "0" ] && ok "no page errors" || nok "page errors: $(field page-errors)"
fi

# agent-browser: a failed launch or interaction is a test failure, not a report-only gap.
read -r -d '' AB_PROBE <<'ABPROBE' || true
set -euo pipefail
python3 -m http.server 8123 --directory /fixture >/tmp/agent-browser-http.log 2>&1 &
server=$!
cleanup() {
  agent-browser close >/dev/null 2>&1 || true
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
}
trap cleanup EXIT
ready=no
for _ in $(seq 1 40); do
  if curl -fsS -o /dev/null http://127.0.0.1:8123/ 2>/dev/null; then ready=yes; break; fi
  sleep 0.25
done
if [ "$ready" != yes ]; then
  cat /tmp/agent-browser-http.log >&2 || true
  echo "agent-browser-fixture-server=not-ready"
  exit 1
fi
printf 'versions=%s | %s\n' "$(agent-browser --version)" "$("$AGENT_BROWSER_EXECUTABLE_PATH" --version 2>/dev/null || echo headless_shell)"
agent-browser open http://127.0.0.1:8123/
before="$(agent-browser get text '#title')"
printf 'agent-browser-content=%s\n' "$before"
[ "$before" = fixture ]
agent-browser click '#go'
after="$(agent-browser get text '#title')"
printf 'agent-browser-after-click=%s\n' "$after"
[ "$after" = clicked ]
agent-browser screenshot /shots/agent-browser.png
bytes="$(stat -c%s /shots/agent-browser.png)"
printf 'agent-browser-screenshot=%s\n' "$bytes"
[ "$bytes" -gt 5000 ]
ABPROBE

printf '  agent-browser smoke test\n'
if ab_out="$(in_image "$AB_PROBE" 2>&1)"; then
	ok "agent-browser launches, reads and interacts with the fixture, and writes a screenshot"
	printf '%s\n' "$ab_out" | grep -E '^(versions|agent-browser-)' | sed 's/^/        /'
else
	nok "agent-browser smoke test failed"
	printf '%s\n' "$ab_out" | sed 's/^/  | /' >&2
fi
printf '  screenshots: %s\n' "$SHOTS"

if [ "$failed" -ne 0 ]; then
	echo "  --- container output ---" >&2
	printf '%s\n' "$out" | sed 's/^/  | /' >&2
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
	echo "sandbox-browser: ok"
else
	echo "sandbox-browser: failed" >&2
fi
exit "$failed"
