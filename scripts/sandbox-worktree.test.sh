#!/usr/bin/env bash

# USAGE: a linked worktree works in the sandbox while the checkout that holds it stays out
#
# Runs a real container, so it needs docker and the image. The worktree is what the run was
# asked for: git has to work in it, and no file of the main checkout may be reachable.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-agent-sandbox}"

failed=0
ok(){ printf '  ok    %s\n' "$1"; }
nok(){ printf '  FAIL  %s\n' "$1" >&2; failed=1; }
expect(){ # <want> <got> <label>
	if [ "$2" = "$1" ]; then ok "$3"; else nok "$3: wanted $1, got $2"; fi
}

# The image runs as uid 1000, which has to own the worktree and its index to write them.
if [ "$(id -u)" != 1000 ]; then
	echo "  skipped: the image runs as uid 1000, this host is $(id -u)" >&2
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

main="$work/main"
wt="$work/wt-$$"
manifest="$work/sandbox.conf"
out="$work/out"

mkdir -p "$main/src"
printf 'keep\n' >"$main/src/keep.txt"
printf 'main only\n' >"$main/main-only.txt"
# Written before the worktree is added, so the checkout that runs in there has it. Every step
# prints, so a failure names the assertion instead of leaving a silent exit behind.
cat >"$main/check.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

pass(){ printf '   ok   %s\n' "\$1"; }
die(){ printf '   FAIL %s\n' "\$1" >&2; exit 1; }

[ -f "$main/.git/HEAD" ] || die "the git directory a worktree's .git file names is not mounted"
[ -f "$main/.git/worktrees/wt-$$/gitdir" ] || die "the worktree's admin directory is not mounted"
pass "the git directory and the worktree's admin directory are mounted"

[ ! -e "$main/main-only.txt" ] || die "a file of the main checkout is reachable"
[ ! -e "$main/src/keep.txt" ] || die "the main checkout's working tree is reachable"
pass "the working tree around that git directory is not"

[ -f "$wt/wt-only.txt" ] || die "the worktree is not there"
[ "\$(git -C "$wt" rev-parse --show-toplevel)" = "$wt" ] || die "git does not see the worktree as its toplevel"
git -C "$wt" status --porcelain | grep -q '?? wt-only.txt' || die "git does not see the worktree's own files"
pass "the worktree is a checkout of its own"

git -C "$wt" log --oneline -1 | grep -q ' init\$' || die "the history is not reachable through commondir"
printf 'from sandbox\n' >"$wt/from-sandbox.txt"
git -C "$wt" add from-sandbox.txt
git -C "$wt" -c user.email=test@example.invalid -c user.name=sandbox commit -qm 'from sandbox'
pass "the history is readable and writable"
EOF

git -C "$main" init -q
# The test repo is throwaway: the host's hooks and signing settings must not reach into it.
mkdir -p "$work/no-hooks"
git -C "$main" config core.hooksPath "$work/no-hooks"
git -C "$main" config commit.gpgsign false
git -C "$main" -c user.email=test@example.invalid -c user.name=test add -A
git -C "$main" -c user.email=test@example.invalid -c user.name=test commit -qm 'init'
git -C "$main" worktree add -q "$wt" -b wt-branch
printf 'worktree only\n' >"$wt/wt-only.txt"

# No grant is on: the run may mount the worktree, the git directory its .git names, and the
# catalogue's own entries. The main checkout is none of those, so nothing of it may appear.
: >"$work/base.conf"
cat >"$manifest" <<'EOF'
AGENTS=""
GIT_AUTH=false
LOCAL_BIN=false
TMUX=false
NETWORK=offline
HOST_SERVICES=""
MOUNTS=()
EOF

if (cd "$wt" && BASE_CONF="$work/base.conf" "$SRC/sandbox.sh" --stdio --new --manifest "$manifest" bash "$wt/check.sh") >"$out" 2>&1; then
	ok "the worktree is usable in the container and the main checkout is out of reach"
else
	nok "the run failed inside the container"
	sed 's/^/        /' "$out" >&2
fi

expect "?? wt-only.txt" "$(git -C "$wt" status --porcelain 2>/dev/null)" "the worktree was written to and left clean"
expect "from sandbox" "$(cat "$wt/from-sandbox.txt" 2>/dev/null)" "the file written in the container landed on the host"
expect "from sandbox" "$(git -C "$main" log --format=%s -1 wt-branch 2>/dev/null)" "the commit made in the container is on the branch the worktree holds"

[ "$failed" -eq 0 ] && echo "sandbox-worktree: ok"
exit "$failed"
