#!/usr/bin/env bash

# USAGE: per-user provisioning inside the vworker guest, run by 'vworker sync' as root

set -euo pipefail

info(){ echo -e "\e[36m>\e[0m $*"; }
warn(){ echo -e "\e[33m!\e[0m $*" >&2; }

VM_USER=__VM_USER__
HOME_DIR=/home/$VM_USER
# secrets.env is copied to the guest by 'vworker sync' and sourced for re-runs
[ -f "$HOME_DIR/.vworker-secrets.env" ] && . "$HOME_DIR/.vworker-secrets.env"

OLLAMA_BASE="${OLLAMA_BASE:-http://10.0.2.2:11434/v1}"
SANDBOX_FOLDER_ID="${SANDBOX_FOLDER_ID:-}"
SYNC_HOST_DEVICE_ID="${SYNC_HOST_DEVICE_ID:-}"
SYNC_HOST_ADDRESS="${SYNC_HOST_ADDRESS:-}"

## FILE OWNERSHIP

info "ownership"
chown -R "$VM_USER:$VM_USER" "$HOME_DIR/.pi" 2>/dev/null || warn "no pi config copied yet"

## CLI ON PATH

# npm globals sit in an agent-owned prefix; mirror them into /usr/local/bin so the
# CLIs resolve for non-login shells too (ssh command execution, cloud-init, scripts)
info "cli symlinks"
for bin in /usr/local/share/npm-global/bin/*; do
	[ -x "$bin" ] || continue
	ln -sf "$bin" "/usr/local/bin/${bin##*/}"
done

## SHELL

info "shell"
grep -q 'zshrc.local' "$HOME_DIR/.zshrc" 2>/dev/null || cat >>"$HOME_DIR/.zshrc" <<'EOF'
# worker additions
[ -f ~/.zshrc.local ] && source ~/.zshrc.local
EOF
chown "$VM_USER:$VM_USER" "$HOME_DIR/.zshrc"
chsh -s /bin/zsh "$VM_USER"

## PI PROVIDERS

# The guest does not run its own ollama: the host serves it, and QEMU user networking
# forwards 10.0.2.2 to the host loopback, so no OLLAMA_HOST change on the host.
if [ -f "$HOME_DIR/.pi/agent/models.json" ]; then
	info "pi ollama endpoint -> $OLLAMA_BASE"
	tmp="$(mktemp)"
	jq --arg u "$OLLAMA_BASE" '.providers.ollama.baseUrl = $u' "$HOME_DIR/.pi/agent/models.json" >"$tmp"
	mv "$tmp" "$HOME_DIR/.pi/agent/models.json"
	chown "$VM_USER:$VM_USER" "$HOME_DIR/.pi/agent/models.json"
	jq -r '.providers | to_entries[] | "  \(.key): \(.value.baseUrl)"' "$HOME_DIR/.pi/agent/models.json"
fi

## PI MCP

# mcp.json is copied verbatim, so servers pinned to host-only paths (the hyprland
# browser helper) would error on every pi start in the guest
mcp="$HOME_DIR/.pi/agent/mcp.json"
if [ -f "$mcp" ]; then
	list="$(jq -r '(.mcpServers // {}) | to_entries[] | select(.value.command // "" | startswith("/")) | "\(.key)\t\(.value.command)"' "$mcp")"
	while IFS=$'\t' read -r key cmd; do
		[ -n "$key" ] || continue
		[ -x "$cmd" ] && continue
		warn "mcp $key dropped: $cmd is not in the guest"
		tmp="$(mktemp)"
		jq --arg k "$key" 'del(.mcpServers[$k])' "$mcp" >"$tmp"
		mv "$tmp" "$mcp"
	done <<<"$list"
	chown "$VM_USER:$VM_USER" "$mcp"
fi

## GIT

# gh's credential helper is not installed in the guest; the copied gh config plus
# https remotes are enough for both gh and glab
git config --system --add safe.directory '*' 2>/dev/null || true

## TAILSCALE

if [ -n "${TS_AUTHKEY:-}" ]; then
	info "tailscale up"
	tailscale up --authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-$(hostname)}" --ssh --accept-routes || warn "tailscale up failed"
	tailscale ip -4 || true
else
	warn "TS_AUTHKEY unset: tailnet join skipped (get one with the tailnet admin, tag:vworker)"
fi

## SYNCTHING

syncthing_apikey(){
	local cfg
	for cfg in "$HOME_DIR/.local/state/syncthing/config.xml" "$HOME_DIR/.config/syncthing/config.xml"; do
		[ -f "$cfg" ] || continue
		sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' "$cfg"
		return
	done
}

if runuser -u "$VM_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$VM_USER")" \
	systemctl --user is-active --quiet syncthing; then
	info "syncthing running"
	api="$(syncthing_apikey)"
	if [ -n "$api" ]; then
		rest(){ curl -fsS -H "X-API-Key: $api" "$@"; }
		my_id="$(rest http://127.0.0.1:8384/rest/system/status | jq -r .myID)"
		printf '%s\n' "$my_id" >"$HOME_DIR/.vworker-id"
		chown "$VM_USER:$VM_USER" "$HOME_DIR/.vworker-id"
		printf '  device id: %s\n' "$my_id"

		if [ -n "$SYNC_HOST_DEVICE_ID" ] && [ "$SYNC_HOST_DEVICE_ID" != "$my_id" ]; then
			info "pairing with host syncthing"
			rest -X PUT -H 'Content-Type: application/json' \
				"http://127.0.0.1:8384/rest/config/devices/$SYNC_HOST_DEVICE_ID" \
				-d "$(jq -n --arg id "$SYNC_HOST_DEVICE_ID" --arg addr "tcp://$SYNC_HOST_ADDRESS" \
					'{deviceID:$id,name:"host",addresses:[$addr],compression:"metadata"}')" || warn "device add failed"
		fi

		if [ -n "$SANDBOX_FOLDER_ID" ]; then
			# the worker gets exactly one folder and it is empty by design: no vault,
			# no real data. Never widen this to a folder that holds something worth
			# keeping, a sendreceive peer can delete what it sees.
			info "sandbox folder $SANDBOX_FOLDER_ID -> ~/sandbox"
			install -d -o "$VM_USER" -g "$VM_USER" "$HOME_DIR/sandbox"
			# the folder marker: without it syncthing refuses to scan (data loss guard)
			install -d -o "$VM_USER" -g "$VM_USER" "$HOME_DIR/sandbox/.stfolder"
			devices="$(jq -n --arg me "$my_id" --arg host "$SYNC_HOST_DEVICE_ID" \
				'[{deviceID:$me}] + (if $host == "" then [] else [{deviceID:$host}] end)')"
			rest -X PUT -H 'Content-Type: application/json' \
				"http://127.0.0.1:8384/rest/config/folders/$SANDBOX_FOLDER_ID" \
				-d "$(jq -n --arg id "$SANDBOX_FOLDER_ID" --arg path "$HOME_DIR/sandbox" --argjson dev "$devices" \
					'{id:$id,label:"sandbox",path:$path,type:"sendreceive",devices:$dev,fsWatcherEnabled:true,rescanIntervalS:3600}')" \
				|| warn "folder add failed"
			# syncthing ships an unused 'default' folder (~/Sync) in a fresh config;
			# the worker holds exactly one folder
			rest -X DELETE "http://127.0.0.1:8384/rest/config/folders/default" >/dev/null 2>&1 || true
			rmdir "$HOME_DIR/Sync" 2>/dev/null || true
		fi
	fi
else
	warn "syncthing user service not active, skipping folder setup"
fi

## SUMMARY

info "state"
printf '  pi:          %s\n' "$(runuser -u "$VM_USER" -- bash -lc 'command -v pi || echo missing')"
printf '  devcontainer:%s\n' "$(runuser -u "$VM_USER" -- bash -lc 'command -v devcontainer || echo missing')"
printf '  docker:      %s\n' "$(docker --version 2>/dev/null || echo missing)"
printf '  ollama:      %s\n' "$(curl -fsS --max-time 5 "${OLLAMA_BASE%/v1}/api/version" 2>/dev/null | jq -r .version || echo unreachable)"
printf '  tailscale:   %s\n' "$(tailscale ip -4 2>/dev/null | head -1 || echo not-joined)"
printf '  folders:     %s\n' "$(runuser -u "$VM_USER" -- bash -c 'K=$(sed -n "s:.*<apikey>\([^<]*\)</apikey>.*:\1:p" ~/.local/state/syncthing/config.xml); curl -fsS -H "X-API-Key: $K" http://127.0.0.1:8384/rest/config/folders | jq -r "[.[].id] | join(\", \")"' 2>/dev/null || echo unknown)"
