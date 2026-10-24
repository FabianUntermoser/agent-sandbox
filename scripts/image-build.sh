#!/usr/bin/env bash

# USAGE: build the image under a candidate tag, check it starts, then promote it to latest

set -euo pipefail

die() { echo -e "\e[31merror:\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[36m>\e[0m $*"; }

help() {
	cat <<EOF
Usage: ${0##*/} [--rollback]

  (none)      build a candidate, promote it to latest once it starts as $RUSER, keep the old as previous
  --rollback  point latest back at previous
EOF
}

## DEFAULTS

IMAGE="${IMAGE:-agent-sandbox}"
RUSER=node
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }

## MAIN

case "${1:-}" in
-h | --help) help; exit 0 ;;
--rollback)
	[ -n "$(image_id "$IMAGE:previous")" ] || die "no $IMAGE:previous to roll back to"
	docker tag "$IMAGE:previous" "$IMAGE:latest"
	info "$IMAGE:latest is $IMAGE:previous again; running sandboxes keep their image until restarted"
	exit 0
	;;
"") ;;
*) help >&2; exit 2 ;;
esac

commit="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$REPO_DIR" diff --quiet HEAD 2>/dev/null || commit="$commit-dirty"
candidate="$IMAGE:build-$commit"

info "Building $candidate..."
cd "$REPO_DIR"
TAG="build-$commit" docker buildx bake --load

user="$(docker run --rm --user 0:0 -e SANDBOX_SKIP_FIREWALL=1 \
	--entrypoint /usr/local/bin/sandbox-entrypoint.sh "$candidate" -- id -un 2>&1 | tail -1)" || true
[ "$user" = "$RUSER" ] || die "$candidate did not start as $RUSER (got: $user); $IMAGE:latest is untouched"

old="$(image_id "$IMAGE:latest")"
new="$(image_id "$candidate")"
if [ -n "$old" ] && [ "$old" != "$new" ]; then
	docker tag "$IMAGE:latest" "$IMAGE:previous"
fi
docker tag "$candidate" "$IMAGE:latest"
docker image rm "$candidate" >/dev/null
info "$IMAGE:latest is now build-$commit${old:+; the one before is $IMAGE:previous (make rollback)}"
