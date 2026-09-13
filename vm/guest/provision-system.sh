#!/usr/bin/env bash

# USAGE: first-boot system provisioning inside the vworker guest (cloud-init, root)

set -euo pipefail

exec > >(tee -a /var/log/vworker-provision.log) 2>&1

info(){ echo -e "\e[36m>\e[0m $*"; }
warn(){ echo -e "\e[33m!\e[0m $*" >&2; }

VM_USER=__VM_USER__
MARKER=/var/lib/vworker/system-ok

## USER LAYOUT

info "user layout for $VM_USER"
install -d -o "$VM_USER" -g "$VM_USER" /home/"$VM_USER"/{repos,work}
install -d -o "$VM_USER" -g "$VM_USER" /usr/local/share/npm-global
usermod -aG docker,sudo "$VM_USER"

## DOCKER

info "docker"
systemctl enable --now docker
# the guest owns its kernel, so docker runs natively: devcontainers, privileged jobs, no host socket

## NODE

# trixie ships node 20, but pi imports globSync from node:fs (22+). The
# official tarball lands in /usr/local, which wins over /usr/bin on PATH.
info "node"
case "$(dpkg --print-architecture)" in arm64) narch=arm64 ;; *) narch=x64 ;; esac
nver="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')"
if curl -fsSL "https://nodejs.org/dist/$nver/node-$nver-linux-$narch.tar.xz" | tar -xJ -C /usr/local --strip-components=1; then
	info "node $nver installed"
else
	warn "node tarball failed, falling back to trixie node 20 (pi will not start)"
	apt-get install -y nodejs npm
fi

## AGENT CLIS

info "agent CLIs"
npm install -g --silent @earendil-works/pi-coding-agent @devcontainers/cli
chown -R "$VM_USER:$VM_USER" /usr/local/share/npm-global

# gh comes from trixie main; glab has no Debian package, so it lands as the
# upstream release binary (the vendor installer asks questions cloud-init
# cannot answer)
info "glab"
arch="$(dpkg --print-architecture)"
ver="$(curl -fsSL 'https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest' | jq -r .tag_name)"
if curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/$ver/downloads/glab_${ver#v}_linux_$arch.tar.gz" \
	| tar -xz -C /tmp bin/glab; then
	install -m 0755 /tmp/bin/glab /usr/local/bin/glab
	rm -rf /tmp/bin
else
	warn "glab install failed"
fi

## TAILSCALE

# Debian ships tailscale in main; fall back to the vendor script when the repo lags
info "tailscale"
if ! apt-get install -y tailscale; then
	warn "apt tailscale unavailable, using vendor installer"
	curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

## SYNCTHING

info "syncthing"
loginctl enable-linger "$VM_USER"
runuser -u "$VM_USER" -- env \
	XDG_RUNTIME_DIR="/run/user/$(id -u "$VM_USER")" \
	systemctl --user enable --now syncthing || warn "syncthing user service did not start yet"

## MARKER

install -d /var/lib/vworker
{
	date -Is
	printf 'user=%s\n' "$VM_USER"
	printf 'pi=%s\n' "$(npm ls -g --depth=0 @earendil-works/pi-coding-agent 2>/dev/null | awk '/pi-coding-agent/{print $2}')"
	printf 'docker=%s\n' "$(docker --version)"
	printf 'node=%s\n' "$(node -v)"
	printf 'tailscale=%s\n' "$(tailscale version | head -1)"
	printf 'syncthing=%s\n' "$(syncthing --version | awk '{print $2}')"
	printf 'gh=%s\n' "$(gh --version | head -1 | awk '{print $3}')"
	printf 'glab=%s\n' "$(glab --version | awk '/glab version/{print $3}')"
} >"$MARKER"

info "system provisioning done"
