#!/usr/bin/env bash

# USAGE: one-time setup — build image, install sandbox.sh to PATH

set -euo pipefail

die() { echo -e "\e[31merror:\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[36m>\e[0m $*"; }

## DEFAULTS

IMAGE=agent-sandbox
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

## MAIN

info "Building image '$IMAGE'..."
cd "$REPO_DIR"
docker buildx bake --load

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

info "Done. Run 'sandbox.sh' in any project directory."
