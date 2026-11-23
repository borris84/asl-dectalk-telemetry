#!/bin/bash
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Build and publish the prebuilt ElevenLabs node name packs.
#
# A pack holds one announcement per distinct text that a node's call sign
# field is spoken as (write_node_callsigns_elevenlabs.sh -T), not one per
# node, so nodes that share a call sign share a file, and a new node with a
# known call sign needs nothing new. Each file is named after the MD5 of
# its text: <md5>.ulaw, 8 kHz u-law, made exactly as the node script makes
# a spoken announcement.
#
# A pack is published as the assets of a GitHub release tagged pack-NAME:
#   pack.conf            the voice and settings (packs/NAME.conf)
#   index.tsv            "md5<TAB>text<TAB>archive" for every announcement
#   base.tar.xz          the first full build
#   delta-<time>.tar.xz  announcements added later
# A node downloads index.tsv, works out which files it lacks, and fetches
# only the archives that hold them.
#
# The local working copy of a pack (DIR) has pack.conf, index.tsv and
# files/<md5>.ulaw for the announcements not yet published, which are
# listed in index.tsv with "-" as their archive.

set -u
set -o pipefail
export LC_ALL=C

TOOL_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
REPO_DIR=$(dirname "$TOOL_DIR")
REPO=${PACK_REPO:-borris84/asl-dectalk-telemetry}
NODE_SCRIPT=$REPO_DIR/write_node_callsigns_elevenlabs.sh
# A delta archive is merged with the others once there are this many, so
# the release stays far below GitHub's 1000 assets.
MAX_DELTAS=${PACK_MAX_DELTAS:-30}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat << EOF
Usage: pack-tool.sh COMMAND ...

  texts ASTDB_DIR              Print "node<TAB>text" for every node in
                               ASTDB_DIR/astdb.txt (letters, no node number)
  init PACK_CONF DIR           Start an empty pack in DIR
  fetch NAME DIR               Download the published pack's pack.conf and
                               index.tsv into DIR
  import DIR TEXTS NODENAMES   Add existing announcements from a node name
                               folder (NODENAMES/<node>.ulaw) for the texts
                               the pack lacks. No requests are sent: the
                               files must have been made with the pack's
                               voice and settings.
  missing DIR TEXTS            Print "md5<TAB>text" for the texts the pack
                               lacks
  render [-j N] [-m MAX] [-y] DIR TEXTS
                               Make the texts the pack lacks with ElevenLabs
                               (N at a time, default 2; at most MAX, default
                               no limit). Asks first unless -y is given.
                               The API key is ELEVENLABS_API_KEY, or else
                               API_KEY in /opt/asl-telem/elevenlabs.conf.
  publish DIR                  Upload the unpublished files: as base.tar.xz
                               if the pack has none, else as a delta
  compact NAME                 Merge the delta archives into one once there
                               are more than $MAX_DELTAS
  status DIR                   Show what the pack holds
EOF
}

need() {
    local c
    for c in "$@"; do command -v "$c" > /dev/null || die "$c is required"; done
}

# conf_value FILE KEY
conf_value() {
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\\1/p" "$1" | head -n 1
}

check_dir() {
    [[ -f $1/pack.conf && -f $1/index.tsv ]] || die "$1 is not a pack (no pack.conf or index.tsv). Use init or fetch."
    mkdir -p "$1/files" || die "could not create $1/files"
}

cmd_texts() {
    [[ -f $1/astdb.txt ]] || die "$1/astdb.txt not found"
    "$NODE_SCRIPT" -T -s "$1"
}

cmd_init() {
    local conf=$1 dir=$2
    [[ -f $conf ]] || die "$conf not found"
    [[ -n $(conf_value "$conf" PACK) && -n $(conf_value "$conf" VOICE_ID) ]] || die "$conf has no PACK or VOICE_ID"
    [[ -e $dir/index.tsv ]] && die "$dir already holds a pack"
    mkdir -p "$dir/files" || die "could not create $dir"
    cp -- "$conf" "$dir/pack.conf" && : > "$dir/index.tsv" || die "could not write to $dir"
    echo "Started pack $(conf_value "$conf" PACK) in $dir"
}

cmd_fetch() {
    local name=$1 dir=$2
    need gh
    mkdir -p "$dir/files" || die "could not create $dir"
    gh release download "pack-$name" --repo "$REPO" --dir "$dir" --clobber \
        --pattern pack.conf --pattern index.tsv || die "could not download pack $name"
    echo "Fetched pack $name: $(wc -l < "$dir/index.tsv") announcements"
}

# missing DIR TEXTS  - "md5<TAB>text" for each distinct text not in the pack.
cmd_missing() {
    check_dir "$1"
    perl -MDigest::MD5=md5_hex -e '
        my ($index, $texts) = @ARGV;
        my %have;
        open(my $i, "<", $index) or die "$index: $!\n";
        while (<$i>) { my ($h) = split /\t/; $have{$h} = 1 }
        open(my $t, "<", $texts) or die "$texts: $!\n";
        my %seen;
        while (<$t>) {
            chomp;
            my (undef, $text) = split /\t/, $_, 2;
            next unless defined $text && $text ne "";
            my $h = md5_hex($text);
            next if $have{$h} || $seen{$h}++;
            print "$h\t$text\n";
        }
    ' "$1/index.tsv" "$2"
}

cmd_import() {
    local dir=$1 texts=$2 from=$3
    check_dir "$dir"
    [[ -d $from ]] || die "$from not found"
    perl -MDigest::MD5=md5_hex -e '
        my ($dir, $texts, $from) = @ARGV;
        my %have;
        open(my $i, "<", "$dir/index.tsv") or die "$dir/index.tsv: $!\n";
        while (<$i>) { my ($h) = split /\t/; $have{$h} = 1 }
        open(my $t, "<", $texts) or die "$texts: $!\n";
        open(my $out, ">>", "$dir/index.tsv") or die "$dir/index.tsv: $!\n";
        my ($added, $absent, %ino) = (0, 0);
        while (<$t>) {
            chomp;
            my ($node, $text) = split /\t/, $_, 2;
            next unless defined $text && $text ne "";
            my $h = md5_hex($text);
            my $src = "$from/$node.ulaw";
            my @st = stat $src;
            if (!@st || !$st[7]) { $absent++ unless $have{$h}; next }
            # Every node with this text should share one file.
            $ino{$h}{$st[1]} = 1;
            next if $have{$h};
            my $dst = "$dir/files/$h.ulaw";
            link($src, $dst) or system("cp", "--", $src, $dst) == 0
                or die "could not copy $src: $!\n";
            print $out "$h\t$text\t-\n";
            $have{$h} = 1;
            $added++;
        }
        my $split = grep { keys %{$ino{$_}} > 1 } keys %ino;
        print "Imported $added announcements from $from.\n";
        print "$split texts had more than one file (call signs differing only in case); one of each was used.\n" if $split;
    ' "$dir" "$texts" "$from" || die "import failed"
    echo "Texts still missing: $(cmd_missing "$dir" "$texts" | wc -l)"
}

# render_one "md5<TAB>text"  - run by xargs: make one announcement.
render_one() {
    local hash=${1%%$'\t'*} text=${1#*$'\t'}
    local out=$PACK_DIR/files/$hash.ulaw
    [[ -e $STOP_FILE ]] && return 0
    if el_render "$text" "$out.tmp.$$"; then
        mv -f -- "$out.tmp.$$" "$out" && printf 'OK\n'
    else
        rm -f -- "$out.tmp.$$"
        printf 'FAIL %s: %s\n' "$text" "$EL_ERROR"
        [[ $EL_ERROR == *"out of credits"* || $EL_ERROR == *"key was not accepted"* ]] && : > "$STOP_FILE"
    fi
    return 0
}

cmd_render() {
    local jobs=2 max=0 yes=0 opt OPTIND=1
    while getopts ":j:m:y" opt; do
        case $opt in
            j) jobs=$OPTARG ;;
            m) max=$OPTARG ;;
            y) yes=1 ;;
            *) usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    (( $# == 2 )) || { usage >&2; exit 1; }
    [[ $jobs =~ ^[1-9][0-9]*$ && $max =~ ^[0-9]+$ ]] || die "-j and -m must be numbers"
    local dir=$1 texts=$2 todo total chars
    check_dir "$dir"
    need curl perl xargs

    SCRIPT_DIR=$REPO_DIR
    EL_CONF=$dir/pack.conf
    # shellcheck source=../elevenlabs-common.sh
    . "$REPO_DIR/elevenlabs-common.sh"
    el_load_config || die "could not read $EL_CONF"
    EL_API_KEY=${ELEVENLABS_API_KEY:-}
    [[ -n $EL_API_KEY ]] || EL_API_KEY=$(conf_value /opt/asl-telem/elevenlabs.conf API_KEY 2> /dev/null)
    [[ -n $EL_API_KEY ]] || die "no API key: set ELEVENLABS_API_KEY"
    export EL_API_KEY

    todo=$(mktemp) || die "could not create a temporary file"
    STOP_FILE=$(mktemp -u)
    trap "rm -f -- '$todo' '$todo.cut' '$STOP_FILE'" EXIT
    cmd_missing "$dir" "$texts" > "$todo" || die "could not work out what is missing"
    (( max )) && { head -n "$max" "$todo" > "$todo.cut"; mv -f "$todo.cut" "$todo"; }
    total=$(wc -l < "$todo")
    if (( total == 0 )); then
        echo "Pack $(conf_value "$dir/pack.conf" PACK) has every announcement."
        return 0
    fi
    chars=$(cut -f2 "$todo" | awk '{ n += length($0) } END { print n + 0 }')
    echo "$total announcements to make with ElevenLabs (voice $EL_VOICE_NAME, $EL_MODEL_ID, speed $EL_SPEED)."
    echo "That is about $chars characters, and will take $(el_duration "$total" "$jobs")."
    if (( ! yes )); then
        local answer
        read -r -p "Continue? [y/N] " answer || die "no answer given"
        [[ ${answer,,} == y || ${answer,,} == yes ]] || { echo "Nothing done."; return 0; }
    fi

    export PACK_DIR=$dir STOP_FILE
    export -f render_one
    local done_count=0 failed=0 line start=$SECONDS
    while IFS= read -r line; do
        if [[ $line == OK ]]; then
            (( ++done_count ))
        else
            (( ++failed ))
            echo "${line#FAIL }" >&2
        fi
        if (( (done_count + failed) % 100 == 0 )); then
            echo "Made $done_count of $total ($(( (done_count + failed) * 100 / total ))%), $failed failed, $(( (SECONDS - start) / 60 )) min"
        fi
    done < <(tr '\n' '\0' < "$todo" | xargs -0 -P "$jobs" -n 1 bash -c 'render_one "$1"' _)

    # Add what was made to the index, as not yet published.
    perl -e '
        my ($dir, $todo) = @ARGV;
        open(my $t, "<", $todo) or die;
        open(my $out, ">>", "$dir/index.tsv") or die;
        while (<$t>) {
            chomp;
            my ($h, $text) = split /\t/, $_, 2;
            print $out "$h\t$text\t-\n" if -s "$dir/files/$h.ulaw";
        }
    ' "$dir" "$todo" || die "could not update $dir/index.tsv"

    echo "Made $done_count of $total announcements, $failed failed, in $(( (SECONDS - start) / 60 )) minutes."
    if [[ -e $STOP_FILE ]]; then
        echo "Stopped early: ElevenLabs stopped accepting requests (see above)." >&2
        return 1
    fi
    (( failed == 0 ))
}

cmd_publish() {
    local dir=$1 name tag archive list count
    check_dir "$dir"
    need gh tar xz
    name=$(conf_value "$dir/pack.conf" PACK)
    [[ -n $name ]] || die "$dir/pack.conf has no PACK"
    tag=pack-$name

    list=$(mktemp) || die "could not create a temporary file"
    trap "rm -f -- '$list'" EXIT
    awk -F'\t' '$3 == "-" { print $1 ".ulaw" }' "$dir/index.tsv" > "$list"
    count=$(wc -l < "$list")
    if (( count == 0 )); then
        echo "Pack $name: nothing new to publish."
        return 0
    fi
    if awk -F'\t' '$3 == "base.tar.xz" { found = 1; exit } END { exit !found }' "$dir/index.tsv"; then
        archive=delta-$(date -u +%Y%m%dT%H%M%SZ).tar.xz
    else
        archive=base.tar.xz
    fi

    echo "Packing $count announcements into $archive..."
    tar -C "$dir/files" --owner=0 --group=0 --mode=644 -cf - -T "$list" \
        | xz -6 -T0 > "$dir/$archive" || die "could not make $archive"

    if ! gh release view "$tag" --repo "$REPO" > /dev/null 2>&1; then
        gh release create "$tag" --repo "$REPO" --prerelease --latest=false \
            --title "Node name voice pack: $(conf_value "$dir/pack.conf" VOICE_NAME)" \
            --notes "Prebuilt ElevenLabs node name announcements for asl-dectalk-telemetry. Updated automatically as nodes are added. See packs/pack-tool.sh." \
            || die "could not create release $tag"
    fi
    # The archive goes up before the index that names it.
    gh release upload "$tag" --repo "$REPO" "$dir/$archive" || die "could not upload $archive"
    awk -F'\t' -v OFS='\t' -v a="$archive" '$3 == "-" { $3 = a } { print }' "$dir/index.tsv" > "$dir/index.tsv.new" \
        && mv -f "$dir/index.tsv.new" "$dir/index.tsv" || die "could not update the index"
    gh release upload "$tag" --repo "$REPO" --clobber "$dir/index.tsv" "$dir/pack.conf" \
        || die "could not upload the index"
    rm -f -- "$dir/$archive"
    echo "Published $count announcements in $archive to $tag."
}

cmd_compact() {
    local name=$1 tag=pack-$1 work deltas archive
    need gh tar xz
    tag=pack-$name
    mapfile -t deltas < <(gh release view "$tag" --repo "$REPO" --json assets \
        --jq '.assets[].name | select(startswith("delta-"))' | sort)
    if (( ${#deltas[@]} <= MAX_DELTAS )); then
        echo "Pack $name has ${#deltas[@]} delta archives: nothing to merge."
        return 0
    fi
    work=$(mktemp -d) || die "could not create a temporary directory"
    trap "rm -rf -- '$work'" EXIT
    mkdir "$work/files"
    gh release download "$tag" --repo "$REPO" --dir "$work" --pattern index.tsv || die "could not download the index"
    local d
    for d in "${deltas[@]}"; do
        gh release download "$tag" --repo "$REPO" --dir "$work" --pattern "$d" || die "could not download $d"
        tar -C "$work/files" -xJf "$work/$d" || die "could not unpack $d"
        rm -f -- "$work/$d"
    done
    archive=delta-$(date -u +%Y%m%dT%H%M%SZ)-merged.tar.xz
    (cd "$work/files" && find . -name '*.ulaw' -printf '%f\n' | sort > ../list) || die "could not list the files"
    tar -C "$work/files" --owner=0 --group=0 --mode=644 -cf - -T "$work/list" | xz -6 -T0 > "$work/$archive" \
        || die "could not make $archive"
    gh release upload "$tag" --repo "$REPO" "$work/$archive" || die "could not upload $archive"
    awk -F'\t' -v OFS='\t' -v a="$archive" '$3 ~ /^delta-/ { $3 = a } { print }' "$work/index.tsv" > "$work/index.new" \
        && mv -f "$work/index.new" "$work/index.tsv" || die "could not update the index"
    gh release upload "$tag" --repo "$REPO" --clobber "$work/index.tsv" || die "could not upload the index"
    for d in "${deltas[@]}"; do
        gh release delete-asset "$tag" "$d" --repo "$REPO" --yes || echo "Could not delete $d" >&2
    done
    echo "Merged ${#deltas[@]} delta archives of pack $name into $archive."
}

cmd_status() {
    check_dir "$1"
    echo "Pack $(conf_value "$1/pack.conf" PACK): $(conf_value "$1/pack.conf" VOICE_NAME)"
    awk -F'\t' '{ n[$3]++ } END { for (a in n) printf "  %-40s %d\n", (a == "-" ? "(not published)" : a), n[a] }' "$1/index.tsv" | sort
}

cmd=${1:-}
(( $# )) && shift
case $cmd in
    texts) (( $# == 1 )) || { usage >&2; exit 1; }; cmd_texts "$@" ;;
    init) (( $# == 2 )) || { usage >&2; exit 1; }; cmd_init "$@" ;;
    fetch) (( $# == 2 )) || { usage >&2; exit 1; }; cmd_fetch "$@" ;;
    import) (( $# == 3 )) || { usage >&2; exit 1; }; cmd_import "$@" ;;
    missing) (( $# == 2 )) || { usage >&2; exit 1; }; cmd_missing "$@" ;;
    render) cmd_render "$@" ;;
    publish) (( $# == 1 )) || { usage >&2; exit 1; }; cmd_publish "$@" ;;
    compact) (( $# == 1 )) || { usage >&2; exit 1; }; cmd_compact "$@" ;;
    status) (( $# == 1 )) || { usage >&2; exit 1; }; cmd_status "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
