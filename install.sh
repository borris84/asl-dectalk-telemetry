#!/bin/bash
# install.sh
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Install the telemetry and node name scripts on an ASL3 node, with
# DECtalk or ElevenLabs as the speech engine:
#   1. Check that this is ASL3 (and not HamVoIP)
#   2. Choose the speech engine (saved in /opt/asl-telem/engine.conf)
#   3. DECtalk: build and install DECtalk's "say" if it is not already
#      working
#   4. Install the programs the scripts need if missing (DECtalk: ffmpeg
#      and perl; ElevenLabs: perl and curl)
#   5. Turn on ASL3's automatic astdb.txt (node database) updates
#   6. Copy the scripts and their data files to /opt/asl-telem and link
#      the scripts into /usr/local/bin so they are on the PATH
#   7. DECtalk: choose the speaking rate. ElevenLabs: enter the API key,
#      choose the model, the voice and its speed (saved in
#      /opt/asl-telem/elevenlabs.conf). Either with an optional preview
#      played on a local node
#   8. Enable custom sounds in /etc/asterisk/asterisk.conf
#   9. Point nodenames in /etc/asterisk/rpt.conf at custom/rpt/nodenames
#  10. Check the install, then offer to generate the sounds
#
# Once installed, it is kept as /opt/asl-telem/install.sh and linked as
# /usr/local/bin/asl-telem-setup.sh, to change the settings later.
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
# dectalk-telemetry-upgrade.sh downloads the latest release and runs its
# install.sh --upgrade.

set -uo pipefail

VERSION=0.22
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
SPEAK_SCRIPT=dectalk-speak.sh
EL_TELEM_SCRIPT=elevenlabs-telemetry.sh
EL_NODES_SCRIPT=write_node_callsigns_elevenlabs.sh
EL_SPEAK_SCRIPT=elevenlabs-speak.sh
UPGRADE_SCRIPT=dectalk-telemetry-upgrade.sh
# This installer is kept in INSTALL_DIR and linked into BIN_DIR under
# this name, so settings can be changed later without the repository.
SETUP_SCRIPT=install.sh
SETUP_LINK=asl-telem-setup.sh
SCRIPTS=("$TELEM_SCRIPT" "$NODES_SCRIPT" "$SPEAK_SCRIPT"
    "$EL_TELEM_SCRIPT" "$EL_NODES_SCRIPT" "$EL_SPEAK_SCRIPT" "$UPGRADE_SCRIPT")
# Code the scripts load: always replaced, not put on the PATH.
LIB_FILES=(elevenlabs-common.sh)
DATA_FILES=(dec-init.cfg prompt-list.txt elevenlabs-prompt-list.txt)
# Installed only if missing: the user's own settings, never replaced.
USER_FILES=(node-overrides.conf)

VERSION_FILE=$INSTALL_DIR/VERSION
# The chosen speech engine, for the installer and anything else to read.
ENGINE_FILE=$INSTALL_DIR/engine.conf
ENGINE=""
OLD_ENGINE=""
ENGINE_CHANGED=0
# Set when the ElevenLabs model, voice or speed changes, so the node names
# are made again.
EL_CHANGED=0
EL_URL=https://elevenlabs.io
STAMP=$(date +%Y%m%d-%H%M%S)
ASTERISK_RESTART_NEEDED=0
MODE=install

DEC_INIT=$INSTALL_DIR/dec-init.cfg
ASTERISK=/usr/sbin/asterisk
# Speaking rate presets: "label|words per minute|samples per frame".
# [:ra] is DECtalk's speaking rate. Above about 350 words per minute DECtalk
# shortens and drops sounds, so the two fastest presets keep a moderate
# [:ra] and speed up the synthesizer itself with [:spf]: the percentage of
# the normal 6.4 ms of audio produced per frame (default 100). 67 plays
# 1.5 times as fast and 50 twice as fast, without changing the pitch.
RATE_PRESETS=(
    "Slowest|180|100"
    "Slow|250|100"
    "Normal|350|100"
    "Faster|350|67"
    "Fastest|300|50"
)
RATE_DEFAULT_CHOICE=3
# DECtalk's own limits for [:ra].
RATE_MIN=75
RATE_MAX=600
RATE_CHANGED=0
PREVIEW_DIR=""
PREVIEW_NODE=""
STEP_NO=0

# ElevenLabs models offered, best choice first: "model_id|description".
# Only those the account can use are shown. The v4 models have no
# English-only version; they are told the text is English (LANGUAGE=en in
# elevenlabs.conf), which keeps them from reading numbers in another
# language.
EL_MODEL_CHOICES=(
    "eleven_v4_turbo|Eleven v4 Turbo: fast and natural, and costs the least"
    "eleven_v4|Eleven v4: the most natural and expressive, but slower"
    "eleven_flash_v2|Eleven Flash v2: English only, fast, older and less natural"
    "eleven_flash_v2_5|Eleven Flash v2.5: fast and low cost, older"
    "eleven_multilingual_v2|Eleven Multilingual v2: older, reads numbers carefully"
)
# ElevenLabs speeds: "label|speed". It allows 0.7 to 1.2.
EL_SPEED_PRESETS=(
    "Slow|0.8"
    "Relaxed|0.9"
    "Normal|1.0"
    "Brisk|1.1"
    "Fast|1.2"
)
EL_SPEED_DEFAULT_CHOICE=3
EL_SPEED_MIN=0.7
EL_SPEED_MAX=1.2

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

trap 'echo; echo "Installation stopped."; exit 130' INT
trap '[[ -n $PREVIEW_DIR ]] && rm -rf -- "$PREVIEW_DIR"' EXIT

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
    STEP_NO=$((STEP_NO + 1))
    echo
    echo "Step $STEP_NO: $1"
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

# --- DECtalk -------------------------------------------------------

# assemble_dectalk SRC DEST  - copy what say needs from a US English build
# in SRC (dectalk/src) into DEST, laid out as upstream's "make install"
# would: say, lib/libtts.so (which loads lib/libtts_<language>.so),
# dic/dtalk_us.dic, DECtalk.conf and the documentation. Build folders are
# named after the kernel version, hence the globs.
assemble_dectalk() {
    local src=$1 dest=$2 f
    local -a files=(
        "755 . samplosf/build/dtsamples/*/us/release/say"
        "755 lib dtalkml/build/*/us/release/libtts.so"
        "755 lib dapi/build/dectalk/*/us/release/libtts_us.so"
        "644 dic dapi/build/dic/*/us/release/dtalk_us.dic"
    )
    local mode dir pattern
    local -a found

    rm -rf -- "$dest"
    mkdir -p -- "$dest/lib" "$dest/dic" "$dest/doc/DECtalk" || return 1
    for f in "${files[@]}"; do
        read -r mode dir pattern <<< "$f"
        # shellcheck disable=SC2206 # the glob is meant to expand
        found=($src/$pattern)
        if (( ${#found[@]} != 1 )) || [[ ! -f ${found[0]} ]]; then
            echo "Not found in the build: $pattern" >&2
            return 1
        fi
        install -m "$mode" -- "${found[0]}" "$dest/$dir/" || return 1
    done

    # The license key and US English lines of the DECtalk.conf that
    # upstream's install target writes.
    sed -nE 's/^[[:space:]]*echo "((licenses|licensepassword|US_dict|US_udict|Default_lang):[^"]*|LANG:us,[^"]*)".*/\1/p' \
        "$src/Makefile" > "$dest/DECtalk.conf" || return 1
    if ! grep -q '^licenses:' "$dest/DECtalk.conf" || ! grep -q '^US_dict:' "$dest/DECtalk.conf"; then
        echo "Could not read the DECtalk.conf settings from $src/Makefile" >&2
        return 1
    fi

    for f in pdf html man; do
        [[ -d $src/docsosf/$f ]] && cp -r -- "$src/docsosf/$f" "$dest/doc/DECtalk/"
    done
    [[ -f $src/kitosf/kitbld/README ]] && install -m 644 -- "$src/kitosf/kitbld/README" "$dest/"
    return 0
}

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

    # Only US English is built: the scripts need nothing else, and the
    # default build compiles all six languages, taking about six times as
    # long. Audio output is disabled: the scripts only write audio to
    # files, and this keeps libtts free of ALSA/PulseAudio dependencies.
    echo "Building DECtalk (US English) for $(uname -m) with $jobs job(s)."
    echo "This takes a few minutes on a Raspberry Pi. Build log: $log"
    if ! ( cd "$BUILD_DIR/dectalk/src" \
            && ./autogen.sh \
            && ./configure --prefix="$DECTALK_DIR" --disable-audio \
            && make -j "$jobs" english_release ) > "$log" 2>&1; then
        echo "The DECtalk build failed. Last lines of the build log:" >&2
        tail -n 20 "$log" >&2
        die "DECtalk build failed. The full log is in $log"
    fi

    dist="$BUILD_DIR/dist"
    assemble_dectalk "$BUILD_DIR/dectalk/src" "$dist" \
        || die "The build finished but its files could not be collected. See $log"

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
    step "DECtalk speech synthesizer"
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
    echo "This needs an internet connection and about 500 MB of free disk space."
    echo
    ask_yn "Build and install DECtalk now?" y \
        || die "The scripts need DECtalk. Installation stopped."
    install_dectalk
}

# --- other packages ------------------------------------------------

# Print the name of the chosen engine's node name script.
nodes_script() {
    if [[ $ENGINE == elevenlabs ]]; then echo "$EL_NODES_SCRIPT"; else echo "$NODES_SCRIPT"; fi
}

# Print the programs the chosen engine's scripts need.
needed_programs() {
    if [[ $ENGINE == elevenlabs ]]; then echo perl curl; else echo ffmpeg perl; fi
}

step_packages() {
    local -a missing=()
    local p
    step "Other required programs"

    for p in $(needed_programs); do
        command -v "$p" > /dev/null || missing+=("$p")
    done
    if (( ${#missing[@]} == 0 )); then
        echo "$(needed_programs | sed 's/ / and /') are already installed."
        return
    fi

    echo "These packages are needed by the scripts and are not installed: ${missing[*]}"
    ask_yn "Install them now?" y || die "The scripts need ${missing[*]}. Installation stopped."
    apt-get update || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" \
        || die "Could not install ${missing[*]}"
}

# --- node database -------------------------------------------------

step_node_database() {
    local nodes
    step "AllStarLink node database ($ASTDB)"

    if ! dpkg-query -W -f='${Status}' asl3-update-nodelist 2> /dev/null | grep -q 'install ok installed'; then
        echo "The asl3-update-nodelist package, which downloads $ASTDB,"
        echo "is not installed."
        ask_yn "Install it now?" y || die "$(nodes_script) needs $ASTDB. Installation stopped."
        apt-get update || die "apt-get update failed"
        DEBIAN_FRONTEND=noninteractive apt-get install -y asl3-update-nodelist \
            || die "Could not install asl3-update-nodelist"
    fi

    if astdb_updates_on && [[ -s $ASTDB ]]; then
        echo "Automatic node database updates are already on."
        return
    fi

    echo "$(nodes_script) reads each node's call sign from $ASTDB."
    echo "ASL3 downloads that file with the asl3-update-astdb service and timer,"
    echo "which are turned off by default. Turning them on downloads the file"
    echo "now, then again at every boot and every 6 hours."
    echo
    if ! ask_yn "Turn on automatic node database updates?" y; then
        if [[ -s $ASTDB ]]; then
            echo "Skipped. $ASTDB will not be kept up to date, so new and changed nodes won't be announced."
        else
            echo "Skipped. $(nodes_script) will not work until $ASTDB exists."
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

# --- scripts -------------------------------------------------------

step_scripts() {
    step "Install the scripts"

    echo "The scripts and their data files will be copied to $INSTALL_DIR,"
    echo "and the scripts will be linked into $BIN_DIR so they can be run"
    echo "from anywhere. This installer is kept there too, as $SETUP_LINK,"
    echo "to change the speech engine, voice or other settings later."
    echo
    ask_yn "Continue?" y || die "Installation stopped."
    install_files
    save_engine
}

# Copy the scripts and data files into INSTALL_DIR and link the scripts
# into BIN_DIR. Used by both install and --upgrade.
install_files() {
    local f src dest link

    mkdir -p -- "$INSTALL_DIR" || die "Could not create $INSTALL_DIR"

    # Run as asl-telem-setup.sh, the files are already in place.
    if running_installed_copy; then
        echo "The files in $INSTALL_DIR are already installed."
    else
        copy_files
    fi

    for f in "${SCRIPTS[@]}"; do
        link="$BIN_DIR/$f"
        if [[ -e $link && ! -L $link ]]; then
            mv -- "$link" "$link.bak-$STAMP" || die "Could not move the old $link aside"
            echo "Moved the old $link to $link.bak-$STAMP"
        fi
        ln -sfn -- "$INSTALL_DIR/$f" "$link" || die "Could not link $link"
        echo "Linked $link -> $INSTALL_DIR/$f"
    done
    link="$BIN_DIR/$SETUP_LINK"
    if [[ -e $link && ! -L $link ]]; then
        mv -- "$link" "$link.bak-$STAMP" || die "Could not move the old $link aside"
        echo "Moved the old $link to $link.bak-$STAMP"
    fi
    ln -sfn -- "$INSTALL_DIR/$SETUP_SCRIPT" "$link" || die "Could not link $link"
    echo "Linked $link -> $INSTALL_DIR/$SETUP_SCRIPT"

    echo "$VERSION" > "$VERSION_FILE" || die "Could not write $VERSION_FILE"
}

# True when this is the copy of the installer kept in INSTALL_DIR.
running_installed_copy() {
    [[ -n $SRC_DIR && $SRC_DIR -ef $INSTALL_DIR ]]
}

# Copy the scripts, the installer and the data files into INSTALL_DIR.
copy_files() {
    local f src dest

    install -m 755 -- "$SRC_DIR/$SETUP_SCRIPT" "$INSTALL_DIR/$SETUP_SCRIPT" || die "Could not copy $SETUP_SCRIPT"
    echo "Installed $INSTALL_DIR/$SETUP_SCRIPT"
    for f in "${SCRIPTS[@]}"; do
        install -m 755 -- "$SRC_DIR/$f" "$INSTALL_DIR/$f" || die "Could not copy $f"
        echo "Installed $INSTALL_DIR/$f"
    done
    for f in "${LIB_FILES[@]}"; do
        install -m 644 -- "$SRC_DIR/$f" "$INSTALL_DIR/$f" || die "Could not copy $f"
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
}

# --- Speech engine ---------------------------------------------------------

# Print the engine saved in ENGINE_FILE, or nothing.
saved_engine() {
    [[ -f $ENGINE_FILE ]] || return 0
    sed -nE 's/^[[:space:]]*ENGINE[[:space:]]*=[[:space:]]*(dectalk|elevenlabs)[[:space:]]*$/\1/p' "$ENGINE_FILE" | head -n 1
}

engine_name() {
    if [[ $1 == elevenlabs ]]; then echo ElevenLabs; else echo DECtalk; fi
}

# Ask which engine to use, before anything is changed. It is saved with
# the scripts (save_engine).
choose_engine() {
    local default=1
    OLD_ENGINE=$(saved_engine)
    # An install from before ElevenLabs was offered uses DECtalk.
    [[ -z $OLD_ENGINE && -f $INSTALL_DIR/$TELEM_SCRIPT ]] && OLD_ENGINE=dectalk
    [[ $OLD_ENGINE == elevenlabs ]] && default=2

    if [[ -n $OLD_ENGINE ]]; then
        echo "The announcements are currently made with $(engine_name "$OLD_ENGINE")."
        echo
    fi
    echo "Which speech engine should make the announcements?"
    echo "  1) DECtalk     Runs on this node: fast, free, and needs no internet"
    echo "                 connection once installed. The classic synthesized voice."
    echo "  2) ElevenLabs  Natural sounding voices from ElevenLabs' online service."
    echo "                 Needs an ElevenLabs plan with API access. Every sound made"
    echo "                 uses credits, and announcing each node by its call sign"
    echo "                 can use a lot of them (there are tens of thousands of nodes)."
    ask_number 2 "$default"
    if (( CHOICE == 2 )); then ENGINE=elevenlabs; else ENGINE=dectalk; fi
    [[ -n $OLD_ENGINE && $ENGINE != "$OLD_ENGINE" ]] && ENGINE_CHANGED=1
    return 0
}

save_engine() {
    printf '# Speech engine chosen with install.sh: dectalk or elevenlabs.\nENGINE=%s\n' "$ENGINE" \
        > "$ENGINE_FILE" || die "Could not write $ENGINE_FILE"
    echo "Saved the speech engine ($(engine_name "$ENGINE")) in $ENGINE_FILE"
}

# --- ElevenLabs --------------------------------------------------------------

save_el_config() {
    el_defaults
    el_save_config || die "Could not write $EL_CONF"
}

# What changes the sound of the ElevenLabs announcements.
el_signature() {
    echo "$EL_MODEL_ID|$EL_VOICE_ID|$EL_SPEED|$EL_LANGUAGE|${EL_STABILITY:-}|${EL_SIMILARITY:-}"
}

step_el_key() {
    local key count
    step "ElevenLabs API key"

    el_load_config || el_defaults
    EL_START_SIGNATURE=$(el_signature)
    if [[ -n $EL_API_KEY ]]; then
        echo "An API key is saved in $EL_CONF (ending in ...${EL_API_KEY: -4})."
        if el_voices; then
            count=$(grep -c . <<< "$EL_VOICE_LIST")
            echo "It works: your voice library has $count voices."
            ask_yn "Keep using this key?" y && return
        else
            echo "It does not work: $EL_ERROR"
        fi
        echo
    fi

    echo "The ElevenLabs scripts need an API key from your ElevenLabs account,"
    echo "and your plan must include API access. If you don't have a key yet,"
    echo "sign in to $EL_URL and create one at:"
    echo
    echo "  $EL_KEYS_URL"
    echo
    echo "Give the key access to Text to Speech, and read access to Voices and"
    echo "Models. Read access to User lets the scripts show the credits you have"
    echo "left. The key is saved in $EL_CONF, which only root can read."
    echo
    while true; do
        read -r -s -p "Paste your API key (it is not shown), or press Enter to stop: " key \
            || { echo; die "No answer given. Installation stopped."; }
        echo
        key=${key//[[:space:]]/}
        [[ -n $key ]] || die "The ElevenLabs scripts need an API key. Installation stopped."
        EL_API_KEY=$key
        echo "Checking the key..."
        if el_voices; then
            count=$(grep -c . <<< "$EL_VOICE_LIST")
            echo "The key works: your voice library has $count voices."
            break
        fi
        echo "That key did not work: $EL_ERROR"
        echo
    done
    save_el_config
    echo "Saved the API key in $EL_CONF"
}

step_el_model() {
    local -a ids=() descs=()
    local entry id desc rate i default=1 note current_listed=0
    step "ElevenLabs model"

    if ! el_models; then
        echo "The model list could not be read ($EL_ERROR)."
        echo "Using ${EL_MODEL_ID:-$EL_DEFAULT_MODEL}."
        save_el_config
        return
    fi
    for entry in "${EL_MODEL_CHOICES[@]}"; do
        IFS='|' read -r id desc <<< "$entry"
        grep -q "^$id"$'\t' <<< "$EL_MODEL_LIST" || continue
        ids+=("$id")
        descs+=("$desc")
    done
    if (( ${#ids[@]} == 0 )); then
        echo "None of the usual models are available to your account. Using $EL_MODEL_ID."
        save_el_config
        return
    fi

    echo "The model is the engine ElevenLabs speaks with. The text is always sent"
    echo "as English, so numbers and call signs are read in English."
    echo
    echo "Choose a model:"
    for i in "${!ids[@]}"; do
        rate=$(awk -F'\t' -v m="${ids[$i]}" '$1 == m { print $3; exit }' <<< "$EL_MODEL_LIST")
        note=""
        (( i == 0 )) && note=" (recommended)"
        if [[ ${ids[$i]} == "$EL_MODEL_ID" ]]; then
            default=$((i + 1))
            current_listed=1
            note+=" (current)"
        fi
        printf '  %d) %s%s\n' $((i + 1)) "${descs[$i]}" "$note"
        # "1 credit", but "0.5 credits" and "2 credits"
        if awk -v r="$rate" 'BEGIN { exit !(r == 1) }'; then
            printf '     %s credit per character\n' "$rate"
        else
            printf '     %s credits per character\n' "$rate"
        fi
    done
    # A model set by hand that isn't listed can be kept.
    if (( ! current_listed )) && [[ -n $EL_MODEL_ID ]]; then
        ids+=("$EL_MODEL_ID")
        default=${#ids[@]}
        printf '  %d) Keep the current model: %s\n' "$default" "$EL_MODEL_ID"
    fi
    ask_number "${#ids[@]}" "$default"
    EL_MODEL_ID=${ids[$((CHOICE - 1))]}
    save_el_config
    echo "Using $EL_MODEL_ID."
}

# Put the chosen voice in EL_VOICE_ID and EL_VOICE_NAME.
choose_voice() {
    local -a vids=() vnames=()
    local id name desc i=0 default=1
    echo "Voices in your ElevenLabs library:"
    while IFS=$'\t' read -r id name desc; do
        vids+=("$id")
        vnames+=("$name")
        i=$((i + 1))
        [[ $id == "$EL_VOICE_ID" ]] && default=$i
        printf '  %2d) %s%s%s\n' "$i" "$name" "${desc:+ ($desc)}" "$( [[ $id == "$EL_VOICE_ID" ]] && echo " (current)")"
    done <<< "$EL_VOICE_LIST"
    echo "Add more voices to your library at $EL_URL/app/voice-library"
    ask_number "${#vids[@]}" "$default"
    EL_VOICE_ID=${vids[$((CHOICE - 1))]}
    EL_VOICE_NAME=${vnames[$((CHOICE - 1))]}
}

# Put the chosen speed in EL_SPEED.
choose_speed() {
    local i label speed default=$EL_SPEED_DEFAULT_CHOICE note custom answer
    echo "How fast should $EL_VOICE_NAME speak?"
    for i in "${!EL_SPEED_PRESETS[@]}"; do
        IFS='|' read -r label speed <<< "${EL_SPEED_PRESETS[$i]}"
        note=""
        (( i + 1 == EL_SPEED_DEFAULT_CHOICE )) && note=" (the voice's normal pace)"
        awk -v a="$speed" -v b="$EL_SPEED" 'BEGIN { exit !(a + 0 == b + 0) }' \
            && { default=$((i + 1)); note+=" (current)"; }
        printf '  %d) %-8s %s%s\n' $((i + 1)) "$label" "$speed" "$note"
    done
    custom=$(( ${#EL_SPEED_PRESETS[@]} + 1 ))
    printf '  %d) %-8s enter a speed from %s to %s\n' "$custom" "Custom" "$EL_SPEED_MIN" "$EL_SPEED_MAX"
    ask_number "$custom" "$default"
    if (( CHOICE < custom )); then
        IFS='|' read -r label EL_SPEED <<< "${EL_SPEED_PRESETS[$((CHOICE - 1))]}"
        return
    fi
    while true; do
        read -r -p "Speed ($EL_SPEED_MIN-$EL_SPEED_MAX) [$EL_SPEED]: " answer \
            || { echo; die "No answer given. Installation stopped."; }
        [[ -z $answer ]] && answer=$EL_SPEED
        if [[ $answer =~ ^[0-9]*\.?[0-9]+$ ]] \
            && awk -v a="$answer" -v lo="$EL_SPEED_MIN" -v hi="$EL_SPEED_MAX" 'BEGIN { exit !(a >= lo && a <= hi) }'; then
            EL_SPEED=$answer
            return
        fi
        echo "Please enter a number from $EL_SPEED_MIN to $EL_SPEED_MAX, for example 1.05."
    done
}

# Make the preview folder, which Asterisk (its own user) must be able to
# read. Returns 1 if it can't be made.
make_preview_dir() {
    [[ -n $PREVIEW_DIR ]] && return 0
    PREVIEW_DIR=$(mktemp -d "$INSTALL_DIR/preview.XXXXXX") \
        && chmod 755 -- "$PREVIEW_DIR" \
        || { echo "Could not create a folder for the preview."; PREVIEW_DIR=""; return 1; }
}

# The sample announcements spoken by a preview.
preview_text() {
    local digits
    digits=$(sed 's/./& /g; s/ $//' <<< "$PREVIEW_NODE")
    echo "Node $digits. Connected to node 2 0 0 0. The time is 3:15 PM. All links disconnected."
}

# Play the chosen voice on a local node until the user decides. Prints
# nothing and returns 0 to use it, or returns 1 with CHOICE 2 (another
# voice) or 3 (another speed).
preview_el_voice() {
    make_preview_dir || return 0
    echo "Making the preview with ElevenLabs..."
    if ! el_render "$(preview_text)" "$PREVIEW_DIR/preview.ul"; then
        echo "The preview could not be made: $EL_ERROR"
        return 0
    fi
    chmod 644 -- "$PREVIEW_DIR/preview.ul"
    play_preview
    while true; do
        echo
        echo "  1) Play it again"
        echo "  2) Choose a different voice"
        echo "  3) Choose a different speed"
        echo "  4) Use this voice and speed"
        ask_number 4 4
        case $CHOICE in
            1) play_preview ;;
            2|3) return 1 ;;
            4) return 0 ;;
        esac
    done
}

step_el_voice() {
    local preview=0 pick_voice=1 chars
    step "ElevenLabs voice and speed"

    if [[ -z ${EL_VOICE_LIST:-} ]] && ! el_voices; then
        die "Could not read your voice library: $EL_ERROR"
    fi
    while true; do
        if (( pick_voice )); then
            choose_voice
            echo
        fi
        choose_speed

        # Asked once: after "choose a different voice/speed" the loop goes
        # straight back to the preview.
        if (( ! preview )); then
            chars=$(preview_text | wc -c)
            echo
            echo "You can hear a preview of this voice on a node on this system."
            echo "It is played like any other announcement, so it is transmitted"
            echo "if the node has a radio. Each preview made uses about $chars characters"
            echo "of your ElevenLabs credits."
            if ask_yn "Preview the voice on a local node?" y; then
                choose_preview_node && preview=1
            fi
        fi
        if (( preview )) && ! preview_el_voice; then
            pick_voice=0
            (( CHOICE == 2 )) && pick_voice=1
            echo
            continue
        fi
        break
    done

    save_el_config
    echo "Using the voice $EL_VOICE_NAME at speed $EL_SPEED."
    [[ $(el_signature) != "$EL_START_SIGNATURE" ]] && EL_CHANGED=1
    return 0
}

# --- Speaking rate -------------------------------------------------

# rate_setting TEXT  - print "RATE SPF" from DECtalk commands in TEXT.
# Either is printed as 0 if TEXT doesn't set it.
rate_setting() {
    local ra spf
    ra=$(grep -oE '\[:ra(te)?[[:space:]]+[0-9]+\]' <<< "$1" | head -n 1 | grep -oE '[0-9]+')
    spf=$(grep -oE '\[:spf[[:space:]]+[0-9]+\]' <<< "$1" | head -n 1 | grep -oE '[0-9]+')
    echo "${ra:-0} ${spf:-0}"
}

# with_rate TEXT RATE SPF  - print TEXT with its [:ra] set to RATE and its
# [:spf] set to SPF. SPF 100 (the default) removes [:spf].
with_rate() {
    local text=$1 ra=$2 spf=$3 cmd
    cmd="[:ra $ra]"
    (( spf != 100 )) && cmd+=" [:spf $spf]"
    text=$(sed -E 's/[[:space:]]*\[:spf[[:space:]]+[0-9]+\]//g' <<< "$text")
    if grep -qE '\[:ra(te)?[[:space:]]+[0-9]+\]' <<< "$text"; then
        sed -E "s/\[:ra(te)?[[:space:]]+[0-9]+\]/$cmd/" <<< "$text"
    elif [[ $text == "[:phoneme on]"* ]]; then
        echo "[:phoneme on] $cmd${text#"[:phoneme on]"}"
    else
        echo "$cmd $text"
    fi
}

# describe_rate RATE SPF  - print a short description of a rate setting.
describe_rate() {
    local ra=$1 spf=$2
    if (( spf == 100 )); then
        echo "$ra words per minute"
    else
        printf '%s words per minute, sped up %s times (about %s)\n' "$ra" \
            "$(awk -v s="$spf" 'BEGIN { printf "%g", int(1000 / s + 0.5) / 10 }')" \
            "$(( (ra * 100 / spf + 5) / 10 * 10 ))"
    fi
}

# choose_rate RATE SPF  - show the speaking rate menu, with RATE and SPF as
# the current setting, and put the choice in NEW_RA and NEW_SPF.
choose_rate() {
    local cur_ra=$1 cur_spf=$2 i label ra spf default=$RATE_DEFAULT_CHOICE
    local count=${#RATE_PRESETS[@]} keep=0 custom matched=0 note
    echo "Choose how fast DECtalk speaks:"
    for i in "${!RATE_PRESETS[@]}"; do
        IFS='|' read -r label ra spf <<< "${RATE_PRESETS[$i]}"
        note=""
        (( i + 1 == RATE_DEFAULT_CHOICE )) && note=" (default)"
        if (( ra == cur_ra && spf == cur_spf )); then
            default=$((i + 1))
            matched=1
            note+=" (current)"
        fi
        printf '  %d) %-8s %s%s\n' $((i + 1)) "$label" "$(describe_rate "$ra" "$spf")" "$note"
    done
    custom=$((count + 1))
    count=$custom
    printf '  %d) %-8s enter a rate from %d to %d words per minute\n' \
        "$custom" "Custom" "$RATE_MIN" "$RATE_MAX"
    # A setting made by hand that isn't one of the presets can be kept.
    if (( ! matched && cur_ra > 0 )); then
        keep=$((count + 1))
        count=$keep
        default=$keep
        printf '  %d) Keep the current setting: %s\n' "$keep" "$(describe_rate "$cur_ra" "$cur_spf")"
    fi
    ask_number "$count" "$default"
    if (( CHOICE == keep )); then
        NEW_RA=$cur_ra
        NEW_SPF=$cur_spf
    elif (( CHOICE == custom )); then
        ask_custom_rate "$cur_ra"
        NEW_SPF=100
    else
        IFS='|' read -r label NEW_RA NEW_SPF <<< "${RATE_PRESETS[$((CHOICE - 1))]}"
    fi
}

# ask_custom_rate RATE  - read a speaking rate from RATE_MIN to RATE_MAX into
# NEW_RA, offering RATE (if it is in range) or 350 as the default.
ask_custom_rate() {
    local default=$1 answer
    (( default >= RATE_MIN && default <= RATE_MAX )) || default=350
    while true; do
        read -r -p "Words per minute ($RATE_MIN-$RATE_MAX) [$default]: " answer \
            || { echo; die "No answer given. Installation stopped."; }
        [[ -z $answer ]] && answer=$default
        if [[ $answer =~ ^[0-9]+$ ]] && (( 10#$answer >= RATE_MIN && 10#$answer <= RATE_MAX )); then
            NEW_RA=$((10#$answer))
            return 0
        fi
        echo "Please enter a number from $RATE_MIN to $RATE_MAX."
    done
}

# Print the node numbers defined in rpt.conf: [506311] and
# [506311](node-main) stanzas.
rpt_nodes() {
    sed -nE 's/^[[:space:]]*\[([0-9]+)\].*/\1/p' "$RPT_CONF"
}

# Pick a running node to play previews on and put it in PREVIEW_NODE.
# Returns 1 (after saying why) if there is none.
choose_preview_node() {
    local -a nodes=()
    local node i

    if ! "$ASTERISK" -rx "core show version" > /dev/null 2>&1; then
        echo "Asterisk is not running, so a preview can't be played."
        return 1
    fi
    for node in $(rpt_nodes); do
        "$ASTERISK" -rx "rpt show variables $node" 2> /dev/null | grep -q '^Variable listing' \
            && nodes+=("$node")
    done
    if (( ${#nodes[@]} == 0 )); then
        echo "No running node was found in $RPT_CONF, so a preview can't be played."
        return 1
    fi

    if (( ${#nodes[@]} == 1 )); then
        PREVIEW_NODE=${nodes[0]}
        echo "The preview will be played on node $PREVIEW_NODE."
        return 0
    fi
    echo "Which node should the preview be played on?"
    for i in "${!nodes[@]}"; do
        echo "  $((i + 1))) Node ${nodes[$i]}"
    done
    ask_number "${#nodes[@]}" 1
    PREVIEW_NODE=${nodes[$((CHOICE - 1))]}
}

# render_preview INIT  - speak sample announcements with the DECtalk
# commands in INIT into $PREVIEW_DIR/preview.ul, as dectalk-telemetry.sh
# renders the prompts.
render_preview() {
    local init=$1 text out="$PREVIEW_DIR/preview.ul"
    text="$(preview_text | sed 's/3:15 PM/3 15 P M/')"
    "$SAY" -e 3 -fo stdout:raw -a "$init $text" < /dev/null 2> /dev/null \
        | ffmpeg -nostdin -v error -f mulaw -ar 8000 -ac 1 -i - \
            -af "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse" \
            -f mulaw -ar 8000 -ac 1 -y "$out" \
        && [[ -s $out ]] && chmod 644 -- "$out"
}

play_preview() {
    echo "Playing the preview on node $PREVIEW_NODE..."
    "$ASTERISK" -rx "rpt localplay $PREVIEW_NODE $PREVIEW_DIR/preview" > /dev/null 2>&1 \
        || echo "Asterisk could not play the preview."
}

# preview_rate INIT  - play INIT on a local node until the user decides.
# Returns 0 to use this rate, 1 to choose another.
preview_rate() {
    local init=$1
    make_preview_dir || return 0
    if ! render_preview "$init"; then
        echo "DECtalk could not make the preview."
        return 0
    fi
    play_preview
    while true; do
        echo
        echo "  1) Play it again"
        echo "  2) Choose a different speaking rate"
        echo "  3) Use this speaking rate"
        ask_number 3 3
        case $CHOICE in
            1) play_preview ;;
            2) return 1 ;;
            3) return 0 ;;
        esac
    done
}

step_speaking_rate() {
    local cfg cur_ra cur_spf new_cfg tmp preview=0
    step "Speaking rate"

    if [[ ! -f $DEC_INIT ]]; then
        echo "$DEC_INIT not found. Skipped."
        return
    fi
    cfg=$(< "$DEC_INIT")
    read -r cur_ra cur_spf <<< "$(rate_setting "$cfg")"
    (( cur_spf == 0 )) && cur_spf=100

    echo "DECtalk becomes hard to understand above about 350 words per minute."
    echo "The Faster and Fastest settings keep a moderate rate and speed up the"
    echo "synthesizer itself instead, which stays clearer."
    echo
    while true; do
        choose_rate "$cur_ra" "$cur_spf"
        new_cfg=$(with_rate "$cfg" "$NEW_RA" "$NEW_SPF")

        # Asked once: after "choose a different rate" the loop goes
        # straight back to the preview.
        if (( ! preview )); then
            echo
            echo "You can hear a preview of this rate on a node on this system."
            echo "It is played like any other announcement, so it is transmitted"
            echo "if the node has a radio."
            if ask_yn "Preview the speaking rate on a local node?" y; then
                choose_preview_node && preview=1
            fi
        fi
        if (( preview )) && ! preview_rate "$(tr '\r\n' '  ' <<< "$new_cfg")"; then
            echo
            continue
        fi
        break
    done

    if [[ $new_cfg == "$cfg" ]]; then
        echo "The speaking rate is unchanged: $(describe_rate "$NEW_RA" "$NEW_SPF")."
        return
    fi
    backup_file "$DEC_INIT"
    tmp=$(mktemp) || die "Could not create a temporary file"
    printf '%s\n' "$new_cfg" > "$tmp" || die "Could not write $tmp"
    replace_contents "$DEC_INIT" "$tmp"
    echo "Speaking rate set to $(describe_rate "$NEW_RA" "$NEW_SPF")."
    RATE_CHANGED=1
}

# --- asterisk.conf -------------------------------------------------

step_asterisk_conf() {
    local tmp line
    step "Allow custom sounds in $ASTERISK_CONF"

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

# --- rpt.conf ------------------------------------------------------

step_rpt_conf() {
    local values tmp line header
    local setting="nodenames = $NODENAMES_DIR ; DECtalk node name announcements"
    step "Point node names in $RPT_CONF at $NODENAMES_DIR"

    if nodenames_configured; then
        echo "nodenames is already set to $NODENAMES_DIR."
        mkdir -p -- "$NODENAMES_DIR" || die "Could not create $NODENAMES_DIR"
        return
    fi

    echo "$(nodes_script) writes node name announcements to"
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

# --- verify --------------------------------------------------------

step_verify() {
    step "Check the installation"
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

    if [[ $ENGINE == elevenlabs ]]; then
        el_load_config || el_defaults
        check "$EL_CONF has an API key and a voice" el_configured
        check "The ElevenLabs API key works" 'el_configured && el_voices 2> /dev/null'
    else
        check "DECtalk speaks ($SAY)" dectalk_works
    fi
    for f in $(needed_programs); do
        check "$f is installed" "command -v $f > /dev/null"
    done
    for f in "${SCRIPTS[@]}"; do
        check "$f is on the PATH" "[[ \$(command -v $f) == $BIN_DIR/$f && -x $INSTALL_DIR/$f ]]"
    done
    check "$SETUP_LINK is on the PATH" "[[ \$(command -v $SETUP_LINK) == $BIN_DIR/$SETUP_LINK && -x $INSTALL_DIR/$SETUP_SCRIPT ]]"
    for f in "${LIB_FILES[@]}" "${DATA_FILES[@]}"; do
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

# --- generate sounds -----------------------------------------------

step_generate() {
    if [[ $ENGINE == elevenlabs ]]; then
        step_generate_el
    else
        step_generate_dectalk
    fi
}

step_generate_dectalk() {
    local -a args=(-a)
    step "Generate the sounds"

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
        # Existing announcements are only rebuilt with -r.
        (( RATE_CHANGED || ENGINE_CHANGED )) && args+=(-r)
        echo
        echo "Each announcement can be followed by the node number,"
        echo "for example \"N 2 D Y I, node 5 0 6 3 1 1\"."
        ask_yn "Add the node number after each call sign?" n && args+=(-i)
        echo
        echo "Call signs can be spelled with letters (\"N 2 D Y I\") or with the"
        echo "phonetic alphabet (\"November, 2, Delta, Yankee, India\")."
        ask_yn "Speak call signs phonetically?" n && args+=(-P)
        if "$BIN_DIR/$NODES_SCRIPT" "${args[@]}"; then
            nodes_reminder "$NODES_SCRIPT" "${args[@]}"
        else
            echo "$NODES_SCRIPT reported a problem (see above)."
        fi
    else
        echo "Skipped. Run \"$NODES_SCRIPT -a\" later to build them."
    fi
}

# astdb_size PHONETIC NUMBER  - print "nodes announcements characters" for
# the node database: how many nodes there are, how many different
# announcements they need, and about how many characters speaking them
# would send to ElevenLabs. As in write_node_callsigns_dectalk.sh, nodes
# with the same call sign share one announcement unless the node number is
# spoken (NUMBER=1). Call signs are sent as they are, or about 5.5 times as
# long as phonetic words (PHONETIC=1).
astdb_size() {
    awk -F'|' -v phon="$1" -v num="$2" '
        /^;/ || NF < 2 || $1 == "" { next }
        { call[$1] = $2 }
        END {
            f = phon ? 5.5 : 1.1
            for (n in call) {
                nodes++
                if (num) { said++; c += f * length(call[n]) + 7 + 2 * length(n) }
                else if (!(call[n] in seen)) { seen[call[n]] = 1; said++; c += f * length(call[n]) }
            }
            printf "%d %d %d\n", nodes, said, c
        }
    ' "$ASTDB" 2> /dev/null || echo "0 0 0"
}

step_generate_el() {
    local -a args=(-a)
    local nodes said chars rate credits method default phon=0 num=0
    step "Generate the sounds"

    echo "The telemetry prompts must be generated before the node names."
    echo "$EL_TELEM_SCRIPT can rename or delete the whole custom sounds"
    echo "directory, which also holds the node names. Prompts that are already"
    echo "made with the same voice and settings are not made (or paid for) again."
    echo
    if ask_yn "Generate the telemetry prompts now ($EL_TELEM_SCRIPT)?" y; then
        "$BIN_DIR/$EL_TELEM_SCRIPT" || echo "$EL_TELEM_SCRIPT reported a problem (see above)."
    else
        echo "Skipped. Run $EL_TELEM_SCRIPT later, before $EL_NODES_SCRIPT."
    fi

    # Asked first: both change how many credits speaking the names uses.
    echo
    echo "Next, the node name announcements."
    echo
    echo "Each announcement can be followed by the node number,"
    echo "for example \"N 2 D Y I, node 5 0 6 3 1 1\"."
    ask_yn "Add the node number after each call sign?" n && { args+=(-i); num=1; }
    echo
    echo "Call signs can be spelled with letters (\"N 2 D Y I\") or with the"
    echo "phonetic alphabet (\"November, 2, Delta, Yankee, India\")."
    ask_yn "Speak call signs phonetically?" n && { args+=(-P); phon=1; }

    read -r nodes said chars <<< "$(astdb_size "$phon" "$num")"
    rate=$(awk -F'\t' -v m="$EL_MODEL_ID" '$1 == m { print $3; exit }' <<< "${EL_MODEL_LIST:-}")
    credits=""
    [[ -n $rate ]] && credits=$(awk -v c="$chars" -v r="$rate" 'BEGIN { printf "%d", c * r + 0.5 }')

    echo
    echo "The node database has $nodes nodes. Nodes with the same call sign share"
    if (( num )); then
        echo "an announcement, but with the node number spoken every node needs its"
        echo "own: $said announcements."
    else
        echo "an announcement, so $said different announcements are needed."
    fi
    echo "They can be made in one of two ways:"
    echo "  1) Joined  Put together from the letter and number sounds of the"
    echo "             telemetry prompts. Uses no credits, but sounds less natural."
    echo "  2) Spoken  Each announcement is one ElevenLabs request. Sounds the most"
    echo "             natural, but uses credits: about $chars characters"
    echo "             ${credits:+($(el_count "$credits" credit)) }for all $said, then a little more each time"
    echo "             nodes are added or changed. Making all $said also takes"
    echo "             a long time: $(el_duration "$said"), sending ${EL_JOBS:-2} at a time."
    default=1
    [[ $EL_NODE_METHOD == speak ]] && default=2
    ask_number 2 "$default"
    if (( CHOICE == 2 )); then method=speak; else method=join; fi
    [[ $method != "$EL_NODE_METHOD" ]] && EL_CHANGED=1
    EL_NODE_METHOD=$method
    save_el_config
    echo "Saved NODE_METHOD=$method in $EL_CONF, for later runs of $EL_NODES_SCRIPT."

    echo
    if ask_yn "Generate the node name announcements now ($EL_NODES_SCRIPT)?" y; then
        # Existing announcements are only rebuilt with -r.
        (( EL_CHANGED || ENGINE_CHANGED )) && args+=(-r)
        if "$BIN_DIR/$EL_NODES_SCRIPT" "${args[@]}"; then
            nodes_reminder "$EL_NODES_SCRIPT" "${args[@]}"
        else
            echo "$EL_NODES_SCRIPT reported a problem (see above)."
        fi
    else
        echo "Skipped. Run \"$EL_NODES_SCRIPT -a$( (( num )) && echo " -i")$( (( phon )) && echo " -P")\" later to build them."
    fi
}

# nodes_reminder SCRIPT ARGS  - after the node names are built with ARGS,
# explain how to keep them current, and that the installer can be run
# again.
nodes_reminder() {
    local script=$1 arg cron
    shift
    cron="0 3 * * * $BIN_DIR/$script -f"
    # -a and -r were for this first full build; keep the voice options.
    for arg in "$@"; do
        [[ $arg == -a || $arg == -r ]] || cron+=" $arg"
    done
    echo
    echo "The node names were built once. Nodes are added and changed all the"
    echo "time, so run $script regularly to keep them current,"
    echo "for example every night at 3:00 from root's crontab (sudo crontab -e):"
    echo
    echo "  $cron"
    echo
    echo "See \"Keeping node names up to date\" in the README:"
    echo "  https://github.com/$REPO#keeping-node-names-up-to-date"
    echo
    if [[ $script == "$EL_NODES_SCRIPT" ]] && grep -q '^NODE_METHOD=speak' "$EL_CONF" 2> /dev/null; then
        echo "Each run speaks only the new and changed nodes, which uses some credits."
        echo
    fi
    echo "To change the speech engine, voice, speaking rate or other settings"
    echo "later, run: sudo $SETUP_LINK"
    echo "Steps that are already done are skipped."
}

# --- Upgrade ---------------------------------------------------------------

upgrade() {
    local old=""
    if running_installed_copy; then
        echo "This is the installer kept in $INSTALL_DIR, the same version as"
        echo "the installed scripts. To upgrade to the latest release, run:"
        echo "  sudo $UPGRADE_SCRIPT"
        exit 0
    fi
    [[ -f $INSTALL_DIR/$TELEM_SCRIPT && -f $INSTALL_DIR/$NODES_SCRIPT ]] \
        || die "No existing install found in $INSTALL_DIR. Run this installer without --upgrade to install."
    [[ -f $VERSION_FILE ]] && old=$(< "$VERSION_FILE")

    echo "Telemetry scripts upgrade for AllStarLink 3"
    echo
    echo "Installed version: ${old:-0.12 or older}"
    echo "New version:       $VERSION"
    echo
    echo "This replaces the scripts in $INSTALL_DIR. If you have edited"
    echo "dec-init.cfg, prompt-list.txt or elevenlabs-prompt-list.txt, you will be"
    echo "asked whether to keep your copy. Your node-overrides.conf, and your"
    echo "ElevenLabs settings and speech engine choice, are kept."
    echo "Nothing else is changed: no packages, no Asterisk config, and no"
    echo "sounds are generated."
    echo
    ask_yn "Upgrade now?" y || { echo "Nothing was changed."; exit 0; }
    echo
    install_files

    ENGINE=$(saved_engine)
    ENGINE=${ENGINE:-dectalk}
    echo
    echo "Checking the installation (speech engine: $(engine_name "$ENGINE")):"
    if ! run_checks; then
        echo "Run \"sudo $SETUP_LINK\" to set up what is missing. It skips"
        echo "everything that is already done."
    fi
    echo
    echo "Upgrade to $VERSION done. Existing sounds were not changed."
    echo "Next time, upgrade with: sudo $UPGRADE_SCRIPT"
    echo "To use changes in this version, regenerate them as described in the"
    if [[ $ENGINE == elevenlabs ]]; then
        echo "README (for example: $EL_NODES_SCRIPT -a -r)."
    else
        echo "README (for example: $NODES_SCRIPT -a -r)."
    fi
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
for f in "${SCRIPTS[@]}" "${LIB_FILES[@]}" "${DATA_FILES[@]}" "${USER_FILES[@]}"; do
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

# The ElevenLabs code, with its settings where the scripts will look.
EL_CONF=$INSTALL_DIR/elevenlabs.conf
# shellcheck source=elevenlabs-common.sh
. "$SRC_DIR/elevenlabs-common.sh"

if [[ $MODE == upgrade ]]; then
    upgrade
    exit 0
fi

echo "Telemetry installer for AllStarLink 3 (DECtalk or ElevenLabs), version $VERSION"
echo
choose_engine

if [[ $ENGINE == elevenlabs ]]; then
    PLAN=(
        "Install perl and curl if they are missing"
        "Turn on automatic updates of the node database ($ASTDB)"
        "Copy the scripts to $INSTALL_DIR and put them on the PATH"
        "Enter your ElevenLabs API key"
        "Choose the ElevenLabs model"
        "Choose a voice and its speed, with an optional preview on your node"
        "Allow custom sounds in $ASTERISK_CONF"
        "Point node names in $RPT_CONF at $NODENAMES_DIR"
        "Check that everything is installed"
        "Offer to generate the telemetry and node name sounds"
    )
else
    PLAN=(
        "Install DECtalk if it is not already working"
        "Install ffmpeg and perl if they are missing"
        "Turn on automatic updates of the node database ($ASTDB)"
        "Copy the scripts to $INSTALL_DIR and put them on the PATH"
        "Choose the speaking rate, with an optional preview on your node"
        "Allow custom sounds in $ASTERISK_CONF"
        "Point node names in $RPT_CONF at $NODENAMES_DIR"
        "Check that everything is installed"
        "Offer to generate the telemetry and node name sounds"
    )
fi
echo
echo "This will:"
for i in "${!PLAN[@]}"; do
    printf '  %d. %s\n' $((i + 1)) "${PLAN[$i]}"
done
echo
echo "You will be asked before each change. Config files are backed up first."
echo
ask_yn "Start the installation?" y || { echo "Nothing was changed."; exit 0; }

if [[ $ENGINE == elevenlabs ]]; then
    step_packages
    step_node_database
    step_scripts
    step_el_key
    step_el_model
    step_el_voice
else
    step_dectalk
    step_packages
    step_node_database
    step_scripts
    step_speaking_rate
fi
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
if [[ $ENGINE == elevenlabs ]]; then
    echo "Done. Run \"$EL_TELEM_SCRIPT\" or \"$EL_NODES_SCRIPT -h\" from anywhere."
    echo "To speak your own text on the node, run \"$EL_SPEAK_SCRIPT -h\" for how."
else
    echo "Done. Run \"$TELEM_SCRIPT\" or \"$NODES_SCRIPT -h\" from anywhere."
    echo "To speak your own text on the node, run \"$SPEAK_SCRIPT -h\" for how."
fi
echo "To upgrade to a newer release later, run \"sudo $UPGRADE_SCRIPT\"."
