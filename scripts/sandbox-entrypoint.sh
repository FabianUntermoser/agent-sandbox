#!/usr/bin/env bash
# Run as root only for firewall bootstrap, then remove network capabilities and start as node.
set -euo pipefail

FIREWALL_SCRIPT="${SANDBOX_FIREWALL_SCRIPT:-/usr/local/bin/init-firewall.sh}"
SETPRIV_BIN="${SANDBOX_SETPRIV_BIN:-/usr/bin/setpriv}"
CHOWN_BIN="${SANDBOX_CHOWN_BIN:-chown}"
ID_BIN="${SANDBOX_ID_BIN:-/usr/bin/id}"
PI_HOST_AGENT_DIR="${SANDBOX_PI_HOST_AGENT_DIR:-${HOME:-/home/node}/.pi/agent}"
PI_POLICY_SOURCE="${SANDBOX_PI_POLICY_SOURCE:-${HOME:-/home/node}/.config/agent-sandbox/pi-permission-policy.json}"
PI_RUN_AGENT_PARENT="${SANDBOX_PI_AGENT_RUN_PARENT:-/tmp}"

die() { printf 'sandbox-entrypoint: %s\n' "$*" >&2; exit 1; }

uid=$("$ID_BIN" -u) || die "cannot determine the bootstrap uid"
[ "$uid" = 0 ] || die "must start as root to initialize the egress firewall"

services=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  services+=("$1")
  shift
done
[ "$#" -gt 0 ] || die "missing -- separator before the agent command"
shift
[ "$#" -gt 0 ] || set -- zsh

if [ "${SANDBOX_SKIP_FIREWALL:-}" != 1 ]; then
  "$FIREWALL_SCRIPT" "${services[@]}"
fi

# Pi saves project-trust decisions in its agent directory. The host's ~/.pi tree is bind-mounted,
# so use an ephemeral per-container directory; link approved config/resources, but never trust.json.
if [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
  case "$PI_CODING_AGENT_DIR" in
    /tmp/agent-sandbox-pi-agent-*) ;;
    *) die "PI_CODING_AGENT_DIR is outside the managed per-container path" ;;
  esac
  mkdir -m 0700 -- "$PI_CODING_AGENT_DIR" || die "cannot create isolated Pi agent directory"
else
  mkdir -p "$PI_RUN_AGENT_PARENT" || die "cannot prepare isolated Pi agent directory"
  PI_CODING_AGENT_DIR=$(mktemp -d "$PI_RUN_AGENT_PARENT/agent-sandbox-pi-agent.XXXXXX") || \
    die "cannot create isolated Pi agent directory"
fi
mkdir -p "$PI_CODING_AGENT_DIR/extensions"
# Copy mutable per-user files/resources so Pi cannot write back through symlinks into the
# host's writable ~/.pi mount. Sessions belong to this container and start empty.
for resource in settings.json keybindings.json mcp.json models.json auth.json \
  AGENTS.override.md AGENTS.md AGENTS.MD CLAUDE.md CLAUDE.MD SYSTEM.md APPEND_SYSTEM.md; do
  source="$PI_HOST_AGENT_DIR/$resource"
  [ -f "$source" ] || continue
  cp -L -- "$source" "$PI_CODING_AGENT_DIR/$resource" || die "cannot stage Pi resource $resource"
done
for resource in npm git; do
  source="$PI_HOST_AGENT_DIR/$resource"
  [ -e "$source" ] || [ -L "$source" ] || continue
  ln -s "$source" "$PI_CODING_AGENT_DIR/$resource"
done
for resource in skills prompts themes packages; do
  source="$PI_HOST_AGENT_DIR/$resource"
  [ -d "$source" ] || continue
  mkdir -p "$PI_CODING_AGENT_DIR/$resource"
  cp -a "$source/." "$PI_CODING_AGENT_DIR/$resource/" || die "cannot stage Pi resource tree $resource"
done

host_extensions="$PI_HOST_AGENT_DIR/extensions"
if [ -d "$host_extensions" ]; then
  for extension in "$host_extensions"/*; do
    [ -e "$extension" ] || [ -L "$extension" ] || continue
    name="${extension##*/}"
    [ "$name" = pi-permission-system ] && continue
    ln -s "$extension" "$PI_CODING_AGENT_DIR/extensions/$name"
  done
  permission_extension="$host_extensions/pi-permission-system"
  if [ -d "$permission_extension" ]; then
    mkdir -p "$PI_CODING_AGENT_DIR/extensions/pi-permission-system/logs"
    for resource in "$permission_extension"/*; do
      [ -e "$resource" ] || [ -L "$resource" ] || continue
      name="${resource##*/}"
      case "$name" in config.json|logs) continue ;; esac
      ln -s "$resource" "$PI_CODING_AGENT_DIR/extensions/pi-permission-system/$name"
    done
    # Keep the unattended sandbox policy in this ephemeral agent directory, not the project.
    if [ -r "$PI_POLICY_SOURCE" ]; then
      cp "$PI_POLICY_SOURCE" "$PI_CODING_AGENT_DIR/extensions/pi-permission-system/config.json" || \
        die "cannot stage isolated Pi permission policy"
      chmod 0644 "$PI_CODING_AGENT_DIR/extensions/pi-permission-system/config.json"
    fi
  fi
fi
# Preserve the launcher’s Pi startup behavior without writing the host trust store. Only the
# current project is auto-trusted, and only inside this disposable per-container agent directory.
if [ "${SANDBOX_SESSION:-}" = pi ]; then
  approve=no
  for arg in "$@"; do
    case "$arg" in
      -na|--no-approve) approve=yes ;;
    esac
  done
  if [ "$approve" = no ] && command -v jq >/dev/null 2>&1; then
    trust_file="$PI_CODING_AGENT_DIR/trust.json"
    [ -f "$trust_file" ] || printf '{}\n' >"$trust_file"
    jq --arg project "$PWD" '. + {($project): true}' "$trust_file" >"$trust_file.tmp" || \
      die "cannot stage isolated Pi project trust"
    mv "$trust_file.tmp" "$trust_file" || die "cannot install isolated Pi project trust"
    printf "sandbox-entrypoint: trusted '%s' in ephemeral Pi state only\n" "$PWD" >&2
  fi
fi

# Make copied state writable by the unprivileged agent, while never following extension/npm/git
# symlinks back into the read-only host mounts.
"$CHOWN_BIN" -hR node:node "$PI_CODING_AGENT_DIR" || die "cannot transfer isolated Pi agent directory to node"
export PI_CODING_AGENT_DIR

# Drop NET_ADMIN and NET_RAW from the bounding, inheritable and ambient sets before the command.
exec "$SETPRIV_BIN" \
  --no-new-privs \
  --bounding-set=-net_admin,-net_raw \
  --inh-caps=-net_admin,-net_raw \
  --ambient-caps=-net_admin,-net_raw \
  --reuid=node --regid=node --init-groups -- "$@"
