#!/usr/bin/env bash

# Unit tests for the root-only firewall bootstrap and post-bootstrap capability drop.
# All host privilege utilities are stubs; these tests do not touch Docker or a firewall.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
pass=0
fail=0

ok() { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; fail=$((fail + 1)); }
contains_line() { grep -Fxq -- "$2" "$1"; }

cat >"$T/bin/id" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UID:-0}"
STUB
cat >"$T/bin/chown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CHOWN_ARGS"
if [ "${FAKE_CHOWN_RC:-0}" -eq 0 ] && "$REAL_CHOWN_BIN" "$@" 2>/dev/null; then
  printf 'yes\n' >"$CHOWN_APPLIED"
else
  printf 'no\n' >"$CHOWN_APPLIED"
fi
# On a developer host without a node account, record the requested production operation and let
# the command-flow test continue. The container has the node user and uses the real chown binary.
exit "${FAKE_CHOWN_RC:-0}"
STUB
cat >"$T/firewall" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FIREWALL_ARGS"
exit "${FAKE_FIREWALL_RC:-0}"
STUB
cat >"$T/setpriv" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PRIV_ARGS"
printf '%s\n' "$PI_CODING_AGENT_DIR" >"$PI_AGENT_DIR_OUTPUT"
exit 0
STUB
chmod +x "$T/bin/id" "$T/bin/chown" "$T/firewall" "$T/setpriv"
REAL_CHOWN_BIN="$(command -v chown)"

mkdir -p "$T/home/.pi/agent/extensions/pi-permission-system/logs" \
  "$T/home/.pi/agent/extensions/other" "$T/home/.config/agent-sandbox" "$T/pi-runs"
printf '{"defaultProvider":"example"}\n' >"$T/home/.pi/agent/settings.json"
mkdir -p "$T/home/.pi/agent/sessions" "$T/home/.pi/agent/npm" "$T/home/.pi/agent/git"
printf 'existing host trust\n' >"$T/home/.pi/agent/trust.json"
cp "$T/home/.pi/agent/trust.json" "$T/trust.before"
printf '{"origin":"host"}\n' >"$T/home/.pi/agent/extensions/pi-permission-system/config.json"
printf 'export default {};\n' >"$T/home/.pi/agent/extensions/pi-permission-system/index.ts"
printf 'export default {};\n' >"$T/home/.pi/agent/extensions/other/index.ts"
printf '{"origin":"isolated catalogue policy"}\n' >"$T/home/.config/agent-sandbox/pi-permission-policy.json"

run() {
  rm -f "$T/firewall.args" "$T/priv.args" "$T/pi-agent-dir" "$T/chown.args" "$T/chown.applied"
  set +e
  HOME="$T/home" FIREWALL_ARGS="$T/firewall.args" PRIV_ARGS="$T/priv.args" \
    CHOWN_ARGS="$T/chown.args" CHOWN_APPLIED="$T/chown.applied" REAL_CHOWN_BIN="$REAL_CHOWN_BIN" \
    PI_AGENT_DIR_OUTPUT="$T/pi-agent-dir" \
    SANDBOX_SKIP_FIREWALL="${FAKE_SKIP_FIREWALL:-}" \
    PI_CODING_AGENT_DIR="${FAKE_PI_AGENT_DIR:-}" \
    SANDBOX_SESSION="${FAKE_SESSION:-}" \
    SANDBOX_PI_HOST_AGENT_DIR="$T/home/.pi/agent" \
    SANDBOX_PI_POLICY_SOURCE="$T/home/.config/agent-sandbox/pi-permission-policy.json" \
    SANDBOX_PI_AGENT_RUN_PARENT="$T/pi-runs" \
    SANDBOX_FIREWALL_SCRIPT="$T/firewall" SANDBOX_SETPRIV_BIN="$T/setpriv" \
    SANDBOX_CHOWN_BIN="$T/bin/chown" \
    SANDBOX_ID_BIN="$T/bin/id" PATH="$T/bin:$PATH" FAKE_UID="${FAKE_UID:-0}" \
    FAKE_FIREWALL_RC="${FAKE_FIREWALL_RC:-0}" FAKE_CHOWN_RC="${FAKE_CHOWN_RC:-0}" \
    "$SRC/sandbox-entrypoint.sh" "$@" >"$T/out" 2>&1
  rc=$?
  set -e
}

printf 'bootstrap and drop order\n'
FAKE_SESSION=pi run ollama -- /usr/bin/printf '%s %s' 'argument with spaces' 'last'
if [ "$rc" -eq 0 ] && [ "$(cat "$T/firewall.args")" = ollama ] && \
  contains_line "$T/priv.args" '--no-new-privs' && \
  contains_line "$T/priv.args" '--bounding-set=-net_admin,-net_raw' && \
  contains_line "$T/priv.args" '--inh-caps=-net_admin,-net_raw' && \
  contains_line "$T/priv.args" '--ambient-caps=-net_admin,-net_raw' && \
  [ "$(sed -n '1p' "$T/chown.args")" = '-hR' ] && \
  [ "$(sed -n '2p' "$T/chown.args")" = 'node:node' ] && \
  [ "$(sed -n '3p' "$T/chown.args")" = "$(cat "$T/pi-agent-dir")" ] && \
  contains_line "$T/priv.args" '--reuid=node' && contains_line "$T/priv.args" '--regid=node' && \
  [ "$(grep -nFx -- '--' "$T/priv.args" | cut -d: -f1)" = 8 ] && \
  contains_line "$T/priv.args" '/usr/bin/printf' && contains_line "$T/priv.args" '%s %s' && \
  contains_line "$T/priv.args" 'argument with spaces' && contains_line "$T/priv.args" last; then
  ok 'firewall receives only service tokens; agent argv remains intact after capability drop'
else
  bad 'bootstrap/drop command or argv was not correct'
  cat "$T/out" >&2
  [ -f "$T/firewall.args" ] && cat "$T/firewall.args" >&2
  [ -f "$T/priv.args" ] && cat "$T/priv.args" >&2
fi

printf 'Pi trust and permission policy stay per-container\n'
agent_dir="$(cat "$T/pi-agent-dir")"
# Verify actual ownership when the host can perform it; elsewhere the test above verifies the
# exact chown request without requiring a host-side node account.
ownership_ok=yes
if [ "$(cat "$T/chown.applied")" = yes ]; then
  [ "$(stat -c '%U:%G' "$agent_dir/settings.json")" = node:node ] || ownership_ok=no
fi
if [ -d "$agent_dir" ] && [ "$ownership_ok" = yes ] && jq -e --arg project "$PWD" '.[$project] == true' "$agent_dir/trust.json" >/dev/null && \
  [ -f "$agent_dir/settings.json" ] && [ ! -L "$agent_dir/settings.json" ] && \
  [ -L "$agent_dir/npm" ] && [ -L "$agent_dir/git" ] && \
  [ -L "$agent_dir/extensions/other" ] && \
  [ -L "$agent_dir/extensions/pi-permission-system/index.ts" ] && \
  cmp -s "$agent_dir/extensions/pi-permission-system/config.json" "$T/home/.config/agent-sandbox/pi-permission-policy.json" && \
  cmp -s "$T/home/.pi/agent/trust.json" "$T/trust.before" && \
  [ "$(cat "$T/home/.pi/agent/extensions/pi-permission-system/config.json")" = '{"origin":"host"}' ]; then
  jq '. + {"sandbox-only-write-test": true}' "$agent_dir/trust.json" >"$agent_dir/trust.tmp"
  mv "$agent_dir/trust.tmp" "$agent_dir/trust.json"
  printf '{"sandbox":"setting"}\n' >"$agent_dir/settings.json"
  if cmp -s "$T/home/.pi/agent/trust.json" "$T/trust.before" && \
    [ "$(cat "$T/home/.pi/agent/settings.json")" = '{"defaultProvider":"example"}' ]; then
    ok 'trust and mutable settings are isolated; npm/git/extensions remain linked; policy is staged outside project/host state'
  else
    bad 'writing isolated Pi trust/settings altered host state'
  fi
else
  bad 'Pi agent directory is not isolated or its resources/policy were staged incorrectly'
fi

rm -rf "$agent_dir"

printf 'ownership transfer failure is a hard stop\n'
FAKE_CHOWN_RC=7 run -- /bin/true
if [ "$rc" -ne 0 ] && [ ! -e "$T/priv.args" ] && \
  grep -Fq 'cannot transfer isolated Pi agent directory to node' "$T/out" && \
  [ "$(sed -n '1p' "$T/chown.args")" = '-hR' ] && \
  [ "$(sed -n '2p' "$T/chown.args")" = 'node:node' ]; then
  ok 'a failed ownership transfer aborts before capability drop or agent execution'
else
  bad 'the entrypoint continued after ownership transfer failed'
fi
agent_dir="$(cat "$T/pi-agent-dir" 2>/dev/null || true)"
[ -z "$agent_dir" ] || rm -rf "$agent_dir"

printf 'firewall failure is a hard stop\n'
FAKE_FIREWALL_RC=7 run ollama -- /bin/true
if [ "$rc" -ne 0 ] && [ ! -e "$T/priv.args" ]; then
  ok 'agent does not start when firewall bootstrap fails'
else
  bad 'agent was invoked despite a failed firewall bootstrap'
fi

printf 'stable per-container path skips duplicate bootstrap\n'
stable="/tmp/agent-sandbox-pi-agent-fixture-$$"
rm -rf "$stable"
FAKE_SKIP_FIREWALL=1 FAKE_PI_AGENT_DIR="$stable" run -- /bin/true
if [ "$rc" -eq 0 ] && [ ! -e "$T/firewall.args" ] && \
  [ "$(cat "$T/pi-agent-dir")" = "$stable" ] && [ -d "$stable" ] && \
  [ "$(stat -c '%a' "$stable")" = 700 ]; then
  ok 'configured per-container state path is reused and host-network mode skips firewall setup'
else
  bad 'stable path or firewall skip was not respected'
fi
rm -rf "$stable"

printf 'no-approve opt-out leaves ephemeral project untrusted\n'
FAKE_SESSION=pi run ollama -- --no-approve /bin/true
agent_dir="$(cat "$T/pi-agent-dir")"
if [ "$rc" -eq 0 ] && [ ! -e "$agent_dir/trust.json" ] && \
  cmp -s "$T/home/.pi/agent/trust.json" "$T/trust.before"; then
  ok 'no-approve skips ephemeral trust and never mutates host trust'
else
  bad 'no-approve did not skip trust or host trust changed'
fi
rm -rf "$agent_dir"

printf 'bootstrap requires root\n'
FAKE_UID=1000 run -- /bin/true
if [ "$rc" -ne 0 ] && [ ! -e "$T/firewall.args" ] && [ ! -e "$T/priv.args" ]; then
  ok 'non-root invocation refuses before firewall or agent execution'
else
  bad 'non-root invocation was not refused'
fi

printf 'separator is required\n'
FAKE_UID=0 run ollama /bin/true
if [ "$rc" -ne 0 ] && [ ! -e "$T/firewall.args" ] && [ ! -e "$T/priv.args" ]; then
  ok 'missing command separator refuses before doing work'
else
  bad 'missing command separator was not refused'
fi

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
