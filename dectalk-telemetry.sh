#!/bin/bash
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Render the ASL3 telemetry prompts in prompt-list.txt with DECtalk.
#
# Each line of prompt-list.txt is "filename: prompt-to-speak". Every prompt is
# written as 8 kHz u-law to /usr/share/asterisk/sounds/custom/<filename>.ul
# with silence trimmed from both ends.

set -u
set -o pipefail

OUT_DIR=/usr/share/asterisk/sounds/custom
SAY=/usr/local/bin/say
SILENCE_THRESHOLD=-50dB
JOBS=$(nproc 2>/dev/null || echo 2)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# --- Preflight -------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "WARNING: this script requires root. Re-run it as root (e.g. with sudo)." >&2
    exit 1
fi

if ! dpkg-query -W -f='${Status}' asl3 2>/dev/null | grep -q 'install ok installed'; then
    die "ASL3 is not installed (package 'asl3' not found). Nothing done."
fi

# readlink -f: find the data files beside the real script, not a PATH symlink
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
PROMPT_LIST="$SCRIPT_DIR/prompt-list.txt"
INIT_CFG="$SCRIPT_DIR/dec-init.cfg"

[ -x "$SAY" ] || die "DECtalk say command not found at $SAY"
command -v ffmpeg >/dev/null || die "ffmpeg is required to trim silence but was not found"
[ -r "$PROMPT_LIST" ] || die "prompt list not found: $PROMPT_LIST"

# --- Read the prompt list --------------------------------------------------

names=()
texts=()
declare -A seen
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue

    if [[ $line != *:* ]]; then
        echo "WARNING: line $lineno has no 'filename: prompt' separator, skipped: $line" >&2
        continue
    fi
    name=${line%%:*}
    text=${line#*:}

    # Trim surrounding whitespace, and any leading slashes so that "/rpt/foo"
    # and "rpt/foo" both land in $OUT_DIR/rpt.
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    while [[ $name == /* ]]; do name=${name#/}; done
    text=${text#"${text%%[![:space:]]*}"}

    if [ -z "$name" ] || [ -z "$text" ]; then
        echo "WARNING: line $lineno has an empty filename or prompt, skipped: $line" >&2
        continue
    fi
    if [[ $name == */ || /$name/ == */../* ]]; then
        echo "WARNING: line $lineno has an unusable filename, skipped: $line" >&2
        continue
    fi
    if [ -n "${seen[$name]:-}" ]; then
        echo "WARNING: line $lineno duplicates '$name' from line ${seen[$name]}; keeping line ${seen[$name]}, skipped: $line" >&2
        continue
    fi
    seen[$name]=$lineno
    names+=("$name")
    texts+=("$text")
done < "$PROMPT_LIST"

[ "${#names[@]}" -gt 0 ] || die "no prompts found in $PROMPT_LIST"

# --- DECtalk init string ---------------------------------------------------

init=""
if [ -f "$INIT_CFG" ]; then
    init=$(tr '\r\n' '  ' < "$INIT_CFG")
    echo "Using DECtalk init from $INIT_CFG"
fi

# --- Existing output directory ---------------------------------------------

if [ -d "$OUT_DIR" ] && [ -n "$(find "$OUT_DIR/" -mindepth 1 -print -quit)" ]; then
    echo "$OUT_DIR already exists and contains files."
    while true; do
        read -r -p "[R]ename it, [D]elete it, [U]se existing (overwrite matching files), or [Q]uit? " answer \
            || die "no answer given, nothing done."
        case "${answer,,}" in
            r|rename)
                backup="$OUT_DIR-$(date +%Y-%m-%d-%H-%M)"
                [ -e "$backup" ] && die "$backup already exists, nothing done."
                mv -- "$OUT_DIR" "$backup" || die "could not rename $OUT_DIR"
                echo "Renamed to $backup"
                break
                ;;
            d|delete)
                # If $OUT_DIR is a symlink this removes the link, not its target.
                rm -rf -- "$OUT_DIR" || die "could not delete $OUT_DIR"
                echo "Deleted $OUT_DIR"
                break
                ;;
            u|use|"use existing")
                break
                ;;
            q|quit)
                echo "Nothing done."
                exit 0
                ;;
            *)
                echo "Please answer R, D, U or Q."
                ;;
        esac
    done
fi

mkdir -p "$OUT_DIR" || die "could not create $OUT_DIR"
# The prompts are about to be DECtalk's: forget what elevenlabs-telemetry.sh
# made, so it makes them all again if ElevenLabs is chosen later.
rm -f -- "$OUT_DIR/.elevenlabs-prompts"

# --- Render ----------------------------------------------------------------

FAIL_DIR=$(mktemp -d) || die "could not create a temporary directory"
trap 'rm -rf "$FAIL_DIR"' EXIT

# render INDEX NAME TEXT
render() {
    local idx=$1 name=$2 text=$3
    local out="$OUT_DIR/$name.ul"
    local tmp="$out.tmp.$$.$idx"

    if ! mkdir -p "$(dirname "$out")"; then
        echo "$name: could not create directory" > "$FAIL_DIR/$idx"
        return 1
    fi

    if ! "$SAY" -e 3 -fo stdout:raw -a "$init$text" < /dev/null 2> "$FAIL_DIR/$idx.err" |
        ffmpeg -nostdin -v error -f mulaw -ar 8000 -ac 1 -i - \
            -af "silenceremove=start_periods=1:start_threshold=$SILENCE_THRESHOLD,areverse,silenceremove=start_periods=1:start_threshold=$SILENCE_THRESHOLD,areverse" \
            -f mulaw -ar 8000 -ac 1 -y "$tmp" 2>> "$FAIL_DIR/$idx.err"; then
        echo "$name: $(tr '\n' ' ' < "$FAIL_DIR/$idx.err")" > "$FAIL_DIR/$idx"
    elif [ ! -s "$tmp" ]; then
        echo "$name: no audio produced" > "$FAIL_DIR/$idx"
    fi
    rm -f "$FAIL_DIR/$idx.err"

    if [ -e "$FAIL_DIR/$idx" ]; then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" && mv -f -- "$tmp" "$out"
}

total=${#names[@]}
echo "Rendering $total prompts to $OUT_DIR using $JOBS parallel jobs..."

running=0
for i in "${!names[@]}"; do
    render "$i" "${names[$i]}" "${texts[$i]}" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n
        running=$((running - 1))
    fi
done
wait

failed=$(find "$FAIL_DIR" -type f | wc -l)
if [ "$failed" -gt 0 ]; then
    echo "FAILED prompts:" >&2
    cat "$FAIL_DIR"/* >&2
    echo "Done: $((total - failed)) of $total prompts rendered, $failed failed." >&2
    exit 1
fi

echo "Done: $total prompts rendered to $OUT_DIR"
