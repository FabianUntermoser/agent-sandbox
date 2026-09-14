#!/usr/bin/env bash
# USAGE: sandbox-panes.sh ls
#        sandbox-panes.sh read <target> [-n <lines>]
#        sandbox-panes.sh send <target> <text>
#        sandbox-panes.sh wait <target> [<timeout-seconds>]
#        sandbox-panes.sh keys <target> <key>...
#
# Reach into the tmux server of a running sandbox container: list its panes, read
# one, type into one, or wait until the agent in it stopped working. The host tmux
# server is never touched, every tmux call is a docker exec in the container the
# target names.
#
# <target> is <container>[:<session>][.<window>[.<pane>]], the container may be the
# short form: 'stockis' finds 'sandbox-stockis-destillerie'. With one sandbox
# running, the container part can be left out. A target without a pane picks
# window 1 pane 1 of that session.
set -euo pipefail

DIM=$'\033[2m'; BOLD=$'\033[1m'; CYAN=$'\033[36m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'
die(){ printf '%serror%s: %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
warn(){ printf '%s!%s %s\n' "$YELLOW" "$OFF" "$*" >&2; }

containers(){
	docker ps --filter 'name=sandbox-' --format '{{.Names}}' 2>/dev/null || true
}

# short name, full name or unique substring to a container name
resolve_container(){
	local want=$1 all name
	all=$(containers)
	[ -n "$all" ] || die "no sandbox container is running"
	if [ -z "$want" ]; then
		[ "$(printf '%s\n' "$all" | wc -l)" = 1 ] || die "several sandbox containers, name one: $(printf '%s ' $all)"
		printf '%s' "$all"
		return
	fi
	for name in $all; do
		[ "$name" = "$want" ] && { printf '%s' "$name"; return; }
	done
	if printf '%s\n' "$all" | grep -qx "sandbox-$want"; then
		printf 'sandbox-%s' "$want"
		return
	fi
	name=$(printf '%s\n' "$all" | grep -F -- "$want" || true)
	case $(printf '%s\n' "$name" | wc -l) in
	1) printf '%s' "$name" ;;
	0) die "no running sandbox container matches '$want'" ;;
	*) die "'$want' matches several containers: $(printf '%s ' $name)" ;;
	esac
}

# <container>[:<session>[.<window>[.<pane>]]] into the container plus a tmux -t target
split_target(){
	local target=$1 rest
	T_CONTAINER=$(resolve_container "${target%%:*}")
	case "$target" in
	*:*) T_SESSION=${target#*:} ;;
	*) T_SESSION= ;;
	esac
	T_WINDOW=1; T_PANE=
	case "$T_SESSION" in
	*.*.*)
		T_PANE=${T_SESSION##*.}
		rest=${T_SESSION%.*}
		T_WINDOW=${rest#*.}
		T_SESSION=${rest%%.*}
		;;
	*.*)
		T_WINDOW=${T_SESSION#*.}
		T_SESSION=${T_SESSION%%.*}
		;;
	esac
	if [ -z "$T_SESSION" ]; then
		T_SESSION=$(docker exec "$T_CONTAINER" tmux list-sessions -F '#{session_name}' 2>/dev/null | head -1) ||
			die "$T_CONTAINER has no tmux session (start the sandbox with an agent, or look at it from inside)"
		[ -n "$T_SESSION" ] || die "$T_CONTAINER has no tmux session"
	fi
	T_TARGET="$T_SESSION:$T_WINDOW${T_PANE:+.$T_PANE}"
}

# agent state that agent-state.ts keeps on the pane: input, working, idle
glyph(){
	case "$1" in
	input) printf '>' ;;
	working) printf '*' ;;
	idle) printf '-' ;;
	*) printf '?' ;;
	esac
}

cmd_ls(){
	local name line session status agent cmd path active glyphs T_TARGET=""
	local found=0
	for name in $(containers); do
		found=1
		printf '%s%s%s%s  %s%s%s\n' "$BOLD" "$name" "$OFF" "" "$DIM" \
			"$(docker exec "$name" tmux display-message -p '#{?client_attached,attached,detached}' 2>/dev/null || printf 'no tmux')" "$OFF"
		if ! docker exec "$name" tmux list-panes -a -F \
			'#{session_name}|#{window_index}.#{pane_index}|#{@agent}|#{@agent_status}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null; then
			printf '  %sno tmux server%s\n' "$DIM" "$OFF"
			continue
		fi | while IFS='|' read -r session pane agent status cmd path; do
			glyphs=$(glyph "$status")
			printf '  %s%s %-4s%s %-8s %-22s %s\n' "$CYAN" "$glyphs" "$status" "$OFF" \
				"${agent:--}" "$session.$pane" "$path"
		done
	done
	[ "$found" = 1 ] || die "no sandbox container is running"
}

pane_exists(){
	docker exec "$T_CONTAINER" tmux list-windows -t "$T_SESSION" -F '#{window_index}' 2>/dev/null |
		grep -qx "$T_WINDOW" || return 1
	[ -n "$T_PANE" ] || return 0
	docker exec "$T_CONTAINER" tmux list-panes -t "$T_SESSION:$T_WINDOW" -F '#{pane_index}' 2>/dev/null |
		grep -qx "$T_PANE"
}

capture(){
	docker exec "$T_CONTAINER" tmux capture-pane -p -t "$T_TARGET" -S "-$1" 2>/dev/null
}

status_of(){
	docker exec "$T_CONTAINER" tmux display-message -p -t "$T_TARGET" '#{@agent_status}' 2>/dev/null
}

cmd_read(){
	local lines=60
	[ "${1:-}" = "-n" ] && { lines=$2; shift 2; }
	split_target "${1:?read needs a target}"
	[ -n "$(docker exec "$T_CONTAINER" tmux list-sessions -F '#{session_name}' 2>/dev/null)" ] ||
		die "$T_CONTAINER has no tmux session"
	pane_exists || die "no pane $T_SESSION:$T_WINDOW${T_PANE:+.$T_PANE} in $T_CONTAINER"
	printf '%s--- %s:%s%s%s (%s)%s\n' "$DIM" "$T_CONTAINER" "$T_SESSION" "$T_WINDOW" "${T_PANE:+.$T_PANE}" "$(status_of)" "$OFF"
	capture "$lines"
}

cmd_send(){
	local text
	split_target "${1:?send needs a target}"
	shift
	text=$*
	[ -n "$text" ] || die "send needs text"
	pane_exists || die "no pane $T_SESSION:$T_WINDOW${T_PANE:+.$T_PANE} in $T_CONTAINER"
	# through the buffer, not send-keys: text keeps its dashes, quotes and newlines
	printf '%s' "$text" | docker exec -i "$T_CONTAINER" tmux load-buffer -b sandbox-panes -
	docker exec "$T_CONTAINER" tmux paste-buffer -d -b sandbox-panes -t "$T_TARGET"
	docker exec "$T_CONTAINER" tmux send-keys -t "$T_TARGET" Enter
	printf 'sent to %s:%s\n' "$T_CONTAINER" "$T_TARGET"
}

cmd_keys(){
	split_target "${1:?keys needs a target}"
	shift
	[ $# -gt 0 ] || die "keys needs at least one key"
	pane_exists || die "no pane $T_SESSION:$T_WINDOW${T_PANE:+.$T_PANE} in $T_CONTAINER"
	docker exec "$T_CONTAINER" tmux send-keys -t "$T_TARGET" "$@"
	printf 'keys %s to %s:%s\n' "$*" "$T_CONTAINER" "$T_TARGET"
}

# wait until the agent stopped working: the pane changed and its status is no
# longer 'working'. Prints the new pane, so send-then-wait is one round trip.
cmd_wait(){
	local timeout=180 waited=0 before after status stable=0 lines=80
	split_target "${1:?wait needs a target}"
	[ $# -gt 1 ] && { timeout=$2; }
	pane_exists || die "no pane $T_SESSION:$T_WINDOW${T_PANE:+.$T_PANE} in $T_CONTAINER"
	before=$(capture 20 | md5sum)
	while [ "$waited" -lt "$timeout" ]; do
		sleep 3; waited=$((waited + 3))
		after=$(capture 20 | md5sum)
		status=$(status_of)
		if [ "$after" != "$before" ]; then
			stable=$((stable + 1))
			[ "$status" = working ] && stable=0
			if [ "$stable" -ge 2 ]; then
				printf '%s--- %s:%s (%s, %ss)%s\n' "$DIM" "$T_CONTAINER" "$T_TARGET" "$status" "$waited" "$OFF"
				capture "$lines"
				return 0
			fi
		fi
	done
	warn "still nothing after ${timeout}s, last pane:"
	capture "$lines"
	return 1
}

case "${1:-}" in
ls | "") shift || true; cmd_ls ;;
read) shift; cmd_read "$@" ;;
send) shift; cmd_send "$@" ;;
wait) shift; cmd_wait "$@" ;;
keys) shift; cmd_keys "$@" ;;
-h | --help | help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
*) die "unknown command '$1' (ls, read, send, wait, keys)" ;;
esac
