#!/bin/bash
# write_node_callsigns.sh
#
# Original script by N5LSN
# Updated by Jory A. Pratt
# DECtalk version Copyright (C) 2026 N2DYI
#
# Licensed under the GNU General Public License, version 2, like the
# original (https://github.com/hardenedpenguin/asl-misc-scripts). See LICENSE.
#
# Make app_rpt telemetry use ASL callsigns instead of node numbers.
# Intended for use on ASL3.
#
# DECtalk version:
#   - Each node's announcement is spoken by DECtalk (/usr/local/bin/say)
#     as 8 kHz u-law instead of being concatenated from letter/digit sound
#     files, with silence trimmed from both ends.
#   - Anything in the astdb callsign field that matches the pattern of an
#     IARU amateur radio call sign is spelled out ("N2DYI" is sent to
#     DECtalk as "n 2 D Y I"). Everything else ("FIRESIDE", "11CAT",
#     "Seattle") is passed to DECtalk as-is, except that asterisks are
#     removed ("*FIRESIDE*" is spoken as "FIRESIDE").
#   - If dec-init.cfg exists beside this script, its contents are
#     prepended to the text to set DECtalk's speech parameters.
#   - Output is still .ulaw (raw headerless u-law), written to a temp file
#     then renamed into place (crash-safe / no partial files).
#   - Parallel jobs (GNU parallel / xargs -P)
#   - Resume-safe: skip existing .ulaw unless callsign changed or -r
#   - Durable previous-db beside astdb.txt (not /tmp)
#   - Auto-locate astdb in /var/lib/asterisk or /var/log/asterisk
#   - Per-node overrides: -o replaces the astdb callsign field for a node
#     (or for every node with a given callsign), -t speaks custom text
#   - -a / -n / -i / -o / -t / -v / -j / -r / -s / -p

set -euo pipefail

# Byte-oriented locale: the callsign patterns below are ASCII-only, and the
# silence trim works on raw u-law bytes.
export LC_ALL=C

SRCDIR=""
DESTDIR="/usr/share/asterisk/sounds/custom/rpt/nodenames"
SAY="/usr/local/bin/say"
# readlink -f: find dec-init.cfg beside the real script, not a PATH symlink
INIT_CFG="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/dec-init.cfg"
DECTALK_INIT=""
PREV_DB=""
JOBS="$(nproc 2>/dev/null || echo 4)"
MAX_PREVIEW=10
PROGRESS_EVERY=1000

VERBOSE=0
INCNODE=0
FORCE_RUN=0
FORCE_REBUILD=0
PROCESS_ALL=0
SINGLE_NODE=""

declare -A PREV_CALLSIGNS
declare -A NODE_OVERRIDE    # node -> replacement callsign field (-o NODE=...)
declare -A CALL_OVERRIDE    # CALLSIGN -> replacement callsign field (-o CALL=...)
declare -A CUSTOM_TEXT      # node -> text spoken as-is (-t NODE=...)

usage() {
    cat << EOF
Usage: write_node_callsigns.sh [options]

OPTIONS:
   -h          Show this message
   -a          Process all nodes (fill gaps; skips existing unless -r)
   -i          Append "node" + node number after the callsign
   -n NODE     Process a single node
   -d PATH     Destination directory (default: $DESTDIR)
   -j N        Parallel jobs (default: nproc)
   -v          Verbose output
   -f          Skip confirmation prompt
   -r          Force regenerate even when output already exists
   -s PATH     Directory containing astdb.txt
   -p PATH     Previous-db path used for change detection
   -o KEY=TEXT Override the astdb callsign field. KEY is a node number
               (that node only) or a callsign (every node with that
               callsign). TEXT is handled like an astdb entry, so call
               signs in it are still spelled out. A node-number override
               wins over a callsign override. Repeatable.
   -t NODE=TEXT
               Speak TEXT as-is for NODE, with no call sign spelling.
               DECtalk [:commands] and [phonemes] are allowed. Wins over
               -o. Repeatable.

Output files are raw headerless u-law (.ulaw), spoken by DECtalk.
If dec-init.cfg exists beside this script, it is prepended to the spoken text.
Nodes with an -o or -t override are regenerated on every run. Nodes given
with -o NODE= or -t are built even when they are not in astdb.txt (private
nodes). After removing an override, rebuild that node with -n NODE -r.

Examples:
    ./write_node_callsigns.sh -a -f       # First full build, no prompt
    ./write_node_callsigns.sh -f          # Only new/changed nodes
    ./write_node_callsigns.sh -n 40000 -r # Rebuild one node
    ./write_node_callsigns.sh -f -o "506311=N2DYI hub" -o "N2DYI=N2DYI repeater"
    ./write_node_callsigns.sh -f -t "1999=the lab node"
EOF
}

log()  { printf '%s\n' "$*"; }
vlog() { (( VERBOSE )) && printf '%s\n' "$*" || true; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

resolve_astdb_dir() {
    local dir candidates=()
    [[ -n "$SRCDIR" ]] && candidates+=("$SRCDIR")
    candidates+=("/var/lib/asterisk" "/var/log/asterisk")
    for dir in "${candidates[@]}"; do
        if [[ -f "$dir/astdb.txt" ]]; then
            SRCDIR="$dir"
            return 0
        fi
    done
    return 1
}

ensure_directory_exists() {
    if [[ ! -d "$1" ]]; then
        log "Creating directory: $1"
        mkdir -p "$1" || die "Failed to create directory $1"
    fi
}

# Spell "$1" one character at a time into SPELLED: N2DYI -> n 2 D Y I
#
# E, N, S and W are sent in lower case. DECtalk reads an upper case E/N/S/W
# that follows a number as a compass point ("W 6 E K" is spoken as
# "W 6 East K"). In lower case it says the letter name, and the audio is
# otherwise identical to the upper case letter.
spell_out() {
    local word=${1^^} i char
    SPELLED=""
    for (( i = 0; i < ${#word}; i++ )); do
        char=${word:i:1}
        [[ $char == [ENSW] ]] && char=${char,,}
        SPELLED+="$char "
    done
    SPELLED=${SPELLED% }
}

# Return 0 if $1 (letters and digits only) has the shape of an IARU/ITU
# amateur radio call sign: a prefix, one separating digit, and a suffix of
# one to four characters, the last of which is a letter.
#   K1A  N2DYI  WB6NIL  KM6RPT     letter(s) + digit + suffix
#   4X1AB  9A2XYZ  3DA0XX          digit + letter(s) + digit + suffix
#   E24OUW  A61AB  T77C            letter + digit + digit + suffix
# Anything else (11CAT, WRYS609, HUB, 2000) is not a call sign.
is_callsign() {
    [[ $1 =~ ^([A-Za-z]{1,2}|[0-9][A-Za-z]{1,2}|[A-Za-z][0-9])[0-9][A-Za-z0-9]{0,3}[A-Za-z]$ ]]
}

# Convert an astdb callsign field into the text sent to DECtalk, written
# into SPEECH_TEXT (no command substitution, so no subshell per node).
#   - runs of letters/digits that are call signs are spelled out
#   - a lone "/" or "-" joined to a call sign (KA4EPS/R, VA2RXP-25) is
#     spoken as "slash" / "dash"
#   - a call sign's final I is sent as [']I (stressed) so it rises
#   - a VA/VE prefix gets a glottal stop after the V (V [q] e 3 R W J)
#   - asterisks are dropped
#   - everything else is passed through untouched
callsign_to_speech() {
    local rest=$1
    local -a tokens=() kinds=()
    local i n tok text="" SPELLED=""

    # Square brackets are DECtalk's command/phoneme delimiters. astdb is
    # user-supplied data, so never let it issue DECtalk commands.
    rest=${rest//[\[\]]/ }

    # Asterisks ("*FIRESIDE*") are decoration; DECtalk would say "asterisk".
    rest=${rest//\*/ }

    # Tokenize into alternating runs: call sign (c), other word (w), separator (s)
    while [[ -n $rest ]]; do
        # is_callsign runs its own regex, so save the match first
        if [[ $rest =~ ^[A-Za-z0-9]+ ]]; then
            tok=${BASH_REMATCH[0]}
            if is_callsign "$tok"; then kinds+=(c); else kinds+=(w); fi
        else
            [[ $rest =~ ^[^A-Za-z0-9]+ ]]
            tok=${BASH_REMATCH[0]}
            kinds+=(s)
        fi
        tokens+=("$tok")
        rest=${rest:${#tok}}
    done

    n=${#tokens[@]}
    for (( i = 0; i < n; i++ )); do
        case "${kinds[i]}" in
            c)
                spell_out "${tokens[i]}"
                # A final I falls flat; a leading stress mark makes it rise.
                [[ $SPELLED == *" I" ]] && SPELLED="${SPELLED% I} [']I"
                # VA/VE prefixes run together; a glottal stop separates them.
                [[ $SPELLED == "V "[Ae]" "* ]] && SPELLED="V [q] ${SPELLED#V }"
                text+=" $SPELLED "
                ;;
            s)
                if [[ ${tokens[i]} == [/-] ]] && (( i > 0 && i < n - 1 )) \
                    && [[ ${kinds[i-1]} == c || ${kinds[i+1]} == c ]]; then
                    if [[ ${tokens[i]} == / ]]; then text+=" slash "; else text+=" dash "; fi
                else
                    text+="${tokens[i]}"
                fi
                ;;
            *)
                text+="${tokens[i]}"
                ;;
        esac
    done

    # Collapse runs of whitespace and trim the ends
    read -r -a tokens <<< "$text" || true
    SPEECH_TEXT="${tokens[*]-}"
}

# Speak one node. Prints exactly one line on stdout per node - "OK ..." or
# "FAIL <reason>" - which report_progress counts and displays.
#   $2 mode: c = $3 is a callsign field (astdb or -o), t = $3 is -t text
process_one_node() {
    local node=$1
    local mode=$2
    local callsign=$3
    local out="$DESTDIR/$node.ulaw"
    local tmp="$out.tmp.$$"
    local SPEECH_TEXT="" SPELLED=""
    local text

    if [[ $mode == t ]]; then
        # Custom text comes from the command line, not astdb, so it is
        # trusted and may carry DECtalk commands.
        SPEECH_TEXT=$callsign
    else
        callsign_to_speech "$callsign"
    fi
    if [[ -z "$SPEECH_TEXT" ]]; then
        printf 'FAIL Error: Nothing speakable for node %s (%s)\n' "$node" "$callsign"
        return 1
    fi
    text="$SPEECH_TEXT"

    if (( INCNODE )); then
        spell_out "$node"
        text+=", node $SPELLED"
    fi

    # [:phoneme on] makes DECtalk treat ['] as a stress mark rather than
    # reading it aloud, whether or not dec-init.cfg turns it on.
    # DECtalk writes 8 kHz u-law straight to stdout. Leading/trailing bytes
    # quieter than about -50 dB (u-law codes 0x73-0x7f / 0xf3-0xff) are
    # trimmed as silence. Write to a temp file first so a crash/kill mid-run
    # never leaves a corrupt/partial node file in place.
    "$SAY" -e 3 -fo stdout:raw -a "$DECTALK_INIT [:phoneme on] $text" < /dev/null 2> /dev/null \
        | perl -0777 -pe 's/^[\x73-\x7f\xf3-\xff]+//; s/[\x73-\x7f\xf3-\xff]+$//' > "$tmp"
    if [[ "${PIPESTATUS[*]}" == "0 0" && -s "$tmp" ]]; then
        mv -f "$tmp" "$out"
    else
        rm -f "$tmp"
        printf 'FAIL DECtalk failed for node %s (%s)\n' "$node" "$callsign"
        return 1
    fi

    printf 'OK %s %s -> %s\n' "$node" "$callsign" "$text"
}

export -f process_one_node callsign_to_speech is_callsign spell_out

load_previous_database() {
    PREV_CALLSIGNS=()
    [[ -f "$PREV_DB" ]] || return 0
    local node callsign
    while IFS='|' read -r node callsign _; do
        [[ -n "$node" ]] || continue
        [[ "$node" == \;* ]] && continue
        PREV_CALLSIGNS["$node"]="$callsign"
    done < "$PREV_DB"
}

# Unique node|callsign lines (last occurrence wins).
latest_astdb_entries() {
    awk -F'|' '
        /^;/ || NF < 2 || $1 == "" { next }
        { node[$1] = $2 }
        END { for (n in node) print n "|" node[n] }
    ' "$SRCDIR/astdb.txt"
}

lookup_node_callsign() {
    local want=$1
    awk -F'|' -v want="$want" '
        /^;/ || NF < 2 { next }
        $1 == want { call = $2 }
        END { if (call != "") print call }
    ' "$SRCDIR/astdb.txt"
}

# Work out what to speak for a node, into SPEAK_MODE and SPEAK_VALUE
# (see process_one_node). Returns 0 if an -o/-t override applies.
resolve_node() {
    local node=$1
    local callsign=$2
    local call_key=${callsign^^}

    SPEAK_MODE=c
    SPEAK_VALUE=$callsign
    if [[ -n ${CUSTOM_TEXT[$node]+x} ]]; then
        SPEAK_MODE=t
        SPEAK_VALUE=${CUSTOM_TEXT[$node]}
    elif [[ -n ${NODE_OVERRIDE[$node]+x} ]]; then
        SPEAK_VALUE=${NODE_OVERRIDE[$node]}
    elif [[ -n $call_key && -n ${CALL_OVERRIDE[$call_key]+x} ]]; then
        SPEAK_VALUE=${CALL_OVERRIDE[$call_key]}
    else
        return 1
    fi
    return 0
}

# Return 0 if the node needs (re)generating.
needs_rebuild() {
    local node=$1
    local callsign=$2
    local out="$DESTDIR/$node.ulaw"
    local old="${PREV_CALLSIGNS[$node]-}"

    (( FORCE_REBUILD )) && return 0
    [[ -f "$out" ]] || return 0
    # Overrides aren't tracked in the previous db, so always rebuild them.
    resolve_node "$node" "$callsign" && return 0

    # Existing file: rebuild only when we know the callsign changed.
    if [[ -n "$old" && "$old" != "$callsign" ]]; then
        return 0
    fi
    return 1
}

queue_node() {
    local node=$1
    local callsign=$2
    local old="${PREV_CALLSIGNS[$node]-}"
    local note=""

    if resolve_node "$node" "$callsign"; then
        if [[ $SPEAK_MODE == t ]]; then note=" (custom text)"; else note=" (override)"; fi
    fi
    printf '%s|%s|%s\n' "$node" "$SPEAK_MODE" "$SPEAK_VALUE" >> "$WORK_FILE"
    if [[ -z "$old" ]]; then
        printf '%s: NEW -> %s%s\n' "$node" "$SPEAK_VALUE" "$note" >> "$CHANGES_FILE"
    else
        printf '%s: %s -> %s%s\n' "$node" "$old" "$SPEAK_VALUE" "$note" >> "$CHANGES_FILE"
    fi
}

# Parse an -o/-t argument KEY=TEXT into OPT_KEY and OPT_TEXT.
parse_override() {
    local flag=$1 arg=$2
    [[ $arg == *=* ]] || die "-$flag needs KEY=TEXT, got: $arg"
    OPT_KEY=${arg%%=*}
    OPT_TEXT=${arg#*=}
    [[ -n $OPT_KEY ]] || die "-$flag: missing key in: $arg"
    [[ -n ${OPT_TEXT//[[:space:]]/} ]] || die "-$flag: missing text in: $arg"
    # "|" separates fields in the work file; a newline would end a record.
    [[ $OPT_TEXT != *[\|$'\n']* ]] || die "-$flag: text may not contain '|' or a newline: $arg"
}

confirm_processing() {
    local node_count=$1
    (( FORCE_RUN )) && return 0

    log "$node_count nodes need to be processed (jobs=$JOBS)."
    log "Preview of changes:"
    local i=0 line
    while IFS= read -r line; do
        log "  $line"
        (( ++i >= MAX_PREVIEW )) && { log "  ...and more."; break; }
    done < "$CHANGES_FILE"

    local response
    read -r -p "Continue? [y/n]: " response
    case "$response" in
        [yY]|[yY][eE][sS]) log "Starting processing..." ;;
        *) log "Aborting."; exit 0 ;;
    esac
}

# Read one status line per finished node from the workers and show a
# running count and percentage every PROGRESS_EVERY nodes.
#
# On a terminal the progress line is redrawn in place (carriage return +
# erase-to-end-of-line) so past updates don't pile up. When output is not a
# terminal (cron, a log file, a pipe), each update is a normal line.
report_progress() {
    local total=$1
    local done_count=0 failed=0 line msg
    local inplace=0 shown=0

    [[ -t 1 ]] && inplace=1

    while IFS= read -r line; do
        done_count=$((done_count + 1))

        # Failures (and per-node lines with -v) are ordinary lines: erase
        # the in-place progress line first so they don't run into it.
        msg=""
        if [[ "$line" == FAIL* ]]; then
            failed=$((failed + 1))
            msg="${line#FAIL }"
        elif (( VERBOSE )); then
            msg="$line"
        fi
        if [[ -n "$msg" ]]; then
            if (( shown )); then printf '\r\033[K'; shown=0; fi
            if [[ "$line" == FAIL* ]]; then printf '%s\n' "$msg" >&2; else printf '%s\n' "$msg"; fi
        fi

        if (( done_count % PROGRESS_EVERY == 0 && done_count < total )); then
            msg="Processed $done_count of $total nodes ($((done_count * 100 / total))%)"
            if (( inplace )); then
                printf '\r\033[K%s' "$msg"
                shown=1
            else
                printf '%s\n' "$msg"
            fi
        fi
    done

    if (( shown )); then printf '\r\033[K'; fi
    if (( failed )); then
        log "Processed $done_count of $total nodes, $failed failed."
    else
        log "Processed $done_count of $total nodes (100%)."
    fi
}

run_parallel() {
    local total
    total="$(wc -l < "$WORK_FILE" | tr -d ' ')"

    if command -v parallel >/dev/null 2>&1; then
        # --will-cite: skip the one-time citation prompt/notice.
        # A node that fails is reported by process_one_node; it must not
        # abort the rest of the run.
        parallel --will-cite -j "$JOBS" --colsep '[|]' process_one_node {1} {2} {3} < "$WORK_FILE" || true
    else
        # Batch many nodes into each spawned worker to amortize bash
        # startup overhead.
        while IFS='|' read -r node mode callsign; do
            printf '%s\0%s\0%s\0' "$node" "$mode" "$callsign"
        done < "$WORK_FILE" \
            | xargs -0 -n 60 -P "$JOBS" bash -c '
                while (( $# )); do
                    process_one_node "$1" "$2" "$3" || true
                    shift 3
                done
              ' _
    fi | report_progress "$total"
}

update_previous_db() {
    ensure_directory_exists "$(dirname "$PREV_DB")"
    cp "$SRCDIR/astdb.txt" "$PREV_DB"
    vlog "Updated previous DB: $PREV_DB"
}

format_total_time() {
    local total_time_ms=$1
    if (( total_time_ms < 1000 )); then
        echo "${total_time_ms}ms"
    elif (( total_time_ms < 60000 )); then
        awk -v ms="$total_time_ms" 'BEGIN { printf "%.1fs\n", ms / 1000 }'
    elif (( total_time_ms < 3600000 )); then
        awk -v ms="$total_time_ms" 'BEGIN { printf "%.1fmin\n", ms / 60000 }'
    else
        awk -v ms="$total_time_ms" 'BEGIN { printf "%.1fh\n", ms / 3600000 }'
    fi
}

# --- options ---
while getopts "haij:n:d:s:p:o:t:fvr" OPTION; do
    case "$OPTION" in
        o)
            parse_override o "$OPTARG"
            # All digits is a node number; anything else is a callsign.
            if [[ $OPT_KEY =~ ^[0-9]+$ ]]; then
                NODE_OVERRIDE["$OPT_KEY"]=$OPT_TEXT
            else
                CALL_OVERRIDE["${OPT_KEY^^}"]=$OPT_TEXT
            fi
            ;;
        t)
            parse_override t "$OPTARG"
            [[ $OPT_KEY =~ ^[0-9]+$ ]] || die "-t key must be a node number: $OPTARG"
            CUSTOM_TEXT["$OPT_KEY"]=$OPT_TEXT
            ;;
        h) usage; exit 0 ;;
        a) PROCESS_ALL=1 ;;
        i) INCNODE=1 ;;
        j) JOBS="$OPTARG" ;;
        n) SINGLE_NODE="$OPTARG" ;;
        d) DESTDIR="$OPTARG" ;;
        s) SRCDIR="$OPTARG" ;;
        p) PREV_DB="$OPTARG" ;;
        f) FORCE_RUN=1 ;;
        v) VERBOSE=1 ;;
        r) FORCE_REBUILD=1 ;;
        *) usage; exit 1 ;;
    esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "-j must be a positive integer"

start_time="$(date +%s%3N)"

resolve_astdb_dir || die "astdb.txt not found (tried /var/lib/asterisk, /var/log/asterisk). Use -s PATH."
[[ -z "$PREV_DB" ]] && PREV_DB="$SRCDIR/previous_astdb.txt"

[[ -x "$SAY" ]] || die "DECtalk say command not found at $SAY"
command -v perl >/dev/null 2>&1 || die "perl is required to trim silence"

if [[ -f "$INIT_CFG" ]]; then
    DECTALK_INIT="$(tr '\r\n' '  ' < "$INIT_CFG")"
    vlog "Using DECtalk init from $INIT_CFG"
fi

ensure_directory_exists "$DESTDIR"
export SAY DECTALK_INIT INCNODE DESTDIR VERBOSE

load_previous_database

WORK_FILE="$(mktemp)"
CHANGES_FILE="$(mktemp)"
cleanup() { rm -f "$WORK_FILE" "$CHANGES_FILE"; }
trap cleanup EXIT

node_count=0

if [[ -n "$SINGLE_NODE" ]]; then
    callsign="$(lookup_node_callsign "$SINGLE_NODE")"
    if [[ -z "$callsign" ]] && ! resolve_node "$SINGLE_NODE" ""; then
        die "Node $SINGLE_NODE not found in $SRCDIR/astdb.txt (use -o or -t for nodes not in astdb)"
    fi
    if needs_rebuild "$SINGLE_NODE" "$callsign"; then
        queue_node "$SINGLE_NODE" "$callsign"
        node_count=1
    fi
else
    declare -A IN_ASTDB=()
    while IFS='|' read -r node callsign; do
        [[ -n "$node" && -n "$callsign" ]] || continue
        IN_ASTDB["$node"]=1
        old="${PREV_CALLSIGNS[$node]-}"

        if (( PROCESS_ALL )); then
            # All nodes: write missing (or changed / -r) files.
            if needs_rebuild "$node" "$callsign"; then
                queue_node "$node" "$callsign"
                (( ++node_count )) || true
            else
                vlog "Skipping $node ($callsign) - output exists"
            fi
            continue
        fi

        # Incremental: only new or changed callsigns, plus overrides.
        if [[ -n "$old" && "$old" == "$callsign" ]] && ! resolve_node "$node" "$callsign"; then
            continue
        fi
        if needs_rebuild "$node" "$callsign"; then
            queue_node "$node" "$callsign"
            (( ++node_count )) || true
        else
            vlog "Skipping $node ($callsign) - output exists (resume)"
        fi
    done < <(latest_astdb_entries)

    # Node-number overrides for nodes not in astdb (private nodes).
    for node in "${!CUSTOM_TEXT[@]}" "${!NODE_OVERRIDE[@]}"; do
        [[ -n ${IN_ASTDB[$node]+x} ]] && continue
        IN_ASTDB["$node"]=1
        queue_node "$node" ""
        (( ++node_count )) || true
    done
fi

if (( node_count == 0 )); then
    log "No nodes need processing."
    if [[ ! -f "$PREV_DB" ]]; then
        update_previous_db
    fi
    end_time="$(date +%s%3N)"
    log "Total script execution time: $(format_total_time "$((end_time - start_time))")"
    exit 0
fi

confirm_processing "$node_count"
run_parallel
update_previous_db

end_time="$(date +%s%3N)"
log "Total script execution time: $(format_total_time "$((end_time - start_time))")"
