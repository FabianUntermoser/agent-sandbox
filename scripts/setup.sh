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
chmod +x "$INSTALL_DIR/sandbox.sh"

info "Done. Run 'sandbox.sh' in any project directory."
