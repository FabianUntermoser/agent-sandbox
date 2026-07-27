#!/usr/bin/env bash

# USAGE: firewalled dev container for $PWD — mounts project, runs any command

set -euo pipefail

prog=${0##*/}
die() { printf "\e[31merror:\e[0m %s\n" "$*" >&2; exit 1; }
help() {
	cat <<-EOF
		$prog — dev container for \$PWD

		  $prog                      interactive shell
		  $prog <command...>         run any command
		  $prog claude [args]        Claude Code
		  $prog pi [args]            pi coding agent
		  --new                      force a fresh container
		  --offline                   restrict network to allowlist only
		  -v, --verbose              run without tmux
	EOF
}

## DEFAULTS

IMAGE=agent-sandbox
RUSER=node

# Per-project manifest (sourced if exists)
MANIFEST=".sandbox.conf"

# Defaults (overridden by manifest)
AGENTS="pi claude codex"
MERGE_AGENTS_SKILLS=true
GIT_AUTH=true
MOUNTS=()


## ARGS

FORCE_NEW=
VERBOSE=
OFFLINE=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h|--help) help; exit ;;
		--new)     FORCE_NEW=1; shift ;;
		--offline) OFFLINE=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		--)        shift; break ;;
		-*)        die "unknown flag $1" ;;
		*)         break ;;
	esac
done

## MAIN

SESSION=${1:-shell}
case "${1:-}" in
	"")        set -- zsh ;;
	claude)    set -- claude --dangerously-skip-permissions "${@:2}" ;;
	pi)        set -- bash -c "export PATH=\$HOME/.npm-global/bin:\$PATH; exec pi" ;;
	ollama)    set -- bash -c "export PATH=\$HOME/.npm-global/bin:\$PATH; exec \$@" bash "${@:2}" ;;
esac
[ -z "$VERBOSE" ] && set -- tmux new-session -A -s "$SESSION" "$@"

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image '$IMAGE' not found - run 'make build' in agent-sandbox repo"

WORK=$PWD
if [ "$WORK" = "$HOME" ] || [ -e "$WORK/.ssh" ] || [ -e "$WORK/.gnupg" ]; then
	die "refusing to mount '$WORK' — it is \$HOME or holds .ssh/.gnupg."
fi
KEY=$(printf '%s' "$WORK" | sed 's#[^a-zA-Z0-9]#-#g')
PROJ="$HOME/.claude/projects/$KEY"
mkdir -p "$PROJ/memory"
NAME="sandbox-$(printf '%s' "${WORK##*/}" | sed 's#[^a-zA-Z0-9_.-]#-#g')"

# Load per-project manifest
if [ -f "$WORK/$MANIFEST" ]; then
	source "$WORK/$MANIFEST"
fi

if [ -z "$FORCE_NEW" ] && docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
	echo "Attaching to '$NAME' ('$prog --new' forces a fresh one)…" >&2
	exec docker exec -it -e "COLORTERM=${COLORTERM:-truecolor}" -w "$WORK" "$NAME" "$@"
fi
n=2; base=$NAME
while docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; do NAME="$base-$n"; n=$((n+1)); done

mounts=(-v "$WORK:$WORK")

# -- Mount helpers -----------------------------------------------------------

declare -A _seen_mounts=()

add_mount() {
	local src=$1 dest=$2
	[ -e "$src" ] || return
	src=$(readlink -f "$src") || return
	local key="$src:$dest"
	[ -n "${_seen_mounts[$key]:-}" ] && return
	_seen_mounts[$key]=1
	mounts+=(-v "$src:$dest")
}

mount_dir()  { [ -d "$1" ] && add_mount "$1" "$2"; }
mount_file() { [ -f "$1" ] && add_mount "$1" "$2"; }

# Mount symlink targets that resolve outside the source directory
mount_symlink_targets() {
	local src=$1 container_prefix=$2
	[ -d "$src" ] || return
	local src_real link rel target_real
	src_real=$(readlink -f "$src") || return
	while IFS= read -r -d '' link; do
		target_real=$(readlink -f "$link") || continue
		case "$target_real" in "$src_real"/*) continue ;; esac
		rel=${link#$src_real/}
		add_mount "$target_real" "$container_prefix/$rel"
	done < <(find "$src" -type l -print0 2>/dev/null)
}

# -- Agent mounts (controlled by manifest) -----------------------------------

has_agent() {
	local name=$1; shift
	for a in $AGENTS; do [ "$a" = "$name" ] && return 0; done
	return 1
}

if has_agent claude; then
	mount_file "$HOME/.claude/.credentials.json" "/home/$RUSER/.claude/.credentials.json"
	mounts+=(-v "$PROJ:/home/$RUSER/.claude/projects/$KEY")
fi

if has_agent pi; then
	mount_dir "$HOME/.pi" "/home/$RUSER/.pi"
	mount_symlink_targets "$HOME/.pi" "/home/$RUSER/.pi"
	mount_dir "$HOME/.agents" "/home/$RUSER/.agents"

	if [ "$MERGE_AGENTS_SKILLS" = "true" ] && [ -d "$HOME/.agents/skills" ]; then
		for skill in "$HOME/.agents/skills"/*/; do
			name=${skill%/}; name=${name##*/}
			[ ! -d "$HOME/.pi/agent/skills/$name" ] && mount_dir "$skill" "/home/$RUSER/.pi/agent/skills/$name"
		done
	fi
fi

if has_agent codex; then
	mount_dir "$HOME/.codex" "/home/$RUSER/.codex"
fi

# Git auth
if [ "$GIT_AUTH" = "true" ]; then
	mount_dir "$HOME/.config/gh"         "/home/$RUSER/.config/gh:ro"
	mount_dir "$HOME/.config/glab-cli"   "/home/$RUSER/.config/glab-cli:ro"
	mount_file "$HOME/.gitconfig"        "/home/$RUSER/.gitconfig:ro"
	mount_dir "$HOME/.config/git"        "/home/$RUSER/.config/git:ro"
	mount_dir "$HOME/.config/git-private" "/home/$RUSER/.config/git-private:ro"
fi

# Additional mounts from manifest
for m in "${MOUNTS[@]}"; do
	src=${m%%:*}
	dest=${m#*:}
	add_mount "$src" "$dest"
done

# Dynamically mount symlink targets from $PWD
SYMLINKS=()
while IFS= read -r -d '' link; do
	target=$(readlink -f "$link")
	[ -n "$target" ] && [ -e "$target" ] && mounts+=(-v "$target:$link") && SYMLINKS+=("$link -> $target")
done < <(find "$WORK" -maxdepth 1 -type l -print0 2>/dev/null)

echo -e "\e[1m${WORK##*/}\e[0m" >&2
if [ ${#SYMLINKS[@]} -gt 0 ]; then
	echo -e "  \e[1msymlinks:\e[0m" >&2
	for s in "${SYMLINKS[@]}"; do
		name="${s#"$WORK/"}"
		echo "    $name" >&2
	done
fi
echo "" >&2

TTY_FLAG="-t"
[ -t 0 ] && TTY_FLAG="-it"

if [ -n "$OFFLINE" ]; then
	exec docker run --rm $TTY_FLAG \
		--name "$NAME" \
		--cap-add=NET_ADMIN --cap-add=NET_RAW \
		--hostname sandbox \
		-e "COLORTERM=${COLORTERM:-truecolor}" \
		-e DISABLE_AUTOUPDATER=1 \
		-e DISABLE_TELEMETRY=1 \
		-w "$WORK" \
		"${mounts[@]}" \
		--entrypoint /bin/bash \
		"$IMAGE" \
		-c "sudo /usr/local/bin/init-firewall.sh && exec \"\$@\"" bash "$@"
else
	exec docker run --rm $TTY_FLAG \
		--name "$NAME" \
		--network=host \
		--hostname sandbox \
		-e "COLORTERM=${COLORTERM:-truecolor}" \
		-e DISABLE_AUTOUPDATER=1 \
		-e DISABLE_TELEMETRY=1 \
		-w "$WORK" \
		"${mounts[@]}" \
		"$IMAGE" "$@"
fi
