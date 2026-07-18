#!/usr/bin/env bash
# One-time setup: provisions auth, builds image, installs sandbox.sh.
set -euo pipefail

die() { echo -e "\e[31merror:\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[36m>\e[0m $*"; }

CONFIG_VOLUME=agent-sandbox-config
IMAGE=agent-sandbox
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# --- git identity ---
if ! git config --global user.name >/dev/null 2>&1; then
	read -rp "Git name (for commits inside sandbox): " GIT_NAME
	git config --global user.name "$GIT_NAME"
fi
if ! git config --global user.email >/dev/null 2>&1; then
	read -rp "Git email: " GIT_EMAIL
	git config --global user.email "$GIT_EMAIL"
fi

# --- config volume ---
info "Creating config volume '$CONFIG_VOLUME'..."
docker volume create "$CONFIG_VOLUME" >/dev/null

# Helper: copy host path into volume via a temporary container
copy_to_volume() {
	local src="$1" vol_path="$2"
	[ -e "$src" ] || return 0
	docker run --rm -v "$CONFIG_VOLUME:/data" -v "$(dirname "$(readlink -f "$src")"):/src:ro" \
		alpine cp -r "/src/$(basename "$src")" "/data/$vol_path" 2>/dev/null || true
}

info "Copying auth from host..."
copy_to_volume "$HOME/.claude/.credentials.json" "claude/credentials.json"
copy_to_volume "$HOME/.claude/CLAUDE.md" "claude/CLAUDE.md"
copy_to_volume "$HOME/.pi" "pi"
copy_to_volume "$HOME/.codex" "codex"
copy_to_volume "$HOME/.config/gh" "gh"
copy_to_volume "$HOME/.config/glab-cli" "glab-cli"
copy_to_volume "$HOME/.gitconfig" "gitconfig"
copy_to_volume "$HOME/.config/git" "git"
copy_to_volume "$HOME/.config/git-private" "git-private"

# --- build image ---
info "Building image '$IMAGE'..."
cd "$REPO_DIR"
docker buildx bake --load

# --- install sandbox.sh ---
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"
\cp "$REPO_DIR/sandbox.sh" "$INSTALL_DIR/sandbox.sh"
chmod +x "$INSTALL_DIR/sandbox.sh"

info "Done! Run 'sandbox.sh' in any project directory."
echo "  sandbox.sh              # interactive shell"
echo "  sandbox.sh claude       # Claude Code"
echo "  sandbox.sh pi           # pi coding agent"
echo "  sandbox.sh npm test     # any command"
