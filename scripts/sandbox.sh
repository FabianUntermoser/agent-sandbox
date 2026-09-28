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
		  --stdio                    stdio straight through, no tmux (paseo provider)
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
GIT_AUTH=true
MOUNTS=()


## ARGS

FORCE_NEW=
VERBOSE=
OFFLINE=
STDIO=
VERSION_PROBE=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h|--help) help; exit ;;
		--version) VERSION_PROBE=1; shift ;;
		--new)     FORCE_NEW=1; shift ;;
		--offline) OFFLINE=1; shift ;;
		--stdio)   STDIO=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		--)        shift; break ;;
		-*)        die "unknown flag $1" ;;
		*)         break ;;
	esac
done

## MAIN

# paseo asks for '<command> --version' before it launches anything and drops the
# rest of the configured argv, so the probe answers with the pi the image carries
# rather than with a flag this script does not know.
if [ -n "$VERSION_PROBE" ]; then
	STDIO=1
	set -- pi --version
fi

SESSION=${1:-shell}
case "${1:-}" in
	"")        set -- zsh ;;
	claude)    set -- claude --dangerously-skip-permissions "${@:2}" ;;
	pi)        set -- bash -c 'export PATH=$HOME/.npm-global/bin:$PATH; exec pi "$@"' bash "${@:2}" ;;
	ollama)    set -- bash -c 'export PATH=$HOME/.npm-global/bin:$PATH; exec ollama "$@"' bash "${@:2}" ;;
esac
if [ -z "$VERBOSE" ] && [ -z "$STDIO" ]; then
	set -- tmux new-session -A -s "$SESSION" "$@"
fi

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image '$IMAGE' not found - run 'make build' in agent-sandbox repo"

WORK=$PWD

# Paseo probes a provider once with the caller's home as the working directory.
# No host home is mounted for that run: the container keeps its own home, and the
# probe, which asks for models, does not need the host files to answer.
if [ -n "$STDIO" ] && [ "$WORK" = "$HOME" ]; then
	WORK="/home/$RUSER"
fi

if [ "$WORK" = "$HOME" ] || [ -e "$WORK/.ssh" ] || [ -e "$WORK/.gnupg" ]; then
	die "refusing to mount '$WORK' — it is \$HOME or holds .ssh/.gnupg."
fi
KEY=$(printf '%s' "$WORK" | sed 's#[^a-zA-Z0-9]#-#g')
PROJ="$HOME/.claude/projects/$KEY"
mkdir -p "$PROJ/memory"
NAME="sandbox-$(printf '%s' "${WORK##*/}" | sed 's#[^a-zA-Z0-9_.-]#-#g')"

# -- Pi project trust --------------------------------------------------------

# pi asks for project trust the first time it runs in a directory that holds
# project resources. The sandbox mounts the project at its own path, so writing
# that path into the trust store here means the container inherits the decision
# instead of stopping at the prompt.
seed_pi_trust() {
	[ "$SESSION" = pi ] || return 0
	case " ${*:-} " in *" -na "*|*" --no-approve "*) return 0 ;; esac
	local store="${PI_TRUST_FILE:-$HOME/.pi/agent/trust.json}"
	command -v jq >/dev/null 2>&1 || return 0
	[ "$(jq -r --arg w "$WORK" '.[$w] // empty' "$store" 2>/dev/null)" = true ] && return 0
	mkdir -p "${store%/*}"
	[ -f "$store" ] || echo '{}' >"$store"
	jq --arg w "$WORK" '. + {($w): true}' "$store" >"$store.tmp" || { rm -f "$store.tmp"; return 0; }
	mv "$store.tmp" "$store"
	echo "pi: trusted '$WORK', project resources may load" >&2
}
seed_pi_trust "$@"

# Load per-project manifest
if [ -f "$WORK/$MANIFEST" ]; then
	source "$WORK/$MANIFEST"
fi

# Attaching is for a human who reopens a project. A paseo launch owns its own
# session and its stdin is a pipe, so it always gets a fresh container.
if [ -z "$FORCE_NEW" ] && [ -z "$STDIO" ] && docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
	echo "Attaching to '$NAME' ('$prog --new' forces a fresh one)…" >&2
	exec docker exec -it -e "COLORTERM=${COLORTERM:-truecolor}" -w "$WORK" "$NAME" "$@"
fi
n=2; base=$NAME
while docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; do NAME="$base-$n"; n=$((n+1)); done

mounts=()

# -- Mount helpers -----------------------------------------------------------

declare -A _seen_mounts=()

add_mount() {
	local src=$1 dest=$2 mode=${3:-}
	# explicit 0: a bare return would hand back the failed test's status and
	# `set -e` ends the run when this is the last command of a loop body
	[ -e "$src" ] || return 0
	src=$(readlink -f "$src") || return 0
	# docker refuses two mounts on one destination, whatever their source or mode
	# is, so the destination alone is what may appear once
	[ -n "${_seen_mounts[$dest]:-}" ] && return
	_seen_mounts[$dest]=1
	mounts+=(-v "$src:$dest${mode:+:$mode}")
}

mount_dir()  { if [ -d "$1" ]; then add_mount "$1" "$2" "${3:-}"; fi; }
mount_file() { if [ -f "$1" ]; then add_mount "$1" "$2" "${3:-}"; fi; }

# The project comes first: it owns its own destination. It goes through the same
# helper as everything else, which resolves a symlinked workdir and keeps a later
# entry from mounting the same destination twice.
mount_dir "$WORK" "$WORK"

# Mount symlink targets that resolve outside the source directory
mount_symlink_targets() {
	local src=$1 container_prefix=$2 mode=${3:-}
	[ -d "$src" ] || return 0
	local src_real link rel target_real
	src_real=$(readlink -f "$src") || return 0
	while IFS= read -r -d '' link; do
		target_real=$(readlink -f "$link") || continue
		# skip when the symlink resolves to the entry itself (a symlinked entry like
		# ~/.config/git-private has no children of its own) or stays inside it
		case "$target_real" in "$src_real" | "$src_real"/*) continue ;; esac
		# rel comes off $src, not off the resolved directory: entries like
		# ~/.config/git-private are symlinks into the repos themselves and the
		# container path has to mirror what the entry says
		rel=${link#"$src"/}
		add_mount "$target_real" "$container_prefix/$rel" "$mode"
	done < <(find "$src" -type l -print0 2>/dev/null)
}

# -- Agent mounts (controlled by manifest) -----------------------------------

has_agent() {
	local name=$1; shift
	for a in $AGENTS; do [ "$a" = "$name" ] && return 0; done
	return 1
}

# -- Base environment (config/base.conf) -------------------------------------

BASE_CONF="${BASE_CONF:-$HOME/.config/agent-sandbox/base.conf}"
[ -f "$BASE_CONF" ] || die "no base environment at '$BASE_CONF' - run 'make setup' in agent-sandbox"

# what a project symlink may never hand to a sandbox even though the project asks
# for it: the curated knowledge layers and the keys. ~/notes/work is fine, agent
# notes live there. An explicit MOUNTS line in .sandbox.conf still wins.
# Resolved up front: the vault is a symlink to its synced copy on this host, so the
# home spelling and the real path both have to be refused.
VAULT=$(readlink -f "$HOME/notes" 2>/dev/null || true)
deny_self=("$HOME" "$(readlink -f "$HOME")" "$HOME/notes")
deny_tree=("$HOME/.ssh" "$HOME/.gnupg")
vault_roots=("$HOME/notes")
for d in "$HOME/.ssh" "$HOME/.gnupg"; do
	r=$(readlink -f "$d" 2>/dev/null || true)
	[ -n "$r" ] && deny_tree+=("$r")
done
if [ -n "$VAULT" ]; then
	deny_self+=("$VAULT")
	vault_roots+=("$VAULT")
fi

denied() {
	local p r v
	p=$1
	r=$(readlink -f "$p" 2>/dev/null) || return 1
	for v in "${deny_self[@]}"; do
		[ "$p" = "$v" ] || [ "$r" = "$v" ] && return 0
	done
	for v in "${deny_tree[@]}"; do
		case "$p" in "$v" | "$v"/*) return 0 ;; esac
		case "$r" in "$v" | "$v"/*) return 0 ;; esac
	done
	# the vault: everything below it is refused except the work layer the agents write
	for v in "${vault_roots[@]}"; do
		case "$r" in
		"$v/work" | "$v/work"/*) return 1 ;;
		"$v"/*) return 0 ;;
		esac
	done
	return 1
}

# the agent a base entry belongs to, so AGENTS in the project manifest can drop it
agent_of() {
	case "$1" in
	"$HOME/.pi") printf pi ;;
	"$HOME/.claude") printf claude ;;
	"$HOME/.codex") printf codex ;;
	esac
}

while read -r kind path opts; do
	case "$kind" in '' | \#*) continue ;; esac
	path="${path/#\~/$HOME}"
	case "$path" in "$HOME"/*) ;; *) die "base entry outside \$HOME: $path" ;; esac

	mode= want_auth=0
	for o in $opts; do
		case "$o" in
		ro) mode=ro ;;
		auth) want_auth=1 ;;
		exclude=*) ;; # guest side, see vworker.sh
		*) die "unknown base option '$o' on '$path'" ;;
		esac
	done

	if ! [ -e "$path" ]; then
		echo "  not on this host: ${path#"$HOME"/}" >&2
		continue
	fi
	if [ "$want_auth" = 1 ] && [ "$GIT_AUTH" != true ]; then
		echo "  credentials off: ${path#"$HOME"/}" >&2
		continue
	fi

	agent=$(agent_of "$path")
	if [ -n "$agent" ] && ! has_agent "$agent"; then
		echo "  agent off: ${path#"$HOME"/}" >&2
		continue
	fi
	# claude is narrowed on purpose: a sandbox sees the history of its own project
	if [ "$agent" = claude ]; then
		mount_file "$HOME/.claude/.credentials.json" "/home/$RUSER/.claude/.credentials.json" "$mode"
		mounts+=(-v "$PROJ:/home/$RUSER/.claude/projects/$KEY")
		continue
	fi

	dest="/home/$RUSER/${path#"$HOME"/}"
	case "$kind" in
	dir)
		mount_dir "$path" "$dest" "$mode"
		mount_symlink_targets "$path" "$dest" "$mode"
		;;
	file) mount_file "$path" "$dest" "$mode" ;;
	*) die "unknown base entry kind '$kind' in $BASE_CONF" ;;
	esac
done <"$BASE_CONF"

# No per-skill mount: pi discovers ~/.agents/skills on its own, which is how the
# host sees them. Mounting each one at the same path under ~/.pi made docker
# create the target on the host, root-owned and empty, inside the mounted ~/.pi;
# the guard then found "a directory" on every later run and skipped the mount, so
# those skills went missing in the container instead.

# Additional mounts from manifest
for m in "${MOUNTS[@]}"; do
	src=${m%%:*}
	dest=${m#*:}
	add_mount "$src" "$dest"
done

# Project symlinks are the manifest of what this project needs besides its own
# tree, so they are followed. The exceptions above are refused and reported.
SYMLINKS=()
REFUSED=()
WORK_REAL=$(readlink -f "$WORK")
while IFS= read -r -d '' link; do
	target=$(readlink -f "$link") || continue
	[ -n "$target" ] && [ -e "$target" ] || continue
	# find prints its own start point when the workdir itself is a symlink, and
	# that one is already mounted as the project
	[ "$target" = "$WORK_REAL" ] && continue
	if denied "$target"; then
		REFUSED+=("${link#"$WORK"/} -> $target")
		continue
	fi
	mounts+=(-v "$target:$link")
	SYMLINKS+=("${link#"$WORK"/} -> $target")
done < <(find "$WORK" -maxdepth 1 -type l -print0 2>/dev/null)

echo -e "\e[1m${WORK##*/}\e[0m" >&2
if [ ${#SYMLINKS[@]} -gt 0 ]; then
	echo -e "  \e[1msymlinks:\e[0m" >&2
	for s in "${SYMLINKS[@]}"; do echo "    $s" >&2; done
fi
if [ ${#REFUSED[@]} -gt 0 ]; then
	echo -e "  \e[1mrefused (knowledge/keys, add a MOUNTS line to override):\e[0m" >&2
	for s in "${REFUSED[@]}"; do echo "    $s" >&2; done
fi
echo "" >&2

# -- Paseo's stdio launch ----------------------------------------------------

# Paseo spawns the agent as its own child and hands it two files it made on this
# host: a merged mcp.json and its integration extension. Both arrive as paths in
# the argv, so they are mounted at their own path or the container cannot read
# them. Path args are scanned from a copy, never from "$@": a shift here would
# eat the command the container is supposed to run.
if [ -n "$STDIO" ]; then
	argv=("$@")
	i=0
	while [ "$i" -lt "${#argv[@]}" ]; do
		arg="${argv[$i]}"
		case "$arg" in
		--mcp-config|--extension)
			i=$((i + 1))
			p="${argv[$i]:-}"
			if [ -n "$p" ]; then add_mount "$p" "$p" ro; fi
			;;
		--mcp-config=*|--extension=*)
			add_mount "${arg#*=}" "${arg#*=}" ro
			;;
		esac
		i=$((i + 1))
	done
	unset argv
fi

# A worktree's .git is a file naming the main checkout's .git/worktrees/<slug>,
# so without that checkout mounted every git call in the container resolves a
# path that is not there. The worktree itself stays the working directory.
if [ -f "$WORK/.git" ]; then
	common=$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	main=${common%/.git}
	if [ -n "$main" ] && [ -d "$main" ] && [ "$main" != "$WORK" ]; then
		add_mount "$main" "$main"
	fi
fi

TTY_FLAG="-t"
if [ -n "$STDIO" ]; then
	# pipes, not a tty: a tty echoes the request stream and rewrites its endings
	TTY_FLAG="-i"
elif [ -t 0 ]; then
	TTY_FLAG="-it"
fi

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
