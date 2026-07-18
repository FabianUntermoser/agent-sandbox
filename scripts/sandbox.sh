#!/usr/bin/env bash
# Throwaway, network-firewalled dev container for the current project.
# Mounts $PWD at its real host path; runs any command (default: shell).
# See README.md for full docs.

set -euo pipefail

prog=${0##*/}
die() { echo -e "\e[31merror:\e[0m $*" >&2; exit 1; }
help() {
	cat <<-EOF
		$prog — firewalled dev container for \$PWD

		  $prog                      interactive shell
		  $prog <command...>         run any command
		  $prog claude [args]        Claude Code
		  $prog pi [args]            pi coding agent
		  $prog ollama launch <agent> [--model <m>]   agent on local models
		  --new                      force a fresh container
		  -v, --verbose              run without tmux
		  --build                    rebuild the image
	EOF
}

IMAGE=agent-sandbox
RUSER=node
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

FORCE_NEW=
VERBOSE=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h|--help) help; exit ;;
		--build)   cd "$REPO_DIR" && docker buildx bake --load; exit ;;
		--new)     FORCE_NEW=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		--)        shift; break ;;
		-*)        die "unknown flag $1" ;;
		*)         break ;;
	esac
done

SESSION=${1:-shell}
OLLAMA_PRELUDE='ollama serve >/tmp/ollama-serve.log 2>&1 & for i in $(seq 30); do ollama ps >/dev/null 2>&1 && break; sleep 0.3; done; exec '
case "${1:-}" in
	"")        set -- zsh ;;
	claude)    set -- claude --dangerously-skip-permissions "${@:2}" ;;
	pi)        : ;;
	ollama)    set -- bash -lc "$OLLAMA_PRELUDE$*" ;;
esac
[ -z "$VERBOSE" ] && set -- tmux new-session -A -s "$SESSION" "$@"

docker image inspect "$IMAGE" >/dev/null 2>&1 || { cd "$REPO_DIR" && docker buildx bake --load; }

WORK=$PWD
if [ "$WORK" = "$HOME" ] || [ -e "$WORK/.ssh" ] || [ -e "$WORK/.gnupg" ]; then
	die "refusing to mount '$WORK' — it is \$HOME or holds .ssh/.gnupg."
fi
KEY=$(printf '%s' "$WORK" | sed 's#[^a-zA-Z0-9]#-#g')
PROJ="$HOME/.claude/projects/$KEY"
mkdir -p "$PROJ/memory"
NAME="sandbox-$(printf '%s' "${WORK##*/}" | sed 's#[^a-zA-Z0-9_.-]#-#g')"

if [ -z "$FORCE_NEW" ] && docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
	echo "Attaching to '$NAME' ('$prog --new' forces a fresh one)…" >&2
	exec docker exec -it -e "COLORTERM=${COLORTERM:-truecolor}" -w "$WORK" "$NAME" "$@"
fi
n=2; base=$NAME
while docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; do NAME="$base-$n"; n=$((n+1)); done

mounts=(-v "$WORK:$WORK")

# Mount auth/config directly from host
[ -f "$HOME/.claude/.credentials.json" ] && mounts+=(-v "$HOME/.claude/.credentials.json:/home/$RUSER/.claude/.credentials.json")
[ -f "$HOME/.claude/CLAUDE.md" ] && mounts+=(-v "$HOME/.claude/CLAUDE.md:/home/$RUSER/.claude/CLAUDE.md:ro")
[ -d "$HOME/.pi" ] && mounts+=(-v "$HOME/.pi:/home/$RUSER/.pi")
[ -d "$HOME/.codex" ] && mounts+=(-v "$HOME/.codex:/home/$RUSER/.codex")
[ -d "$HOME/.config/gh" ] && mounts+=(-v "$HOME/.config/gh:/home/$RUSER/.config/gh:ro")
[ -d "$HOME/.config/glab-cli" ] && mounts+=(-v "$HOME/.config/glab-cli:/home/$RUSER/.config/glab-cli:ro")
[ -f "$HOME/.gitconfig" ] && mounts+=(-v "$HOME/.gitconfig:/home/$RUSER/.gitconfig:ro")
[ -d "$HOME/.config/git" ] && mounts+=(-v "$HOME/.config/git:/home/$RUSER/.config/git:ro")
[ -d "$HOME/.config/git-private" ] && mounts+=(-v "$HOME/.config/git-private:/home/$RUSER/.config/git-private:ro")

# Claude project dir (per-folder convos + memory)
mounts+=(-v "$PROJ:/home/$RUSER/.claude/projects/$KEY")

echo "sandbox: $WORK" >&2

exec docker run --rm -it \
	--name "$NAME" \
	--cap-add=NET_ADMIN --cap-add=NET_RAW \
	--hostname sandbox \
	-e "COLORTERM=${COLORTERM:-truecolor}" \
	-e DISABLE_AUTOUPDATER=1 \
	-e DISABLE_TELEMETRY=1 \
	-w "$WORK" \
	"${mounts[@]}" \
	"$IMAGE" "$@"
