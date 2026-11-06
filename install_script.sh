#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

BASE_PATH=$(readlink --canonicalize "${BASH_SOURCE:-$0}")
BASE_DIRECTORY="${BASE_PATH%/*}"

export DEBIAN_FRONTEND="noninteractive"

cat > '/etc/apt/preferences.d/no-debian-nodejs' <<EOF
Package: nodejs nodejs-doc npm libnode* node-*
Pin: release *
Pin-Priority: -1
EOF

apt-get update --assume-yes
apt-get dist-upgrade --assume-yes
apt-get install --assume-yes --no-install-recommends apt-transport-https ca-certificates curl jq libatomic1 tar tini


MACHINE_ARCHITECTURE="$(uname -m)"
CPU_LIMIT="$(nproc)"
DEBIAN_ARCHITECTURE="$(dpkg --print-architecture)"

case "$DEBIAN_ARCHITECTURE" in
    'amd64')
        GNU_ARCH='x86_64-linux-gnu'
        NODEJS_ARCHITECTURE='x64'
        ;;
    'arm64')
        GNU_ARCH='aarch64-linux-gnu'
        NODEJS_ARCHITECTURE='arm64'
        ;;
    *) echo "Unknown architecture ${DEBIAN_ARCHITECTURE}" >&2
       exit 1
       ;;
esac

{
    REPOSITORY_SLUG='mikefarah/yq'
    OS='linux'
    ARCHITECTURE="$DEBIAN_ARCHITECTURE"
    SUFFIX='.tar.gz'
    SOURCE_FILE_NAME="./yq_linux_${ARCHITECTURE}"
    TARGET_FILE_PATH='/usr/local/bin/yq'

    DOWNLOAD_URL=$(curl --silent --location --fail "https://api.github.com/repos/${REPOSITORY_SLUG}/releases/latest" | jq -r '.assets[].browser_download_url' | sed --silent --regexp-extended 's/^(.*'"$OS"'.*'"$ARCHITECTURE"'.*'"$SUFFIX"')$/\1/p')

    TEMPORARY_FILE=$(mktemp)
    TEMPORARY_DIRECTORY=$(mktemp --directory)

    curl --location --silent --fail --output "$TEMPORARY_FILE" --url "$DOWNLOAD_URL"
    tar xvf "$TEMPORARY_FILE" -C "$TEMPORARY_DIRECTORY"

    cp --remove-destination --recursive --no-dereference --preserve=mode,links,timestamps "${TEMPORARY_DIRECTORY}/${SOURCE_FILE_NAME}" "$TARGET_FILE_PATH"
}


DIST_URL='https://nodejs.org/dist'
DOWNLOAD_URL='https://nodejs.org'
OS='linux'
SUFFIX='.tar.gz'

read -r VERSION < <(curl --silent --location --show-error --fail --url "${DIST_URL}/${NODEJS_VERSION}" | sed --silent --regexp-extended "s/^.*<a href=\"(.+${OS}.*${NODEJS_ARCHITECTURE}\.*${SUFFIX//\./\\.})\">.*$/\1/p")
DOWNLOAD_URL="${DOWNLOAD_URL}/${VERSION}"

TEMPORARY_FILE=$(mktemp)
TEMPORARY_FILES+=("$TEMPORARY_FILE")
TEMPORARY_DIRECTORY=$(mktemp --directory)
TEMPORARY_FILES+=("$TEMPORARY_DIRECTORY")

curl --location --silent --show-error --fail --output "$TEMPORARY_FILE" --url "$DOWNLOAD_URL"
tar --extract --file "$TEMPORARY_FILE" --directory "$TEMPORARY_DIRECTORY"

CONTENT_DIRECTORY=$(find "$TEMPORARY_DIRECTORY" -mindepth 1 -maxdepth 1 -type d)

if [ -d /usr/local/lib/node_modules ]; then
    rm --force --recursive /usr/local/lib/node_modules
fi
cp --remove-destination --recursive --no-dereference --preserve=mode,ownership,links,timestamps "${CONTENT_DIRECTORY}/bin/." /usr/local/bin
cp --remove-destination --recursive --no-dereference --preserve=mode,ownership,links,timestamps "${CONTENT_DIRECTORY}/lib/." /usr/local/lib

CONFIGURATION_FILE_PATH='/mnt/docker/configuration.yaml'
export MAJOR_VERSION="${NODEJS_VERSION%%.*}"

if [ ! -f "$CONFIGURATION_FILE_PATH" ]; then
    npm install --global npm@latest
    npm install --global tsx@latest
    npm install --global @types/node@latest
    npm update --global
else
    while read -r PACKAGE VERSION; do
        npm install --global "$PACKAGE@$VERSION"
    done < <(yq '.nodejs_versions[strenv(MAJOR_VERSION)].packages | to_entries | .[] | [.key, .value] | @tsv' "$CONFIGURATION_FILE_PATH")
fi

echo "NODE version"
node -v
echo "NPM version"
npm -v

rm --recursive --force /tmp/* 2>/dev/null || true
