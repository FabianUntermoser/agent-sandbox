#!/usr/bin/env bash

# USAGE: one-time setup, build image, install sandbox.sh to PATH

set -euo pipefail

die() { echo -e "\e[31merror:\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[36m>\e[0m $*"; }

## DEFAULTS

IMAGE=agent-sandbox
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

## MAIN

cd "$REPO_DIR"
IMAGE="$IMAGE" "$REPO_DIR/scripts/image-build.sh"

INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"
\cp "$REPO_DIR/scripts/sandbox.sh" "$INSTALL_DIR/sandbox.sh"
\cp "$REPO_DIR/scripts/sandbox-panes.sh" "$INSTALL_DIR/sandbox-panes.sh"
chmod +x "$INSTALL_DIR/sandbox.sh" "$INSTALL_DIR/sandbox-panes.sh"
# what a sandbox inherits, read at run time so editing it needs no rebuild.
# the repo copy stays the source of truth, so this install overwrites it.
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox"
mkdir -p "$CONF_DIR"
\cp "$REPO_DIR/config/base.conf" "$CONF_DIR/base.conf"
# The tool catalogue: one data file per tool, read at run time and granted by TOOLS in the manifest.
if [ -d "$REPO_DIR/config/tools.d" ]; then
	mkdir -p "$CONF_DIR/tools.d"
	for conf in "$REPO_DIR"/config/tools.d/*.conf; do
		[ -f "$conf" ] && \cp "$conf" "$CONF_DIR/tools.d/"
	done
fi
# the permission policy a sandboxed pi starts with, copied into each project that has none.
\cp "$REPO_DIR/config/pi-permission-policy.json" "$CONF_DIR/pi-permission-policy.json"
\cp "$REPO_DIR/config/sandbox-gitignore" "$CONF_DIR/gitignore"

# A sandbox commits, so git in there needs an identity and an excludes file. Both live in this one
# generated file rather than in the operator's ~/.gitconfig, which carries a credential helper and
# is mounted only with GIT_AUTH. sandbox.sh points GIT_CONFIG_GLOBAL at it, so a project's own
# .git/config still wins where it sets one.
git_name="$(git -C /tmp config user.name 2>/dev/null || true)"
git_email="$(git -C /tmp config user.email 2>/dev/null || true)"
if [ -n "$git_name" ] && [ -n "$git_email" ]; then
	{
		printf '[user]\n\tname = %s\n\temail = %s\n' "$git_name" "$git_email"
		printf '[core]\n\texcludesFile = ~/.config/agent-sandbox/gitignore\n'
	} >"$CONF_DIR/gitconfig"
	info "git identity for sandboxes: $git_name <$git_email>"
else
	rm -f "$CONF_DIR/gitconfig"
	info "no git identity on this host, so a sandbox commits with none"
fi

info "Done. Run 'sandbox.sh' in any project directory."
