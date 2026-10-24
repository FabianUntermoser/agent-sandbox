#!/usr/bin/env bash

# USAGE: cases for the staged image build and its rollback, run by make check

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
failed=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; failed=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tags"

# docker is stubbed with a tag store: one file per tag holding the image id it names. A build
# writes NEW_ID under the tag bake is given, and a run answers as RUN_USER.
cat >"$work/bin/docker" <<EOF
#!/usr/bin/env bash
tags="$work/tags"
key() { printf '%s' "\$1" | tr ':/' '__'; }
case "\$1 \$2" in
"buildx bake") [ -n "\${BUILD_FAILS:-}" ] && exit 1; printf '%s' "\$NEW_ID" >"\$tags/\$(key "\$IMAGE:\$TAG")" ;;
"image inspect") f="\$tags/\$(key "\${@: -1}")"; [ -f "\$f" ] && cat "\$f" && echo || exit 1 ;;
"image rm") rm -f "\$tags/\$(key "\$3")" ;;
run*) echo "\$RUN_USER" ;;
tag*) cp "\$tags/\$(key "\$2")" "\$tags/\$(key "\$3")" ;;
esac
EOF
chmod +x "$work/bin/docker"

run() { PATH="$work/bin:$PATH" IMAGE=sb "$@" "$SRC/image-build.sh" ${ARGS:-} >"$work/out" 2>&1; }
id_of() { cat "$work/tags/sb_$1" 2>/dev/null || echo none; }
reset() { rm -f "$work"/tags/*; [ -z "${1:-}" ] || printf '%s' "$1" >"$work/tags/sb_latest"; }

reset good
if run env NEW_ID=cand RUN_USER=node && [ "$(id_of latest)" = cand ] && [ "$(id_of previous)" = good ]; then
	ok "a candidate that starts as node becomes latest and the old latest is kept as previous"
else
	bad "promotion: latest=$(id_of latest) previous=$(id_of previous): $(tail -1 "$work/out")"
fi
if ls "$work/tags" | grep -q build-; then bad "the candidate tag is left behind"; else ok "the candidate tag is removed once latest names it"; fi

reset good
if run env NEW_ID=broken RUN_USER=root; then
	bad "a candidate that does not drop to node was promoted"
elif [ "$(id_of latest)" = good ] && ls "$work/tags" | grep -q build-; then
	ok "a candidate that does not drop to node leaves latest untouched and stays inspectable"
else
	bad "failed check: latest=$(id_of latest)"
fi

reset good
if run env NEW_ID=x RUN_USER=node BUILD_FAILS=1; then
	bad "a failed build reported success"
elif [ "$(id_of latest)" = good ]; then
	ok "a failed build leaves latest untouched"
else
	bad "failed build: latest=$(id_of latest)"
fi

reset good
if run env NEW_ID=good RUN_USER=node && [ "$(id_of previous)" = none ]; then
	ok "rebuilding the same image does not overwrite previous with itself"
else
	bad "same image: previous=$(id_of previous)"
fi

reset
if run env NEW_ID=first RUN_USER=node && [ "$(id_of latest)" = first ] && [ "$(id_of previous)" = none ]; then
	ok "a first build on a machine with no latest promotes without a previous"
else
	bad "first build: latest=$(id_of latest) previous=$(id_of previous)"
fi

reset cand
printf '%s' good >"$work/tags/sb_previous"
if ARGS=--rollback run env && [ "$(id_of latest)" = good ]; then
	ok "rollback points latest back at previous"
else
	bad "rollback: latest=$(id_of latest)"
fi

reset cand
if ARGS=--rollback run env; then
	bad "rollback with no previous reported success"
elif [ "$(id_of latest)" = cand ]; then
	ok "rollback with no previous refuses and leaves latest alone"
else
	bad "rollback without previous: latest=$(id_of latest)"
fi

exit "$failed"
