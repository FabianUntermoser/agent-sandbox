#!/usr/bin/env bash

# USAGE: two sibling worktrees cannot reach into each other's files or git state
#
# Runs a real container, so it needs docker and the image. One main checkout holds two linked
# worktrees and a sandbox starts in the first: the second has to stay unreadable, and its admin
# directory, branch and registration have to stay untouched.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-agent-sandbox}"

failed=0
ok(){ printf '  ok    %s\n' "$1"; }
nok(){ printf '  FAIL  %s\n' "$1" >&2; failed=1; }
expect(){ # <want> <got> <label>
	if [ "$2" = "$1" ]; then ok "$3"; else nok "$3: wanted $1, got $2"; fi
}

# The image runs as uid 1000, which has to own both worktrees and their indexes.
if [ "$(id -u)" != 1000 ]; then
	echo "  skipped: the image runs as uid 1000, this host is $(id -u)" >&2
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

main="$work/main"
a="$work/wt-a-$$"
b="$work/wt-b-$$"
slug_b="wt-b-$$"
manifest="$work/sandbox.conf"
out="$work/out"

mkdir -p "$main"
git -C "$main" init -q
# The test repo is throwaway: the host's hooks and signing settings must not reach into it.
mkdir -p "$work/no-hooks"
git -C "$main" config core.hooksPath "$work/no-hooks"
git -C "$main" config commit.gpgsign false

# The check runs inside the sandbox, so it is committed before the worktrees are added and ends
# up in both of them. Every vector prints, so a breach names itself.
cat >"$main/check.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

reached=0
breach(){ printf '   REACH  %s\n' "\$1"; reached=1; }
fenced(){ printf '   fenced %s\n' "\$1"; }
must_pass(){ # <label> <command...>
	local label="\$1"
	shift
	if "\$@" >/dev/null 2>&1; then printf '   ok     %s\n' "\$label"; else printf '   FAIL   %s\n' "\$label"; reached=1; fi
}
must_fail(){ # <label> <command...>
	local label="\$1"
	shift
	if "\$@" >/dev/null 2>&1; then breach "\$label"; else fenced "\$label"; fi
}

# This sandbox is the first worktree and has to keep working.
must_pass "the first worktree is a checkout of its own" git -C "$a" rev-parse --show-toplevel
must_pass "its history is readable" git -C "$a" log --oneline -1

# The second one is not part of this run, neither as files nor as git state. The branch probe
# comes first: a clobbered HEAD would hide whether git still guards a checked-out branch.
must_fail "a forced delete of the branch the second worktree holds" git -C "$a" branch -D branch-b
must_fail "a write to the second worktree's admin HEAD" sh -c "printf x >>'$main/.git/worktrees/$slug_b/HEAD'"
must_fail "a write to the second worktree's index" sh -c "printf x >>'$main/.git/worktrees/$slug_b/index'"
must_fail "a new file in the second worktree's admin directory" sh -c "printf x >'$main/.git/worktrees/$slug_b/planted'"
must_pass "the second worktree stays registered" sh -c "git --git-dir='$main/.git' worktree prune; test -f '$main/.git/worktrees/$slug_b/gitdir'"
must_fail "the second worktree directory" test -e "$b"
must_fail "a file of the second worktree" test -e "$b/b-only.txt"

[ "\$reached" -eq 0 ]
EOF

printf 'base\n' >"$main/base.txt"
git -C "$main" -c user.email=test@example.invalid -c user.name=test add -A
git -C "$main" -c user.email=test@example.invalid -c user.name=test commit -qm 'init'
git -C "$main" worktree add -q "$a" -b branch-a
git -C "$main" worktree add -q "$b" -b branch-b

# State only the second worktree may change: a commit, a staged file and an untracked file.
printf 'committed in b\n' >"$b/committed.txt"
git -C "$b" -c user.email=test@example.invalid -c user.name=test add committed.txt
git -C "$b" -c user.email=test@example.invalid -c user.name=test commit -qm 'in b'
printf 'staged in b\n' >"$b/staged.txt"
git -C "$b" add staged.txt
printf 'b only\n' >"$b/b-only.txt"

b_head=$(git -C "$b" rev-parse HEAD)
b_index=$(sha256sum "$main/.git/worktrees/$slug_b/index" | cut -d' ' -f1)

# No grant is on: the run may mount the worktree it starts in, the git directory its .git names,
# the other worktrees' admin directories read-only, and the catalogue's own entries.
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

run_ok=yes
if ! (cd "$a" && BASE_CONF="$work/base.conf" "$SRC/sandbox.sh" --stdio --new --manifest "$manifest" bash "$a/check.sh") >"$out" 2>&1; then
	run_ok=no
fi

printf '%s\n' "  from inside the container:"
grep -E '^   ' "$out" | sed 's/^   /  /' || true
if [ "$run_ok" = yes ]; then
	ok "a sandbox in the first worktree left the second alone"
else
	nok "a sandbox in the first worktree reached into the second"
	sed 's/^/        /' "$out" >&2
fi

expect "$b_head" "$(git -C "$b" rev-parse HEAD 2>/dev/null)" "the second worktree kept its commit"
expect "$b_index" "$(sha256sum "$main/.git/worktrees/$slug_b/index" 2>/dev/null | cut -d' ' -f1)" "the second worktree kept its index"
expect "staged.txt" "$(git -C "$b" diff --cached --name-only 2>/dev/null)" "the second worktree kept its staged file"
expect "b only" "$(cat "$b/b-only.txt" 2>/dev/null)" "the second worktree kept its untracked file"
expect "$b" "$(git -C "$b" rev-parse --show-toplevel 2>/dev/null)" "the second worktree is still registered"

[ "$failed" -eq 0 ] && echo "sandbox-worktree-siblings: ok"
exit "$failed"
