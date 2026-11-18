#!/bin/bash
# dectalk-speak.sh
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Speak text with DECtalk on an ASL3 node, or write it to a .ulaw file.
#
# The text is read from FILE, or from standard input, and spoken with the
# voice settings in dec-init.cfg, like the other scripts. DECtalk
# [:commands] in the text are allowed.
#
# The node is the -n NODE given, or the default saved in speak-node.conf
# beside this script. With neither, the nodes defined in rpt.conf that
# Asterisk is running are found; if there are several, you choose one.
# The node found or chosen is saved as the default.

set -uo pipefail

# Byte-oriented locale: the silence trim works on raw u-law bytes.
export LC_ALL=C

SAY=/usr/local/bin/say
ASTERISK=/usr/sbin/asterisk
RPT_CONF=/etc/asterisk/rpt.conf
# readlink -f: find the files beside the real script, not a PATH symlink
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
INIT_CFG=$SCRIPT_DIR/dec-init.cfg
NODE_FILE=$SCRIPT_DIR/speak-node.conf
# Asterisk plays a file after "rpt localplay" returns, so it can't be
# deleted straight away. Files are kept in memory-backed /run (only root
# can write there, Asterisk can read it), and deleted after an hour.
PLAY_DIR=/run/asl-telem
KEEP_MINUTES=60

NODE=""
SAVE=0
GLOBAL=0
INTERACTIVE=0
OUT_FILE=""
IN_FILE=""

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat << EOF
Usage: dectalk-speak.sh [options] [FILE]

Speak the text in FILE, or typed or piped to standard input, on a node
with DECtalk, or write it to a .ulaw file. The voice settings come from
$INIT_CFG.
DECtalk [:commands] in the text are allowed.

OPTIONS:
   -n NODE     Play on NODE this time (the saved default is unchanged)
   -s          Save the node as the default: the -n NODE, or without -n,
               choose again from the nodes running on this system
   -l          Play on the node only (the default)
   -g          Play on the node and every node connected to it
   -i          Interactive: each line you type is spoken when you press
               Enter, until Ctrl-C. Works with -n, -s, -l and -g.
   -o FILE     Write the speech to FILE (8 kHz u-law, use a .ulaw name)
               instead of playing it. Needs no node and no root.
   -h          Show this message

Without -n, the default node saved in $NODE_FILE
is used. The first time, the nodes defined in $RPT_CONF
that Asterisk is running are found. If there are several, you choose
one. The node is then saved as the default.

EXAMPLES:
   echo "Net starts in five minutes." | sudo dectalk-speak.sh
   sudo dectalk-speak.sh -g announcement.txt
   sudo dectalk-speak.sh -n 506311 -s       (then type, and press Ctrl-D)
   sudo dectalk-speak.sh -i -g              (type line after line)
   echo "Welcome." | dectalk-speak.sh -o welcome.ulaw
EOF
}

# --- Nodes -----------------------------------------------------------------

# Print the node numbers defined in rpt.conf: [506311] and
# [506311](node-main) stanzas.
rpt_nodes() {
    sed -nE 's/^[[:space:]]*\[([0-9]+)\].*/\1/p' "$RPT_CONF"
}

node_running() {
    "$ASTERISK" -rx "rpt show variables $1" 2> /dev/null | grep -q '^Variable listing'
}

# True if questions can be asked on a terminal, even when standard input
# carries the text.
have_tty() {
    { : < /dev/tty; } 2> /dev/null
}

# Find the running nodes and put one in NODE, asking which if there are
# several.
choose_node() {
    local -a nodes=()
    local node i answer

    [[ -f $RPT_CONF ]] || die "$RPT_CONF not found. Use -n NODE."
    for node in $(rpt_nodes); do
        node_running "$node" && nodes+=("$node")
    done
    (( ${#nodes[@]} )) || die "No running node was found in $RPT_CONF. Use -n NODE."

    if (( ${#nodes[@]} == 1 )); then
        NODE=${nodes[0]}
        echo "Using node $NODE, the only node running on this system." >&2
        return
    fi

    have_tty || die "Several nodes are running (${nodes[*]}). Choose one with -n NODE (add -s to save it), or run this on a terminal to choose."
    {
        echo "Several nodes are running on this system. Which one should be used?"
        for i in "${!nodes[@]}"; do
            echo "  $((i + 1))) Node ${nodes[$i]}"
        done
    } > /dev/tty
    while true; do
        read -r -p "Enter a number (1-${#nodes[@]}) [1]: " answer < /dev/tty 2> /dev/tty \
            || die "No answer given."
        [[ -z $answer ]] && answer=1
        if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#nodes[@]} )); then
            NODE=${nodes[$((answer - 1))]}
            return
        fi
        echo "Please enter a number from 1 to ${#nodes[@]}." > /dev/tty
    done
}

# Print the saved default node, if there is one.
saved_node() {
    [[ -f $NODE_FILE ]] || return 0
    grep -m 1 -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$NODE_FILE" | tr -d '[:space:]'
}

save_node() {
    printf '# Default node for dectalk-speak.sh. Change it with: dectalk-speak.sh -s\n%s\n' "$NODE" \
        > "$NODE_FILE" || die "Could not save the default node in $NODE_FILE"
    echo "Saved node $NODE as the default in $NODE_FILE." >&2
}

# Set NODE from -n, the saved default, or the running nodes.
resolve_node() {
    local saved

    if [[ -n $NODE ]]; then
        node_running "$NODE" || die "Node $NODE is not running on this system."
        (( SAVE )) && save_node
        return
    fi
    saved=$(saved_node)
    if [[ -n $saved ]] && (( ! SAVE )); then
        NODE=$saved
        node_running "$NODE" \
            || die "The default node $NODE (from $NODE_FILE) is not running. Use -n NODE, or -s to choose again."
        return
    fi
    choose_node
    save_node
}

# --- Speech ----------------------------------------------------------------

# speak TEXT OUT  - write TEXT spoken by DECtalk to OUT as 8 kHz u-law,
# with silence trimmed from both ends as for the node names.
speak() {
    local text=$1 out=$2 init=""
    [[ -f $INIT_CFG ]] && init=$(tr '\r\n' '  ' < "$INIT_CFG")
    "$SAY" -e 3 -fo stdout:raw -a "$init [:phoneme on] $text" < /dev/null 2> /dev/null \
        | perl -0777 -pe 's/^[\x73-\x7f\xf3-\xff]+//; s/[\x73-\x7f\xf3-\xff]+$//' > "$out"
    [[ ${PIPESTATUS[*]} == "0 0" && -s $out ]]
}

# Print the length of the u-law FILE in seconds, to one decimal place.
seconds() {
    local bytes
    bytes=$(stat -c %s -- "$1")
    echo "$((bytes / 8000)).$((bytes % 8000 * 10 / 8000))"
}

# Print TEXT with its lines joined (DECtalk sees the whole text at once)
# and surrounding white space removed.
clean_text() {
    local text
    text=$(tr '\r\n\t' '   ' <<< "$1")
    text=${text#"${text%%[![:space:]]*}"}
    echo "${text%"${text##*[![:space:]]}"}"
}

# play_text TEXT  - speak TEXT on $NODE. Returns 1 (after saying why) if it
# could not be played.
play_text() {
    local text=$1 file command where

    # A failed mkdir also fails mktemp, which says so below.
    mkdir -p -m 755 -- "$PLAY_DIR" 2> /dev/null
    find "$PLAY_DIR" -maxdepth 1 -name 'speak-*.ulaw' -mmin +"$KEEP_MINUTES" -delete 2> /dev/null
    if ! file=$(mktemp --suffix=.ulaw "$PLAY_DIR/speak-XXXXXX"); then
        echo "Error: Could not create a file in $PLAY_DIR" >&2
        return 1
    fi
    if ! speak "$text" "$file"; then
        rm -f -- "$file"
        echo "Error: DECtalk could not speak the text." >&2
        return 1
    fi
    chmod 644 -- "$file"

    if (( GLOBAL )); then
        command="rpt playback"
        where="node $NODE and the nodes connected to it"
    else
        command="rpt localplay"
        where="node $NODE"
    fi
    # Asterisk adds the extension itself.
    if ! "$ASTERISK" -rx "$command $NODE ${file%.ulaw}" > /dev/null 2>&1; then
        echo "Error: Asterisk could not play the speech on node $NODE." >&2
        return 1
    fi
    echo "Playing $(seconds "$file") seconds of speech on $where." >&2
}

# Read lines from the terminal and play each one when Enter is pressed,
# until Ctrl-C or Ctrl-D. Lines can be edited, and the up arrow brings
# back earlier ones.
interactive() {
    local line text where="node $NODE"
    (( GLOBAL )) && where+=" and the nodes connected to it"

    trap 'echo; exit 0' INT
    echo "Each line you type is spoken on $where when you press Enter." >&2
    echo "Press Ctrl-C (or Ctrl-D) to quit." >&2
    while IFS= read -r -e -p "> " line; do
        text=$(clean_text "$line")
        [[ -n $text ]] || continue
        history -s -- "$line"
        play_text "$text"
    done
    echo
}

# --- Main ------------------------------------------------------------------

while getopts ":n:slgio:h" opt; do
    case $opt in
        n) NODE=$OPTARG ;;
        s) SAVE=1 ;;
        l) GLOBAL=0 ;;
        g) GLOBAL=1 ;;
        i) INTERACTIVE=1 ;;
        o) OUT_FILE=$OPTARG ;;
        h) usage; exit 0 ;;
        :) usage >&2; die "-$OPTARG needs a value" ;;
        *) usage >&2; die "Unknown option: -$OPTARG" ;;
    esac
done
shift $((OPTIND - 1))
(( $# <= 1 )) || { usage >&2; die "Give at most one text file."; }
IN_FILE=${1:-}

[[ -z $NODE || $NODE =~ ^[0-9]+$ ]] || die "-n needs a node number, got: $NODE"
if [[ -n $OUT_FILE ]] && { [[ -n $NODE ]] || (( SAVE || GLOBAL || INTERACTIVE )); }; then
    die "-o writes a file and plays nothing, so it can't be used with -n, -s, -g or -i."
fi
if (( INTERACTIVE )); then
    [[ -z $IN_FILE ]] || die "-i reads what you type, so it can't be used with a text file."
    [[ -t 0 ]] || die "-i needs a terminal to type in."
fi
[[ -x $SAY ]] || die "DECtalk say command not found at $SAY"
command -v perl > /dev/null || die "perl is required to trim silence"
if [[ -n $IN_FILE && $IN_FILE != - ]]; then
    [[ -r $IN_FILE ]] || die "Cannot read $IN_FILE"
fi
if [[ -n $OUT_FILE ]]; then
    [[ -w $(dirname -- "$OUT_FILE") ]] || die "Cannot write to $(dirname -- "$OUT_FILE")"
fi

# Playing needs the Asterisk console. Choose the node before the text is
# typed, so a problem shows up first.
if [[ -z $OUT_FILE ]]; then
    [[ $EUID -eq 0 ]] || die "Playing on a node needs root (for example: sudo dectalk-speak.sh). -o FILE does not."
    [[ -x $ASTERISK ]] || die "Asterisk not found at $ASTERISK"
    "$ASTERISK" -rx "core show version" > /dev/null 2>&1 || die "Asterisk is not running."
    resolve_node
fi

if (( INTERACTIVE )); then
    interactive
    exit 0
fi

if [[ -z $IN_FILE || $IN_FILE == - ]]; then
    [[ -t 0 ]] && echo "Type the text to speak, then press Ctrl-D on a new line:" >&2
    text=$(cat) || die "Could not read the text."
else
    text=$(< "$IN_FILE") || die "Could not read $IN_FILE"
fi
text=$(clean_text "$text")
[[ -n $text ]] || die "There is no text to speak."

if [[ -n $OUT_FILE ]]; then
    tmp="$OUT_FILE.tmp.$$"
    if ! speak "$text" "$tmp"; then
        rm -f -- "$tmp"
        die "DECtalk could not speak the text."
    fi
    mv -f -- "$tmp" "$OUT_FILE" || { rm -f -- "$tmp"; die "Could not write $OUT_FILE"; }
    echo "Wrote $OUT_FILE ($(seconds "$OUT_FILE") seconds)." >&2
    exit 0
fi

play_text "$text" || exit 1
