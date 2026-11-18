#!/bin/bash
# dectalk-telemetry-upgrade.sh
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Upgrade an existing install of the DECtalk telemetry scripts to the
# latest release on GitHub.
#
# The latest release is the one the installer on GitHub's main branch
# installs. It is downloaded and its "install.sh --upgrade" is run, which
# only replaces the scripts and data files in /opt/asl-telem: no packages,
# no Asterisk config and no sounds are changed.
#
# Run it from the PATH once installed, or straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/borris84/asl-dectalk-telemetry/main/dectalk-telemetry-upgrade.sh | sudo bash

set -uo pipefail

REPO=borris84/asl-dectalk-telemetry
MAIN_INSTALLER="https://raw.githubusercontent.com/$REPO/main/install.sh"
INSTALL_DIR=/opt/asl-telem
VERSION_FILE=$INSTALL_DIR/VERSION
# On disk, like the installer: /tmp is a small tmpfs on many Pis.
SRC_BASE=/usr/local/src

CHECK=0
FORCE=0

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat << EOF
Usage: dectalk-telemetry-upgrade.sh [-c] [-f]

Upgrade the DECtalk telemetry scripts in $INSTALL_DIR to the latest
release on GitHub. Only the scripts and their data files are replaced.

   -c   Only check: show the installed and latest versions. Exits 0 if
        the install is up to date, 10 if a newer release is available.
   -f   Upgrade even if the installed version is already the latest
        (reinstalls the scripts).
   -h   Show this message
EOF
}

# version_lt A B  - true if version A is older than version B.
version_lt() {
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]
}

while getopts ":cfh" opt; do
    case $opt in
        c) CHECK=1 ;;
        f) FORCE=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: -$OPTARG" ;;
    esac
done
shift $((OPTIND - 1))
(( $# == 0 )) || { usage >&2; die "Unexpected argument: $1"; }

command -v curl > /dev/null || die "curl is needed to download the upgrade."

[[ -f $INSTALL_DIR/dectalk-telemetry.sh ]] \
    || die "No existing install found in $INSTALL_DIR. Install first: https://github.com/$REPO#installation"

installed=""
[[ -f $VERSION_FILE ]] && installed=$(< "$VERSION_FILE")

latest=$(curl -fsSL "$MAIN_INSTALLER" | sed -n 's/^VERSION=\([0-9][0-9.]*\)$/\1/p' | head -n 1)
[[ -n $latest ]] || die "Could not find the latest version at $MAIN_INSTALLER"

echo "Installed version: ${installed:-0.12 or older}"
echo "Latest version:    $latest"

if [[ -z $installed ]] || version_lt "$installed" "$latest"; then
    newer=1
else
    newer=0
fi

if (( CHECK )); then
    if (( newer )); then
        echo "A newer version is available."
        exit 10
    fi
    if [[ $installed == "$latest" ]]; then
        echo "Up to date."
    else
        echo "The installed version is newer than the latest release."
    fi
    exit 0
fi

if (( ! newer && ! FORCE )); then
    if [[ $installed == "$latest" ]]; then
        echo "Already up to date. Use -f to reinstall it anyway."
    else
        echo "The installed version is newer than the latest release. Use -f to install $latest anyway."
    fi
    exit 0
fi

[[ $EUID -eq 0 ]] || die "The upgrade must be run as root (for example: sudo dectalk-telemetry-upgrade.sh)."
# The installer asks questions. Piped from curl, standard input is the
# script itself, so they are read from the terminal.
{ : < /dev/tty; } 2> /dev/null || die "No terminal to ask questions on. Run it from a terminal."

url="https://github.com/$REPO/archive/refs/tags/v$latest.tar.gz"
dir=$SRC_BASE/asl-dectalk-telemetry-$latest
echo
echo "Downloading asl-dectalk-telemetry $latest to $dir..."
rm -rf -- "$dir"
mkdir -p -- "$dir" || die "Could not create $dir"
curl -fsSL "$url" | tar -xz -C "$dir" --strip-components=1 \
    || die "Could not download $url"
[[ -f $dir/install.sh ]] || die "The download from $url has no install.sh"
echo

exec bash "$dir/install.sh" --upgrade < /dev/tty
