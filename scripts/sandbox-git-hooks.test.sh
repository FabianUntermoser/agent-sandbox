#!/usr/bin/env bash

# USAGE: a sandbox cannot hand the host code to run through git state
#
# Runs real containers, so it needs docker and the image. Two shapes are exercised: a plain
# checkout and a linked worktree of the same repository. In both, the sandbox has to be unable to
# write the hooks directory, the config that chooses it, or a worktree config, while reading them,
# committing and reading history keep working. The host files are compared afterwards: a write that
# reached them is the breach this guards.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-agent-sandbox}"

failed=0
ok(){ printf '  ok    %s\n' "$1"; }
nok(){ printf '  FAIL  %s\n' "$1" >&2; failed=1; }
expect(){ # <want> <got> <label>
	if [ "$2" = "$1" ]; then ok "$3"; else nok "$3: wanted $1, got $2"; fi
}

if [ "$(id -u)" != 1000 ]; then
	echo "  skipped: the image runs as uid 1000, this host is $(id -u)" >&2
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

main="$work/main"
wt="$work/wt-$$"
slug="wt-$$"
manifest="$work/sandbox.conf"

mkdir -p "$main"
git -C "$main" init -q
git -C "$main" config commit.gpgsign false
git -C "$main" config user.email test@example.invalid
git -C "$main" config user.name test
# The test repo is throwaway: the host's own hooks must not run while it is built. The fixture sets
# core.hooksPath again below, to the directory inside the repository this test is about.
mkdir -p "$work/no-hooks"
git -C "$main" config core.hooksPath "$work/no-hooks"

# The check runs inside the sandbox, so it is committed before the worktree is added and ends up in
# both shapes. It resolves every path with git itself, so the same script fits the two layouts.
cat >"$main/check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

reached=0
breach(){ printf '   REACH  %s\n' "$1"; reached=1; }
fenced(){ printf '   fenced %s\n' "$1"; }
must_pass(){ # <label> <command...>
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then printf '   ok     %s\n' "$label"; else printf '   FAIL   %s\n' "$label"; reached=1; fi
}
must_fail(){ # <label> <command...>
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then breach "$label"; else fenced "$label"; fi
}

git_dir="$(git rev-parse --git-dir)"
hooks="$(git rev-parse --git-path hooks)"
config="$(git rev-parse --git-path config)"

# Legitimate work: history is readable, a file can be committed, the hooks directory is readable.
must_pass "the history is readable" git log --oneline -1
must_pass "the object store is writable" sh -c "printf 'by the sandbox\n' > sandbox-file.txt && git add sandbox-file.txt && git commit -qm 'from the sandbox'"
must_pass "the hooks directory is readable" test -d "$hooks"

# Host execution surfaces: a hook written here runs on the host after the next git operation in
# this checkout, and a writable config is enough to point git at a hooks directory the sandbox owns.
must_fail "a hook planted in the hooks directory" sh -c "printf '#!/bin/sh\ntouch \"$0.executed\"\n' >'$hooks/pre-commit' && chmod +x '$hooks/pre-commit'"
must_fail "a hook path appended to the config" sh -c "printf '\n[core]\n\thooksPath = .\n' >>'$config'"
must_fail "a hook planted at the hooks path the operator configured" sh -c "printf '#!/bin/sh\nexit 0\n' >.githooks/pre-commit"

[ "$reached" -eq 0 ]
EOF

printf 'base\n' >"$main/base.txt"
mkdir -p "$main/.githooks"
printf '# the operator own hooks live here\n' >"$main/.githooks/README"
# A hook the operator installed is readable and runs where git reads it, which is the legitimate half
# the fences above must not break. The sandbox commit below is what proves it still runs.
cat >"$main/.githooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
printf 'the operator hook ran\n' > hook-ran.txt
HOOK
chmod +x "$main/.githooks/pre-commit"
git -C "$main" add -A
git -C "$main" commit -qm 'init'
git -C "$main" config core.hooksPath .githooks
git -C "$main" worktree add -q "$wt" -b sandbox-branch
# The fixture commit ran the hook too, so its marker goes before the sandbox runs: what the
# assertions below see has to be the sandbox commit and nothing earlier.
rm -f "$main/hook-ran.txt" "$wt/hook-ran.txt"

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

# What the host has to still hold afterwards, whichever shape ran.
hooks_listing="$(ls -A "$main/.git/hooks" 2>/dev/null)"
config_hash="$(sha256sum "$main/.git/config" | cut -d' ' -f1)"
githooks_hash="$(sha256sum "$main/.githooks/README" | cut -d' ' -f1)"
operator_hook_hash="$(sha256sum "$main/.githooks/pre-commit" | cut -d' ' -f1)"

# A hooks path that points at the checkout itself cannot be fenced without making the whole tree
# read-only, so the launcher refuses instead of leaving the hook files writable.
tight="$work/tight"
mkdir -p "$tight"
git -C "$tight" init -q
git -C "$tight" config core.hooksPath .
printf 'x\n' >"$tight/file.txt"
git -C "$tight" add -A
if (cd "$tight" && BASE_CONF="$work/base.conf" "$SRC/sandbox.sh" --stdio --new --manifest "$manifest" bash -c 'exit 0') >"$work/tight.out" 2>&1; then
	nok "a hooks path pointing at the checkout root was accepted"
elif grep -q 'cannot be fenced' "$work/tight.out"; then
	ok "a hooks path pointing at the checkout root is refused before docker runs"
else
	nok "the refusal did not say why: $(tail -2 "$work/tight.out")"
fi

# The worktree config is a third way to choose a hooks directory, and git reads it only with the
# extension on. The file that turns it on is read-only inside, so the extension being on already is
# what has to stop the run: the sandbox would otherwise write the redirect itself.
extended="$work/extended"
mkdir -p "$extended"
git -C "$extended" init -q
git -C "$extended" config extensions.worktreeConfig true
printf 'x\n' >"$extended/file.txt"
git -C "$extended" add -A
if (cd "$extended" && BASE_CONF="$work/base.conf" "$SRC/sandbox.sh" --stdio --new --manifest "$manifest" bash -c 'exit 0') >"$work/extended.out" 2>&1; then
	nok "a repository with the worktree config extension on was accepted"
elif grep -q 'extensions.worktreeConfig is on' "$work/extended.out"; then
	ok "the worktree config extension being on is refused before docker runs"
else
	nok "the refusal did not say why: $(tail -2 "$work/extended.out")"
fi

run(){ # <label> <directory>
	local label=$1
	local dir=$2
	local out="$work/out-$(basename "$dir")"
	if (cd "$dir" && BASE_CONF="$work/base.conf" "$SRC/sandbox.sh" --stdio --new --manifest "$manifest" bash "$dir/check.sh") >"$out" 2>&1; then
		printf '%s\n' "  $label, from inside the container:"
		grep -E '^   ' "$out" | sed 's/^   /    /' || true
		ok "$label: the sandbox could not hand the host a hook"
	else
		nok "$label: the sandbox reached a host execution surface"
		sed 's/^/        /' "$out" >&2
	fi
}

run "plain checkout" "$main"
run "linked worktree" "$wt"

# The host side of the same claim: nothing a sandbox wrote may be there.
expect "$hooks_listing" "$(ls -A "$main/.git/hooks" 2>/dev/null)" "the host hooks directory is unchanged"
expect "$config_hash" "$(sha256sum "$main/.git/config" | cut -d' ' -f1)" "the host git config is unchanged"
expect "$githooks_hash" "$(sha256sum "$main/.githooks/README" | cut -d' ' -f1)" "the operator hooks directory is unchanged"
expect "README pre-commit" "$(ls -A "$main/.githooks" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "the operator hooks directory holds only what it held"
expect ".githooks" "$(git -C "$main" config --get core.hooksPath)" "the host still points at its own hooks directory"

# And the legitimate half has to have happened, or the fences above prove nothing.
expect "1" "$(git -C "$main" log --oneline --author=test -1 --format=%s | grep -c 'from the sandbox' || true)" "the host sees the commit the sandbox made in the plain checkout"
expect "by the sandbox" "$(cat "$main/sandbox-file.txt" 2>/dev/null)" "the sandbox wrote its file in the plain checkout"
expect "1" "$(git -C "$wt" log --oneline -1 --format=%s | grep -c 'from the sandbox' || true)" "the host sees the commit the sandbox made in the worktree"
expect "the operator hook ran" "$(cat "$main/hook-ran.txt" 2>/dev/null)" "the hook the operator installed still ran for the sandbox commit"
expect "the operator hook ran" "$(cat "$wt/hook-ran.txt" 2>/dev/null)" "and it ran in the worktree shape too"
expect "$operator_hook_hash" "$(sha256sum "$main/.githooks/pre-commit" | cut -d' ' -f1)" "the operator hook is byte-identical afterwards"

[ "$failed" -eq 0 ] && echo "sandbox-git-hooks: ok"
exit "$failed"
