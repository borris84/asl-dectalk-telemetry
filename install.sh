#!/bin/bash
# install.sh
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Install the DECtalk telemetry and node name scripts on an ASL3 node:
#   1. Check that this is ASL3 (and not HamVoIP)
#   2. Build and install DECtalk's "say" if it is not already working
#   3. Install ffmpeg and perl if missing (the scripts need them)
#   4. Turn on ASL3's automatic astdb.txt (node database) updates
#   5. Copy the scripts and their data files to /opt/asl-telem and link
#      the scripts into /usr/local/bin so they are on the PATH
#   6. Enable custom sounds in /etc/asterisk/asterisk.conf
#   7. Point nodenames in /etc/asterisk/rpt.conf at custom/rpt/nodenames
#   8. Check the install, then offer to generate the sounds
#
# Run it as root from the directory that holds the scripts, or straight
# from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/borris84/asl-dectalk-telemetry/main/install.sh | sudo bash
# In that case it downloads release $VERSION and runs from that copy.
# Safe to run again: finished steps are detected and skipped.
#
# install.sh --upgrade only replaces the scripts of an existing install
# (from GitHub: ... | sudo bash -s -- --upgrade). It changes no Asterisk
# config, installs no packages and generates no sounds.

set -uo pipefail

VERSION=0.13
REPO=borris84/asl-dectalk-telemetry
RELEASE_URL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
DOWNLOAD_DIR=/usr/local/src/asl-dectalk-telemetry-$VERSION

# Piped into bash there is no script file, so there is no SRC_DIR.
SRC_DIR=""
if [[ -f ${BASH_SOURCE[0]:-} ]]; then
    SRC_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
fi
INSTALL_DIR=/opt/asl-telem
BIN_DIR=/usr/local/bin
DECTALK_DIR=/opt/dectalk
SAY=/usr/local/bin/say
DECTALK_REPO=https://github.com/dectalk/dectalk.git
# Build on disk: /tmp and /var/tmp are small tmpfs mounts on many Pis,
# and the DECtalk source tree is larger than that.
BUILD_DIR=/usr/local/src/dectalk-build
ASTERISK_CONF=/etc/asterisk/asterisk.conf
RPT_CONF=/etc/asterisk/rpt.conf
NODENAMES_DIR=/usr/share/asterisk/sounds/custom/rpt/nodenames
ASTDB=/var/lib/asterisk/astdb.txt
ASTDB_UNITS=(asl3-update-astdb.service asl3-update-astdb.timer)

TELEM_SCRIPT=dectalk-telemetry.sh
NODES_SCRIPT=write_node_callsigns_dectalk.sh
SCRIPTS=("$TELEM_SCRIPT" "$NODES_SCRIPT")
DATA_FILES=(dec-init.cfg prompt-list.txt)
# Installed only if missing: the user's own settings, never replaced.
USER_FILES=(node-overrides.conf)

VERSION_FILE=$INSTALL_DIR/VERSION
STAMP=$(date +%Y%m%d-%H%M%S)
ASTERISK_RESTART_NEEDED=0
MODE=install

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

trap 'echo; echo "Installation stopped."; exit 130' INT

# ask_yn QUESTION [y|n]  - returns 0 for yes. The optional default is used
# when the user just presses Enter.
ask_yn() {
    local question=$1 default=${2:-} hint answer
    case $default in
        y) hint="[Y/n]" ;;
        n) hint="[y/N]" ;;
        *) hint="[y/n]" ;;
    esac
    while true; do
        read -r -p "$question $hint " answer || { echo; die "No answer given. Installation stopped."; }
        answer=${answer,,}
        [[ -z $answer ]] && answer=$default
        case $answer in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        echo "Please answer y or n."
    done
}

# ask_number MAX DEFAULT  - reads a choice from 1 to MAX into CHOICE.
ask_number() {
    local max=$1 default=$2 answer
    while true; do
        read -r -p "Enter a number (1-$max) [$default]: " answer || { echo; die "No answer given. Installation stopped."; }
        [[ -z $answer ]] && answer=$default
        if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= max )); then
            CHOICE=$answer
            return 0
        fi
        echo "Please enter a number from 1 to $max."
    done
}

step() {
    echo
    echo "Step $1: $2"
    echo
}

backup_file() {
    cp -p -- "$1" "$1.bak-$STAMP" || die "Could not back up $1"
    echo "Saved a backup copy as $1.bak-$STAMP"
}

# Replace FILE's contents with TMP's, keeping FILE's owner and permissions.
replace_contents() {
    cat -- "$2" > "$1" || die "Could not write $1"
    rm -f -- "$2"
}

# --- Checks --------------------------------------------------------------

is_hamvoip() {
    grep -qsi hamvoip /etc/os-release /etc/issue /etc/motd /etc/hostname && return 0
    compgen -G '/etc/*hamvoip*' > /dev/null && return 0
    compgen -G '/usr/local/etc/*hamvoip*' > /dev/null && return 0
    compgen -G '/usr/local/sbin/*hamvoip*' > /dev/null && return 0
    compgen -G '/usr/local/bin/*hamvoip*' > /dev/null && return 0
    # HamVoIP is built on Arch Linux; ASL3 is Debian only.
    [[ -f /etc/arch-release && ( -d /etc/asterisk || -n $(command -v asterisk) ) ]] && return 0
    return 1
}

is_asl3() {
    command -v dpkg-query > /dev/null || return 1
    dpkg-query -W -f='${Status}' asl3 2> /dev/null | grep -q 'install ok installed'
}

# Return 0 if DECtalk's say runs and produces audio.
dectalk_works() {
    local bytes
    [[ -x $SAY ]] || return 1
    bytes=$("$SAY" -e 3 -fo stdout:raw -a "test" < /dev/null 2> /dev/null | wc -c)
    (( bytes > 0 ))
}

custom_sounds_enabled() {
    grep -Eq '^[[:space:]]*sounds_search_custom_dir[[:space:]]*=[[:space:]]*yes' "$ASTERISK_CONF"
}

# Return 0 if ASL3's astdb.txt updates are enabled and the timer is running.
astdb_updates_on() {
    systemctl is-enabled --quiet asl3-update-astdb.timer 2> /dev/null \
        && systemctl is-active --quiet asl3-update-astdb.timer
}

# Print the values of the active (uncommented) nodenames lines in rpt.conf.
rpt_nodenames_values() {
    sed -nE 's/^[[:space:]]*nodenames[[:space:]]*=[[:space:]]*([^;[:space:]]*).*/\1/p' "$RPT_CONF"
}

nodenames_configured() {
    local values
    values=$(rpt_nodenames_values)
    [[ -n $values ]] && ! grep -qvxF "$NODENAMES_DIR" <<< "$values"
}

# --- Step 1: DECtalk -------------------------------------------------------

install_dectalk() {
    local jobs mem_mb dist log="$BUILD_DIR/build.log"

    echo "Installing the packages needed to build DECtalk..."
    apt-get update || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential autoconf automake libtool pkg-config git \
        || die "Could not install the build packages"

    rm -rf -- "$BUILD_DIR"
    mkdir -p -- "$BUILD_DIR" || die "Could not create $BUILD_DIR"

    echo "Downloading the DECtalk source code..."
    git clone --depth 1 "$DECTALK_REPO" "$BUILD_DIR/dectalk" \
        || die "Could not download DECtalk from $DECTALK_REPO"

    # Roughly 512 MB of memory per compile job, so small Pis don't run out.
    mem_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
    jobs=$(nproc 2> /dev/null || echo 1)
    (( jobs > mem_mb / 512 )) && jobs=$(( mem_mb / 512 ))
    (( jobs < 1 )) && jobs=1

    # Audio output is disabled: the scripts only write audio to files, and
    # this keeps libtts free of ALSA/PulseAudio dependencies.
    echo "Building DECtalk for $(uname -m) with $jobs job(s)."
    echo "This can take 10 minutes or more on a Raspberry Pi. Build log: $log"
    if ! ( cd "$BUILD_DIR/dectalk/src" \
            && ./autogen.sh \
            && ./configure --prefix="$DECTALK_DIR" --disable-audio \
            && make -j "$jobs" ) > "$log" 2>&1; then
        echo "The DECtalk build failed. Last lines of the build log:" >&2
        tail -n 20 "$log" >&2
        die "DECtalk build failed. The full log is in $log"
    fi

    dist="$BUILD_DIR/dectalk/dist"
    if [[ ! -x $dist/say || ! -f $dist/lib/libtts.so ]]; then
        die "The build finished but $dist does not contain say and lib/libtts.so. See $log"
    fi

    if [[ -e $DECTALK_DIR ]]; then
        mv -- "$DECTALK_DIR" "$DECTALK_DIR.bak-$STAMP" || die "Could not move the old $DECTALK_DIR aside"
        echo "Moved the old $DECTALK_DIR to $DECTALK_DIR.bak-$STAMP"
    fi
    mkdir -p -- "$DECTALK_DIR" && cp -a -- "$dist/." "$DECTALK_DIR/" \
        || die "Could not copy DECtalk to $DECTALK_DIR"

    # Something other than our link (another program called say) is moved
    # aside rather than overwritten.
    if [[ -e $SAY && ! -L $SAY ]]; then
        mv -- "$SAY" "$SAY.bak-$STAMP" || die "Could not move the old $SAY aside"
        echo "Moved the old $SAY to $SAY.bak-$STAMP"
    fi
    ln -sfn -- "$DECTALK_DIR/say" "$SAY" || die "Could not link $SAY"

    dectalk_works || die "DECtalk was installed to $DECTALK_DIR but $SAY does not produce audio. See $log"
    rm -rf -- "$BUILD_DIR"
    echo "DECtalk is installed in $DECTALK_DIR and $SAY works."
}

step_dectalk() {
    step 1 "DECtalk speech synthesizer"
    if dectalk_works; then
        echo "DECtalk is already installed and working ($SAY -> $(readlink -f "$SAY"))."
        return
    fi

    if [[ -e $SAY ]]; then
        echo "$SAY exists but does not work as DECtalk."
    else
        echo "DECtalk is not installed."
    fi
    echo "It will be downloaded from $DECTALK_REPO and built for this"
    echo "machine ($(uname -m)), then installed in $DECTALK_DIR with $SAY linked to it."
    echo "This needs an internet connection and about 1 GB of free disk space."
    echo
    ask_yn "Build and install DECtalk now?" y \
        || die "The scripts need DECtalk. Installation stopped."
    install_dectalk
}

# --- Step 2: other packages ------------------------------------------------

step_packages() {
    local -a missing=()
    step 2 "Other required programs"

    command -v ffmpeg > /dev/null || missing+=(ffmpeg)
    command -v perl > /dev/null || missing+=(perl)
    if (( ${#missing[@]} == 0 )); then
        echo "ffmpeg and perl are already installed."
        return
    fi

    echo "These packages are needed by the scripts and are not installed: ${missing[*]}"
    ask_yn "Install them now?" y || die "The scripts need ${missing[*]}. Installation stopped."
    apt-get update || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" \
        || die "Could not install ${missing[*]}"
}

# --- Step 3: node database -------------------------------------------------

step_node_database() {
    local nodes
    step 3 "AllStarLink node database ($ASTDB)"

    if ! dpkg-query -W -f='${Status}' asl3-update-nodelist 2> /dev/null | grep -q 'install ok installed'; then
        echo "The asl3-update-nodelist package, which downloads $ASTDB,"
        echo "is not installed."
        ask_yn "Install it now?" y || die "$NODES_SCRIPT needs $ASTDB. Installation stopped."
        apt-get update || die "apt-get update failed"
        DEBIAN_FRONTEND=noninteractive apt-get install -y asl3-update-nodelist \
            || die "Could not install asl3-update-nodelist"
    fi

    if astdb_updates_on && [[ -s $ASTDB ]]; then
        echo "Automatic node database updates are already on."
        return
    fi

    echo "$NODES_SCRIPT reads each node's call sign from $ASTDB."
    echo "ASL3 downloads that file with the asl3-update-astdb service and timer,"
    echo "which are turned off by default. Turning them on downloads the file"
    echo "now, then again at every boot and every 6 hours."
    echo
    if ! ask_yn "Turn on automatic node database updates?" y; then
        if [[ -s $ASTDB ]]; then
            echo "Skipped. $ASTDB will not be kept up to date, so new and changed nodes won't be announced."
        else
            echo "Skipped. $NODES_SCRIPT will not work until $ASTDB exists."
        fi
        return
    fi

    # As in the asl3-update-astdb(1) man page.
    systemctl enable "${ASTDB_UNITS[@]}" || die "Could not enable ${ASTDB_UNITS[*]}"
    systemctl start asl3-update-astdb.timer || die "Could not start asl3-update-astdb.timer"

    echo "Downloading the node database..."
    if systemctl start asl3-update-astdb.service && [[ -s $ASTDB ]]; then
        nodes=$(grep -c '^[0-9]' "$ASTDB")
        echo "$ASTDB is up to date ($nodes nodes)."
    else
        echo "The download failed. Check the internet connection, then run:"
        echo "  systemctl start asl3-update-astdb.service"
    fi
}

# --- Step 4: scripts -------------------------------------------------------

step_scripts() {
    step 4 "Install the scripts"

    echo "The scripts and their data files will be copied to $INSTALL_DIR,"
    echo "and the scripts will be linked into $BIN_DIR so they can be run"
    echo "from anywhere."
    echo
    ask_yn "Continue?" y || die "Installation stopped."
    install_files
}

# Copy the scripts and data files into INSTALL_DIR and link the scripts
# into BIN_DIR. Used by both install and --upgrade.
install_files() {
    local f src dest link

    mkdir -p -- "$INSTALL_DIR" || die "Could not create $INSTALL_DIR"

    for f in "${SCRIPTS[@]}"; do
        install -m 755 -- "$SRC_DIR/$f" "$INSTALL_DIR/$f" || die "Could not copy $f"
        echo "Installed $INSTALL_DIR/$f"
    done

    # Data files may have been edited after a previous install: ask before
    # replacing a changed one.
    for f in "${DATA_FILES[@]}"; do
        src="$SRC_DIR/$f"
        dest="$INSTALL_DIR/$f"
        if [[ -f $dest ]] && ! cmp -s -- "$src" "$dest"; then
            echo
            echo "$dest already exists and is different from the new copy."
            echo "  1) Keep the current file"
            echo "  2) Replace it with the new file (the current one is backed up)"
            ask_number 2 1
            if (( CHOICE == 1 )); then
                echo "Kept $dest"
                continue
            fi
            backup_file "$dest"
        fi
        install -m 644 -- "$src" "$dest" || die "Could not copy $f"
        echo "Installed $dest"
    done

    for f in "${USER_FILES[@]}"; do
        dest="$INSTALL_DIR/$f"
        if [[ -f $dest ]]; then
            echo "Kept your $dest"
        else
            install -m 644 -- "$SRC_DIR/$f" "$dest" || die "Could not copy $f"
            echo "Installed $dest"
        fi
    done

    for f in "${SCRIPTS[@]}"; do
        link="$BIN_DIR/$f"
        if [[ -e $link && ! -L $link ]]; then
            mv -- "$link" "$link.bak-$STAMP" || die "Could not move the old $link aside"
            echo "Moved the old $link to $link.bak-$STAMP"
        fi
        ln -sfn -- "$INSTALL_DIR/$f" "$link" || die "Could not link $link"
        echo "Linked $link -> $INSTALL_DIR/$f"
    done

    echo "$VERSION" > "$VERSION_FILE" || die "Could not write $VERSION_FILE"
}

# --- Step 5: asterisk.conf -------------------------------------------------

step_asterisk_conf() {
    local tmp line
    step 5 "Allow custom sounds in $ASTERISK_CONF"

    if custom_sounds_enabled; then
        echo "Custom sounds are already enabled (sounds_search_custom_dir = yes)."
        return
    fi

    echo "Asterisk only uses the sounds in /usr/share/asterisk/sounds/custom"
    echo "when sounds_search_custom_dir = yes is set in $ASTERISK_CONF."
    echo
    ask_yn "Set it now?" y || { echo "Skipped. The DECtalk sounds will not be used until this is set."; return; }

    backup_file "$ASTERISK_CONF"
    tmp=$(mktemp) || die "Could not create a temporary file"

    # Change an active setting if there is one, otherwise uncomment the
    # stock example, otherwise add the setting under [options].
    if line=$(grep -nE -m1 '^[[:space:]]*sounds_search_custom_dir[[:space:]]*=' "$ASTERISK_CONF") \
        || line=$(grep -nE -m1 '^[[:space:]]*;[[:space:]]*sounds_search_custom_dir[[:space:]]*=' "$ASTERISK_CONF"); then
        sed -E "${line%%:*}s/^[[:space:]]*;?[[:space:]]*sounds_search_custom_dir[[:space:]]*=[[:space:]]*[A-Za-z]*/sounds_search_custom_dir = yes/" \
            "$ASTERISK_CONF" > "$tmp"
    elif grep -q '^\[options\]' "$ASTERISK_CONF"; then
        sed '/^\[options\]/a sounds_search_custom_dir = yes' "$ASTERISK_CONF" > "$tmp"
    else
        { cat "$ASTERISK_CONF"; printf '\n[options]\nsounds_search_custom_dir = yes\n'; } > "$tmp"
    fi
    replace_contents "$ASTERISK_CONF" "$tmp"

    custom_sounds_enabled || die "Could not enable custom sounds in $ASTERISK_CONF"
    echo "Custom sounds enabled."
    ASTERISK_RESTART_NEEDED=1
}

# --- Step 6: rpt.conf ------------------------------------------------------

step_rpt_conf() {
    local values tmp line header
    local setting="nodenames = $NODENAMES_DIR ; DECtalk node name announcements"
    step 6 "Point node names in $RPT_CONF at $NODENAMES_DIR"

    if nodenames_configured; then
        echo "nodenames is already set to $NODENAMES_DIR."
        mkdir -p -- "$NODENAMES_DIR" || die "Could not create $NODENAMES_DIR"
        return
    fi

    echo "$NODES_SCRIPT writes node name announcements to"
    echo "$NODENAMES_DIR. Asterisk is told to use that directory with"
    echo "the nodenames setting in $RPT_CONF. Existing node name sounds"
    echo "elsewhere are not changed or deleted."
    values=$(rpt_nodenames_values)
    if [[ -n $values ]]; then
        echo
        echo "nodenames is currently set to:"
        sed 's/^/  /' <<< "$values"
    fi
    echo
    ask_yn "Set nodenames to $NODENAMES_DIR?" y \
        || { echo "Skipped. Asterisk will not use the new node name sounds until this is set."; return; }

    backup_file "$RPT_CONF"
    tmp=$(mktemp) || die "Could not create a temporary file"

    if [[ -n $values ]]; then
        # Change every active setting to the new directory.
        sed -E "s|^([[:space:]]*nodenames[[:space:]]*=[[:space:]]*)[^;[:space:]]*|\1$NODENAMES_DIR|" \
            "$RPT_CONF" > "$tmp"
    else
        # Uncomment the stock example in the [node-main] template, or add
        # the setting just below the template's header.
        line=$(awk '
            /^[[:space:]]*\[/ { s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\].*/, "", s) }
            s == "node-main" && /^[[:space:]]*;[[:space:]]*nodenames[[:space:]]*=/ { print NR; exit }
        ' "$RPT_CONF")
        header=$(grep -nE -m1 '^[[:space:]]*\[node-main\]' "$RPT_CONF")
        if [[ -n $line ]]; then
            sed "${line}s|.*|$setting|" "$RPT_CONF" > "$tmp"
        elif [[ -n $header ]]; then
            sed "${header%%:*}a $setting" "$RPT_CONF" > "$tmp"
        else
            rm -f -- "$tmp"
            echo "$RPT_CONF has no [node-main] template, so the setting can't be added automatically."
            echo "Add this line to each node's section in $RPT_CONF by hand:"
            echo "  nodenames = $NODENAMES_DIR"
            return
        fi
    fi
    replace_contents "$RPT_CONF" "$tmp"

    nodenames_configured || die "Could not set nodenames in $RPT_CONF"
    mkdir -p -- "$NODENAMES_DIR" || die "Could not create $NODENAMES_DIR"
    echo "nodenames set to $NODENAMES_DIR."
    ASTERISK_RESTART_NEEDED=1
}

# --- Step 7: verify --------------------------------------------------------

step_verify() {
    step 7 "Check the installation"
    if ! run_checks; then
        echo "Fix them and run this installer again before generating the sounds."
        return 1
    fi
    echo "Everything is installed."
}

# Print an OK/PROBLEM line for each part of the install. Changes nothing.
# Returns 1 if anything is wrong.
run_checks() {
    local problems=0 f

    check() {
        if eval "$2"; then
            echo "  OK       $1"
        else
            echo "  PROBLEM  $1"
            problems=$((problems + 1))
        fi
    }

    check "DECtalk speaks ($SAY)" dectalk_works
    check "ffmpeg is installed" 'command -v ffmpeg > /dev/null'
    check "perl is installed" 'command -v perl > /dev/null'
    for f in "${SCRIPTS[@]}"; do
        check "$f is on the PATH" "[[ \$(command -v $f) == $BIN_DIR/$f && -x $INSTALL_DIR/$f ]]"
    done
    for f in "${DATA_FILES[@]}"; do
        check "$INSTALL_DIR/$f is present" "[[ -f $INSTALL_DIR/$f ]]"
    done
    check "Node database updates are on (asl3-update-astdb.timer)" astdb_updates_on
    check "$ASTDB is present" "[[ -s $ASTDB ]]"
    check "Custom sounds are enabled in $ASTERISK_CONF" custom_sounds_enabled
    check "nodenames is set in $RPT_CONF" nodenames_configured

    echo
    if (( problems )); then
        echo "$problems problem(s) found."
        return 1
    fi
}

# --- Step 8: generate sounds -----------------------------------------------

step_generate() {
    local -a args=(-a)
    step 8 "Generate the sounds"

    echo "The telemetry prompts must be generated before the node names."
    echo "$TELEM_SCRIPT can rename or delete the whole custom sounds"
    echo "directory, which also holds the node names."
    echo
    if ask_yn "Generate the telemetry prompts now ($TELEM_SCRIPT)?" y; then
        "$BIN_DIR/$TELEM_SCRIPT" || echo "$TELEM_SCRIPT reported a problem (see above)."
    else
        echo "Skipped. Run $TELEM_SCRIPT later, before $NODES_SCRIPT."
    fi

    echo
    echo "Node names are generated for every node in the AllStarLink node"
    echo "database. A full build can take a long time on a Raspberry Pi."
    if ask_yn "Generate the node name announcements now ($NODES_SCRIPT)?" y; then
        echo
        echo "Each announcement can be followed by the node number,"
        echo "for example \"N 2 D Y I, node 5 0 6 3 1 1\"."
        ask_yn "Add the node number after each call sign?" n && args+=(-i)
        echo
        echo "Call signs can be spelled with letters (\"N 2 D Y I\") or with the"
        echo "phonetic alphabet (\"November, 2, Delta, Yankee, India\")."
        ask_yn "Speak call signs phonetically?" n && args+=(-P)
        "$BIN_DIR/$NODES_SCRIPT" "${args[@]}" || echo "$NODES_SCRIPT reported a problem (see above)."
    else
        echo "Skipped. Run \"$NODES_SCRIPT -a\" later to build them."
    fi
}

# --- Upgrade ---------------------------------------------------------------

upgrade() {
    local old=""
    [[ -f $INSTALL_DIR/$TELEM_SCRIPT && -f $INSTALL_DIR/$NODES_SCRIPT ]] \
        || die "No existing install found in $INSTALL_DIR. Run this installer without --upgrade to install."
    [[ -f $VERSION_FILE ]] && old=$(< "$VERSION_FILE")

    echo "DECtalk telemetry upgrade for AllStarLink 3"
    echo
    echo "Installed version: ${old:-0.12 or older}"
    echo "New version:       $VERSION"
    echo
    echo "This replaces the scripts in $INSTALL_DIR. If you have edited"
    echo "dec-init.cfg or prompt-list.txt, you will be asked whether to keep"
    echo "your copy. Your node-overrides.conf is kept."
    echo "Nothing else is changed: no packages, no Asterisk config, and no"
    echo "sounds are generated."
    echo
    ask_yn "Upgrade now?" y || { echo "Nothing was changed."; exit 0; }
    echo
    install_files

    echo
    echo "Checking the installation:"
    if ! run_checks; then
        echo "Run this installer without --upgrade to set up what is missing."
        echo "It skips everything that is already done."
    fi
    echo
    echo "Upgrade to $VERSION done. Existing sounds were not changed."
    echo "To use changes in this version, regenerate them as described in the"
    echo "README (for example: $NODES_SCRIPT -a -r)."
}

usage() {
    cat << EOF
Usage: install.sh [--upgrade]

Without options, guide you through installing DECtalk, the scripts and the
Asterisk configuration.

   --upgrade, -u  Only replace the scripts of an existing install with this
                  version. Changes no Asterisk config, installs no packages
                  and generates no sounds.
   --help, -h     Show this message
EOF
}

# --- Main ------------------------------------------------------------------

case ${1:-} in
    "") ;;
    --upgrade|-u) MODE=upgrade ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
esac

[[ $EUID -eq 0 ]] || die "This installer must be run as root (for example: sudo $0)."

if is_hamvoip; then
    die "This looks like a HamVoIP system. This installer and the DECtalk scripts do not work on HamVoIP. They need AllStarLink 3 (ASL3) on Debian."
fi
is_asl3 || die "AllStarLink 3 (ASL3) is not installed (package 'asl3' not found). Nothing was changed."
[[ -f $ASTERISK_CONF ]] || die "$ASTERISK_CONF not found. Nothing was changed."
[[ -f $RPT_CONF ]] || die "$RPT_CONF not found. Nothing was changed."

have_files=1
for f in "${SCRIPTS[@]}" "${DATA_FILES[@]}" "${USER_FILES[@]}"; do
    [[ -n $SRC_DIR && -f $SRC_DIR/$f ]] || have_files=0
done
if (( ! have_files )); then
    # Run from a pipe (curl | bash) or on its own: fetch the release and
    # run its installer, reading answers from the terminal rather than
    # from the pipe.
    [[ -r /dev/tty ]] || die "No terminal to ask questions on. Download the release and run install.sh from it instead."
    command -v curl > /dev/null || die "curl is needed to download the installer files."
    echo "Downloading asl-dectalk-telemetry $VERSION to $DOWNLOAD_DIR..."
    rm -rf -- "$DOWNLOAD_DIR"
    mkdir -p -- "$DOWNLOAD_DIR" || die "Could not create $DOWNLOAD_DIR"
    curl -fsSL "$RELEASE_URL" | tar -xz -C "$DOWNLOAD_DIR" --strip-components=1 \
        || die "Could not download $RELEASE_URL"
    [[ -f $DOWNLOAD_DIR/install.sh ]] || die "The download from $RELEASE_URL has no install.sh"
    exec bash "$DOWNLOAD_DIR/install.sh" "$@" < /dev/tty
fi

if [[ $MODE == upgrade ]]; then
    upgrade
    exit 0
fi

echo "DECtalk telemetry installer for AllStarLink 3, version $VERSION"
echo
echo "This will:"
echo "  1. Install DECtalk if it is not already working"
echo "  2. Install ffmpeg and perl if they are missing"
echo "  3. Turn on automatic updates of the node database ($ASTDB)"
echo "  4. Copy the scripts to $INSTALL_DIR and put them on the PATH"
echo "  5. Allow custom sounds in $ASTERISK_CONF"
echo "  6. Point node names in $RPT_CONF at $NODENAMES_DIR"
echo "  7. Check that everything is installed"
echo "  8. Offer to generate the telemetry and node name sounds"
echo
echo "You will be asked before each change. Config files are backed up first."
echo
ask_yn "Start the installation?" y || { echo "Nothing was changed."; exit 0; }

step_dectalk
step_packages
step_node_database
step_scripts
step_asterisk_conf
step_rpt_conf
step_verify && step_generate

if (( ASTERISK_RESTART_NEEDED )); then
    echo
    echo "Asterisk must be restarted to use the changed configuration."
    echo "Restarting drops any active connections on this node."
    if ask_yn "Restart Asterisk now?" n; then
        systemctl restart asterisk && echo "Asterisk restarted." || echo "Restart failed. Run: systemctl restart asterisk"
    else
        echo "Restart it later with: systemctl restart asterisk"
    fi
fi

echo
echo "Done. Run \"$TELEM_SCRIPT\" or \"$NODES_SCRIPT -h\" from anywhere."
