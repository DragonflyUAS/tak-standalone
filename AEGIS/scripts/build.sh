#!/usr/bin/env bash
#
# AEGIS — build the single self-contained TAK Server image (gradle "full" flavor).
#
# Produces a docker image `${IMAGE_NAME}:<version>` (+ :latest) from this source
# tree. Reusable locally (x86-64) and in CI (GitHub Actions).
#
# Env overrides:
#   IMAGE_NAME   image repository name            (default: takserver-aegis)
#   REGISTRY     registry prefix, e.g.            (default: empty = local-only tags)
#                ghcr.io/dragonflyuas
#   SKIP_GRADLE  "1" = reuse existing build output, skip gradle (debug only)
#
# Requirements: x86-64 host, JDK 17, Docker. TAK Server does NOT build on arm64.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGIS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$AEGIS_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/src"
DIST_DIR="$AEGIS_DIR/dist"
STAGING_DIR="$DIST_DIR/staging"

VERSION="$(tr -d '[:space:]' < "$AEGIS_DIR/VERSION")"
IMAGE_NAME="${IMAGE_NAME:-takserver-aegis}"
REGISTRY="${REGISTRY:-}"
if [[ -n "$REGISTRY" ]]; then
  IMAGE_REF="${REGISTRY%/}/${IMAGE_NAME}"
else
  IMAGE_REF="${IMAGE_NAME}"
fi

log() { printf '\033[36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[build:ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
log "TAK version (pinned): $VERSION"
log "image ref:            $IMAGE_REF"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64 | amd64) ;;
  *) die "TAK Server requires x86-64; detected '$ARCH'. Build on an amd64 host / CI runner." ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
command -v unzip  >/dev/null 2>&1 || die "unzip not found on PATH."
command -v java   >/dev/null 2>&1 || die "java not found. JDK 17 is required."

JV="$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
[[ "$JV" == "17" ]] || die "JDK 17 required; found major version '$JV'."

# --- version tag -----------------------------------------------------------
# build.gradle derives the version via `Grgit.open(..).describe()` then tokenizes
# on '-'. This repo carries no tags, so the build would fail. Create an ephemeral
# *annotated* tag on HEAD matching VERSION (annotated so `git describe` / JGit
# both see it), and remove it on exit so the user's repo state is untouched.
CREATED_TAG=""
cleanup() { [[ -n "$CREATED_TAG" ]] && git -C "$REPO_ROOT" tag -d "$CREATED_TAG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if EXACT="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null)"; then
  log "HEAD already tagged ($EXACT) — using existing tag."
elif git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  die "Tag '$VERSION' exists but is not on HEAD. Move it to HEAD or check out the tagged commit."
else
  log "Creating ephemeral annotated tag '$VERSION' on HEAD (auto-removed on exit)."
  git -C "$REPO_ROOT" tag -a "$VERSION" -m "AEGIS build $VERSION"
  CREATED_TAG="$VERSION"
fi

# --- gradle build (full flavor → single-image zip) -------------------------
if [[ "${SKIP_GRADLE:-0}" != "1" ]]; then
  log "Running ./gradlew clean buildFullDocker (first run downloads deps, ~10-15 min)…"
  ( cd "$SRC_DIR" && ./gradlew --no-daemon clean buildFullDocker )
else
  log "SKIP_GRADLE=1 — reusing existing build output."
fi

ZIP="$(ls -t "$SRC_DIR"/takserver-package/build/distributions/takserver-docker-full-*.zip 2>/dev/null | head -1 || true)"
[[ -n "$ZIP" && -f "$ZIP" ]] || die "buildFullDocker zip not found under takserver-package/build/distributions/."
log "artifact: $ZIP"

# --- stage -----------------------------------------------------------------
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp "$ZIP" "$DIST_DIR/"
unzip -q "$ZIP" -d "$STAGING_DIR"

PKG_DIR="$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$PKG_DIR" ]] || die "Could not locate extracted package dir under $STAGING_DIR."
log "staged: $PKG_DIR"

# --- verify expected payload ----------------------------------------------
for f in \
  "tak/takserver.war" \
  "tak/docker_entrypoint.sh" \
  "tak/coreConfigEnvHelper.py" \
  "tak/db-utils/SchemaManager.jar" \
  "docker/Dockerfile.takserver"; do
  [[ -e "$PKG_DIR/$f" ]] || die "expected artifact file missing: $f"
done
PKG_VER="$(tr -d '[:space:]' < "$PKG_DIR/tak/version.txt" 2>/dev/null || echo unknown)"
log "payload version.txt: $PKG_VER"

# --- docker build (single self-contained image) ----------------------------
log "docker build → $IMAGE_REF:$VERSION (+ :latest)"
docker build \
  -f "$PKG_DIR/docker/Dockerfile.takserver" \
  -t "$IMAGE_REF:$VERSION" \
  -t "$IMAGE_REF:latest" \
  "$PKG_DIR"

IMAGE_ID="$(docker image inspect "$IMAGE_REF:$VERSION" --format '{{.Id}}')"
log "built image id: $IMAGE_ID"
log "DONE. Tags: $IMAGE_REF:$VERSION , $IMAGE_REF:latest"
