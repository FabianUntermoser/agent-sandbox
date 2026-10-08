#!/usr/bin/env bash

# USAGE: firewalled dev container for $PWD, mounts project, runs any command

set -euo pipefail

prog=${0##*/}
die() { printf "\e[31merror:\e[0m %s\n" "$*" >&2; exit 1; }
help() {
	cat <<-EOF
		$prog, dev container for \$PWD

		  $prog                      interactive shell
		  $prog <command...>         run any command
		  $prog claude [args]        Claude Code
		  $prog pi [args]            pi coding agent
		  --stdio                    stdio straight through, no tmux (paseo provider)
		  --manifest <path>          manifest to source instead of $PWD/.sandbox.conf; a path
		                             outside the project lets one run use a generated manifest
		  --new                      force a fresh container
		  --name <container>         name the container instead of sandbox-<project>
		  --network=host             share the host network namespace
		  --offline                  bridge plus default-deny egress (the default)
		  -v, --verbose              run without tmux

		What the sandbox inherits comes from .sandbox.conf in the project, and
		nothing is inherited without one. --manifest names another file. Grants, all
		off by default:

		  BASE=full                  the whole inherited set (the old default)
		  AGENTS="pi claude codex"   agent config dirs
		  GIT_AUTH=true              forge credentials
		  LOCAL_BIN=true             ~/.local/bin
		  TMUX=true                  ~/.tmux.conf
		  MOUNTS=(...)               extra host paths
		  NETWORK=host               host networking (default: bridge + firewall)
		  HOST_SERVICES=ollama       open the host gateway on 11434
	EOF
}

## DEFAULTS

IMAGE=agent-sandbox
RUSER=node

# Per-project manifest, sourced when it exists. An absolute MANIFEST names a file outside the
# project, which is what a launcher wants when the manifest is generated for one run.
# MANIFEST_EXPLICIT records that the caller named it: that one has to be there, the default one
# may be absent.
MANIFEST=".sandbox.conf"
MANIFEST_EXPLICIT=

# Defaults: every switch is off, a manifest grants what it needs. BASE=full
# restores the old inherited set for a project that has no manifest yet.
AGENTS=
GIT_AUTH=false
LOCAL_BIN=false
TMUX=false
NETWORK=bridge
HOST_SERVICES=
BASE=
MOUNTS=()


## ARGS

FORCE_NEW=
VERBOSE=
OFFLINE=
STDIO=
VERSION_PROBE=
NETWORK_FLAG=
NAME_FLAG=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h|--help) help; exit ;;
		--version) VERSION_PROBE=1; shift ;;
		--new)     FORCE_NEW=1; shift ;;
		--name)    [ -n "${2:-}" ] || die "--name needs a container name"
		           NAME_FLAG=$2; shift 2 ;;
		--name=*)  [ -n "${1#*=}" ] || die "--name needs a container name"
		           NAME_FLAG=${1#*=}; shift ;;
		--offline) OFFLINE=1; shift ;;
		--network=*) NETWORK_FLAG=${1#*=}; shift ;;
		--network) [ -n "${2:-}" ] || die "--network needs bridge or host"
		           NETWORK_FLAG=$2; shift 2 ;;
		--stdio)   STDIO=1; shift ;;
		--manifest) [ -n "${2:-}" ] || die "--manifest needs a path"
		            MANIFEST=$2; MANIFEST_EXPLICIT=1; shift 2 ;;
		--manifest=*) MANIFEST=${1#*=}; MANIFEST_EXPLICIT=1; shift ;;
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
	die "refusing to mount '$WORK', it is \$HOME or holds .ssh/.gnupg."
fi
KEY=$(printf '%s' "$WORK" | sed 's#[^a-zA-Z0-9]#-#g')
PROJ="$HOME/.claude/projects/$KEY"
mkdir -p "$PROJ/memory"
NAME="sandbox-$(printf '%s' "${WORK##*/}" | sed 's#[^a-zA-Z0-9_.-]#-#g')"

# An explicit name is the caller's: several containers for one project are told apart by name,
# and only the caller knows which is which. It is used as given, so it has to be legal.
if [ -n "$NAME_FLAG" ]; then
	case "$NAME_FLAG" in
		"" | [!a-zA-Z0-9]* | *[!a-zA-Z0-9_.-]*)
			die "--name takes a docker container name, letters, digits, dot, dash or underscore: '$NAME_FLAG'"
			;;
	esac
	NAME="$NAME_FLAG"
fi

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

# Load the manifest. The project's own may be absent; one the caller named must be readable, since
# a run that quietly loses the grants it was asked for is worse than one that stops here.
manifest_path="$WORK/$MANIFEST"
# An absolute path is used as given, so the manifest can live outside the project it configures.
[ "${MANIFEST#/}" != "$MANIFEST" ] && manifest_path=$MANIFEST
if [ -f "$manifest_path" ] && [ -r "$manifest_path" ]; then
	source "$manifest_path"
elif [ -n "$MANIFEST_EXPLICIT" ]; then
	die "manifest not found or unreadable: $manifest_path"
fi

# BASE=full is the migration hatch for a project that predates deny-by-default: it
# turns on every grant still at its default, so an explicit grant in the manifest
# still narrows it. --network and --offline beat the manifest.
if [ "$BASE" = full ]; then
	[ -z "$AGENTS" ] && AGENTS="pi claude codex"
	[ "$GIT_AUTH" = false ] && GIT_AUTH=true
	[ "$LOCAL_BIN" = false ] && LOCAL_BIN=true
	[ "$TMUX" = false ] && TMUX=true
fi
[ -n "$NETWORK_FLAG" ] && NETWORK="$NETWORK_FLAG"
[ -n "$OFFLINE" ] && NETWORK=bridge

# A project without a manifest inherits nothing. Say so, so the tighter default
# does not read as the sandbox silently missing files.
if [ ! -f "$WORK/$MANIFEST" ] && [ -z "$VERSION_PROBE" ]; then
	{
		echo -e "  \e[33mno $MANIFEST: nothing is inherited from the host.\e[0m"
		echo "  add one with BASE=full for the old defaults, or grant what it needs:"
		echo "  AGENTS, GIT_AUTH, LOCAL_BIN, TMUX, MOUNTS, NETWORK, HOST_SERVICES"
	} >&2
fi

# Attaching is for a human who reopens a project. A paseo launch owns its own
# session and its stdin is a pipe, so it always gets a fresh container.
if [ -z "$FORCE_NEW" ] && [ -z "$STDIO" ] && docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
	echo "Attaching to '$NAME' ('$prog --new' forces a fresh one)…" >&2
	exec docker exec -it -e "COLORTERM=${COLORTERM:-truecolor}" -w "$WORK" "$NAME" "$@"
fi
# A derived name steps aside for whatever already holds it. An explicit one is taken as given,
# so a container already carrying it stops the run instead of pushing this one to a -2.
if [ -n "$NAME_FLAG" ]; then
	if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
		die "container '$NAME' already exists; stop it first with: docker rm -f $NAME"
	fi
else
	n=2; base=$NAME
	while docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; do NAME="$base-$n"; n=$((n+1)); done
fi

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

# -- Agent mounts (controlled by manifest) -----------------------------------

has_agent() {
	local name=$1; shift
	for a in $AGENTS; do [ "$a" = "$name" ] && return 0; done
	return 1
}

truthy() { case "${1:-}" in true | 1 | yes | on) return 0 ;; *) return 1 ;; esac; }

# -- Base environment (config/base.conf) -------------------------------------

BASE_CONF="${BASE_CONF:-$HOME/.config/agent-sandbox/base.conf}"
[ -f "$BASE_CONF" ] || die "no base environment at '$BASE_CONF' - run 'make setup' in agent-sandbox"

# A catalogue from before the grants existed carries no grant tags, so its entries
# mount for everyone. Say it instead of quietly keeping the old permissive default.
grep -q 'grant=' "$BASE_CONF" || echo -e "  \e[33m$BASE_CONF has no grant tags, re-run 'make setup' for the gated catalogue.\e[0m" >&2

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
	# the skills tree is pi's, it discovers ~/.agents/skills
	"$HOME/.agents") printf pi ;;
	esac
}

while read -r kind path opts; do
	case "$kind" in '' | \#*) continue ;; esac
	path="${path/#\~/$HOME}"
	case "$path" in "$HOME"/*) ;; *) die "base entry outside \$HOME: $path" ;; esac

	mode= want_auth=0 grant=
	for o in $opts; do
		case "$o" in
		ro) mode=ro ;;
		auth) want_auth=1 ;;
		grant=*) grant=${o#grant=} ;;
		exclude=*) ;; # guest side, see vworker.sh
		*) die "unknown base option '$o' on '$path'" ;;
		esac
	done

	if ! [ -e "$path" ]; then
		echo "  not on this host: ${path#"$HOME"/}" >&2
		continue
	fi
	if [ "$want_auth" = 1 ] && ! truthy "$GIT_AUTH"; then
		echo "  credentials off: ${path#"$HOME"/}" >&2
		continue
	fi
	if [ -n "$grant" ] && ! truthy "${!grant:-}"; then
		echo "  grant off (${grant}): ${path#"$HOME"/}" >&2
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
	dir) mount_dir "$path" "$dest" "$mode" ;;
	file) mount_file "$path" "$dest" "$mode" ;;
	*) die "unknown base entry kind '$kind' in $BASE_CONF" ;;
	esac

	# An agent directory is a stow farm: the files inside it are symlinks into a
	# checkout outside the container's copy of $HOME, so mounting the directory
	# alone hands over dead links and pi will not start. Mount each target where
	# its link resolves. LOCAL_BIN is left out, its dangling links are the point.
	if [ -n "$agent" ] && [ "$kind" = dir ]; then
		while IFS= read -r -d '' link; do
			target=$(readlink -f "$link") || continue
			[ -n "$target" ] && [ -e "$target" ] || continue
			denied "$target" && continue
			add_mount "$target" "$target"
		done < <(find "$path" -maxdepth 4 -type l -print0 2>/dev/null)
	fi
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

# A worktree's .git is a file naming the main checkout's .git/worktrees/<slug>, whose
# commondir reaches the object store and the refs. That git directory is what has to be
# there, at its own path: mounting the checkout that holds it would hand the whole
# working tree, and every file in it, to a sandbox that asked for one worktree.
if [ -f "$WORK/.git" ]; then
	common=$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	if [ -n "$common" ] && [ -d "$common" ]; then
		add_mount "$common" "$common"
		# Every other worktree keeps its index, HEAD and reflog in that same directory, and one
		# run must not be able to write them. Each sibling admin directory is mounted read-only
		# over the writable git directory above; this worktree's own stays writable through it.
		own=$(git -C "$WORK" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null || true)
		if [ -n "$own" ]; then
			for sibling in "$common"/worktrees/*/; do
				[ -d "$sibling" ] || continue
				sibling=${sibling%/}
				[ "$sibling" = "$own" ] && continue
				add_mount "$sibling" "$sibling" ro
			done
		fi
	fi
fi

TTY_FLAG="-t"
if [ -n "$STDIO" ]; then
	# pipes, not a tty: a tty echoes the request stream and rewrites its endings
	TTY_FLAG="-i"
elif [ -t 0 ]; then
	TTY_FLAG="-it"
fi

run=(docker run --rm $TTY_FLAG \
	--name "$NAME" \
	--hostname sandbox \
	-e "COLORTERM=${COLORTERM:-truecolor}" \
	-e DISABLE_AUTOUPDATER=1 \
	-e DISABLE_TELEMETRY=1 \
	-w "$WORK" \
	"${mounts[@]}")

case "$NETWORK" in
host)
	exec "${run[@]}" --network=host "$IMAGE" "$@"
	;;
bridge | offline | "")
	# One dedicated network for every sandbox: the default bridge is shared with
	# every other container on the host. Default-deny egress stays the floor, and
	# HOST_SERVICES is the one grant that opens this container's own gateway.
	NETNAME=agent-sandbox-net
	docker network inspect "$NETNAME" >/dev/null 2>&1 || docker network create "$NETNAME" >/dev/null
	run+=(--network="$NETNAME")
	if [ -n "$HOST_SERVICES" ]; then
		run+=(--add-host=host.docker.internal:host-gateway)
		case " $HOST_SERVICES " in
		*" ollama "*)
			run+=(-e OLLAMA_HOST=http://host.docker.internal:11434)
			;;
		esac
	fi
	exec "${run[@]}" \
		--cap-add=NET_ADMIN --cap-add=NET_RAW \
		--entrypoint /bin/bash \
		"$IMAGE" \
		-c "sudo /usr/local/bin/init-firewall.sh $HOST_SERVICES && exec \"\$@\"" bash "$@"
	;;
*)
	die "unknown NETWORK '$NETWORK' (bridge or host)"
	;;
esac
