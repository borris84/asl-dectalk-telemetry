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
#   - Nodes that say exactly the same thing (same call sign and options,
#     no node number) share one file: it is rendered once and the other
#     nodes' files are hard links to it
#   - Resume-safe: skip existing .ulaw unless callsign changed or -r
#   - Durable previous-db beside astdb.txt (not /tmp)
#   - Auto-locate astdb in /var/lib/asterisk or /var/log/asterisk
#   - Per-node overrides, saved in node-overrides.conf beside this script:
#     "override" replaces the astdb callsign field for a node (or for every
#     node with a given callsign), "text" speaks custom text. -o / -t save
#     an override, -x removes one, -l lists them.
#   - Only nodes whose override was added, changed or removed since the
#     last run are rebuilt (the applied overrides are kept beside the
#     previous-db).
#   - -P speaks call signs with the phonetic alphabet ("November, echo,
#     2, Delta, Yankee, India."), with a pause between items and a falling
#     pitch on the last one
#   - "mode" entries (-m) turn -P and -i on or off for one node or call
#     sign, without changing what is said
#   - -a / -n / -i / -P / -o / -t / -m / -x / -l / -c / -v / -j / -r / -s / -p
#
# ElevenLabs: run as write_node_callsigns_elevenlabs.sh (which sets
# ASL_TELEM_ENGINE=elevenlabs and runs this script), the announcements are
# made with the voice in elevenlabs.conf instead, in one of two ways:
#   - speak (-S): each announcement is one ElevenLabs request. It sounds
#     the most natural, but every node costs credits.
#   - join (-J): each announcement is joined from the letter, digit and
#     phonetic alphabet sounds made by elevenlabs-telemetry.sh, with short
#     gaps between them. Costs nothing, but sounds less natural. Custom
#     text (-t) is still spoken by ElevenLabs.
# The default is NODE_METHOD in elevenlabs.conf.

set -euo pipefail

# Byte-oriented locale: the callsign patterns below are ASCII-only, and the
# silence trim works on raw u-law bytes.
export LC_ALL=C

SRCDIR=""
DESTDIR="/usr/share/asterisk/sounds/custom/rpt/nodenames"
SAY="/usr/local/bin/say"
ENGINE=${ASL_TELEM_ENGINE:-dectalk}
SOUNDS_DIR="/usr/share/asterisk/sounds/custom"
# Gaps between joined sounds (-J), in 8 kHz u-law bytes: between letters,
# and at a comma or period.
GAP_SHORT_BYTES=640
GAP_LONG_BYTES=2400
JOIN=""
# readlink -f: find the config files beside the real script, not a PATH symlink
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
INIT_CFG="$SCRIPT_DIR/dec-init.cfg"
OVERRIDES_FILE="$SCRIPT_DIR/node-overrides.conf"
PREV_OVERRIDES=""
DECTALK_INIT=""
PREV_DB=""
JOBS=""
MAX_PREVIEW=10
PROGRESS_EVERY=1000
# Speaking each announcement with ElevenLabs takes far longer per node, so
# the progress on a terminal is updated this often instead.
PROGRESS_EVERY_SPEAK=100

VERBOSE=0
INCNODE=0
PHONETIC=0
FORCE_RUN=0
FORCE_REBUILD=0
PROCESS_ALL=0
SINGLE_NODE=""
LIST_ONLY=0
PRINT_TEXT=0

declare -A PREV_CALLSIGNS
# Overrides from the overrides file, and the ones applied by the last run.
declare -A NODE_OVERRIDE PREV_NODE_OVERRIDE  # node -> replacement callsign field
declare -A CALL_OVERRIDE PREV_CALL_OVERRIDE  # CALLSIGN -> replacement callsign field
declare -A CUSTOM_TEXT PREV_CUSTOM_TEXT      # node -> text spoken as-is
declare -A NODE_MODE PREV_NODE_MODE          # node -> mode words ("phonetic number")
declare -A CALL_MODE PREV_CALL_MODE          # CALLSIGN -> mode words
OVERRIDES_SAME=0
# -o / -t / -m / -x edits to the overrides file, applied in command line order
EDIT_OPS=() EDIT_KEYS=() EDIT_TEXTS=()
REMOVE_NODES=()

if [[ $ENGINE == elevenlabs ]]; then
    NAME=write_node_callsigns_elevenlabs.sh
else
    NAME=write_node_callsigns_dectalk.sh
fi

usage() {
    local text_note="DECtalk [:commands] and [phonemes] are allowed."
    local jobs_note="nproc"
    if [[ $ENGINE == elevenlabs ]]; then
        text_note="It is always spoken by ElevenLabs, even with -J."
        jobs_note="nproc with -J; JOBS in elevenlabs.conf, or 2, with -S"
    fi
    cat << EOF
Usage: $NAME [options]

OPTIONS:
   -h          Show this message
   -a          Process all nodes (fill gaps; skips existing unless -r)
   -i          Append "node" + node number after the callsign
   -P          Speak call signs phonetically: November, echo, 2, Delta...
   -n NODE     Process a single node
   -d PATH     Destination directory (default: $DESTDIR)
   -j N        Parallel jobs (default: $jobs_note)
   -v          Verbose output
   -f          Skip confirmation prompt
   -r          Force regenerate even when output already exists
   -s PATH     Directory containing astdb.txt
   -p PATH     Previous-db path used for change detection
   -o KEY=TEXT Save an override of the astdb callsign field. KEY is a
               node number (that node only) or a callsign (every node with
               that callsign). TEXT is handled like an astdb entry, so call
               signs in it are still spelled out. A node-number override
               wins over a callsign override. Repeatable.
   -t NODE=TEXT
               Save custom text for NODE, spoken as-is with no call sign
               spelling. $text_note
               Wins over -o. Repeatable.
   -m KEY=WORDS
               Save a mode for KEY (a node number or a callsign) that sets
               -P and -i for just those nodes: "phonetic" or "letters",
               and "number" or "no-number". Anything not given follows the
               command line. A node-number mode wins over a callsign mode.
               Repeatable.
   -x KEY      Remove the saved override(s) and mode for KEY (a node
               number or a callsign). Repeatable.
   -l          List the saved overrides and exit (after any -o/-t/-m/-x).
   -T          Print "node<TAB>text" for every node in astdb.txt and exit:
               the text each call sign field is spoken as (with -P if
               given), without overrides or -i. Nothing is made.
   -c PATH     Overrides file (default: $OVERRIDES_FILE)
EOF
    if [[ $ENGINE == elevenlabs ]]; then
        cat << EOF
   -S          Speak each announcement with one ElevenLabs request: most
               natural, but every node costs credits
   -J          Join each announcement from the letter, digit and phonetic
               sounds made by elevenlabs-telemetry.sh: free, less natural.
               Without -S or -J, NODE_METHOD in elevenlabs.conf is used.

Output files are raw headerless u-law (.ulaw), made with the ElevenLabs
voice in elevenlabs.conf.
EOF
    else
        cat << EOF

Output files are raw headerless u-law (.ulaw), spoken by DECtalk.
If dec-init.cfg exists beside this script, it is prepended to the spoken text.
EOF
    fi
    cat << EOF
-i and -P only affect nodes that are (re)built: after turning either on or
off, or changing the voice, rebuild everything with -a -r.
Overrides are saved in the overrides file and applied on every run; the file
can also be edited by hand. Only nodes whose override was added, changed or
removed since the last run are rebuilt. Nodes with a node-number override
are built even when they are not in astdb.txt (private nodes); when such an
override is removed, the node's announcement is deleted.

Examples:
    $NAME -a -f       # First full build, no prompt
    $NAME -f          # Only new/changed nodes
    $NAME -n 40000 -r # Rebuild one node
    $NAME -f -o "506311=N2DYI hub" -o "N2DYI=N2DYI repeater"
    $NAME -f -t "1999=the lab node"
    $NAME -f -m "506311=phonetic" -m "506312=letters number"
    $NAME -f -x 506311 # Remove an override
    $NAME -l          # List saved overrides
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
# For DECtalk, E, N, S and W are sent in lower case. DECtalk reads an
# upper case E/N/S/W that follows a number as a compass point ("W 6 E K" is
# spoken as "W 6 East K"). In lower case it says the letter name, and the
# audio is otherwise identical to the upper case letter.
spell_out() {
    local word=${1^^} i char
    SPELLED=""
    for (( i = 0; i < ${#word}; i++ )); do
        char=${word:i:1}
        [[ $ENGINE == dectalk && $char == [ENSW] ]] && char=${char,,}
        SPELLED+="$char "
    done
    SPELLED=${SPELLED% }
}

# Append the phonetic alphabet words for each character of "$1" to the
# PHONETIC_ITEMS array: N2DYI -> November echo... Digits stay digits.
#
# For DECtalk, Papa and Delta are written as phonemes. DECtalk says "papa"
# as "poppa", and softens the t in "delta" to "delda"; starting the t's
# syllable as a separate word keeps it a full t.
phonetic_items() {
    local word=${1^^} i
    for (( i = 0; i < ${#word}; i++ )); do
        case ${word:i:1} in
            A) PHONETIC_ITEMS+=(Alfa) ;;
            B) PHONETIC_ITEMS+=(Bravo) ;;
            C) PHONETIC_ITEMS+=(Charlie) ;;
            D) if [[ $ENGINE == dectalk ]]; then PHONETIC_ITEMS+=("[d'ehl tah]"); else PHONETIC_ITEMS+=(Delta); fi ;;
            E) PHONETIC_ITEMS+=(Echo) ;;
            F) PHONETIC_ITEMS+=(Foxtrot) ;;
            G) PHONETIC_ITEMS+=(Golf) ;;
            H) PHONETIC_ITEMS+=(Hotel) ;;
            I) PHONETIC_ITEMS+=(India) ;;
            J) PHONETIC_ITEMS+=(Juliett) ;;
            K) PHONETIC_ITEMS+=(Kilo) ;;
            L) PHONETIC_ITEMS+=(Lima) ;;
            M) PHONETIC_ITEMS+=(Mike) ;;
            N) PHONETIC_ITEMS+=(November) ;;
            O) PHONETIC_ITEMS+=(Oscar) ;;
            P) if [[ $ENGINE == dectalk ]]; then PHONETIC_ITEMS+=("[paap'aa]"); else PHONETIC_ITEMS+=(Papa); fi ;;
            Q) PHONETIC_ITEMS+=(Quebec) ;;
            R) PHONETIC_ITEMS+=(Romeo) ;;
            S) PHONETIC_ITEMS+=(Sierra) ;;
            T) PHONETIC_ITEMS+=(Tango) ;;
            U) PHONETIC_ITEMS+=(Uniform) ;;
            V) PHONETIC_ITEMS+=(Victor) ;;
            W) PHONETIC_ITEMS+=(Whiskey) ;;
            X) PHONETIC_ITEMS+=(X-ray) ;;
            Y) PHONETIC_ITEMS+=(Yankee) ;;
            Z) PHONETIC_ITEMS+=(Zulu) ;;
            *) PHONETIC_ITEMS+=("${word:i:1}") ;;
        esac
    done
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
#   - runs of letters/digits that are call signs are spelled out (for
#     ElevenLabs they are sent as one upper case word, N2DYI, which it
#     spells more reliably, with any 0 set apart by spaces: KB 0 RIS)
#   - a lone "/" or "-" joined to a call sign (KA4EPS/R, VA2RXP-25) is
#     spoken as "slash" / "dash"
#   - DECtalk only: a call sign's final I is sent as [']I (stressed) so it
#     rises, and a VA/VE prefix gets a glottal stop after the V
#     (V [q] e 3 R W J)
#   - with PHONETIC=1, call signs use the phonetic alphabet instead, one
#     item per comma (a pause; ElevenLabs gets no commas) and a period
#     after the last (falling pitch). A short suffix joined by "/" or "-"
#     (KA4EPS/R, VA2RXP-25) is part of the call sign: "... Romeo, X-ray, Papa, dash, 25." A
#     repeater's "/R" is not spelled phonetically: "... Sierra, slash R."
#   - asterisks are dropped
#   - everything else is passed through untouched
callsign_to_speech() {
    local rest=$1
    local -a tokens=() kinds=()
    local i n tok item text="" SPELLED=""
    local -a PHONETIC_ITEMS

    # Square brackets are DECtalk's command/phoneme delimiters (and
    # ElevenLabs' audio tags). astdb is user-supplied data, so never let it
    # issue commands.
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
                if (( PHONETIC )); then
                    PHONETIC_ITEMS=()
                    phonetic_items "${tokens[i]}"
                    if (( i + 2 < n )) && [[ ${tokens[i+1]} == [/-] && ${tokens[i+2]} =~ ^[A-Za-z0-9]{1,4}$ ]]; then
                        if [[ ${tokens[i+1]} == / ]]; then PHONETIC_ITEMS+=(slash); else PHONETIC_ITEMS+=(dash); fi
                        if [[ ${tokens[i+1]} == / && ${tokens[i+2]} == [Rr] ]]; then
                            # "/R" marks a repeater; it isn't part of the call.
                            PHONETIC_ITEMS[-1]="slash R"
                        elif [[ ${tokens[i+2]} =~ ^[0-9]+$ ]]; then
                            PHONETIC_ITEMS+=("${tokens[i+2]}")
                        else
                            phonetic_items "${tokens[i+2]}"
                        fi
                        (( i += 2 ))
                    fi
                    # DECtalk pauses at each comma. ElevenLabs reads the
                    # words better as one phrase, without them.
                    text+=" ${PHONETIC_ITEMS[0]}"
                    for item in "${PHONETIC_ITEMS[@]:1}"; do
                        if [[ $ENGINE == dectalk ]]; then text+=", $item"; else text+=" $item"; fi
                    done
                    text+=". "
                    continue
                fi
                if [[ $ENGINE == elevenlabs ]]; then
                    # ElevenLabs says a call sign best as one upper case
                    # word: spaced-out single letters are read unreliably
                    # ("y" as "yeah", "b" as "buh"). A 0 inside the word is
                    # read as the letter O, so it is set apart: KB0RIS is
                    # sent as "KB 0 RIS".
                    tok=${tokens[i]^^}
                    text+=" ${tok//0/ 0 } "
                    continue
                fi
                spell_out "${tokens[i]}"
                if [[ $ENGINE == dectalk ]]; then
                    # A final I falls flat; a leading stress mark makes it rise.
                    [[ $SPELLED == *" I" ]] && SPELLED="${SPELLED% I} [']I"
                    # VA/VE prefixes run together; a glottal stop separates them.
                    [[ $SPELLED == "V "[Ae]" "* ]] && SPELLED="V [q] ${SPELLED#V }"
                fi
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

# node_number_text NODE  - set SPEECH_TEXT to what is said for a node whose
# call sign field has nothing to say: "Node 2 9 4 4 5".
node_number_text() {
    spell_out "$1"
    SPEECH_TEXT="Node $SPELLED"
}

# Speak one announcement for one or more nodes that say the same thing.
# Prints exactly one line on stdout per node - "OK ..." or "FAIL <reason>" -
# which report_progress counts and displays.
#   $1 nodes: comma-separated. The first node's file is rendered and the
#      others are hard links to it, so the audio is stored once.
#   $2 mode: c = $3 is a callsign field (astdb or -o), t = $3 is -t text
#   $4 / $5: 1 or 0 for these nodes' -P and -i (their mode, or the defaults)
process_one_node() {
    local -a nodes
    IFS=, read -r -a nodes <<< "$1"
    local node=${nodes[0]}
    local mode=$2
    local callsign=$3
    local PHONETIC=${4:-$PHONETIC}
    local INCNODE=${5:-$INCNODE}
    local out="$DESTDIR/$node.ulaw"
    local tmp="$out.tmp.$$"
    local SPEECH_TEXT="" SPELLED=""
    local text n link

    # ElevenLabs refused for the whole account (no credits, bad key): the
    # rest would fail too, so don't send them.
    if [[ -n ${STOP_FILE:-} && -e $STOP_FILE ]]; then
        for n in "${nodes[@]}"; do
            printf 'FAIL -\n'  # counted, not shown
        done
        return 1
    fi

    if [[ $mode == t ]]; then
        # Custom text comes from the overrides file, not astdb, so it is
        # trusted and may carry DECtalk commands.
        SPEECH_TEXT=$callsign
    else
        callsign_to_speech "$callsign"
    fi
    # A call sign field with no letter or digit to say (such as "????" or
    # "-") is replaced by the node number: "Node 2 9 4 4 5". Each node then
    # says something different, so nodes grouped by that field are made one
    # by one.
    if [[ $SPEECH_TEXT != *[[:alnum:]]* && $mode != t ]]; then
        if (( ${#nodes[@]} > 1 )); then
            local rc=0
            for n in "${nodes[@]}"; do
                process_one_node "$n" "$mode" "$callsign" "$PHONETIC" "$INCNODE" || rc=1
            done
            return "$rc"
        fi
        node_number_text "$node"
        INCNODE=0  # the number is already said
    fi
    if [[ -z "$SPEECH_TEXT" ]]; then
        for n in "${nodes[@]}"; do
            printf 'FAIL Error: Nothing speakable for node %s (%s)\n' "$n" "$callsign"
        done
        return 1
    fi
    text="$SPEECH_TEXT"

    if (( INCNODE )); then
        spell_out "$node"
        # After a phonetic call sign's closing period, start a new sentence.
        if [[ $text == *. ]]; then text+=" Node $SPELLED"; else text+=", node $SPELLED"; fi
    fi

    # Joined announcements are written by join_writer, one process for the
    # whole run, which is far quicker than starting cat for each one.
    if [[ $ENGINE == elevenlabs && $JOIN == 1 && $mode != t ]]; then
        printf 'JOIN\t%s\t%s\t%s\n' "$1" "${callsign//$'\t'/ }" "$text"
        return 0
    fi

    # Write to a temp file first so a crash/kill mid-run never leaves a
    # corrupt/partial node file in place.
    if render_announcement "$mode" "$text" "$tmp"; then
        mv -f "$tmp" "$out"
    else
        rm -f "$tmp"
        for n in "${nodes[@]}"; do
            printf 'FAIL %s for node %s (%s)\n' "$RENDER_ERROR" "$n" "$callsign"
        done
        return 1
    fi
    printf 'OK %s %s -> %s\n' "$node" "$callsign" "$text"

    # Link under a temp name, then rename over the old file, so each node
    # always has a complete announcement. Renaming only replaces that
    # node's name: a later change to one node leaves the others alone.
    for n in "${nodes[@]:1}"; do
        link="$DESTDIR/$n.ulaw"
        if ln -f -- "$out" "$link.tmp.$$" && mv -f -- "$link.tmp.$$" "$link"; then
            printf 'OK %s %s -> %s (shared with %s)\n' "$n" "$callsign" "$text" "$node"
        else
            rm -f -- "$link.tmp.$$"
            printf 'FAIL Could not link node %s to %s\n' "$n" "$out"
        fi
    done
}

# render_announcement MODE TEXT OUT  - write TEXT spoken by the engine to
# OUT as 8 kHz u-law. (Joined announcements are made by join_writer.) On
# failure RENDER_ERROR says why.
render_announcement() {
    local mode=$1 text=$2 out=$3
    RENDER_ERROR=""
    if [[ $ENGINE == elevenlabs ]]; then
        el_render "$text" "$out" && return 0
        RENDER_ERROR="ElevenLabs failed ($EL_ERROR)"
        [[ $EL_ERROR == *"out of credits"* || $EL_ERROR == *"key was not accepted"* ]] \
            && [[ -n ${STOP_FILE:-} ]] && : > "$STOP_FILE"
        return 1
    fi
    # [:phoneme on] makes DECtalk treat ['] as a stress mark rather than
    # reading it aloud, whether or not dec-init.cfg turns it on.
    # DECtalk writes 8 kHz u-law straight to stdout. Leading/trailing bytes
    # quieter than about -50 dB (u-law codes 0x73-0x7f / 0xf3-0xff) are
    # trimmed as silence.
    "$SAY" -e 3 -fo stdout:raw -a "$DECTALK_INIT [:phoneme on] $text" < /dev/null 2> /dev/null \
        | perl -0777 -pe 's/^[\x73-\x7f\xf3-\xff]+//; s/[\x73-\x7f\xf3-\xff]+$//' > "$out"
    [[ "${PIPESTATUS[*]}" == "0 0" && -s "$out" ]] && return 0
    RENDER_ERROR="DECtalk failed"
    return 1
}

# join_writer  - pass the workers' status lines through, and make the
# announcement for each "JOIN<TAB>nodes<TAB>callsign<TAB>text" line, printing
# an OK or FAIL line per node for report_progress.
#
# TEXT (as made by callsign_to_speech) is built from the telemetry sounds in
# SOUNDS_DIR: a single letter or digit, a phonetic alphabet word, "slash",
# "dash" and "node" each have their own sound, and any other word is
# spelled out a character at a time. A short gap goes between sounds, and
# a longer one at a comma or period. Each sound is read once and kept in
# memory. As in process_one_node, the first node's file is written under a
# temp name and renamed, and the other nodes' files are hard links to it.
join_writer() {
    perl -e '
        use strict; use warnings;
        my ($dest, $snd, $gap_short, $gap_long) = @ARGV;
        my ($short, $long) = ("\xff" x $gap_short, "\xff" x $gap_long);
        my %phon = (ALFA => "a", BRAVO => "b", CHARLIE => "c", DELTA => "d",
            ECHO => "e", FOXTROT => "f", GOLF => "g", HOTEL => "h", INDIA => "i",
            JULIETT => "j", KILO => "k", LIMA => "l", MIKE => "m", NOVEMBER => "n",
            OSCAR => "o", PAPA => "p", QUEBEC => "q", ROMEO => "r", SIERRA => "s",
            TANGO => "t", UNIFORM => "u", VICTOR => "v", WHISKEY => "w",
            "X-RAY" => "x", YANKEE => "y", ZULU => "z");
        my %word = (SLASH => "letters/slash", DASH => "letters/dash", NODE => "rpt/node");
        my %cache;
        sub sound {
            my $f = "$snd/$_[0].ul";
            return $cache{$f} if exists $cache{$f};
            open(my $h, "<:raw", $f) or return $cache{$f} = undef;
            local $/;
            my $d = <$h>;
            return $cache{$f} = $d;
        }
        $| = 1;
        while (my $line = <STDIN>) {
            if ($line !~ /^JOIN\t/) { print $line; next }
            chomp $line;
            my (undef, $list, $call, $text) = split /\t/, $line, 4;
            my @nodes = split /,/, $list;
            my (@parts, @kind, $err);
            my $add = sub {
                my $d = sound($_[0]);
                if (!defined $d) { $err //= "Missing $snd/$_[0].ul (run elevenlabs-telemetry.sh first)"; return }
                if (@parts && $kind[-1] ne "pause") { push @parts, $short; push @kind, "gap" }
                push @parts, $d; push @kind, "sound";
            };
            my $pause = sub {
                if (@parts && $kind[-1] ne "pause") { push @parts, $long; push @kind, "pause" }
            };
            (my $t = $text) =~ s/([,.])/ $1 /g;
            # Phonetic call signs come without commas; each word next to a
            # phonetic alphabet word gets the pause a comma would give.
            my $last_phon = 0;
            for my $w (split " ", $t) {
                my $u = uc $w;
                my $is_phon = exists $phon{$u};
                $pause->() if $is_phon || ($last_phon && $u ne "," && $u ne ".");
                $last_phon = $is_phon;
                if ($u eq "," || $u eq ".") {
                    $pause->();
                } elsif (exists $word{$u}) {
                    $add->($word{$u});
                } elsif ($is_phon) {
                    $add->("phonetic/$phon{$u}_p");
                } else {
                    for my $c (split //, $u) {
                        if ($c =~ /[A-Z]/) { $add->("letters/" . lc $c) }
                        elsif ($c =~ /[0-9]/) { $add->("digits/$c") }
                        elsif ($c eq "/") { $add->("letters/slash") }
                        elsif ($c eq "-") { $add->("letters/dash") }
                        # Other characters have a sound only if the prompt
                        # list made one (letters/ascii<code>).
                        elsif (-f "$snd/letters/ascii" . ord($c) . ".ul") { $add->("letters/ascii" . ord($c)) }
                    }
                }
            }
            if (@kind && $kind[-1] eq "pause") { pop @parts; pop @kind }
            $err //= "Nothing to join" unless @parts;
            if ($err) { print "FAIL $err for node $_ ($call)\n" for @nodes; next }

            my $out = "$dest/$nodes[0].ulaw";
            my $tmp = "$out.tmp.$$";
            my $ok = open(my $h, ">:raw", $tmp);
            $ok &&= print $h @parts;
            $ok &&= close $h;
            $ok &&= rename $tmp, $out;
            if (!$ok) {
                unlink $tmp;
                print "FAIL Could not write $out for node $_ ($call)\n" for @nodes;
                next;
            }
            print "OK $nodes[0] $call -> $text\n";
            for my $n (@nodes[1 .. $#nodes]) {
                my $link = "$dest/$n.ulaw";
                if (link($out, "$link.tmp.$$") && rename("$link.tmp.$$", $link)) {
                    print "OK $n $call -> $text (shared with $nodes[0])\n";
                } else {
                    unlink "$link.tmp.$$";
                    print "FAIL Could not link node $n to $out\n";
                }
            }
        }
    ' -- "$DESTDIR" "$SOUNDS_DIR" "$GAP_SHORT_BYTES" "$GAP_LONG_BYTES"
}

export -f process_one_node callsign_to_speech is_callsign spell_out phonetic_items node_number_text \
    render_announcement

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

# resolve_with SET NODE CALLSIGN
# Work out what to speak for a node under a set of overrides (SET is "" for
# the current ones or "PREV_" for the last run's) into:
#   SPEAK_MODE, SPEAK_VALUE  what to say (see process_one_node)
#   SPEAK_PHON, SPEAK_NUM    1 or 0 for -P and -i, after any mode entry
#   SPEAK_WORDS              the mode entry's words, or empty
# Returns 0 if an override or text entry applies (a mode alone doesn't count).
resolve_with() {
    local -n _rw_node=${1}NODE_OVERRIDE _rw_call=${1}CALL_OVERRIDE _rw_text=${1}CUSTOM_TEXT
    local -n _rw_nmode=${1}NODE_MODE _rw_cmode=${1}CALL_MODE
    local node=$2
    local callsign=$3
    local call_key=${callsign^^} word

    SPEAK_PHON=$PHONETIC SPEAK_NUM=$INCNODE SPEAK_WORDS=""
    if [[ -n ${_rw_nmode[$node]+x} ]]; then
        SPEAK_WORDS=${_rw_nmode[$node]}
    elif [[ -n $call_key && -n ${_rw_cmode[$call_key]+x} ]]; then
        SPEAK_WORDS=${_rw_cmode[$call_key]}
    fi
    for word in $SPEAK_WORDS; do
        case $word in
            phonetic) SPEAK_PHON=1 ;;
            letters) SPEAK_PHON=0 ;;
            number) SPEAK_NUM=1 ;;
            no-number) SPEAK_NUM=0 ;;
        esac
    done

    SPEAK_MODE=c
    SPEAK_VALUE=$callsign
    if [[ -n ${_rw_text[$node]+x} ]]; then
        SPEAK_MODE=t
        SPEAK_VALUE=${_rw_text[$node]}
    elif [[ -n ${_rw_node[$node]+x} ]]; then
        SPEAK_VALUE=${_rw_node[$node]}
    elif [[ -n $call_key && -n ${_rw_call[$call_key]+x} ]]; then
        SPEAK_VALUE=${_rw_call[$call_key]}
    else
        return 1
    fi
    return 0
}

# Resolve a node under the current overrides.
resolve_node() {
    resolve_with "" "$1" "$2"
}

# Return 0 if the overrides make the node sound different from the last
# run: an override, text or mode for it was added, changed or removed.
override_changed() {
    local before
    (( OVERRIDES_SAME )) && return 1
    resolve_with PREV_ "$1" "$2" || true
    before="$SPEAK_MODE|$SPEAK_VALUE|$SPEAK_PHON|$SPEAK_NUM"
    resolve_node "$1" "$2" || true
    [[ $before != "$SPEAK_MODE|$SPEAK_VALUE|$SPEAK_PHON|$SPEAK_NUM" ]]
}

# Normalize mode words ("Phonetic, number") into MODE_WORDS ("phonetic
# number"). Returns 1 for an unknown word or both words of a pair.
parse_mode_words() {
    local word phon="" num=""
    for word in ${1//,/ }; do
        case ${word,,} in
            phonetic) [[ $phon == letters ]] && return 1; phon=phonetic ;;
            letters) [[ $phon == phonetic ]] && return 1; phon=letters ;;
            number) [[ $num == no-number ]] && return 1; num=number ;;
            no-number|nonumber) [[ $num == number ]] && return 1; num=no-number ;;
            *) return 1 ;;
        esac
    done
    MODE_WORDS="$phon${phon:+${num:+ }}$num"
    [[ -n $MODE_WORDS ]]
}

# Return 0 if the node needs (re)generating.
needs_rebuild() {
    local node=$1
    local callsign=$2
    local out="$DESTDIR/$node.ulaw"
    local old="${PREV_CALLSIGNS[$node]-}"

    (( FORCE_REBUILD )) && return 0
    [[ -f "$out" ]] || return 0
    override_changed "$node" "$callsign" && return 0

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
    elif override_changed "$node" "$callsign"; then
        note=" (override removed)"
        resolve_node "$node" "$callsign" || true
    fi
    [[ -n $SPEAK_WORDS ]] && note+=" (mode: $SPEAK_WORDS)"
    # File descriptors 3 and 4 are WORK_FILE and CHANGES_FILE.
    printf '%s|%s|%s|%s|%s\n' "$node" "$SPEAK_MODE" "$SPEAK_VALUE" "$SPEAK_PHON" "$SPEAK_NUM" >&3
    if [[ -z "$old" ]]; then
        printf '%s: NEW -> %s%s\n' "$node" "$SPEAK_VALUE" "$note" >&4
    else
        printf '%s: %s -> %s%s\n' "$node" "$old" "$SPEAK_VALUE" "$note" >&4
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
    [[ $OPT_KEY =~ ^[^[:space:]=\|]+$ ]] || die "-$flag: key may not contain spaces: $arg"
}

# Parse one overrides-file line into P_KIND, P_KEY and P_TEXT:
#   override KEY = TEXT
#   text NODE = TEXT
#   mode KEY = WORDS      (P_TEXT is the normalized words)
parse_override_line() {
    [[ $1 =~ ^[[:space:]]*(override|text|mode)[[:space:]]+([^[:space:]=]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || return 1
    P_KIND=${BASH_REMATCH[1]}
    P_KEY=${BASH_REMATCH[2]}
    P_TEXT=${BASH_REMATCH[3]}
    P_TEXT=${P_TEXT%"${P_TEXT##*[![:space:]]}"}
    [[ -n $P_TEXT && $P_TEXT != *\|* ]] || return 1
    if [[ $P_KIND == mode ]]; then
        parse_mode_words "$P_TEXT" || return 1
        P_TEXT=$MODE_WORDS
    fi
    [[ $P_KIND != text || $P_KEY =~ ^[0-9]+$ ]]
}

# load_overrides FILE SET WARN
# Read an overrides file into a set of arrays (SET is "" for the current
# ones or "PREV_"). With WARN=1, report lines that can't be used.
load_overrides() {
    local file=$1 warn=$3 line lineno=0
    local -n _lo_node=${2}NODE_OVERRIDE _lo_call=${2}CALL_OVERRIDE _lo_text=${2}CUSTOM_TEXT
    local -n _lo_nmode=${2}NODE_MODE _lo_cmode=${2}CALL_MODE
    _lo_node=() _lo_call=() _lo_text=() _lo_nmode=() _lo_cmode=()
    [[ -f $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if ! parse_override_line "$line"; then
            (( warn )) && printf 'Warning: %s line %d is not a valid override, skipped: %s\n' \
                "$file" "$lineno" "$line" >&2
            continue
        fi
        if [[ $P_KIND == text ]]; then
            _lo_text["$P_KEY"]=$P_TEXT
        elif [[ $P_KIND == mode ]]; then
            if [[ $P_KEY =~ ^[0-9]+$ ]]; then _lo_nmode["$P_KEY"]=$P_TEXT; else _lo_cmode["${P_KEY^^}"]=$P_TEXT; fi
        elif [[ $P_KEY =~ ^[0-9]+$ ]]; then
            _lo_node["$P_KEY"]=$P_TEXT
        else
            _lo_call["${P_KEY^^}"]=$P_TEXT
        fi
    done < "$file"
}

# Print the current overrides, one "kind KEY = TEXT" line each, sorted.
print_overrides() {
    local key
    {
        for key in "${!NODE_OVERRIDE[@]}"; do printf 'override %s = %s\n' "$key" "${NODE_OVERRIDE[$key]}"; done
        for key in "${!CALL_OVERRIDE[@]}"; do printf 'override %s = %s\n' "$key" "${CALL_OVERRIDE[$key]}"; done
        for key in "${!CUSTOM_TEXT[@]}"; do printf 'text %s = %s\n' "$key" "${CUSTOM_TEXT[$key]}"; done
        for key in "${!NODE_MODE[@]}"; do printf 'mode %s = %s\n' "$key" "${NODE_MODE[$key]}"; done
        for key in "${!CALL_MODE[@]}"; do printf 'mode %s = %s\n' "$key" "${CALL_MODE[$key]}"; done
    } | sort
}

# Run awk program $1 over the overrides file and replace the file's
# contents with the result, keeping its owner and permissions.
rewrite_overrides_file() {
    local tmp
    if [[ ! -f $OVERRIDES_FILE ]]; then
        printf '%s\n' \
            "# Node announcement overrides for write_node_callsigns_dectalk.sh." \
            "# One entry per line (see README.md):" \
            "#   override KEY = TEXT   KEY is a node number or a call sign" \
            "#   text NODE = TEXT      TEXT is spoken exactly as written" \
            "#   mode KEY = WORDS      phonetic|letters and/or number|no-number" \
            > "$OVERRIDES_FILE" || die "Could not create $OVERRIDES_FILE"
    fi
    tmp=$(mktemp) || die "Could not create a temporary file"
    awk "$1" "$OVERRIDES_FILE" > "$tmp" && cat "$tmp" > "$OVERRIDES_FILE" \
        || { rm -f "$tmp"; die "Could not update $OVERRIDES_FILE"; }
    rm -f "$tmp"
}

# The awk programs below find entry lines by kind and key (any case) and
# take their values from the environment, so backslashes in TEXT survive.
OVERRIDE_LINE_AWK='
    function entry(line, p) {
        sub(/^[ \t]+/, "", line)
        if (!match(line, /^(override|text|mode)[ \t]+[^ \t=]+/)) return 0
        split(substr(line, 1, RLENGTH), p, /[ \t]+/)
        kind = p[1]; key = toupper(p[2])
        return 1
    }'

# Add an entry, or replace an existing entry of the same kind and key.
save_override() {
    KIND=$1 KEY=$2 TEXT=$3 rewrite_overrides_file "$OVERRIDE_LINE_AWK"'
        entry($0) && kind == ENVIRON["KIND"] && key == toupper(ENVIRON["KEY"]) {
            if (!done) print ENVIRON["KIND"] " " ENVIRON["KEY"] " = " ENVIRON["TEXT"]
            done = 1
            next
        }
        { print }
        END { if (!done) print ENVIRON["KIND"] " " ENVIRON["KEY"] " = " ENVIRON["TEXT"] }'
    log "Saved: $1 $2 = $3"
}

# Remove every entry (override, text or mode) for a key.
remove_override() {
    local before after
    if [[ -f $OVERRIDES_FILE ]]; then
        before=$(wc -l < "$OVERRIDES_FILE")
        KEY=$1 rewrite_overrides_file "$OVERRIDE_LINE_AWK"'
            entry($0) && key == toupper(ENVIRON["KEY"]) { next }
            { print }'
        after=$(wc -l < "$OVERRIDES_FILE")
    fi
    if [[ -f $OVERRIDES_FILE ]] && (( before > after )); then
        log "Removed the saved override(s) for $1"
    else
        log "Warning: no saved override for $1 in $OVERRIDES_FILE" >&2
    fi
}

# Save the overrides this run applied, for the next run to compare against.
save_override_snapshot() {
    print_overrides > "$PREV_OVERRIDES" || die "Could not write $PREV_OVERRIDES"
    vlog "Updated previous overrides: $PREV_OVERRIDES"
}

# Print an estimate of the characters ElevenLabs will be sent for the
# work in GROUP_FILE (a call sign is sent as it is, but phonetic words are
# about 5.5 times as long).
estimate_characters() {
    awk -F'|' -v join="${JOIN:-0}" '
        $2 == "t" { n += length($3); next }
        join == 1 { next }
        { n += ($4 == 1 ? 5.5 : 1.1) * length($3) }
        $5 == 1 { n += 7 + 2 * length($1) }
        END { printf "%d\n", n }
    ' "$GROUP_FILE"
}

confirm_processing() {
    local node_count=$1
    local remove_count=$2 chars requests
    if [[ $ENGINE == elevenlabs ]] && (( node_count )); then
        group_work
        chars=$(estimate_characters)
        if (( chars > 0 )); then
            requests=$(wc -l < "$GROUP_FILE" | tr -d ' ')
            log "Asking ElevenLabs what this will cost..."
            log "ElevenLabs will be sent $(el_count "$requests" request)."
            el_cost_report "$chars"
            # Each request takes about a second, so a full build runs for hours.
            if (( requests * 12 / 10 / JOBS >= 600 )); then
                log "WARNING: this will take $(el_duration "$requests" "$JOBS") ($JOBS requests at a time)."
                log "Run it where it won't be interrupted, for example in screen or tmux,"
                log "or with nohup. If it is stopped, run it again with -a to finish."
            fi
        elif (( JOIN )); then
            log "The announcements are joined from the telemetry sounds: no ElevenLabs credits are used."
        fi
    fi
    (( FORCE_RUN )) && return 0

    log "$node_count nodes need to be processed (jobs=$JOBS)."
    (( remove_count )) && log "$remove_count announcements will be deleted."
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
# running count and percentage every PROGRESS_EVERY nodes (every
# PROGRESS_EVERY_SPEAK when speaking with ElevenLabs on a terminal).
#
# On a terminal the progress line is redrawn in place (carriage return +
# erase-to-end-of-line) so past updates don't pile up. When output is not a
# terminal (cron, a log file, a pipe), each update is a normal line.
report_progress() {
    local total=$1
    local done_count=0 failed=0 skipped=0 line msg
    local inplace=0 shown=0

    [[ -t 1 ]] && inplace=1

    while IFS= read -r line; do
        done_count=$((done_count + 1))

        # Failures (and per-node lines with -v) are ordinary lines: erase
        # the in-place progress line first so they don't run into it.
        msg=""
        if [[ "$line" == "FAIL -" ]]; then
            failed=$((failed + 1))
            skipped=$((skipped + 1))
        elif [[ "$line" == FAIL* ]]; then
            failed=$((failed + 1))
            msg="${line#FAIL }"
        elif (( VERBOSE )); then
            msg="$line"
        fi
        if [[ -n "$msg" ]]; then
            if (( shown )); then printf '\r\033[K'; shown=0; fi
            if [[ "$line" == FAIL* ]]; then printf '%s\n' "$msg" >&2; else printf '%s\n' "$msg"; fi
        fi

        # After a message, put the progress line straight back rather than
        # leaving it off the screen until the next update.
        if (( inplace && ! shown && done_count < total )) \
            || (( done_count % PROGRESS_EVERY == 0 && done_count < total )); then
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
        (( skipped )) && log "$skipped of them were not sent, because ElevenLabs stopped accepting requests (see above)."
        log "To retry them, run again with -a: announcements that already exist are skipped."
    else
        log "Processed $done_count of $total nodes (100%)."
    fi
}

# Group the work file's nodes by what they will say, into GROUP_FILE lines
# "node,node,...|mode|value|phonetic|number". Nodes whose number is spoken
# are never grouped. Groups keep the order of their first node.
group_work() {
    awk -F'|' -v OFS='|' '
        {
            key = $2 FS $3 FS $4 FS $5
            if ($5 == 1) key = key FS $1
            if (key in nodes) { nodes[key] = nodes[key] "," $1; next }
            order[++count] = key
            nodes[key] = $1
            rest[key] = $2 OFS $3 OFS $4 OFS $5
        }
        END { for (i = 1; i <= count; i++) print nodes[order[i]], rest[order[i]] }
    ' "$WORK_FILE" > "$GROUP_FILE"
}

run_parallel() {
    local total groups
    total="$(wc -l < "$WORK_FILE" | tr -d ' ')"
    [[ -s $GROUP_FILE ]] || group_work
    groups="$(wc -l < "$GROUP_FILE" | tr -d ' ')"
    (( groups < total )) \
        && log "$total nodes say $groups different things: rendering $groups announcements, the rest are shared."

    if command -v parallel >/dev/null 2>&1; then
        # --will-cite: skip the one-time citation prompt/notice.
        # A node that fails is reported by process_one_node; it must not
        # abort the rest of the run.
        parallel --will-cite -j "$JOBS" --colsep '[|]' process_one_node {1} {2} {3} {4} {5} < "$GROUP_FILE" || true
    else
        # Batch many announcements into each spawned worker to amortize
        # bash startup overhead.
        while IFS='|' read -r node mode callsign phon num; do
            printf '%s\0%s\0%s\0%s\0%s\0' "$node" "$mode" "$callsign" "$phon" "$num"
        done < "$GROUP_FILE" \
            | xargs -0 -n 100 -P "$JOBS" bash -c '
                while (( $# )); do
                    process_one_node "$1" "$2" "$3" "$4" "$5" || true
                    shift 5
                done
              ' _
    fi | if [[ $ENGINE == elevenlabs && $JOIN == 1 ]]; then join_writer; else cat; fi \
       | report_progress "$total"
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
while getopts "haiPj:n:d:s:p:o:t:m:x:c:lfvrSJT" OPTION; do
    case "$OPTION" in
        o)
            parse_override o "$OPTARG"
            # All digits is a node number; anything else is a callsign.
            [[ $OPT_KEY =~ ^[0-9]+$ ]] || OPT_KEY=${OPT_KEY^^}
            EDIT_OPS+=(override) EDIT_KEYS+=("$OPT_KEY") EDIT_TEXTS+=("$OPT_TEXT")
            ;;
        t)
            parse_override t "$OPTARG"
            [[ $OPT_KEY =~ ^[0-9]+$ ]] || die "-t key must be a node number: $OPTARG"
            EDIT_OPS+=(text) EDIT_KEYS+=("$OPT_KEY") EDIT_TEXTS+=("$OPT_TEXT")
            ;;
        m)
            parse_override m "$OPTARG"
            parse_mode_words "$OPT_TEXT" \
                || die "-m words must be phonetic or letters, and/or number or no-number: $OPTARG"
            [[ $OPT_KEY =~ ^[0-9]+$ ]] || OPT_KEY=${OPT_KEY^^}
            EDIT_OPS+=(mode) EDIT_KEYS+=("$OPT_KEY") EDIT_TEXTS+=("$MODE_WORDS")
            ;;
        x)
            [[ $OPTARG =~ ^[^[:space:]=\|]+$ ]] || die "-x needs a node number or callsign, got: $OPTARG"
            EDIT_OPS+=(remove) EDIT_KEYS+=("$OPTARG") EDIT_TEXTS+=("")
            ;;
        c) OVERRIDES_FILE="$OPTARG" ;;
        l) LIST_ONLY=1 ;;
        T) PRINT_TEXT=1 ;;
        h) usage; exit 0 ;;
        a) PROCESS_ALL=1 ;;
        i) INCNODE=1 ;;
        P) PHONETIC=1 ;;
        j) JOBS="$OPTARG" ;;
        n) SINGLE_NODE="$OPTARG" ;;
        d) DESTDIR="$OPTARG" ;;
        s) SRCDIR="$OPTARG" ;;
        p) PREV_DB="$OPTARG" ;;
        f) FORCE_RUN=1 ;;
        v) VERBOSE=1 ;;
        r) FORCE_REBUILD=1 ;;
        S|J)
            [[ $ENGINE == elevenlabs ]] || die "-$OPTION is only for write_node_callsigns_elevenlabs.sh"
            if [[ $OPTION == J ]]; then JOIN=1; else JOIN=0; fi
            ;;
        *) usage; exit 1 ;;
    esac
done

[[ -z "$JOBS" || "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "-j must be a positive integer"

start_time="$(date +%s%3N)"

# -T: what each node's call sign field is spoken as. Used to build and
# match the prebuilt ElevenLabs voice packs.
if (( PRINT_TEXT )); then
    resolve_astdb_dir || die "astdb.txt not found (tried /var/lib/asterisk, /var/log/asterisk). Use -s PATH."
    while IFS='|' read -r node callsign; do
        [[ -n $node && -n $callsign ]] || continue
        callsign_to_speech "$callsign"
        [[ $SPEECH_TEXT == *[[:alnum:]]* ]] || node_number_text "$node"
        printf '%s\t%s\n' "$node" "$SPEECH_TEXT"
    done < <(latest_astdb_entries | sort -t'|' -k1,1n)
    exit 0
fi

for i in "${!EDIT_OPS[@]}"; do
    if [[ ${EDIT_OPS[i]} == remove ]]; then
        remove_override "${EDIT_KEYS[i]}"
    else
        save_override "${EDIT_OPS[i]}" "${EDIT_KEYS[i]}" "${EDIT_TEXTS[i]}"
    fi
done
load_overrides "$OVERRIDES_FILE" "" 1

if (( LIST_ONLY )); then
    if [[ -n $(print_overrides) ]]; then
        log "Saved overrides in $OVERRIDES_FILE:"
        print_overrides | sed 's/^/  /'
    else
        log "No saved overrides in $OVERRIDES_FILE."
    fi
    exit 0
fi

resolve_astdb_dir || die "astdb.txt not found (tried /var/lib/asterisk, /var/log/asterisk). Use -s PATH."
[[ -z "$PREV_DB" ]] && PREV_DB="$SRCDIR/previous_astdb.txt"
PREV_OVERRIDES="$(dirname "$PREV_DB")/previous_node_overrides.conf"
load_overrides "$PREV_OVERRIDES" PREV_ 0
# Fast path: nothing changed, so no node needs comparing.
if [[ -f $PREV_OVERRIDES && $(print_overrides) == "$(< "$PREV_OVERRIDES")" ]]; then
    OVERRIDES_SAME=1
fi

command -v perl >/dev/null 2>&1 || die "perl is required to trim silence"
if [[ $ENGINE == elevenlabs ]]; then
    [[ -r "$SCRIPT_DIR/elevenlabs-common.sh" ]] || die "$SCRIPT_DIR/elevenlabs-common.sh not found"
    # shellcheck source=elevenlabs-common.sh
    . "$SCRIPT_DIR/elevenlabs-common.sh"
    # Joining needs no settings; anything spoken does.
    if ! el_load_config; then
        el_defaults
        [[ $JOIN == 1 ]] || die "$EL_CONF not found. Run "sudo asl-telem-setup.sh" (or install.sh) and choose ElevenLabs to set it up."
    fi
    [[ -n $JOIN ]] || { [[ $EL_NODE_METHOD == join ]] && JOIN=1 || JOIN=0; }
    if (( JOIN )); then
        for f in letters/a digits/0 phonetic/a_p rpt/node; do
            [[ -f $SOUNDS_DIR/$f.ul ]] \
                || die "$SOUNDS_DIR/$f.ul not found. -J joins the telemetry sounds: run elevenlabs-telemetry.sh first."
        done
    fi
    # -t text is spoken by ElevenLabs even when joining.
    if (( ! JOIN )) || (( ${#CUSTOM_TEXT[@]} )); then
        el_configured || die "$EL_CONF has no API_KEY or VOICE_ID. Run "sudo asl-telem-setup.sh" to set them."
        command -v curl >/dev/null 2>&1 || die "curl is required to reach ElevenLabs"
    fi
    if [[ -z $JOBS ]]; then
        if (( JOIN )); then JOBS="$(nproc 2>/dev/null || echo 4)"; else JOBS=$EL_JOBS; fi
    fi
    # On a terminal the progress line is redrawn in place, so frequent
    # updates cost nothing; in a log (cron) they would be thousands of lines.
    (( ! JOIN )) && [[ -t 1 ]] && PROGRESS_EVERY=$PROGRESS_EVERY_SPEAK
    vlog "Using ElevenLabs voice ${EL_VOICE_NAME:-$EL_VOICE_ID} ($( (( JOIN )) && echo "joined sounds" || echo "one request per announcement"))"
else
    [[ -x "$SAY" ]] || die "DECtalk say command not found at $SAY"
    if [[ -f "$INIT_CFG" ]]; then
        DECTALK_INIT="$(tr '\r\n' '  ' < "$INIT_CFG")"
        vlog "Using DECtalk init from $INIT_CFG"
    fi
    [[ -n $JOBS ]] || JOBS="$(nproc 2>/dev/null || echo 4)"
fi

ensure_directory_exists "$DESTDIR"
export SAY DECTALK_INIT INCNODE PHONETIC DESTDIR VERBOSE ENGINE JOIN SOUNDS_DIR

# Reading and checking tens of thousands of nodes takes a while on a slow
# system (about a minute on a Raspberry Pi 4), so say what is going on.
[[ -z "$SINGLE_NODE" ]] && log "Reading the node database ($SRCDIR/astdb.txt)..."
load_previous_database

WORK_FILE="$(mktemp)"
CHANGES_FILE="$(mktemp)"
GROUP_FILE="$(mktemp)"
ENTRIES_FILE="$(mktemp)"
STOP_FILE="$(mktemp -u)"
cleanup() { rm -f "$WORK_FILE" "$CHANGES_FILE" "$GROUP_FILE" "$ENTRIES_FILE" "$STOP_FILE"; }
trap cleanup EXIT
export STOP_FILE
# queue_node writes a line to each for every node: keep them open rather
# than opening them tens of thousands of times.
exec 3>> "$WORK_FILE" 4>> "$CHANGES_FILE"

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
    latest_astdb_entries > "$ENTRIES_FILE"
    scan_total=$(wc -l < "$ENTRIES_FILE" | tr -d ' ')
    log "Checking which of the $scan_total nodes need to be made. This can take a minute or two."
    scanned=0
    scan_shown=0
    while IFS='|' read -r node callsign; do
        # A running count on a terminal, redrawn in place.
        if (( ++scanned % 1000 == 0 )) && [[ -t 1 ]]; then
            printf '\r\033[KChecked %d of %d nodes (%d%%)' "$scanned" "$scan_total" $(( scanned * 100 / scan_total ))
            scan_shown=1
        fi
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

        # Incremental: only new or changed callsigns and overrides.
        if [[ -n "$old" && "$old" == "$callsign" ]] && ! override_changed "$node" "$callsign"; then
            continue
        fi
        if needs_rebuild "$node" "$callsign"; then
            queue_node "$node" "$callsign"
            (( ++node_count )) || true
        else
            vlog "Skipping $node ($callsign) - output exists (resume)"
        fi
    done < "$ENTRIES_FILE"
    (( scan_shown )) && printf '\r\033[K'

    # Node-number overrides for nodes not in astdb (private nodes).
    for node in "${!CUSTOM_TEXT[@]}" "${!NODE_OVERRIDE[@]}"; do
        [[ -n ${IN_ASTDB[$node]+x} ]] && continue
        IN_ASTDB["$node"]=1
        if needs_rebuild "$node" ""; then
            queue_node "$node" ""
            (( ++node_count )) || true
        fi
    done

    # A private node whose override was removed has nothing left to say:
    # delete its announcement.
    for node in "${!PREV_CUSTOM_TEXT[@]}" "${!PREV_NODE_OVERRIDE[@]}"; do
        [[ -n ${IN_ASTDB[$node]+x} ]] && continue
        IN_ASTDB["$node"]=1
        [[ -f $DESTDIR/$node.ulaw ]] || continue
        REMOVE_NODES+=("$node")
        printf '%s: override removed, not in astdb -> announcement deleted\n' "$node" >> "$CHANGES_FILE"
    done
fi

exec 3>&- 4>&-

# The previous db and overrides record what a full run applied, so a
# single-node run (-n) leaves them alone.
if (( node_count == 0 && ${#REMOVE_NODES[@]} == 0 )); then
    log "No nodes need processing."
    if [[ -z "$SINGLE_NODE" ]]; then
        [[ -f "$PREV_DB" ]] || update_previous_db
        save_override_snapshot
    fi
    end_time="$(date +%s%3N)"
    log "Total script execution time: $(format_total_time "$((end_time - start_time))")"
    exit 0
fi

confirm_processing "$node_count" "${#REMOVE_NODES[@]}"
for node in "${REMOVE_NODES[@]}"; do
    rm -f "$DESTDIR/$node.ulaw" && log "Deleted the announcement for node $node"
done
(( node_count )) && run_parallel
if [[ -z "$SINGLE_NODE" ]]; then
    update_previous_db
    save_override_snapshot
fi

end_time="$(date +%s%3N)"
log "Total script execution time: $(format_total_time "$((end_time - start_time))")"
