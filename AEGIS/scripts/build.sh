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
  # Annotated tag needs a tagger identity; supply one inline so this works on CI
  # runners with no configured git user (does not mutate global/local config).
  git -C "$REPO_ROOT" \
    -c user.name="${GIT_TAGGER_NAME:-AEGIS Build}" \
    -c user.email="${GIT_TAGGER_EMAIL:-aegis-build@dragonflyuas.local}" \
    tag -a "$VERSION" -m "AEGIS build $VERSION"
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

# --- build-time patches to docker_entrypoint.sh ----------------------------
# Bake the deployment fixes into the image so compose/k8s deploys can be pure
# `image + env + volume` (no runtime wrapper). Each patch is guarded so the
# script is idempotent and reviewable. Re-validate these on each TAK upstream
# version bump (Phase 6 upstream-sync).
ENT="$PKG_DIR/tak/docker_entrypoint.sh"
log "patching $ENT (4 fixes)"

# (1) logs symlink idempotency — the image ships /opt/tak/logs as a real dir,
#     so `ln -s .../data/logs /opt/tak/logs` nests as /opt/tak/logs/logs and
#     collides under `set -e` on re-runs. Pre-create data/logs and clear the
#     stale real dir before the entrypoint's own `ln -s` runs.
if ! grep -qF 'rm -rf "/opt/tak/logs"' "$ENT"; then
  sed -i '/^set -e$/a\
mkdir -p "/opt/tak/data/logs"\
rm -rf "/opt/tak/logs"' "$ENT"
fi

# (2) admin registration retry — stock runs `certmod -A` once at a fixed ~60s
#     under `set -e`; on slow nodes the Ignite service isn't ready and the
#     container exits → crash loop. Rewrite into retry-until-ready.
sed -i -E 's#^(java -jar /opt/tak/utils/UserManager.jar certmod -A .*)$#until \1; do echo "[aegis] server not ready for admin registration; retry in 30s"; sleep 30; done#' "$ENT"

# (3) CoreConfig precedence fix — the TAK JVMs load /opt/tak/CoreConfig.xml
#     (their CWD) but the image ships that file with host `tak-database` and
#     EMPTY password, while coreConfigEnvHelper only fixes data/CoreConfig.xml.
#     Copy the env-corrected file over the JVM-loaded path right after the
#     helper. Without this the API HikariPool can't auth → mTLS requests hang.
if ! grep -qF 'cp "$CONFIG" "$TR/CoreConfig.xml"' "$ENT"; then
  sed -i '/coreConfigEnvHelper.py/a cp "$CONFIG" "$TR/CoreConfig.xml"' "$ENT"
fi

# (4) client truststore anchor — makeRootCa.sh builds truststore-root.jks from
#     ca.pem *before* the intermediate CA exists, so it holds root only; the
#     later `yes | makeCert.sh ca intermediate` overwrites ca.pem with the
#     intermediate chain but never revisits the truststore. CoreConfig signs
#     device certs with the intermediate, so verifying a leaf needs the path
#     leaf -> intermediate -> root — which the server cannot build unless the
#     client volunteers the intermediate. Our Go client does; real hardware
#     does not (Skydio X10 sends leaf only), so the 8089 handshake dies with
#     "peer not verified", the controller shows UNREACHABLE, and TAK logs
#     nothing. Import the intermediate once all certs exist.
#     NOT a trust widening: with root as the anchor "leaf + intermediate"
#     already verified — only the burden of supplying the middle link moves.
#     Anchored on chmod, the one unique line after all four cert blocks.
#     See AEG-467 and AEGIS/adr/adr-001-client-truststore-anchor.md.
if ! grep -qF 'aegis: anchor the client truststore' "$ENT"; then
  sed -i '/^chmod -R 777 /i\
# aegis: anchor the client truststore on the intermediate as well as the root.\
AEGIS_TS="${CR}/files/truststore-root.jks"\
if keytool -list -alias intermediate -keystore "${AEGIS_TS}" -storepass "${CA_PASS}" >/dev/null 2>&1; then\
\  echo "[aegis] client truststore already anchors the intermediate CA"\
else\
\  echo "[aegis] importing intermediate CA into client truststore"\
\  keytool -importcert -noprompt -alias intermediate -file "${CR}/files/intermediate.pem" -keystore "${AEGIS_TS}" -storepass "${CA_PASS}"\
fi\
' "$ENT"
fi
# Fail the build if (4) did not land. A `sed` whose address never matches exits
# 0, so upstream renaming/removing the chmod line would silently ship an image
# with the original defect — and that defect is invisible until real hardware
# fails to connect in the field. (Patches 1-3 carry the same exposure and no
# assertion yet; worth adding when one of them next drifts.)
grep -qF 'aegis: anchor the client truststore' "$ENT" \
  || die "patch (4) did not apply: the 'chmod -R 777' anchor is gone from docker_entrypoint.sh (upstream drift). See AEGIS/adr/adr-001-client-truststore-anchor.md."

log "entrypoint patched (logs idempotency, certmod retry, CoreConfig precedence, truststore anchor)"

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
