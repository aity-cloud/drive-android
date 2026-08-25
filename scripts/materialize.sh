#!/usr/bin/env bash
# Materialize the Aity Drive Android tree for one Environment:
# clone the upstream Pin into build/upstream, copy the overlay on top
# (common first, then the Environment), then apply patches/*.patch.
#
# Idempotent: every run resets build/upstream to the pristine Pin before
# overlaying, so it can be re-run at will. CI and developers use it
# identically:
#
#   scripts/materialize.sh production
#   scripts/materialize.sh staging
#
# The Pin is the UPSTREAM_TAG variable in .gitlab-ci.yml (renovate-watched,
# single source of truth); export UPSTREAM_TAG to override for a Bump trial.
set -euo pipefail

usage() {
    echo "usage: scripts/materialize.sh <production|staging>" >&2
    exit 64
}

ENV="${1:-}"
case "$ENV" in
    production|staging) ;;
    *) usage ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/build/upstream"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/owncloud/android.git}"

if [ -z "${UPSTREAM_TAG:-}" ]; then
    UPSTREAM_TAG="$(sed -n 's/^ *UPSTREAM_TAG: *"\([^"]*\)".*/\1/p' "$ROOT/.gitlab-ci.yml" | head -n1)"
fi
if [ -z "$UPSTREAM_TAG" ]; then
    echo "materialize: cannot determine UPSTREAM_TAG (not in env, not in .gitlab-ci.yml)" >&2
    exit 1
fi

echo "==> materialize $ENV from owncloud/android $UPSTREAM_TAG"

if [ ! -d "$DEST/.git" ]; then
    mkdir -p "$ROOT/build"
    git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$DEST"
else
    # Make sure the Pin's tag exists locally (the clone may predate a Bump).
    if ! git -C "$DEST" rev-parse --verify --quiet "refs/tags/$UPSTREAM_TAG" >/dev/null; then
        git -C "$DEST" fetch --depth 1 origin "refs/tags/$UPSTREAM_TAG:refs/tags/$UPSTREAM_TAG"
    fi
fi

# Pristine Pin: drop every trace of a previous materialize (overlay files,
# patched sources, gradle outputs).
git -C "$DEST" -c advice.detachedHead=false checkout --detach "refs/tags/$UPSTREAM_TAG"
git -C "$DEST" reset --hard "refs/tags/$UPSTREAM_TAG"
git -C "$DEST" clean -ffdxq

for layer in common "$ENV"; do
    if [ -d "$ROOT/overlay/$layer" ]; then
        echo "==> overlay/$layer"
        cp -a "$ROOT/overlay/$layer/." "$DEST/"
    fi
done

shopt -s nullglob
for p in "$ROOT"/patches/*.patch; do
    echo "==> patch $(basename "$p")"
    git -C "$DEST" apply --verbose "$p"
done

echo "==> $ENV tree materialized at build/upstream ($(git -C "$DEST" rev-parse --short HEAD) = $UPSTREAM_TAG)"
