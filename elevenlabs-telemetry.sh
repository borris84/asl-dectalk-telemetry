#!/bin/bash
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Render the ASL3 telemetry prompts in elevenlabs-prompt-list.txt with
# ElevenLabs, using the voice and settings in elevenlabs.conf.
#
# Each line of the prompt list is "filename: prompt-to-speak". Every prompt
# is written as 8 kHz u-law to /usr/share/asterisk/sounds/custom/<filename>.ul
# with silence trimmed from both ends and its level set to -24 dB RMS.
#
# ElevenLabs charges for every request, so a prompt is only sent again
# when its text or the voice settings have changed since it was made
# (or with -r).
#
# With -o DIR the prompts are written to DIR instead, which needs neither
# root nor ASL3: packs/pack-tool.sh uses it to make a pack's telemetry,
# with EL_CONF naming the pack's settings and the key in
# ELEVENLABS_API_KEY.

set -u
set -o pipefail

OUT_DIR=/usr/share/asterisk/sounds/custom
# What made each prompt, so unchanged ones are not paid for again.
MANIFEST_NAME=.elevenlabs-prompts

# readlink -f: find the data files beside the real script, not a PATH symlink
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
PROMPT_LIST="$SCRIPT_DIR/elevenlabs-prompt-list.txt"

REBUILD=0
ASSUME_YES=0
JOBS=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat << EOF
Usage: elevenlabs-telemetry.sh [-r] [-f] [-j N] [-o DIR]

Make the telemetry prompts in $PROMPT_LIST
with ElevenLabs, using the voice in elevenlabs.conf.

   -r     Make every prompt again, even those that have not changed
   -f     Don't ask: use the existing sounds folder and don't ask before
          spending credits
   -j N   Requests to send at once (default: JOBS in elevenlabs.conf, or 2)
   -o DIR Write the prompts to DIR instead of $OUT_DIR
   -h     Show this message
EOF
}

CUSTOM_OUT=0
while getopts ":rfj:o:h" opt; do
    case $opt in
        r) REBUILD=1 ;;
        f) ASSUME_YES=1 ;;
        j) JOBS=$OPTARG ;;
        o) OUT_DIR=$OPTARG; CUSTOM_OUT=1 ;;
        h) usage; exit 0 ;;
        :) usage >&2; die "-$OPTARG needs a value" ;;
        *) usage >&2; die "Unknown option: -$OPTARG" ;;
    esac
done
shift $((OPTIND - 1))
(( $# == 0 )) || { usage >&2; die "Unexpected argument: $1"; }
[[ -z $JOBS || $JOBS =~ ^[1-9][0-9]*$ ]] || die "-j must be a positive integer"

# --- Preflight -------------------------------------------------------------

if (( ! CUSTOM_OUT )) && [ "$(id -u)" -ne 0 ]; then
    echo "WARNING: this script requires root. Re-run it as root (e.g. with sudo)." >&2
    exit 1
fi

if (( ! CUSTOM_OUT )) && ! dpkg-query -W -f='${Status}' asl3 2>/dev/null | grep -q 'install ok installed'; then
    die "ASL3 is not installed (package 'asl3' not found). Nothing done."
fi

[ -r "$SCRIPT_DIR/elevenlabs-common.sh" ] || die "$SCRIPT_DIR/elevenlabs-common.sh not found"
# shellcheck source=elevenlabs-common.sh
. "$SCRIPT_DIR/elevenlabs-common.sh"
el_load_config || die "$EL_CONF not found. Run "sudo asl-telem-setup.sh" (or install.sh) and choose ElevenLabs to set it up."
[[ -n $EL_API_KEY ]] || EL_API_KEY=${ELEVENLABS_API_KEY:-}
el_configured || die "$EL_CONF has no API_KEY or VOICE_ID. Run "sudo asl-telem-setup.sh" to set them."
JOBS=${JOBS:-$EL_JOBS}

for cmd in curl perl md5sum; do
    command -v "$cmd" > /dev/null || die "$cmd is required but was not found"
done
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

    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    while [[ $name == /* ]]; do name=${name#/}; done
    text=${text#"${text%%[![:space:]]*}"}
    text=${text%"${text##*[![:space:]]}"}

    if [ -z "$name" ] || [ -z "$text" ]; then
        echo "WARNING: line $lineno has an empty filename or prompt, skipped: $line" >&2
        continue
    fi
    if [[ $name == */ || /$name/ == */../* || $name == *$'\t'* ]]; then
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

# --- Existing output directory ---------------------------------------------

if (( ! ASSUME_YES )) && [ -d "$OUT_DIR" ] && [ -n "$(find "$OUT_DIR/" -mindepth 1 -print -quit)" ]; then
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
MANIFEST="$OUT_DIR/$MANIFEST_NAME"

# --- Work out what needs making ----------------------------------------------

# signature TEXT  - what a prompt sounds like: its text and every setting
# that changes the audio.
signature() {
    printf '%s|' "$1" "$EL_VOICE_ID" "$EL_MODEL_ID" "$EL_LANGUAGE" "$EL_SPEED" \
        "${EL_STABILITY:-}" "${EL_SIMILARITY:-}" "$EL_TARGET_RMS" | md5sum | cut -c 1-32
}

declare -A made
if [ -f "$MANIFEST" ] && (( ! REBUILD )); then
    while IFS=$'\t' read -r name sig; do
        [ -n "$name" ] && made[$name]=$sig
    done < "$MANIFEST"
fi

todo=()
sigs=()
chars=0
for i in "${!names[@]}"; do
    sigs[i]=$(signature "${texts[$i]}")
    if [ -f "$OUT_DIR/${names[$i]}.ul" ] && [ "${made[${names[$i]}]:-}" == "${sigs[$i]}" ]; then
        continue
    fi
    todo+=("$i")
    chars=$((chars + ${#texts[$i]}))
done

total=${#names[@]}
if [ "${#todo[@]}" -eq 0 ]; then
    echo "All $total prompts are up to date for voice ${EL_VOICE_NAME:-$EL_VOICE_ID}. Use -r to make them again."
    exit 0
fi

echo "${#todo[@]} of $(el_count "$total" prompt) will be made with ElevenLabs (voice ${EL_VOICE_NAME:-$EL_VOICE_ID}, $EL_MODEL_ID)."
el_cost_report "$chars"
if (( ! ASSUME_YES )) && [ -t 0 ]; then
    read -r -p "Continue? [Y/n] " answer || die "no answer given, nothing done."
    case "${answer,,}" in
        ""|y|yes) ;;
        *) echo "Nothing done."; exit 0 ;;
    esac
fi

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
    if ! el_render "$text" "$tmp"; then
        echo "$name: $EL_ERROR" > "$FAIL_DIR/$idx"
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" && mv -f -- "$tmp" "$out" && touch "$FAIL_DIR/$idx.ok"
}

echo "Rendering $(el_count "${#todo[@]}" prompt) to $OUT_DIR, $JOBS at a time..."

running=0
for i in "${todo[@]}"; do
    render "$i" "${names[$i]}" "${texts[$i]}" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n
        running=$((running - 1))
    fi
    # Out of credits or a bad key: every other request would fail too.
    if grep -lqsE 'out of credits|key was not accepted' "$FAIL_DIR"/[0-9]* 2> /dev/null; then
        echo "Stopping: $(cat "$(grep -lsE 'out of credits|key was not accepted' "$FAIL_DIR"/[0-9]* | head -n 1)")" >&2
        break
    fi
done
wait

# Record what each prompt that exists now was made from.
tmp_manifest="$MANIFEST.tmp.$$"
for i in "${!names[@]}"; do
    if [ -e "$FAIL_DIR/$i.ok" ]; then
        printf '%s\t%s\n' "${names[$i]}" "${sigs[$i]}"
    elif [ -n "${made[${names[$i]}]:-}" ] && [ -f "$OUT_DIR/${names[$i]}.ul" ] && [ ! -e "$FAIL_DIR/$i" ]; then
        printf '%s\t%s\n' "${names[$i]}" "${made[${names[$i]}]}"
    fi
done > "$tmp_manifest" && mv -f -- "$tmp_manifest" "$MANIFEST"

done_count=$(find "$FAIL_DIR" -name '*.ok' | wc -l)
failed=$(find "$FAIL_DIR" -type f ! -name '*.ok' | wc -l)
if [ "$done_count" -lt "${#todo[@]}" ]; then
    if [ "$failed" -gt 0 ]; then
        echo "FAILED prompts:" >&2
        find "$FAIL_DIR" -type f ! -name '*.ok' -exec cat {} + >&2
    fi
    echo "Done: $done_count of $(el_count "${#todo[@]}" prompt) rendered, $((${#todo[@]} - done_count)) not made. Run this again to retry them." >&2
    exit 1
fi

echo "Done: $(el_count "$done_count" prompt) rendered to $OUT_DIR"
