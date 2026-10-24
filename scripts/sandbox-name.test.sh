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
inspect_args="$work/inspect.args"
mkdir -p "$work/runtime"

cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
	info) : ;;
	version) printf '%s\n' "\${STUB_ENGINE-29.0.0}" ;;
	run) printf '%s\n' "\$@" >"$args" ;;
	ps)
		case "\$*" in
			*'{{.Label "agent-sandbox.managed"}}'*)
				[ -n "\${STUB_LEGACY:-}" ] && printf '%s\tUp 3 minutes\tagent-sandbox\tfalse\t\n' "\$STUB_LEGACY"
				printf '%s\tUp 2 minutes\tagent-sandbox\ttrue\t/tmp/project\n' "\${STUB_PS:-sandbox-listed-item}" ;;
			*)
				[ -n "\${STUB_PS:-}" ] && printf '%s\n' "\$STUB_PS" ;;
		esac
		;;
	container)
		printf '%s\n' "\$@" >"$inspect_args"
		printf '%s\n' 'name:       /sandbox-cli-test' 'status:     running' 'image:      agent-sandbox' 'project:    /tmp/project' 'manifest:   /tmp/project/.sandbox.conf' 'network:    agent-sandbox-net' 'published:  {"3000/tcp":[{"HostIp":"127.0.0.1","HostPort":"8130"}]}' 'cap-add:    ["NET_ADMIN"]' 'cap-drop:   ["NET_RAW"]' 'mounts:' '  /tmp/project -> /tmp/project (rw)'
		;;
esac
exit 0
EOF
chmod +x "$stub/docker"

# The catalogue ships in the repo; the run reads it from the path setup writes on a real machine,
# so the case points at the repo's own copy instead of whatever the host has installed.
base_conf="$work/base.conf"
cp "$SRC/../config/base.conf" "$base_conf"

run(){ # the flags a case adds, then the command the container runs
	rm -f "$args"
	(cd "$work" && PATH="$stub:$PATH" HOME="$work/home" XDG_RUNTIME_DIR="$work/runtime" BASE_CONF="$base_conf" "$SRC/sandbox.sh" --stdio --new "$@" true) >"$work/out" 2>&1
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
expect yes "$(got '--user=0:0')" 'firewall bootstrap runs as root only at startup'
expect yes "$(got '/usr/local/bin/sandbox-entrypoint.sh')" 'the dedicated entrypoint owns bootstrap and capability drop'
expect yes "$(got '--cap-add=NET_ADMIN')" 'NET_ADMIN is granted only for firewall bootstrap'
expect no "$(got '--cap-add=NET_RAW')" 'NET_RAW is never granted to the bootstrap container'
expect yes "$(got '--cap-drop=NET_RAW')" 'NET_RAW is removed from Docker capability defaults'
expect yes "$(got '--')" 'the agent command is separated from trusted service grants'
expect no "$(got '/bin/bash')" 'the launcher no longer runs an agent shell as the privileged bootstrap command'

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



printf '  host network mode still isolates Pi and drops privileges\n'
host_manifest="$work/host-network.conf"
printf 'MOUNTS=()\nNETWORK=host\n' >"$host_manifest"
run --manifest "$host_manifest" || true
expect yes "$(got '--network=host')" 'host mode keeps the explicit network selection'
expect yes "$(got '--entrypoint')" 'host mode uses the security entrypoint'
expect yes "$(got 'SANDBOX_SKIP_FIREWALL=1')" 'host mode skips unsupported firewall bootstrap'
expect yes "$(got '/usr/local/bin/sandbox-entrypoint.sh')" 'host mode still uses the privilege-dropping entrypoint'
expect yes "$(got '--cap-drop=NET_RAW')" 'host mode also drops NET_RAW'
expect no "$(got '--cap-add=NET_ADMIN')" 'host mode receives no NET_ADMIN'
expect no "$(got '--cap-add=NET_RAW')" 'host mode receives no NET_RAW'
expect yes "$(got 'PI_CODING_AGENT_DIR=/tmp/agent-sandbox-pi-agent-sandbox-'$project)" 'host mode gets a stable per-container Pi state path'

printf '  both network modes hand the command its own home\n'
# The entrypoint derives the Pi agent directory and the permission policy from $HOME before it
# drops privileges, so a root home means a root path in either mode. One shared argument, asserted
# in both, is the point of this case.
printf 'MOUNTS=()\n' >"$work/bridge-home.conf"
run --manifest "$work/bridge-home.conf" || true
expect yes "$(got 'HOME=/home/node')" 'bridge mode hands the command its own home'
run --manifest "$host_manifest" || true
expect yes "$(got 'HOME=/home/node')" 'host mode hands the command its own home'

printf '  no arguments shows help rather than launching a shell\n'
if (cd "$work" && PATH="$stub:$PATH" "$SRC/sandbox.sh") >"$work/out" 2>&1 &&
	grep -q 'interactive shell' "$work/out" &&
	! grep -q "image 'agent-sandbox' not found" "$work/out"; then
	printf '  ok    no arguments shows help without launching\n'
else
	printf '  FAIL  no arguments did not show help\n' >&2
	sed 's/^/        /' "$work/out" >&2
	failed=1
fi

port_manifest="$work/ports.conf"
printf 'MOUNTS=()\nPORTS=("8130:3000")\n' >"$port_manifest"
printf '  reverse port publishing\n'
run --manifest "$port_manifest" || true
expect yes "$(got '127.0.0.1:8130:3000/tcp')" 'PORTS maps the sandbox port onto host loopback'
services_mount=$(grep -F '/etc/agent-sandbox-host-services:ro' "$args" | sed 's#:/etc/agent-sandbox-host-services:ro$##' | tail -1)
if [ -n "$services_mount" ] && grep -qx 'published:3000' "$services_mount"; then
  printf '  ok    the firewall grant file includes the published container port\n'
else
  printf '  FAIL  the firewall grant file does not include published:3000\n' >&2
  failed=1
fi

for engine in 27.5.1 '' not-a-version; do
  STUB_ENGINE=$engine run --manifest "$port_manifest" || true
  expect no "$(ran)" "PORTS refuses Docker Engine '$engine' before docker run"
done
STUB_ENGINE=28.0.0 run --manifest "$port_manifest" || true
expect yes "$(got '127.0.0.1:8130:3000/tcp')" 'PORTS accepts Docker Engine 28.0.0'

printf 'MOUNTS=()\nPORTS=("0:3000")\n' >"$port_manifest"
run --manifest "$port_manifest" || true
expect no "$(ran)" 'port zero refuses launch before docker'

printf 'MOUNTS=()\nPORTS=("8130:3000" "8130:5173")\n' >"$port_manifest"
run --manifest "$port_manifest" || true
expect no "$(ran)" 'duplicate host port refuses launch before docker'

printf 'MOUNTS=()\nNETWORK=host\nPORTS=("8130:3000")\n' >"$port_manifest"
run --manifest "$port_manifest" || true
expect no "$(ran)" 'PORTS cannot be combined with host networking'

printf '  --list includes running managed and legacy sandboxes\n'
if (cd "$work" && PATH="$stub:$PATH" STUB_PS=sandbox-listed-item STUB_LEGACY=custom-named-sandbox "$SRC/sandbox.sh" --list) >"$work/out" 2>&1 &&
	grep -q 'sandbox-listed-item' "$work/out" &&
	grep -q 'custom-named-sandbox' "$work/out"; then
	printf '  ok    --list reports managed, default-named and legacy custom-named sandboxes\n'
else
	printf '  FAIL  --list did not list sandboxes\n' >&2
	sed 's/^/        /' "$work/out" >&2
	failed=1
fi

printf '  inspect shows effective Docker configuration\n'
if (cd "$work" && PATH="$stub:$PATH" STUB_PS=sandbox-cli-test "$SRC/sandbox.sh" inspect) >"$work/out" 2>&1 &&
	grep -q 'image:      agent-sandbox' "$work/out" &&
	grep -q 'network:    agent-sandbox-net' "$work/out" &&
	grep -q 'published:  .*127.0.0.1' "$work/out" &&
	grep -q 'mounts:' "$work/out" &&
	grep -q -- '--format' "$inspect_args"; then
	printf '  ok    inspect reports image, network, ports, capabilities and mounts\n'
else
	printf '  FAIL  inspect did not show effective Docker configuration\n' >&2
	sed 's/^/        /' "$work/out" >&2
	failed=1
fi

[[ $failed == 0 ]] && echo "sandbox-name: ok"
exit $failed
