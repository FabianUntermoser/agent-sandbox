#!/usr/bin/env bash

# USAGE: browser QA in the shipped image: render a served fixture, click it, shoot it
#
# Runs a real container from the image and needs no network: the fixture is served inside the
# container from a read-only mount. Playwright is the gate. agent-browser is reported, never
# silently: a launch it cannot make prints GAP and does not fail this suite, because the issue
# that tracks it is open and a green run here must not read as settled.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-agent-sandbox}"

failed=0
ok() { printf '  ok    %s\n' "$1"; }
nok() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
gap() { printf '  GAP   %s\n' "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

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
	docker run --rm --shm-size=1g -v "$T:/fixture:ro" --entrypoint /bin/bash "$IMAGE" -c "$1"
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
  const args = ["--no-sandbox", "--disable-dev-shm-usage"];
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
  await page.screenshot({ path: "/tmp/shot.png" });
  console.log("screenshot=" + fs.statSync("/tmp/shot.png").size);
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

# agent-browser: reported, not gated.
ab="$(in_image 'cd /tmp && agent-browser open "data:text/html,<h1>ab</h1>" >/tmp/ab.log 2>&1; agent-browser get text h1 2>/dev/null | tail -1; agent-browser close >/dev/null 2>&1' 2>&1 | tail -1 || true)"
if [ "$ab" = "ab" ]; then
	ok "agent-browser launches a browser"
else
	gap "agent-browser cannot launch a browser in this container, tracked on its issue"
fi

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
