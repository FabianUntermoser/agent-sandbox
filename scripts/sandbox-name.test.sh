#!/usr/bin/env bash

# USAGE: cases for the container name a run gets, run by make check
#
# No container is started: docker is stubbed and records the argv of the run, so the name the
# script chose can be read back, and a run that never reached the stub was stopped before it.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0

work="$(mktemp -d)"
stub="$(mktemp -d)"
trap 'rm -rf "$work" "$stub"' EXIT

args="$work/run.args"

cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
	run) printf '%s\n' "\$@" >"$args" ;;
	ps)  [ -n "\${STUB_PS:-}" ] && printf '%s\n' "\$STUB_PS" ;;
esac
exit 0
EOF
chmod +x "$stub/docker"

run(){ # the flags a case adds, then the command the container runs
	rm -f "$args"
	(cd "$work" && PATH="$stub:$PATH" "$SRC/sandbox.sh" --stdio --new "$@" true) >"$work/out" 2>&1
}

expect(){ # <want> <got> <label>
	if [ "$2" = "$1" ]; then
		printf '  ok    %s\n' "$3"
	else
		printf '  FAIL  %s: wanted %s, got %s\n' "$3" "$1" "$2" >&2
		sed 's/^/        /' "$work/out" >&2
		failed=1
	fi
}

got(){ grep -qx -- "$1" "$args" 2>/dev/null && echo yes || echo no; }
ran(){ [ -f "$args" ] && echo yes || echo no; }
project="$(basename "$work")"

printf '  no flag\n'
run || true
expect yes "$(got "sandbox-$project")" "the container is named after the project"

printf '  --name\n'
run --name probe-one || true
expect yes "$(got probe-one)" "the given name is the one docker is asked for"
expect no "$(got "sandbox-$project")" "and the derived name is not"

printf '  --name= form\n'
run --name=probe-two || true
expect yes "$(got probe-two)" "the equals form works too"

printf '  an illegal name\n'
if run --name 'probe three'; then
	expect stopped ran "a name with a space is refused"
else
	expect no "$(ran)" "a name with a space stops the run before docker"
fi

printf '  a name already taken\n'
if STUB_PS=probe-one run --name probe-one; then
	expect stopped ran "a taken name is refused"
else
	expect no "$(ran)" "a taken name stops the run before docker"
fi

[[ $failed == 0 ]] && echo "sandbox-name: ok"
exit $failed
