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
		  HOST_SERVICES=name:443     open that name through the host, on that port
		  TOOLS="linear"             tools granted from ~/.config/agent-sandbox/tools.d, one KEY=value file per tool
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
TOOLS=


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
		echo "  AGENTS, GIT_AUTH, LOCAL_BIN, TMUX, MOUNTS, NETWORK, HOST_SERVICES, TOOLS"
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

# A fence drops any grant already on its destination, because add_mount keeps one mount per
# destination and a project MOUNTS entry naming a git execution surface must not shadow the fence.
drop_mount() { # <destination>
	local i spec dst
	local -a kept=()
	for ((i = 0; i < ${#mounts[@]}; i += 2)); do
		spec=${mounts[i + 1]}
		dst=${spec#*:}
		dst=${dst%%:*}
		if [ "$dst" != "$1" ]; then
			kept+=("${mounts[i]}" "${mounts[i + 1]}")
		fi
	done
	if [ "${#kept[@]}" -gt 0 ]; then
		mounts=("${kept[@]}")
	else
		mounts=()
	fi
	unset '_seen_mounts[$1]'
	return 0
}

# A fence is not a hint: every name is covered, or the run does not start. A name that is not a plain
# file or directory is refused rather than written through, because a symlink takes the write
# somewhere else, and a sandbox can create any name the host has not.
protected=()

add_mask_dir() { # <path> <what>
	local path=$1 what=${2:-git state}
	if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
		die "refusing to launch: $what at $path is not a directory"
	fi
	if [ ! -d "$path" ]; then
		mkdir -p "$path" 2>/dev/null || die "refusing to launch: cannot create $what at $path"
	fi
	drop_mount "$path"
	add_mount "$path" "$path" ro
	protected+=("$path")
	[ -d "$path" ] || die "refusing to launch: $what at $path is not a directory"
}

add_mask_file() { # <path> <what>
	local path=$1 what=${2:-git state}
	if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
		die "refusing to launch: $what at $path is not a regular file"
	fi
	if [ ! -f "$path" ]; then
		( set -C; : >"$path" ) 2>/dev/null || die "refusing to launch: cannot create $what at $path"
	fi
	drop_mount "$path"
	add_mount "$path" "$path" ro
	protected+=("$path")
	[ -f "$path" ] || die "refusing to launch: $what at $path is not a regular file"
}

# commondir points git at another common directory, and a git directory that has none is its own
# common directory. That is what the file is given: one line written by the launcher rather than a
# mount, because a mount onto a name that does not exist makes docker create it in the host checkout,
# and a name a sandbox can create is a name it can aim at a git directory it wrote.
fence_commondir() { # <git dir>
	local path="$1/commondir"
	if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
		die "refusing to launch: the common directory pointer at $path is not a regular file"
	fi
	if [ ! -f "$path" ]; then
		printf '%s\n' "$1" >"$path" 2>/dev/null ||
			die "refusing to launch: cannot write the common directory pointer at $path"
	fi
	add_mask_file "$path" "the common directory pointer"
}

# A worktree config is a third place a hooks path can be chosen, and git reads it only when the shared
# config turns the extension on. That config is read-only here and a run with the extension already on
# is refused, so a name that does not exist yet is inert and is left alone rather than created.
add_mask_file_if_present() { # <path> <what>
	[ -e "$1" ] || [ -L "$1" ] || return 0
	add_mask_file "$1" "${2:-git state}"
}

# A mount that exposes a hook path keeps its place in the set, read-only instead: the container may
# still read what the operator put there, and cannot write a hook through it. The destination is what
# is fenced, because that is the path the container writes through, symlink or not.
fence_mount_destination() { # <destination> <source>
	drop_mount "$1"
	add_mount "$2" "$1" ro
	protected+=("$1")
}

# Judged on the finished mount set: a writable entry at or under a fenced name puts it back in reach,
# and a writable mount of the tree that holds an external manifest hands the host a file it sources.
validate_mounts() {
	local i spec src dst mode p outside=
	case "$manifest_path" in
	"$WORK"/*) ;;
	*) [ -f "$manifest_path" ] && outside=$(readlink -f "$manifest_path" 2>/dev/null || printf '%s' "$manifest_path") ;;
	esac
	for ((i = 0; i < ${#mounts[@]}; i += 2)); do
		spec=${mounts[i + 1]}
		src=${spec%%:*}
		dst=${spec#*:}
		dst=${dst%%:*}
		mode=${spec##*:}
		[ "$mode" = ro ] && continue
		for p in "${protected[@]}"; do
			case "$dst" in
			"$p" | "$p"/*) die "refusing a writable mount at $dst: $p is fenced read-only" ;;
			esac
		done
		if [ -n "$outside" ]; then
			src=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
			case "$outside" in
			"$src" | "$src"/*) die "refusing a writable mount at $dst: it holds the manifest $manifest_path, which the host sources" ;;
			esac
		fi
	done
	return 0
}

# The project comes first: it owns its own destination. It goes through the same
# helper as everything else, which resolves a symlinked workdir and keeps a later
# entry from mounting the same destination twice.
mount_dir "$WORK" "$WORK"

# The manifest is read on the host and mounted back read-only: the project tree is writable, so
# otherwise a sandbox would pick its own grants for the next run.
case "$manifest_path" in
"$WORK"/*)
	[ -f "$manifest_path" ] && add_mask_file "$manifest_path" "the manifest"
	;;
esac

# -- Agent mounts (controlled by manifest) -----------------------------------

has_agent() {
	local name=$1; shift
	for a in $AGENTS; do [ "$a" = "$name" ] && return 0; done
	return 1
}

truthy() { case "${1:-}" in true | 1 | yes | on) return 0 ;; *) return 1 ;; esac; }

# AGENTS names the agents a run may use rather than being a boolean, so any name in it turns that
# grant on. Every other key in the catalogue is a boolean.
granted() {
	case "$1" in
	AGENTS) [ -n "$AGENTS" ] ;;
	*) truthy "${!1:-}" ;;
	esac
}

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
# The grant directory holds what another run's firewall trusts, so neither it nor the directory
# above it is ever handed over, under either base the launcher can pick.
services_base="${XDG_RUNTIME_DIR:-$HOME/.cache}"
services_dir="$services_base/agent-sandbox"
for base in "${XDG_RUNTIME_DIR:-}" "$HOME/.cache"; do
	[ -n "$base" ] || continue
	for d in "$base" "$base/agent-sandbox"; do
		deny_tree+=("$d")
		r=$(readlink -f "$d" 2>/dev/null || true)
		[ -n "$r" ] && deny_tree+=("$r")
	done
done

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

# The roots an agent directory link may resolve into. A link is mounted only inside one of them: a
# grant that says pi's config directory must not also carry whatever else a link in it names.
follow_roots=()

inside_follow_root() {
	local i
	for ((i = 0; i < ${#follow_roots[@]}; i++)); do
		case "$1" in "${follow_roots[i]}" | "${follow_roots[i]}"/*) return 0 ;; esac
	done
	return 1
}

while read -r kind path opts; do
	case "$kind" in '' | \#*) continue ;; esac

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

	# A follow root is never mounted itself, so it needs no destination and may sit outside $HOME,
	# which is where a stow farm lives.
	if [ "$kind" = follow ]; then
		if [ -n "$grant" ] && ! granted "$grant"; then
			echo "  grant off ($grant): $path" >&2
			continue
		fi
		root=$(readlink -f "${path/#\~/$HOME}") || die "$path does not resolve"
		[ -d "$root" ] || die "$path is not a directory"
		follow_roots+=("$root")
		continue
	fi

	path="${path/#\~/$HOME}"
	case "$path" in "$HOME"/*) ;; *) die "base entry outside \$HOME: $path" ;; esac

	if ! [ -e "$path" ]; then
		echo "  not on this host: ${path#"$HOME"/}" >&2
		continue
	fi
	if [ "$want_auth" = 1 ] && ! truthy "$GIT_AUTH"; then
		echo "  credentials off: ${path#"$HOME"/}" >&2
		continue
	fi
	if [ -n "$grant" ] && ! granted "$grant"; then
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

	# An agent directory is a stow farm: its files are symlinks into a checkout outside the
	# container's copy of $HOME, so mounting the directory alone hands over dead links. Mount each
	# target over the link, at the guest path the link already occupies, so the checkout itself stays
	# out of the container. A link counts only when it resolves inside a follow root: the sandbox
	# writes this directory, so without that bound a planted link would carry what it names into the
	# next run, and a grant for pi's config would hand over a forge token with it.
	# Depth 3 is what an agent reads: a config file below the directory, a skill directory below that.
	# What links deeper is runtime state, codex's arg0 shims sit at depth 5, and it stays out.
	if [ -n "$agent" ] && [ "$kind" = dir ]; then
		[ "${#follow_roots[@]}" -gt 0 ] || echo -e "  \e[33m${BASE_CONF} declares no follow root, so no link under an agent directory is followed.\e[0m" >&2
		while IFS= read -r -d '' link; do
			target=$(readlink -f "$link") || continue
			[ -n "$target" ] && [ -e "$target" ] || continue
			if denied "$target"; then
				echo "  link not followed (the vault, or a key): ${link#"$path"/} -> $target" >&2
				continue
			fi
			if ! inside_follow_root "$target"; then
				echo "  link not followed (outside every follow root): ${link#"$path"/} -> $target" >&2
				continue
			fi
			add_mount "$target" "/home/$RUSER/${link#"$HOME"/}"
		done < <(find "$path" -maxdepth 3 -type l -print0 2>/dev/null)
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

# -- Tools (config/tools.d) --------------------------------------------------

# One data file per tool, named by the manifest in TOOLS. The file says what the tool mounts and
# which hosts its egress may open, so a new tool is a new file and never code: nothing below knows
# any tool by name. Naming a tool is the whole of the opt-in, so a catalogue entry nobody names
# grants nothing and cannot break an unrelated run. A tool's directory is mounted read-only at its
# own guest path, a credential is one file and never a directory, and the egress it names goes into
# the same read-only grant file HOST_SERVICES uses, which the firewall resolves at start rather
# than at build time.
TOOLS_DIR="${TOOLS_DIR:-$HOME/.config/agent-sandbox/tools.d}"
tool_host_grants=()
tool_file=""

# A tools.d file is data, never bash: each line is KEY=value and an unknown key is refused, so a
# typo cannot quietly drop a grant.
tool_read() { # <file>
	local line key value
	TOOL_SKILL_HOST= TOOL_SKILL_CONTAINER= TOOL_CRED_HOST= TOOL_CRED_CONTAINER=
	TOOL_CLI_HOST= TOOL_CLI_CONTAINER= TOOL_HOSTS=
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '' | '#'*) continue ;; esac
		case "$line" in
		*=*) ;;
		*) die "$1: '$line' is not KEY=value" ;;
		esac
		key=${line%%=*}
		value=${line#*=}
		key=${key//[[:space:]]/}
		value=${value#"${value%%[![:space:]]*}"}
		value=${value%"${value##*[![:space:]]}"}
		case "$key" in
		SKILL_HOST) TOOL_SKILL_HOST=$value ;;
		SKILL_CONTAINER) TOOL_SKILL_CONTAINER=$value ;;
		CRED_HOST) TOOL_CRED_HOST=$value ;;
		CRED_CONTAINER) TOOL_CRED_CONTAINER=$value ;;
		CLI_HOST) TOOL_CLI_HOST=$value ;;
		CLI_CONTAINER) TOOL_CLI_CONTAINER=$value ;;
		HOSTS) TOOL_HOSTS=$value ;;
		*) die "$1: unknown key '$key'" ;;
		esac
	done <"$1"
}

# A host path and its destination are one grant: half a pair mounts nothing and would still read as
# granted, so either half missing stops the run. A grant the base catalogue already refuses is
# refused here too, so the keys and the vault stay out of reach of this one path as well.
tool_host_path() { # <host> <destination> <what>
	[ -n "$1" ] || [ -n "$2" ] || return 0
	[ -n "$1" ] && [ -n "$2" ] || die "$tool_file: $3 needs both a host path and a destination"
	printf '%s' "${1/#\~/$HOME}"
}

# One mount per destination, and the first one wins. A tool whose destination is already taken
# would arrive as a name that mounts nothing while the run reports it granted, so it is refused.
tool_mount() { # <source> <destination> <what>
	case "$2" in
	/*) ;;
	*) die "$tool_file: $3 destination is not an absolute path: $2" ;;
	esac
	case "$2" in
	*:*) die "$tool_file: $3 destination carries a colon, which the mount spec cannot hold: $2" ;;
	esac
	case "/$2/" in
	*/../*) die "$tool_file: $3 destination carries a parent segment: $2" ;;
	esac
	[ -z "${_seen_mounts[$2]:-}" ] ||
		die "$tool_file: $3 cannot mount at $2, that destination already holds a mount"
	add_mount "$1" "$2" ro
}

grant_tool() { # <name>
	local name=$1 host resolved
	tool_file="$TOOLS_DIR/$name.conf"
	tool_read "$tool_file"

	resolved=$(tool_host_path "$TOOL_SKILL_HOST" "$TOOL_SKILL_CONTAINER" "the skill directory")
	if [ -n "$resolved" ]; then
		resolved=$(readlink -f "$resolved") || die "$tool_file: the skill directory does not resolve: $TOOL_SKILL_HOST"
		[ -d "$resolved" ] || die "$tool_file: the skill directory is not a directory: $resolved"
		denied "$resolved" && die "$tool_file: the skill directory is one the sandbox may not see: $resolved"
		tool_mount "$resolved" "$TOOL_SKILL_CONTAINER" "the skill directory"
	fi

	resolved=$(tool_host_path "$TOOL_CRED_HOST" "$TOOL_CRED_CONTAINER" "the credential")
	if [ -n "$resolved" ]; then
		resolved=$(readlink -f "$resolved") || die "$tool_file: the credential does not resolve: $TOOL_CRED_HOST"
		# One file, never a directory: a directory would hand over every key beside the one named.
		[ -f "$resolved" ] || die "$tool_file: the credential is not a regular file: $resolved"
		[ -r "$resolved" ] || die "$tool_file: the credential is not readable: $resolved"
		denied "$resolved" && die "$tool_file: the credential is one the sandbox may not see: $resolved"
		tool_mount "$resolved" "$TOOL_CRED_CONTAINER" "the credential"
	fi

	# The host shim is a stow-farm link, which is why the resolved file is what is mounted: the guest
	# gets the script, never the farm it points into, and the image needs no per-tool copy of it.
	resolved=$(tool_host_path "$TOOL_CLI_HOST" "$TOOL_CLI_CONTAINER" "the CLI")
	if [ -n "$resolved" ]; then
		resolved=$(readlink -f "$resolved") || die "$tool_file: the CLI does not resolve: $TOOL_CLI_HOST"
		[ -f "$resolved" ] || die "$tool_file: the CLI is not a regular file: $resolved"
		[ -x "$resolved" ] || die "$tool_file: the CLI is not executable: $resolved"
		denied "$resolved" && die "$tool_file: the CLI is one the sandbox may not see: $resolved"
		tool_mount "$resolved" "$TOOL_CLI_CONTAINER" "the CLI"
	fi

	# The firewall opens a grant only from 1 to 65535, on a name it can resolve, so an entry it would
	# refuse is refused here instead of failing inside container init.
	for host in $TOOL_HOSTS; do
		case "${host%:*}" in
		"" | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
			die "$tool_file: '$host' does not name a host the firewall can resolve" ;;
		esac
		case "${host##*:}" in
		"" | *[!0-9]*) die "$tool_file: '$host' is not a <host>:<port> egress grant" ;;
		esac
		[ "$((10#${host##*:}))" -ge 1 ] && [ "$((10#${host##*:}))" -le 65535 ] ||
			die "$tool_file: '$host' needs a TCP port from 1 to 65535"
		tool_host_grants+=("$host")
	done
}

# A name forms a path, so it is held to what a filename may be before anything is read, and a name
# the catalogue does not hold is refused with the list instead of mounting nothing.
known_tools() {
	local found out=""
	for found in "$TOOLS_DIR"/*.conf; do
		[ -f "$found" ] || continue
		out+="$(basename "$found" .conf) "
	done
	printf '%s' "${out:-none in $TOOLS_DIR}"
}

for name in $TOOLS; do
	case "$name" in
	"" | [!a-z0-9]* | *[!a-z0-9_-]*) die "a tool name takes lowercase letters, digits, dash or underscore: '$name'" ;;
	esac
	[ -f "$TOOLS_DIR/$name.conf" ] || die "unknown tool '$name'; the catalogue has: $(known_tools)"
	grant_tool "$name"
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
#
# Git administration is the one place a sandbox could hand the host code to run. A hook written in
# the hooks directory executes on the host at the next git operation in that checkout, and a
# writable config is enough to point core.hooksPath at a directory the sandbox owns. Every one of
# those surfaces is mounted back read-only. Git still reads all of them, so history, the hooks the
# operator installed and commits keep working: only writing stops.
# The names a sandbox could hand the host to run. Each is mounted back read-only, and a name that is
# not there yet is created and fenced by the helpers above, so history, the hooks the operator
# installed and commits keep working and only writing stops.
fence_git_surfaces() { # <git dir> <working tree>
	local gitdir=$1 work=$2
	add_mask_file "$gitdir/config"
	add_mask_file_if_present "$gitdir/config.worktree" "the worktree config"
	fence_commondir "$gitdir"
	add_mask_dir "$gitdir/hooks"
	fence_modules "$gitdir"
	fence_hooks_path "$work" "$gitdir"
	return 0
}

fence_modules() { # <git dir>: a submodule keeps its own git directory, and its own hooks, inside this
	local dir
	for dir in "$1"/modules/*/; do
		[ -d "$dir" ] && [ ! -L "${dir%/}" ] || continue
		dir=${dir%/}
		add_mask_file "$dir/config"
		add_mask_dir "$dir/hooks"
		fence_commondir "$dir"
		fence_modules "$dir"
	done
	return 0
}

# core.hooksPath is the operator's own setting. Where it points inside the mounted trees, that target
# is an execution surface exactly like hooks/, and is fenced the same way.
fence_hooks_path() { # <working tree> <git dir>
	local work=$1 gitdir=$2 path literal resolved spec dst i exposed=0
	path=$(git -C "$work" config --get core.hooksPath 2>/dev/null || true)
	[ -n "$path" ] || return 0
	# Git resolves this like any pathname: `~` is the home directory, a relative value sits under the
	# working tree. Reading it any other way would fence the wrong directory.
	case "$path" in
	"~") literal="$HOME" ;;
	"~/"*) literal="$HOME/${path#\~/}" ;;
	"~"*) return 0 ;; # ~user resolves out of the passwd database, outside every mount
	/*) literal=$path ;;
	*) literal="$work/$path" ;;
	esac
	resolved=$(readlink -f "$literal" 2>/dev/null || true)
	[ -n "$resolved" ] || resolved=$literal
	case "$resolved" in
	"$work" | "$gitdir")
		die "core.hooksPath points at $resolved itself, which cannot be fenced without making it read-only; point it at a directory of its own" ;;
	"$work"/* | "$gitdir"/*)
		add_mask_dir "$resolved" "the hooks path"
		return 0 ;;
	esac
	# Outside the trees it is only an execution surface when the mount set exposes it, and a mount can
	# expose it either at its own path or at a symlink to it: both are collected before any of them is
	# fenced, because fencing rebuilds the mount list.
	local -a expose=() under_rw=0
	for ((i = 0; i < ${#mounts[@]}; i += 2)); do
		spec=${mounts[i + 1]}
		src=${spec%%:*}
		dst=${spec#*:}
		dst=${dst%%:*}
		real=$(readlink -f "$dst" 2>/dev/null || true)
		[ -n "$real" ] || real=$dst
		case "$real" in
		"$resolved" | "$resolved"/*) expose+=("$dst:$src") ;;
		esac
		case "$resolved" in
		"$dst" | "$dst"/*) under_rw=1 ;;
		esac
	done
	if [ "${#expose[@]}" -gt 0 ]; then
		exposed=1
		for spec in "${expose[@]}"; do
			fence_mount_destination "${spec%%:*}" "${spec#*:}"
		done
	fi
	# Under a writable parent mount the target is reachable at its own path, so it takes a fence there
	# too: a nested read-only mount wins over the parent it sits in.
	if [ "$under_rw" = 1 ]; then
		exposed=1
		add_mask_dir "$resolved" "the exposed hooks path"
	fi
	[ "$exposed" = 1 ] || return 0
}

# A worktree config is a third place a hooks path can be chosen, and git reads it only when the
# shared config turns the extension on. That file is read-only here, so the extension cannot be
# switched on by a sandbox; one that is already on would let it write the redirect itself.
if [ -n "$(git -C "$WORK" config --get extensions.worktreeConfig 2>/dev/null || true)" ]; then
	die "extensions.worktreeConfig is on in $WORK, so a worktree config a sandbox could create would choose its hooks; turn the extension off"
fi

if [ -f "$WORK/.git" ]; then
	common=$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	if [ -n "$common" ] && [ -d "$common" ]; then
		# The shared git directory is read-only, and only the parts a commit writes are mounted back
		# read-write. A writable root is what lets a sandbox create a name the operator reads next:
		# a commondir alone points the host at a git directory the sandbox wrote, hooks and all.
		add_mount "$common" "$common" ro
		for path in objects refs logs; do
			[ -d "$common/$path" ] || continue
			add_mount "$common/$path" "$common/$path"
		done
		own=$(git -C "$WORK" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null || true)
		if [ -n "$own" ]; then
			# This worktree's own admin directory has to stay writable: the index, HEAD and the reflog
			# of a commit live in it. Its two pointer files are the exception.
			add_mount "$own" "$own"
			add_mask_file_if_present "$own/config.worktree" "the worktree config"
			fence_commondir "$own"
		fi
		protected+=("$common/hooks" "$common/config" "$common/config.worktree" "$common/commondir")
		fence_hooks_path "$WORK" "$common"
	fi
	# The pointer file names the git directory git uses from here on, and it sits inside the writable
	# project mount.
	add_mask_file "$WORK/.git"
elif [ -d "$WORK/.git" ]; then
	# A plain checkout: the project mount above covers .git, so the names git follows inside it are
	# fenced. Its root stays writable because a commit creates its lock and message files there.
	fence_git_surfaces "$WORK/.git" "$WORK"
fi

validate_mounts

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
	# A tool's egress grant is a firewall rule, and host networking has no firewall.
	if [ "${#tool_host_grants[@]}" -gt 0 ]; then
		echo -e "  \e[33mNETWORK=host skips the firewall, so a tool's egress grant is not enforced.\e[0m" >&2
	fi
	exec "${run[@]}" --network=host "$IMAGE" "$@"
	;;
bridge | offline | "")
	# One dedicated network for every sandbox: the default bridge is shared with
	# every other container on the host. Default-deny egress stays the floor, and
	# HOST_SERVICES is the one grant that opens this container's own gateway.
	NETNAME=agent-sandbox-net
	docker network inspect "$NETNAME" >/dev/null 2>&1 || docker network create "$NETNAME" >/dev/null
	run+=(--network="$NETNAME")
	# A container cannot enumerate the host's other docker networks, so the launcher lists their
	# subnets and the firewall treats each as a network a grant may not reach.
	networks=$(docker network ls -q 2>/dev/null) || die "cannot list the docker networks"
	subnets=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' $networks 2>/dev/null) ||
		die "cannot read the docker network subnets"
	closed=()
	while read -r subnet; do
		[ -n "$subnet" ] || continue
		closed+=("closed=$subnet")
	done < <(printf '%s\n' "$subnets" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -u)
	if [ ${#closed[@]} -eq 0 ]; then
		# The guard a <host>:<port> grant rests on cannot be drawn without them.
		if printf '%s\n' $HOST_SERVICES | grep -q ':'; then
			die "no docker network has a subnet, so a <host>:<port> grant could reach a sibling container"
		fi
		echo -e "  \e[33mno docker network has a subnet, so a grant could reach a sibling container.\e[0m" >&2
	fi
	# The grant is a file, not an argument, because the container's user can run the firewall script:
	# one file root reads, in a directory no other local user can reach.
	mkdir -p -m 700 "$services_dir" 2>/dev/null && chmod 700 "$services_dir" ||
		die "cannot create the grant directory $services_dir"
	services=$(mktemp "$services_dir/$NAME.XXXXXX") ||
		die "cannot create the grant file in $services_dir"
	{
		printf '%s\n' "${closed[@]}"
		printf '%s\n' $HOST_SERVICES | grep -E ':' || true
		# A tool's egress is a name and a port, resolved when the firewall starts: the image
		# bakes no per-tool address list, so a new tool needs no rebuild and a host may move.
		for grant in "${tool_host_grants[@]}"; do printf '%s\n' "$grant"; done
	} >"$services"
	fixed_services=$(printf '%s\n' $HOST_SERVICES | grep -v ':' | tr '\n' ' ' || true)
	run+=(-v "$services:/etc/agent-sandbox-host-services:ro")
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
		-c "sudo /usr/local/bin/init-firewall.sh $fixed_services && exec \"\$@\"" bash "$@"
	;;
*)
	die "unknown NETWORK '$NETWORK' (bridge or host)"
	;;
esac
