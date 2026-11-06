#!/bin/bash

# Builds images locally the same way as .github/workflows/build.yml,
# runs the smoke test and keeps the result in the local Docker image store.
# Nothing is pushed anywhere.
#
# Usage: ./debug_script.sh [NODEJS] [DEBIAN] [PLATFORM]
#   NODEJS    - Node.js minor version from configuration.yaml (e.g. 22), default: all
#   DEBIAN    - Debian codename (e.g. trixie), default: all
#   PLATFORM  - target platform (e.g. linux/arm64), default: native platform
#
# Examples:
#   ./debug_script.sh                       # all combinations, native platform
#   ./debug_script.sh 22                    # Node.js 22 on all Debian releases
#   ./debug_script.sh 22 trixie linux/arm64

set -euo pipefail
IFS=$'\n\t'

BASE_PATH=$(readlink --canonicalize "${BASH_SOURCE:-$0}")
BASE_DIRECTORY="${BASE_PATH%/*}"

FILTER_NODEJS="${1:-}"
FILTER_DEBIAN="${2:-}"
PLATFORM="${3:-}"
IMAGE="nodejs-debug"

for COMMAND in docker yq jq; do
    if ! command -v "$COMMAND" > /dev/null; then
        echo "Missing required command: ${COMMAND}"
        exit 1
    fi
done

CONFIG=$(yq -o=json "${BASE_DIRECTORY}/configuration.yaml")

TARGETS=$(echo "$CONFIG" | jq -r --arg nodejs "$FILTER_NODEJS" --arg debian "$FILTER_DEBIAN" '
    .nodejs_versions | to_entries[]
    | select($nodejs == "" or .key == $nodejs)
    | .key as $NODEJS
    | .value.nodejs.version as $VERSION
    | .value.debian[]
    | select($debian == "" or . == $debian)
    | [$NODEJS, $VERSION, .] | @tsv')

if [ -z "$TARGETS" ]; then
    echo "No Node.js × Debian combination matches NODEJS='${FILTER_NODEJS}' DEBIAN='${FILTER_DEBIAN}'"
    exit 1
fi

PLATFORM_ARGS=()
if [ -n "$PLATFORM" ]; then
    PLATFORM_ARGS=(--platform "$PLATFORM")
fi

# Same label values as in CI, the commit is marked "-dirty" when there are uncommitted changes
VCS_REF=$(git -C "$BASE_DIRECTORY" describe --always --dirty --abbrev=40 --match='' 2>/dev/null || true)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

FAILED=()
SUCCEEDED=()
while read -r -u 3 NODEJS VERSION DEBIAN; do
    TAG="${IMAGE}:${VERSION}-${DEBIAN}"

    echo "###########"
    echo "NODEJS_VERSION: ${VERSION}"
    echo "DEBIAN_CODENAME: ${DEBIAN}"
    echo "PLATFORM: ${PLATFORM:-native}"
    echo "IMAGE: ${TAG}"
    echo "###########"

    # The point release is read from the base image
    if ! DEBIAN_POINT_RELEASE=$(docker run --rm --pull always "${PLATFORM_ARGS[@]}" "debian:${DEBIAN}-slim" cat /etc/debian_version); then
        FAILED+=("${TAG} (Debian release)")
        continue
    fi
    echo "DEBIAN_POINT_RELEASE: ${DEBIAN_POINT_RELEASE}"

    if ! LABELS=$(NODEJS_VERSION="$VERSION" NODEJS_MAJOR="$NODEJS" DEBIAN_CODENAME="$DEBIAN" \
        DEBIAN_POINT_RELEASE="$DEBIAN_POINT_RELEASE" VCS_REF="$VCS_REF" BUILD_DATE="$BUILD_DATE" \
        bash "${BASE_DIRECTORY}/labels_script.sh"); then
        FAILED+=("${TAG} (labels)")
        continue
    fi
    LABEL_ARGS=()
    while read -r LABEL; do
        LABEL_ARGS+=(--label "$LABEL")
    done <<< "$LABELS"

    if ! docker buildx build \
        --load \
        "${PLATFORM_ARGS[@]}" \
        --build-arg "DEBIAN_CODENAME=${DEBIAN}" \
        --build-arg "NODEJS_VERSION=${VERSION}" \
        "${LABEL_ARGS[@]}" \
        --tag "$TAG" \
        "$BASE_DIRECTORY"; then
        FAILED+=("${TAG} (build)")
        continue
    fi

    # set -e is ignored inside "if", so every test is checked explicitly
    SMOKE_TESTS=(
        "node -v"
        "npm -v"
        "tsx -v"
        "grep -q VERSION_CODENAME=${DEBIAN} /etc/os-release"
    )
    SMOKE_FAILED=()
    for SMOKE_TEST in "${SMOKE_TESTS[@]}"; do
        echo "+ ${SMOKE_TEST}"
        if ! docker run --rm "${PLATFORM_ARGS[@]}" "$TAG" sh -c "$SMOKE_TEST"; then
            SMOKE_FAILED+=("$SMOKE_TEST")
        fi
    done

    if [ "${#SMOKE_FAILED[@]}" -gt 0 ]; then
        for SMOKE_TEST in "${SMOKE_FAILED[@]}"; do
            FAILED+=("${TAG} (smoke test: ${SMOKE_TEST})")
        done
        continue
    fi

    SUCCEEDED+=("$TAG")
done 3<<< "$TARGETS"

echo "###########"
for TAG in "${SUCCEEDED[@]}"; do
    echo "OK:     ${TAG}"
done
for TAG in "${FAILED[@]}"; do
    echo "FAILED: ${TAG}"
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    exit 1
fi
