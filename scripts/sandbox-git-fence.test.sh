#!/usr/bin/env bash

# USAGE: cases for the git fences, run by make check
#
# Docker is stubbed and writes its own arguments to a file. That is what makes the refusal cases real:
# a launch that must be refused is asserted to leave that file unwritten, so nothing reached docker.
# The argv is also where the mount set is read, because the fences are only worth what they produce.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
ok() { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted [$3] got [$2]"; fi; }

mkdir -p "$T/bin" "$T/nohooks" "$T/hooks-default" "$T/hooks-ext" "$T/extra"
cat >"$T/bin/docker" <<STUB
#!/usr/bin/env bash
# Every call is logged. A launch is what the cases below are about, so only \`run\` records an argv:
# the launcher also asks docker for a free container name before it gets that far.
printf '%s\n' "\$*" >>"$T/docker.calls"
if [ "\${1:-}" = run ]; then printf '%s\n' "\$@" >"$T/docker.argv"; fi
exit 0
STUB
chmod +x "$T/bin/docker"
: >"$T/base.conf"
cat >"$T/manifest.conf" <<'EOF'
AGENTS=""
GIT_AUTH=false
LOCAL_BIN=false
TMUX=false
NETWORK=offline
HOST_SERVICES=""
EOF

mounts() { # every -v entry as destination=mode, from the argv docker was handed
	python3 - "$T/docker.argv" <<'PY'
import os, sys
path = sys.argv[1]
if not os.path.exists(path):
    raise SystemExit
args = [line for line in open(path).read().splitlines() if line]
for i, arg in enumerate(args):
    if arg != "-v" or i + 1 >= len(args):
        continue
    parts = args[i + 1].split(":")
    mode = parts[-1] if len(parts) > 2 and parts[-1] in ("ro", "rw") else "rw"
    dest = ":".join(parts[1:-1]) if mode != "rw" else ":".join(parts[1:])
    print(f"{dest}={mode}")
PY
}

fixture() { # <name> -> a plain checkout with one commit and no hooks directory
	local dir="$T/$1"
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" config user.email test@example.invalid
	git -C "$dir" config user.name test
	printf 'base\n' >"$dir/a.txt"
	git -C "$dir" add -A
	git -C "$dir" -c core.hooksPath="$T/nohooks" commit -qm init
	printf '%s\n' "$dir"
}

launch() { # <dir> [mount entry ...] -> run the launcher with the stub docker
	local dir=$1
	shift
	{
		cat "$T/manifest.conf"
		printf 'MOUNTS=('
		printf ' %q' "$@"
		printf ')\n'
	} >"$T/manifest.local"
	rm -f "$T/docker.argv" "$T/docker.calls"
	set +e
	(cd "$dir" && BASE_CONF="$T/base.conf" PATH="$T/bin:$PATH" "$SRC/sandbox.sh" --stdio --new --manifest "$T/manifest.local" true) >"$T/out" 2>&1
	echo "$?"
}

launched() { [ -f "$T/docker.argv" ]; }

printf '  a missing hooks directory is created and fenced\n'
repo="$(fixture missing-hooks)"
rm -rf "$repo/.git/hooks"
rc="$(launch "$repo")"
chk "the launch proceeds" "$rc" "0"
chk "the hooks directory is mounted read-only" "$(mounts | grep -c "^$repo/.git/hooks=ro$")" "1"
chk "the name now exists on the host" "$([ -d "$repo/.git/hooks" ] && echo yes || echo no)" "yes"

printf '  a missing configured hooks target is created and fenced\n'
repo="$(fixture missing-target)"
git -C "$repo" config core.hooksPath .githooks
rc="$(launch "$repo")"
chk "the launch proceeds" "$rc" "0"
chk "the target is mounted read-only" "$(mounts | grep -c "^$repo/.githooks=ro$")" "1"
chk "the target now exists on the host" "$([ -d "$repo/.githooks" ] && echo yes || echo no)" "yes"

printf '  a git directory that cannot be fenced refuses before docker\n'
repo="$(fixture unwritable)"
chmod 500 "$repo/.git"
rc="$(launch "$repo")"
chmod 700 "$repo/.git"
if [ "$rc" = 0 ]; then
	bad "a launch proceeded with a git directory it could not fence"
elif launched; then
	bad "docker was invoked for a launch that cannot fence its git directory"
elif grep -q 'refusing to launch' "$T/out"; then
	ok "the launch is refused before docker when the git directory cannot be fenced"
else
	bad "the refusal did not say why: $(tail -2 "$T/out")"
fi

printf '  a commondir that is a symlink refuses before docker\n'
repo="$(fixture dangling)"
printf 'sentinel\n' >"$T/sentinel"
ln -s "$T/sentinel" "$repo/.git/commondir"
rc="$(launch "$repo")"
if [ "$rc" = 0 ]; then
	bad "a launch proceeded with a symlinked commondir"
elif launched; then
	bad "docker was invoked for a launch with a symlinked commondir"
elif grep -q 'not a regular file' "$T/out"; then
	ok "a symlinked commondir is refused before docker"
else
	bad "the refusal did not say why: $(tail -2 "$T/out")"
fi
chk "the symlink target is untouched" "$(cat "$T/sentinel" 2>/dev/null)" "sentinel"

printf '  a writable mount below a fenced name refuses before docker\n'
repo="$(fixture nested)"
rc="$(launch "$repo" "$T/extra:$repo/.git/hooks/nested")"
if [ "$rc" = 0 ]; then
	bad "a launch proceeded with a writable mount under the hooks directory"
elif launched; then
	bad "docker was invoked with a writable mount under a fenced name"
elif grep -q 'fenced read-only' "$T/out"; then
	ok "a writable mount below a fenced name is refused before docker"
else
	bad "the refusal did not say why: $(tail -2 "$T/out")"
fi

printf '  an external hooks path is fenced only when the mount set exposes it\n'
repo="$(fixture external)"
git -C "$repo" config core.hooksPath "$T/hooks-ext"
rc="$(launch "$repo")"
chk "a target outside every mount changes nothing" "$rc" "0"
chk "nothing is mounted for it" "$(mounts | grep -c "^$T/hooks-ext=" || true)" "0"

rc="$(launch "$repo" "$T/hooks-ext:$T/hooks-ext")"
chk "the launch proceeds when a manifest entry exposes it" "$rc" "0"
chk "the exposed directory is mounted read-only" "$(mounts | grep -c "^$T/hooks-ext=ro$")" "1"
chk "and no writable entry is left for it" "$(mounts | grep -c "^$T/hooks-ext=rw$" || true)" "0"

ln -s "$T/hooks-ext" "$repo/hooks-link"
rc="$(launch "$repo")"
chk "the launch proceeds when a project symlink exposes it" "$rc" "0"
chk "the symlink destination is mounted read-only" "$(mounts | grep -c "^$repo/hooks-link=ro$")" "1"
chk "and no writable entry is left for it" "$(mounts | grep -c "^$repo/hooks-link=rw$" || true)" "0"

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
