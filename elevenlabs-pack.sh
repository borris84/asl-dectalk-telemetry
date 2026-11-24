#!/bin/bash
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Download and update a ready-made ElevenLabs voice pack: every node name
# announcement and every telemetry prompt, already made in an ElevenLabs
# voice, so a node needs no API key and uses no credits for them. The packs are built and kept up to date on GitHub (see
# packs/README.md in the repository).
#
# The pack used is PACK in elevenlabs.conf (set by asl-telem-setup.sh).
# It is kept in /var/lib/asl-telem/packs/NAME:
#   pack.conf, index.tsv  as published
#   telemetry.tsv         what the installed telemetry prompts were made from
#   files/<md5>.ulaw      one announcement per text. The node names in
#                         sounds/custom/rpt/nodenames are hard links to
#                         these, made by write_node_callsigns_elevenlabs.sh,
#                         which runs "elevenlabs-pack.sh sync" first.
# The telemetry prompts go straight into /usr/share/asterisk/sounds/custom.

set -u
set -o pipefail
export LC_ALL=C

SOUNDS_DIR=/usr/share/asterisk/sounds/custom
# readlink -f: find the data files beside the real script, not a PATH symlink
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
QUIET=0

die() {
    echo "ERROR: $*" >&2
    exit 1
}

say() {
    (( QUIET )) || printf '%s\n' "$*"
}

usage() {
    cat << EOF
Usage: elevenlabs-pack.sh COMMAND

Ready-made ElevenLabs voices: node names and telemetry prompts that are
already made, so no API key or credits are needed for them.

   list         Show the ready-made voices
   sync [-q]    Download what is new in the voice pack chosen in
                elevenlabs.conf (PACK): node name announcements and
                telemetry prompts. -q prints only what was downloaded.
                write_node_callsigns_elevenlabs.sh runs this itself.
   status       Show the downloaded pack
   -h           Show this message

Choose a pack with: sudo asl-telem-setup.sh
EOF
}

[[ -r $SCRIPT_DIR/elevenlabs-common.sh ]] || die "$SCRIPT_DIR/elevenlabs-common.sh not found"
# shellcheck source=elevenlabs-common.sh
. "$SCRIPT_DIR/elevenlabs-common.sh"

cmd_list() {
    local name id voice accent gender
    if ! el_pack_refresh; then
        echo "(The list of ready-made voices could not be downloaded from"
        echo "$EL_PACK_CATALOG_URL: showing the last one known.)"
    fi
    echo "Ready-made voices (eleven_v4_turbo, speed 1.2, call signs spelled with"
    echo "letters, no node number):"
    while IFS=$'\t' read -r name id voice accent gender; do
        printf '  %-8s %-40s %s, %s\n' "$name" "$voice" "${accent^}" "$gender"
    done < <(el_pack_list)
}

# load_pack  - read elevenlabs.conf and set NAME, STORE and URL.
load_pack() {
    el_load_config || die "$EL_CONF not found. Choose a voice pack with: sudo asl-telem-setup.sh"
    NAME=$EL_PACK
    [[ -n $NAME ]] || die "No voice pack is chosen (PACK in $EL_CONF). Choose one with: sudo asl-telem-setup.sh"
    [[ $NAME =~ ^[a-z0-9_-]+$ ]] || die "PACK in $EL_CONF is not a pack name: $NAME"
    STORE=$EL_PACK_ROOT/$NAME
    URL=$EL_PACK_URL/pack-$NAME
}

# archive_size FILE  - print the size of one of the pack's files, such as
# "276 MB", or nothing if it can't be found out (for messages only).
archive_size() {
    (( QUIET )) && return 0
    curl -fsIL --connect-timeout 10 --max-time 20 "$URL/$1" 2> /dev/null | tr -d '\r' \
        | awk 'tolower($1) == "content-length:" { n = $2 } END { if (n > 1048576) printf "%d MB", n / 1048576; else if (n > 0) printf "%d KB", (n + 1023) / 1024 }'
}

# fetch FILE OUT  - download one of the pack's files.
fetch() {
    curl -fsSL --retry 3 --retry-delay 10 -o "$2" "$URL/$1"
}

cmd_sync() {
    local tmp archive got=0 total missing incoming status=0 i size
    local -a archives
    [[ ${1:-} == -q ]] && QUIET=1
    [[ $(id -u) -eq 0 ]] || die "This needs root. Run it with sudo."
    for c in curl tar xz perl; do
        command -v "$c" > /dev/null || die "$c is required but was not found"
    done
    load_pack
    mkdir -p -- "$STORE/files" || die "Could not create $STORE"

    # One sync at a time (cron and a manual run).
    exec 9> "$STORE/.lock"
    flock 9

    tmp=$(mktemp -d "$STORE/.sync.XXXXXX") || die "Could not create a temporary folder in $STORE"
    trap "rm -rf -- '$tmp'" EXIT

    say "Checking voice pack $NAME for new announcements..."
    fetch index.tsv "$tmp/index.tsv" && fetch pack.conf "$tmp/pack.conf" \
        || die "Could not download voice pack $NAME from $URL"
    # A broken download must not be taken as the pack.
    perl -ne 'exit 1 unless /^[0-9a-f]{32}\t[^\t]*\t[A-Za-z0-9._-]+$/; END { exit 1 unless $. }' "$tmp/index.tsv" \
        || die "The voice pack index from $URL is not valid. Try again later."

    # Archives that hold announcements not here yet. The first download
    # is the whole pack (about 300 MB), later ones only what was added.
    mapfile -t archives < <(perl -F'\t' -lane 'BEGIN { $d = shift } print $F[2] if $F[2] ne "-" && !-e "$d/$F[0].ulaw"' \
        "$STORE/files" "$tmp/index.tsv" | sort -u)
    if (( ${#archives[@]} )) && [[ -z $(find "$STORE/files" -maxdepth 1 -name '*.ulaw' -print -quit) ]]; then
        say "This is the first download: the whole pack, about 300 MB. On a slow"
        say "connection it can take a while; the progress is shown as it goes."
    fi
    i=0
    for archive in "${archives[@]}"; do
        i=$((i + 1))
        size=$(archive_size "$archive")
        say "Downloading $archive${size:+ ($size)}, $i of ${#archives[@]}, from voice pack $NAME..."
        incoming=$tmp/incoming
        rm -rf -- "$incoming" && mkdir -- "$incoming" || die "Could not create $incoming"
        if [[ -t 2 ]] && (( ! QUIET )); then
            # The full meter: size, speed and time left.
            curl -fL --retry 3 --retry-delay 10 "$URL/$archive"
        else
            curl -fsSL --retry 3 --retry-delay 10 "$URL/$archive"
        fi | xz -dc | tar -x --no-same-owner -C "$incoming" -f -
        if (( PIPESTATUS[0] || PIPESTATUS[1] || PIPESTATUS[2] )); then
            echo "Could not download $archive. It will be tried again next time." >&2
            status=1
            continue
        fi
        # Only once the whole archive is unpacked, so no announcement is
        # ever half written. Files already here are kept: the nodes
        # linked to them stay linked.
        find "$incoming" -maxdepth 1 -name '*.ulaw' -exec mv -n -t "$STORE/files" -- {} + \
            || { echo "Could not move the files from $archive into $STORE/files" >&2; status=1; }
        got=1
    done
    mv -f -- "$tmp/index.tsv" "$STORE/index.tsv" && mv -f -- "$tmp/pack.conf" "$STORE/pack.conf" \
        || die "Could not update $STORE"
    missing=$(perl -F'\t' -lane 'BEGIN { $d = shift } $n++ unless -e "$d/$F[0].ulaw"; END { print $n + 0 }' \
        "$STORE/files" "$STORE/index.tsv")
    total=$(wc -l < "$STORE/index.tsv")

    sync_telemetry "$tmp" || status=1
    sync_settings

    if (( got )) || (( ! QUIET )); then
        echo "Voice pack $NAME ($EL_VOICE_NAME): $(( total - missing )) of $total announcements here."
    fi
    return $status
}

# sync_telemetry TMP  - install the pack's telemetry prompts that are new
# or changed in the pack. The first time, all of them are installed. After
# that, a prompt made some other way since (elevenlabs-telemetry.sh with an
# API key, for a prompt you changed) is left alone.
sync_telemetry() {
    local tmp=$1 f p manifest=$SOUNDS_DIR/.elevenlabs-prompts
    fetch telemetry.tsv "$tmp/telemetry.tsv" || { echo "Could not download the telemetry list of voice pack $NAME." >&2; return 1; }
    # What the manifest would be with the pack's new prompts in it, and
    # the prompts to install for that.
    perl -e '
        my ($new, $old, $local, $out, $list) = @ARGV;
        my (%n, @order, %o, %l);
        sub rd { my ($f, $h, $ord) = @_; open(my $fh, "<", $f) or return 0;
            while (<$fh>) { chomp; my ($k, $v) = split /\t/; next unless defined $v;
                push @$ord, $k if $ord && !exists $h->{$k}; $h->{$k} = $v } 1 }
        rd($new, \%n, \@order) or die "no list\n";
        my $first = !rd($old, \%o);
        rd($local, \%l);
        open(my $m, ">", $out) or die; open(my $i, ">", $list) or die;
        my %done;
        for my $k (@order) {
            my $install = !exists $l{$k} || ($l{$k} ne $n{$k} && ($first || !exists $o{$k} || $l{$k} eq $o{$k}));
            print $i "$k\n" if $install && (!exists $l{$k} || $l{$k} ne $n{$k});
            print $m "$k\t", ($install ? $n{$k} : $l{$k}), "\n";
            $done{$k} = 1;
        }
        # Prompts of your own that the pack does not have.
        for my $k (sort keys %l) { print $m "$k\t$l{$k}\n" unless $done{$k} }
    ' "$tmp/telemetry.tsv" "$STORE/telemetry.tsv" "$manifest" "$tmp/manifest" "$tmp/install.list" \
        || { echo "Could not read the telemetry list of voice pack $NAME." >&2; return 1; }
    if [[ ! -s $tmp/install.list ]]; then
        cp -f -- "$tmp/telemetry.tsv" "$STORE/telemetry.tsv"
        return 0
    fi
    say "Downloading the telemetry prompts of voice pack $NAME..."
    mkdir -p -- "$SOUNDS_DIR" || { echo "Could not create $SOUNDS_DIR" >&2; return 1; }
    f=$(mktemp -d "$SOUNDS_DIR/.pack-incoming.XXXXXX") || { echo "Could not create a folder in $SOUNDS_DIR" >&2; return 1; }
    if ! curl -fsSL --retry 3 --retry-delay 10 "$URL/telemetry.tar.xz" | xz -dc \
            | tar -x --no-same-owner -C "$f" -f -; then
        rm -rf -- "$f"
        echo "Could not download the telemetry prompts of voice pack $NAME." >&2
        return 1
    fi
    # Each prompt replaces the old one by renaming, so Asterisk never
    # plays half a file. The manifest goes last: it says what made each
    # prompt, so elevenlabs-telemetry.sh (with an API key) doesn't make the
    # pack's again.
    while IFS= read -r p; do
        [[ -f $f/$p.ul ]] || continue
        mkdir -p -- "$SOUNDS_DIR/$(dirname "$p")" && chmod 755 -- "$SOUNDS_DIR/$(dirname "$p")" \
            && chmod 644 -- "$f/$p.ul" && mv -f -- "$f/$p.ul" "$SOUNDS_DIR/$p.ul" \
            || { rm -rf -- "$f"; echo "Could not install the telemetry prompts in $SOUNDS_DIR" >&2; return 1; }
    done < "$tmp/install.list"
    rm -rf -- "$f"
    chmod 644 -- "$tmp/manifest" && mv -f -- "$tmp/manifest" "$manifest"
    cp -f -- "$tmp/telemetry.tsv" "$STORE/telemetry.tsv"
    echo "Installed $(el_count "$(wc -l < "$tmp/install.list")" "telemetry prompt") of voice pack $NAME in $SOUNDS_DIR."
}

# Keep the voice settings in elevenlabs.conf the pack's, so anything spoken
# with an API key (elevenlabs-speak.sh, custom text) is in the same voice.
sync_settings() {
    local before after
    before="$EL_VOICE_ID|$EL_VOICE_NAME|$EL_MODEL_ID|$EL_LANGUAGE|$EL_SPEED|$EL_STABILITY|$EL_SIMILARITY|$EL_NODE_METHOD"
    el_use_pack "$NAME" || return 0
    after="$EL_VOICE_ID|$EL_VOICE_NAME|$EL_MODEL_ID|$EL_LANGUAGE|$EL_SPEED|$EL_STABILITY|$EL_SIMILARITY|$EL_NODE_METHOD"
    [[ $before == "$after" ]] && return 0
    el_save_config && echo "Updated the voice settings in $EL_CONF to voice pack $NAME's."
}

cmd_status() {
    local total have
    load_pack
    echo "Voice pack: $NAME ($EL_VOICE_NAME)"
    if [[ ! -f $STORE/index.tsv ]]; then
        echo "Not downloaded yet. Run: sudo elevenlabs-pack.sh sync"
        return 0
    fi
    total=$(wc -l < "$STORE/index.tsv")
    have=$(find "$STORE/files" -maxdepth 1 -name '*.ulaw' | wc -l)
    echo "Announcements: $have here, $total in the pack (updated $(date -r "$STORE/index.tsv" '+%Y-%m-%d %H:%M'))"
    if [[ -f $STORE/telemetry.tsv ]]; then
        echo "Telemetry prompts: $(grep -cxFf "$STORE/telemetry.tsv" "$SOUNDS_DIR/.elevenlabs-prompts" 2> /dev/null || echo 0) of the pack's $(wc -l < "$STORE/telemetry.tsv") in $SOUNDS_DIR"
    else
        echo "Telemetry prompts: not installed yet. Run: sudo elevenlabs-pack.sh sync"
    fi
    echo "Stored in $STORE ($(du -sh "$STORE" 2> /dev/null | cut -f1))"
}

case ${1:-} in
    list) cmd_list ;;
    sync) shift; cmd_sync "$@" ;;
    status) cmd_status ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
