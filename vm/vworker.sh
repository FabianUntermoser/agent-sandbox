#!/usr/bin/env bash

# USAGE: vworker - boot a QEMU worker VM and hand it an isolated synced sandbox (pi, docker, devcontainer, gh/glab, syncthing, tailscale)

# The worker shares exactly one folder with the host and never sees the vault:
# keep real data out of the sandbox, the worker can write and delete inside it.

set -euo pipefail

# progress goes to stderr: stdout is captured for values (ssh key, ids)
die(){ echo -e "\e[31merror:\e[0m $*" >&2; exit 1; }
info(){ echo -e "\e[36m>\e[0m $*" >&2; }
warn(){ echo -e "\e[33m!\e[0m $*" >&2; }

## DEFAULTS

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO="$(cd "$SRC/.." && pwd)"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vworker"
[ -f "$CFG_DIR/config" ] && . "$CFG_DIR/config"
[ -f "$CFG_DIR/secrets.env" ] && . "$CFG_DIR/secrets.env"

VM_NAME="${VM_NAME:-vworker}"
VM_HOME="${VM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/vworker/$VM_NAME}"
VM_USER="${VM_USER:-agent}"
VM_CPUS="${VM_CPUS:-4}"
VM_RAM="${VM_RAM:-8192}"
VM_DISK="${VM_DISK:-40G}"
SSH_PORT="${SSH_PORT:-2222}"
# syncthing: host side port that forwards to the guest's 22000 (the host owns 22000 itself)
SYNC_PORT="${SYNC_PORT:-22002}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/vworker_ed25519}"
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
# cache the cloud image outside VM_HOME so 'vworker destroy' keeps it
BASE_IMAGE="${BASE_IMAGE:-${XDG_DATA_HOME:-$HOME/.local/share}/vworker/base.qcow2}"
# the guest reaches the host's loopback through QEMU user networking, so the host keeps
# ollama bound to 127.0.0.1 and the same address works on any remote host
OLLAMA_BASE="${OLLAMA_BASE:-http://10.0.2.2:11434/v1}"
# the worker's only share: a dedicated throwaway folder, never the vault
SANDBOX_FOLDER_ID="${SANDBOX_FOLDER_ID:-vworker}"
SANDBOX_HOST_PATH="${SANDBOX_HOST_PATH:-$HOME/vworker}"
SYNC_HOST_DEVICE_ID="${SYNC_HOST_DEVICE_ID:-}"
SYNC_HOST_ADDRESS="${SYNC_HOST_ADDRESS:-}"
SSH_PUBKEY=""

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new
	-o UserKnownHostsFile="$VM_HOME/known_hosts" -o LogLevel=ERROR -o ConnectTimeout=10)
RSH="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$VM_HOME/known_hosts -o LogLevel=ERROR"

## HELPERS

running(){ [ -f "$VM_HOME/qemu.pid" ] && kill -0 "$(cat "$VM_HOME/qemu.pid")" 2>/dev/null; }
gssh(){ ssh "${SSH_OPTS[@]}" "$VM_USER@127.0.0.1" "$@"; }

render(){ # <template> [embedded-script]
	awk -v user="$VM_USER" -v name="$VM_NAME" -v pub="$SSH_PUBKEY" -v script="${2:-}" '
		function suball(l){ gsub(/__VM_USER__/, user, l); gsub(/__HOSTNAME__/, name, l); gsub(/__SSH_PUBKEY__/, pub, l); return l }
		/__SYSTEM_SCRIPT__/ { while ((getline l < script) > 0) print "      " suball(l); close(script); next }
		{ print suball($0) }
	' "$1"
}

copy(){ # copy <src> <remote-path relative to the guest home>, skips what this host does not have
	[ -e "$1" ] || { warn "missing $1, skipped"; return 0; }
	# -L: dotfiles are symlinks into the repos, copy the referent not the link
	rsync -aL -e "$RSH" "$1" "$VM_USER@127.0.0.1:$2"
}

copydir(){ # same, but syncs the directory contents instead of nesting it
	[ -d "$1" ] || { warn "missing $1, skipped"; return 0; }
	rsync -aL -e "$RSH" "${1%/}/" "$VM_USER@127.0.0.1:$2/"
}

ssh_pubkey(){
	if [ ! -f "$SSH_KEY" ]; then
		info "generating $SSH_KEY"
		ssh-keygen -q -t ed25519 -N '' -C "$VM_NAME" -f "$SSH_KEY"
	fi
	SSH_PUBKEY="$(cat "$SSH_KEY.pub")"
	case "$SSH_PUBKEY" in ssh-*) printf '%s\n' "$SSH_PUBKEY" ;; *) die "$SSH_KEY.pub does not look like a key" ;; esac
}

base_image(){
	[ -f "$BASE_IMAGE" ] && return
	install -d "$(dirname "$BASE_IMAGE")"
	info "downloading ${IMAGE_URL##*/}"
	curl -fL -sS -o "$BASE_IMAGE.part" "$IMAGE_URL"
	mv "$BASE_IMAGE.part" "$BASE_IMAGE"
}

seed_image(){
	SSH_PUBKEY="$(ssh_pubkey)"
	render "$SRC/cloud-init/user-data" "$SRC/guest/provision-system.sh" >"$VM_HOME/user-data"
	render "$SRC/cloud-init/meta-data" >"$VM_HOME/meta-data"
	rm -f "$VM_HOME/seed.img"
	truncate -s 1M "$VM_HOME/seed.img"
	mkfs.vfat -n CIDATA "$VM_HOME/seed.img" >/dev/null
	mcopy -i "$VM_HOME/seed.img" "$VM_HOME/user-data" "$VM_HOME/meta-data" ::
}

qemu_launch(){
	if [ -r /dev/kvm ]; then
		ACCEL='-machine q35,accel=kvm -cpu host'
	else
		warn "/dev/kvm unusable, falling back to TCG (slow)"
		ACCEL='-machine q35,accel=tcg -cpu max'
	fi
	# shellcheck disable=SC2086
	qemu-system-x86_64 \
		-name "$VM_NAME" $ACCEL \
		-smp "$VM_CPUS" -m "$VM_RAM" \
		-drive "file=$VM_HOME/disk.qcow2,if=virtio,cache=writeback,discard=unmap" \
		-drive "file=$VM_HOME/seed.img,if=virtio,format=raw,readonly=on" \
		-device virtio-rng-pci \
		-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$SYNC_PORT-:22000" \
		-device virtio-net-pci,netdev=net0 \
		-display none -monitor none -serial "file:$VM_HOME/serial.log" \
		-pidfile "$VM_HOME/qemu.pid" -daemonize
}

wait_ssh(){
	local i
	for i in $(seq 1 100); do
		gssh true 2>/dev/null && return 0
		sleep 3
	done
	printf '\n'
	warn "ssh not up after 5 min; last serial output:"
	tail -20 "$VM_HOME/serial.log" || true
	die "guest did not come up"
}

guest_ready(){
	local i
	for i in $(seq 1 200); do
		gssh 'test -f /var/lib/vworker/system-ok' 2>/dev/null && return 0
		sleep 5
	done
	die "guest system provisioning did not finish; see 'vworker ssh sudo cat /var/log/vworker-provision.log'"
}

# syncthing REST helper for the host side
host_st_cfg(){
	local c
	for c in "$HOME/.config/syncthing/config.xml" "${XDG_STATE_HOME:-$HOME/.local/state}/syncthing/config.xml"; do
		[ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
	done
	die "host syncthing config not found"
}

host_st_api(){
	[ -n "${ST_KEY:-}" ] || ST_KEY="$(sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' "$(host_st_cfg)")"
	[ -n "$ST_KEY" ] || die "no syncthing apikey in $(host_st_cfg)"
	curl -fsS -H "X-API-Key: $ST_KEY" "$@"
}

set_cfg(){ # set_cfg KEY VALUE, appends to the user config without duplicating
	local f="$CFG_DIR/config"
	install -d "$CFG_DIR"
	touch "$f"
	grep -v "^$1=" "$f" >"$f.tmp" || true
	printf '%s=%s\n' "$1" "$2" >>"$f.tmp"
	mv "$f.tmp" "$f"
}

## COMMANDS

cmd_create(){
	local t
	for t in qemu-system-x86_64 qemu-img mkfs.vfat mcopy rsync; do
		command -v "$t" >/dev/null || die "$t missing"
	done
	[ -f "$VM_HOME/disk.qcow2" ] && die "$VM_HOME already holds a VM (use 'vworker start', or 'vworker destroy --yes')"
	install -d "$VM_HOME"
	base_image
	info "creating disk $VM_DISK"
	qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_HOME/disk.qcow2" "$VM_DISK" >/dev/null
	seed_image
	info "booting $VM_NAME"
	qemu_launch
	wait_ssh
	info "waiting for first-boot provisioning (apt + docker + node)"
	guest_ready
	cmd_sync
	cmd_status
	info "done - 'vworker ssh' for a shell, 'vworker sync' after host config changes"
}

cmd_start(){
	running && die "$VM_NAME already running"
	[ -f "$VM_HOME/disk.qcow2" ] || die "no VM in $VM_HOME, run 'vworker create'"
	# the DHCP lease and the hostfwd port are recreated per run: refresh the pinned host key
	rm -f "$VM_HOME/known_hosts"
	qemu_launch
	wait_ssh
	info "$VM_NAME up"
}

cmd_stop(){
	running || die "$VM_NAME not running"
	kill "$(cat "$VM_HOME/qemu.pid")"
	for _ in $(seq 1 20); do running || break; sleep 1; done
	running && warn "still running, sending SIGKILL" && kill -9 "$(cat "$VM_HOME/qemu.pid")"
	rm -f "$VM_HOME/qemu.pid"
	info "$VM_NAME stopped"
}

cmd_sync(){
	running || die "$VM_NAME not running"
	info "pushing host state into the guest"
	gssh "mkdir -p ~/.pi/agent ~/.config/gh ~/.config/glab-cli ~/.config/git ~/.ssh"
	copy "$HOME/.pi/agent/models.json" .pi/agent/models.json
	copy "$HOME/.pi/agent/settings.json" .pi/agent/settings.json
	copy "$HOME/.pi/agent/auth.json" .pi/agent/auth.json
	copy "$HOME/.pi/agent/AGENTS.md" .pi/agent/AGENTS.md
	copy "$HOME/.pi/agent/mcp.json" .pi/agent/mcp.json
	copy "$HOME/.pi/agent/DEVICES.md" .pi/agent/DEVICES.md
	copy "$HOME/.config/gh/hosts.yml" .config/gh/hosts.yml
	copy "$HOME/.config/gh/config.yml" .config/gh/config.yml
	copy "$HOME/.config/glab-cli/config.yml" .config/glab-cli/config.yml
	copy "$HOME/.gitconfig" .gitconfig
	copydir "$HOME/.config/git-private" .config/git-private
	copy "$HOME/.config/git/gitignore_global" .config/git/gitignore_global
	copy "$HOME/.config/git/termux.inc" .config/git/termux.inc
	copy "$REPO/config/aliasrc" .config/aliasrc
	copy "$REPO/config/zshrc.local" .zshrc.local
	copy "$REPO/config/tmux.conf" .tmux.conf

	render "$SRC/guest/provision-user.sh" >"$VM_HOME/provision-user.sh"
	# one env file carries everything the guest needs, secrets included
	{
		printf 'OLLAMA_BASE=%q\n' "$OLLAMA_BASE"
		printf 'SANDBOX_FOLDER_ID=%q\n' "$SANDBOX_FOLDER_ID"
		printf 'SYNC_HOST_DEVICE_ID=%q\n' "$SYNC_HOST_DEVICE_ID"
		printf 'SYNC_HOST_ADDRESS=%q\n' "$SYNC_HOST_ADDRESS"
		[ -n "${TS_AUTHKEY:-}" ] && printf 'TS_AUTHKEY=%q\n' "$TS_AUTHKEY"
		[ -n "${TS_HOSTNAME:-}" ] && printf 'TS_HOSTNAME=%q\n' "$TS_HOSTNAME"
	} >"$VM_HOME/guest.env"
	copy "$VM_HOME/guest.env" .vworker-secrets.env
	copy "$VM_HOME/provision-user.sh" /tmp/vworker-provision-user.sh
	gssh "chmod 600 ~/.vworker-secrets.env 2>/dev/null; sudo -n bash /tmp/vworker-provision-user.sh"
}

cmd_pair_sandbox(){ # cmd_pair_sandbox [host-address-for-guest]
	running || die "$VM_NAME not running"
	local addr="${1:-10.0.2.2:22000}" guest_id my_id devices
	# sync first: the guest writes its syncthing id during user provisioning
	cmd_sync
	guest_id="$(gssh cat .vworker-id 2>/dev/null | tr -d '\r' || true)"
	case "$guest_id" in *-*-*) ;; *) die "could not read a syncthing id from the guest" ;; esac
	my_id="$(host_st_api http://127.0.0.1:8384/rest/system/status | jq -r .myID)"
	[ -n "$my_id" ] || die "could not read the host syncthing id"

	install -d "$SANDBOX_HOST_PATH/.stfolder"
	info "sandbox folder on the host: $SANDBOX_HOST_PATH"

	info "allowing $VM_NAME ($guest_id) into the host syncthing config"
	host_st_api -X PUT -H 'Content-Type: application/json' \
		"http://127.0.0.1:8384/rest/config/devices/$guest_id" \
		-d "$(jq -n --arg id "$guest_id" --arg name "$VM_NAME" --arg a "tcp://127.0.0.1:$SYNC_PORT" \
			'{deviceID:$id,name:$name,addresses:[$a],compression:"metadata"}')"

	# the folder holds this worker and nothing else: no vault, no other devices
	devices="$(jq -n --arg me "$my_id" --arg guest "$guest_id" '[{deviceID:$me},{deviceID:$guest}]')"
	info "creating folder $SANDBOX_FOLDER_ID, shared with the worker only"
	host_st_api -X PUT -H 'Content-Type: application/json' \
		"http://127.0.0.1:8384/rest/config/folders/$SANDBOX_FOLDER_ID" \
		-d "$(jq -n --arg id "$SANDBOX_FOLDER_ID" --arg path "$SANDBOX_HOST_PATH" --argjson dev "$devices" \
			'{id:$id,label:"vworker sandbox",path:$path,type:"sendreceive",devices:$dev,fsWatcherEnabled:true,rescanIntervalS:3600,
			  versioning:{type:"staggered",params:{maxAge:"7776000"},cleanupIntervalS:3600}}')" \
		|| die "could not create the sandbox folder"

	set_cfg SANDBOX_FOLDER_ID "$SANDBOX_FOLDER_ID"
	set_cfg SYNC_HOST_DEVICE_ID "$my_id"
	set_cfg SYNC_HOST_ADDRESS "$addr"
	SYNC_HOST_DEVICE_ID="$my_id"
	SYNC_HOST_ADDRESS="$addr"
	cmd_sync
	info "paired: the worker sees only ~/sandbox, the vault is not shared with it"
}

cmd_ssh(){
	if [ $# -gt 0 ]; then
		gssh "$@"
	else
		exec ssh "${SSH_OPTS[@]}" "$VM_USER@127.0.0.1"
	fi
}

cmd_status(){
	if running; then
		printf '%s  running (pid %s)\n' "$VM_NAME" "$(cat "$VM_HOME/qemu.pid")"
		printf '  ssh:   ssh -i %s -p %s %s@127.0.0.1\n' "$SSH_KEY" "$SSH_PORT" "$VM_USER"
		printf '  state: %s\n' "$VM_HOME"
		if gssh true 2>/dev/null; then
			gssh 'printf "  guest: %s | up %s | disk %s\n" "$(hostname)" "$(uptime -p)" "$(df -h --output=used,size / | tail -1)"'
			gssh 'printf "  ready: %s\n" "$(test -f /var/lib/vworker/system-ok && echo yes || echo provisioning)"'
		else
			printf '  guest: booting\n'
		fi
	else
		printf '%s  stopped (%s)\n' "$VM_NAME" "$VM_HOME"
	fi
}

cmd_logs(){
	tail -n "${1:-40}" "$VM_HOME/serial.log"
}

cmd_destroy(){
	[ "${1:-}" = "--yes" ] || die "this deletes $VM_HOME; re-run with 'vworker destroy --yes'"
	case "$VM_HOME" in /|"$HOME") die "refusing to delete $VM_HOME" ;; esac
	running && cmd_stop
	rm -rf "$VM_HOME"
	info "$VM_NAME destroyed"
}

cmd_help(){
	sed -n '3p' "$0" | sed 's/^# USAGE: /usage: /'
	cat <<'EOF'

  vworker create     download base image, create disk, boot, provision, sync host state
  vworker start      boot an existing worker
  vworker stop       shut it down
  vworker status     running state + guest summary
  vworker ssh [cmd]  shell or one-off command in the worker
  vworker sync       re-push pi/gh/glab/git config and re-run user provisioning
  vworker pair-sandbox [host-address]
                     pair syncthing with the host and share the worker's own sandbox
                     folder, nothing else (default host-address 10.0.2.2:22000 for the
                     local QEMU worker, use host:22000 on a tailnet)
  vworker logs [n]   serial console tail
  vworker destroy --yes

Config:  ~/.config/vworker/config   (VM_RAM, VM_DISK, VM_NAME, OLLAMA_BASE,
                                    SANDBOX_HOST_PATH, SANDBOX_FOLDER_ID, ...)
Secrets: ~/.config/vworker/secrets.env  (TS_AUTHKEY, SYNC_HOST_DEVICE_ID, SYNC_HOST_ADDRESS)
EOF
}

## MAIN

case "${1:-help}" in
	create) cmd_create ;;
	start) cmd_start ;;
	stop) cmd_stop ;;
	restart) cmd_stop; cmd_start ;;
	status) cmd_status ;;
	ssh) shift; cmd_ssh "$@" ;;
	pair-sandbox) shift; cmd_pair_sandbox "$@" ;;
	sync) cmd_sync ;;
	logs) shift; cmd_logs "${1:-40}" ;;
	destroy) shift; cmd_destroy "${1:-}" ;;
	-h|--help|help) cmd_help ;;
	*) die "unknown command '$1' (see 'vworker help')" ;;
esac
