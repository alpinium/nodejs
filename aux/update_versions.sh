#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

BASE_PATH=$(readlink --canonicalize "${BASH_SOURCE:-$0}")
BASE_DIRECTORY="${BASE_PATH%/*}"

CONFIGURATION_YAML_PATH="${BASE_DIRECTORY}/../configuration.yaml"

INDEX_URL='https://nodejs.org/dist/index.json'

REGISTRY_URL='https://registry.npmjs.org'

function SemverCompare()
{
    local VERSION_A="$1"
    local VERSION_B="$2"

    local RE='^v?([0-9]+)(\.([0-9]+)(\.([0-9]+))?)?([-+].*)?$'
    if ! [[ "$VERSION_A" =~ $RE ]]; then
        echo "Invalid version: ${VERSION_A}" >&2
        return 1
    fi

    local VERSION_A_NUM=$(( ( 10#${BASH_REMATCH[1]:-0} << 40 ) + ( 10#${BASH_REMATCH[3]:-0} << 20 ) + 10#${BASH_REMATCH[5]:-0} ))

    if ! [[ "$VERSION_B" =~ $RE ]]; then
        echo "Invalid version: ${VERSION_B}" >&2
        return 1
    fi

    local VERSION_B_NUM=$(( ( 10#${BASH_REMATCH[1]:-0} << 40 ) + ( 10#${BASH_REMATCH[3]:-0} << 20 ) + 10#${BASH_REMATCH[5]:-0} ))

    echo $(( VERSION_A_NUM - VERSION_B_NUM ))
}

function SemverSatisfies()
{
    local VERSION="$1"
    local RANGES="$2"

    local RE='^v?([0-9]+)(\.([0-9]+)(\.([0-9]+))?)?([-+].*)?$'
    if ! [[ "$VERSION" =~ $RE ]]; then
        echo "Invalid version: ${VERSION}" >&2
        return 2
    fi

    local VERSION_NUM=$(( ( 10#${BASH_REMATCH[1]:-0} << 40 ) + ( 10#${BASH_REMATCH[3]:-0} << 20 ) + 10#${BASH_REMATCH[5]:-0} ))

    RE='^(>=|<=|>|<|=|\^|~>|~)?v?(([0-9]+)|[xX*])(\.(([0-9]+)|[xX*]))?(\.(([0-9]+)|[xX*]))?([-+].*)?$'

    while [[ "$RANGES" =~ (>=|<=|>|<|=|\^|~>|~)[[:space:]]+ ]]; do
        RANGES="${RANGES/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}"}"
    done

    local -a SETS
    readarray -t SETS <<< "${RANGES//||/$'\n'}"

    local SET
    for SET in "${SETS[@]}"; do

        if [[ "$SET" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+-[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            SET=">=${BASH_REMATCH[1]} <=${BASH_REMATCH[2]}"
        fi

        local -a COMPARATORS
        IFS=$' \t' read -r -a COMPARATORS <<< "$SET"
        if [ "${#COMPARATORS[@]}" -eq 0 ]; then
            COMPARATORS=('*')
        fi

        local SET_OK=1
        local COMPARATOR
        for COMPARATOR in "${COMPARATORS[@]}"; do
            if ! [[ "$COMPARATOR" =~ $RE ]]; then
                echo "Unknown comparator: ${COMPARATOR}" >&2
                return 2
            fi
            
            local OP="${BASH_REMATCH[1]}"
            local MAJOR="${BASH_REMATCH[3]}"
            local MINOR="${BASH_REMATCH[6]}"
            local PATCH="${BASH_REMATCH[9]}"
            local COUNT
            
            if [ -z "$MAJOR" ]; then
                COUNT=0
            else 
                MAJOR=$(( 10#$MAJOR ))
                if [ -z "$MINOR" ]; then
                    COUNT=1
                else
                    MINOR=$(( 10#$MINOR ))
                    if [ -z "$PATCH" ]; then
                        COUNT=2
                    else
                        COUNT=3
                        PATCH=$(( 10#$PATCH ))
                    fi
                fi
            fi
            
            local LOW=('0' '0' '0')
            local HIGH=('1000000' '1000000' '1000000')
            
            case "$OP" in
                '>=') # >= same as >=
                    case "$COUNT" in
                        1) LOW=("$MAJOR" '0' '0');;
                        2) LOW=("$MAJOR" "$MINOR" '0');;
                        3) LOW=("$MAJOR" "$MINOR" "$PATCH");;
                    esac
                    ;;
                '<=') # Convert <= to <
                    case "$COUNT" in
                        1) HIGH=("$MAJOR" '1000000' '1000000');;
                        2) HIGH=("$MAJOR" "$MINOR" '1000000');;
                        3) HIGH=("$MAJOR" "$MINOR" "$(( PATCH + 1))");;
                    esac
                    ;;
                '>') # Convert > to >=
                    case "$COUNT" in
                        0) HIGH=('0' '0' '0');;
                        1) LOW=("$(( MAJOR + 1))" '0' '0');;
                        2) LOW=("$MAJOR" "$(( MINOR + 1 ))" '0');;
                        3) LOW=("$MAJOR" "$MINOR" "$(( PATCH + 1))" );;
                    esac
                    ;;
                '<') # < same as <
                    case "$COUNT" in
                        0) HIGH=('0' '0' '0');;
                        1) HIGH=("$MAJOR" '0' '0');;
                        2) HIGH=("$MAJOR" "$MINOR" '0');;
                        3) HIGH=("$MAJOR" "$MINOR" "$PATCH");;
                    esac
                    ;;
                ''|'=') # Convert = to >= <
                    case "$COUNT" in
                        1) LOW=("$MAJOR" '0' '0'); HIGH=("$MAJOR" '1000000' '1000000');;
                        2) LOW=("$MAJOR" "$MINOR" '0'); HIGH=("$MAJOR" "$MINOR" '1000000');;
                        3) LOW=("$MAJOR" "$MINOR" "$PATCH"); HIGH=("$MAJOR" "$MINOR" "$(( PATCH + 1))");;
                    esac
                    ;;
                '^')
                    case "$COUNT" in
                        1) if [ "$MAJOR" -eq 0 ]; then
                               LOW=("$MAJOR" '0' '0'); HIGH=("$MAJOR" '1000000' '1000000');
                           else
                               LOW=("$MAJOR" '0' '0'); HIGH=("$MAJOR" '1000000' '1000000');
                           fi
                           ;;
                        2) if [ "$MAJOR" -eq 0 ]; then
                               LOW=("$MAJOR" "$MINOR" '0'); HIGH=("$MAJOR" "$MINOR" '1000000');
                           else
                               LOW=("$MAJOR" "$MINOR" '0'); HIGH=("$MAJOR" '1000000' '1000000');
                           fi
                           ;;
                        3) if [ "$MAJOR" -eq 0 ]; then
                               if [ "$MINOR" -eq 0 ]; then
                                   LOW=("$MAJOR" "$MINOR" "$PATCH"); HIGH=("$MAJOR" "$MINOR" "$(( PATCH + 1 ))")
                               else
                                   LOW=("$MAJOR" "$MINOR" "$PATCH"); HIGH=("$MAJOR" "$MINOR" '1000000')
                               fi
                           else
                               LOW=("$MAJOR" "$MINOR" "$PATCH"); HIGH=("$MAJOR" '1000000' '1000000')
                           fi
                           ;;
                    esac
                    ;;
                '~>'|'~')
                    case "$COUNT" in
                        1) LOW=("$MAJOR" '0' '0'); HIGH=("$MAJOR" '1000000' '1000000');;
                        2) LOW=("$MAJOR" "$MINOR" '0'); HIGH=("$MAJOR" "$MINOR" '1000000');;
                        3) LOW=("$MAJOR" "$MINOR" "$PATCH"); HIGH=("$MAJOR" "$MINOR" '1000000');;
                    esac
                    ;;
            esac
            
            local LOW_NUM=$(( ( LOW[0] << 40 ) + ( LOW[1] << 20 ) + LOW[2] ))
            local HIGH_NUM=$(( ( HIGH[0] << 40 ) + ( HIGH[1] << 20 ) + HIGH[2] ))
            
            if [ "$VERSION_NUM" -lt "$LOW_NUM" ] || [ "$VERSION_NUM" -ge "$HIGH_NUM" ]; then
                SET_OK=0
                break
            fi
        done
        if [ "$SET_OK" -eq 1 ]; then
            return 0
        fi
    done

    return 1
}

function FindLatestPackageVersion()
{
    local NODEJS_VERSION="$1"
    local PACKAGE_NAME="$2"

    local PACKAGE_VERSION=
    local NODEJS_RANGE=
    local FOUND_VERSION=
    while read -r PACKAGE_VERSION NODEJS_RANGE; do
        if SemverSatisfies "$NODEJS_VERSION" "$NODEJS_RANGE"; then
            if [ -z "$FOUND_VERSION" ] || [ $(SemverCompare "$PACKAGE_VERSION" "$FOUND_VERSION" ) -gt 0 ]; then
                FOUND_VERSION="$PACKAGE_VERSION"
            fi
        fi
    done < <(curl --silent --location --show-error --fail --header 'Accept: application/vnd.npm.install-v1+json' --url "${REGISTRY_URL}/${PACKAGE_NAME}" | jq -r '.versions | to_entries[] | select(.key | contains("-") | not) | [.key,  (.value.engines.node | if type == "string" and (gsub("\\s";"") != "") then . else "*" end)] | @tsv')

    if [ -z "$FOUND_VERSION" ]; then
        return 1
    else
        echo "$FOUND_VERSION"
    fi
}

declare -x MAJOR_VERSION
readarray -t MAJOR_VERSIONS < <(yq '.nodejs_versions | keys | .[]' "$CONFIGURATION_YAML_PATH")
for MAJOR_VERSION in "${MAJOR_VERSIONS[@]}"; do

    declare -x NODEJS_VERSION
    declare -x NPM_VERSION
    read -r NODEJS_VERSION NPM_VERSION < <(curl --silent --location --show-error --fail --url "$INDEX_URL" | jq --raw-output --exit-status --arg major "$MAJOR_VERSION" '[.[] | select(.version | test("^\($major)\\.\\d+\\.\\d+$"))] | max_by(.version | ltrimstr("v") | split(".") | map(tonumber)) | select(. != null) | [.version, .npm] | @tsv')

    echo "NODEJS ${NODEJS_VERSION}   NPM ${NPM_VERSION}"

    yq -i 'with(.nodejs_versions[strenv(MAJOR_VERSION)].nodejs.version; . = strenv(NODEJS_VERSION) | . style="single")' "$CONFIGURATION_YAML_PATH"

    declare -x PACKAGE_NAME
    while read -r PACKAGE_NAME; do

        declare -x PACKAGE_VERSION
        PACKAGE_VERSION=$(FindLatestPackageVersion "$NODEJS_VERSION" "$PACKAGE_NAME")

        echo "$MAJOR_VERSION $PACKAGE_NAME"
        yq -i 'with(.nodejs_versions[strenv(MAJOR_VERSION)].packages[strenv(PACKAGE_NAME)]; . = strenv(PACKAGE_VERSION) | . style="single")' "$CONFIGURATION_YAML_PATH"

    done < <(yq '.nodejs_versions[strenv(MAJOR_VERSION)].packages | keys | .[]' "$CONFIGURATION_YAML_PATH")

done
