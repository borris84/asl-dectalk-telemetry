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
#   telemetry.tar.xz     the telemetry prompts (elevenlabs-prompt-list.txt)
#                        in the same voice, laid out as the sounds/custom
#                        folder, with the .elevenlabs-prompts manifest
#   telemetry.tsv        a copy of that manifest
#   preview.ul           a short sample of the voice, which the installer
#                        plays so the voice can be heard before choosing it
# A node downloads index.tsv, works out which files it lacks, and fetches
# only the archives that hold them.
#
# The release tagged packs has packs.tsv, the list of the packs a node can
# choose ("name<TAB>voice id<TAB>voice name<TAB>accent<TAB>gender", from
# each pack.conf): every pack-NAME release that has all the files above.
# The installer and elevenlabs-pack.sh download it, so a new pack can be
# chosen without a new release of the scripts. It is remade by catalog,
# which publish, telemetry and preview run when a pack may have become
# complete.
#
# The local working copy of a pack (DIR) has pack.conf, index.tsv and
# files/<md5>.ulaw for the announcements not yet published, which are
# listed in index.tsv with "-" as their archive, and telemetry/ for the
# telemetry prompts.

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
# The release that holds packs.tsv, and the files a pack release must have
# to be listed in it.
CATALOG_TAG=packs
CATALOG_NEEDS=(pack.conf index.tsv base.tar.xz telemetry.tar.xz telemetry.tsv preview.ul)

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
  telemetry [-j N] [-i SOUNDS] DIR
                               Make the telemetry prompts the pack lacks, or
                               whose text has changed, with
                               elevenlabs-telemetry.sh, and publish them as
                               telemetry.tar.xz. -i first takes the prompts
                               in a sounds folder (with its
                               .elevenlabs-prompts) that were made with the
                               pack's exact settings, so they aren't made
                               again.
  preview DIR                  Make and publish preview.ul, a short
                               sample of the voice
  catalog                      Remake packs.tsv, the list of complete packs
                               that nodes can choose, and publish it if it
                               changed
  link DIR TEXTS NODENAMES     Hard-link NODENAMES/<node>.ulaw to the
                               pack's file for each node in TEXTS
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

# The ElevenLabs API key: ELEVENLABS_API_KEY, or else the node's own.
api_key() {
    local key=${ELEVENLABS_API_KEY:-}
    [[ -n $key ]] || key=$(conf_value /opt/asl-telem/elevenlabs.conf API_KEY 2> /dev/null)
    [[ -n $key ]] && printf '%s' "$key"
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
    EL_API_KEY=$(api_key) || die "no API key: set ELEVENLABS_API_KEY"
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
    trap "rm -f -- '$list' '$list.remote'" EXIT
    # The published index may have gained entries since this copy was
    # fetched (the daily workflow): merge them in, so uploading this index
    # doesn't drop them. Entries made here that were also published there
    # since take the published archive.
    if gh release download "$tag" --repo "$REPO" --pattern index.tsv --output "$list.remote" 2> /dev/null; then
        awk -F'\t' -v OFS='\t' '
            FNR == NR { remote[$1] = $0; order[++n] = $1; next }
            { if ($1 in remote) { if ($3 == "-") next; delete remote[$1] } local[++m] = $0 }
            END {
                for (i = 1; i <= n; i++) if (order[i] in remote) print remote[order[i]]
                for (i = 1; i <= m; i++) print local[i]
            }
        ' "$list.remote" "$dir/index.tsv" > "$dir/index.tsv.new" \
            && mv -f "$dir/index.tsv.new" "$dir/index.tsv" || die "could not merge the published index"
    fi
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
    [[ $archive == base.tar.xz ]] && update_catalog
    return 0
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

cmd_telemetry() {
    local jobs=2 from="" opt OPTIND=1
    while getopts ":j:i:" opt; do
        case $opt in
            j) jobs=$OPTARG ;;
            i) from=$OPTARG ;;
            *) usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    (( $# == 1 )) || { usage >&2; exit 1; }
    [[ $jobs =~ ^[1-9][0-9]*$ ]] || die "-j must be a number"
    local dir=$1 name tag tdir manifest key before published rc=0
    check_dir "$dir"
    need gh tar xz md5sum
    name=$(conf_value "$dir/pack.conf" PACK)
    tag=pack-$name
    tdir=$(cd "$dir" && pwd)/telemetry
    manifest=$tdir/.elevenlabs-prompts
    gh release view "$tag" --repo "$REPO" > /dev/null 2>&1 || die "pack $name is not published yet: publish it first"
    published=$(gh release view "$tag" --repo "$REPO" --json assets \
        --jq '.assets[].name | select(. == "telemetry.tar.xz")') || die "could not read release $tag"
    mkdir -p "$tdir" || die "could not create $tdir"

    # Start from what is published, so only new or changed prompts are made.
    if [[ ! -f $manifest && -n $published ]]; then
        gh release download "$tag" --repo "$REPO" --dir "$dir" --clobber --pattern telemetry.tar.xz \
            && tar -C "$tdir" -xJf "$dir/telemetry.tar.xz" || die "could not fetch the published telemetry"
        rm -f -- "$dir/telemetry.tar.xz"
    fi
    if [[ -n $from ]]; then
        [[ -f $from/.elevenlabs-prompts ]] || die "$from has no .elevenlabs-prompts"
        (cd "$from" && cut -f1 .elevenlabs-prompts | sed 's/$/.ul/' | while IFS= read -r f; do
            [[ ! -f $f ]] || cp --parents -- "$f" "$tdir/" || exit 1
        done) || die "could not copy the prompts from $from"
        # Prompts imported here are only kept if elevenlabs-telemetry.sh
        # agrees they were made from the same text and settings.
        cp -- "$from/.elevenlabs-prompts" "$manifest" || die "could not copy the manifest"
    fi
    before=$(cat -- "$manifest" 2> /dev/null | md5sum)

    key=$(api_key) || die "no API key: set ELEVENLABS_API_KEY"
    EL_CONF=$dir/pack.conf ELEVENLABS_API_KEY=$key \
        "$REPO_DIR/elevenlabs-telemetry.sh" -f -j "$jobs" -o "$tdir" || rc=1
    [[ -f $manifest ]] || die "no telemetry prompts were made"

    if [[ -n $published && $(md5sum < "$manifest") == "$before" && -z $from ]]; then
        echo "Pack $name: telemetry unchanged."
        return $rc
    fi
    # Every prompt file goes in, even one whose new version failed: the
    # old one is better than none, and the manifest says it is out of date.
    (cd "$tdir" && { echo .elevenlabs-prompts; find . -name '*.ul' -printf '%P\n' | sort; } > ../telemetry.list) \
        && tar -C "$tdir" --owner=0 --group=0 --mode=644 -cf - -T "$dir/telemetry.list" \
            | xz -6 -T0 > "$dir/telemetry.tar.xz" \
        && cp -- "$manifest" "$dir/telemetry.tsv" || die "could not make telemetry.tar.xz"
    gh release upload "$tag" --repo "$REPO" --clobber "$dir/telemetry.tar.xz" "$dir/telemetry.tsv" \
        || die "could not upload the telemetry"
    echo "Published $(( $(wc -l < "$dir/telemetry.list") - 1 )) telemetry prompts to $tag."
    rm -f -- "$dir/telemetry.tar.xz" "$dir/telemetry.list"
    [[ -z $published ]] && update_catalog
    return $rc
}

# What preview.ul says: a node name as the pack says one, then telemetry.
PREVIEW_TEXT="W 1 A W. Connected to node 2 0 0 0. The time is 3:15 PM. All links disconnected."

cmd_preview() {
    local dir=$1 name tag
    check_dir "$dir"
    need gh curl perl
    name=$(conf_value "$dir/pack.conf" PACK)
    tag=pack-$name
    gh release view "$tag" --repo "$REPO" > /dev/null 2>&1 || die "pack $name is not published yet: publish it first"
    SCRIPT_DIR=$REPO_DIR
    EL_CONF=$dir/pack.conf
    # shellcheck source=../elevenlabs-common.sh
    . "$REPO_DIR/elevenlabs-common.sh"
    el_load_config || die "could not read $EL_CONF"
    EL_API_KEY=$(api_key) || die "no API key: set ELEVENLABS_API_KEY"
    el_render "$PREVIEW_TEXT" "$dir/preview.ul" || die "could not make the preview: $EL_ERROR"
    gh release upload "$tag" --repo "$REPO" --clobber "$dir/preview.ul" || die "could not upload preview.ul"
    echo "Published preview.ul to $tag."
    update_catalog
}

# catalog  - list every pack-NAME release that has all of CATALOG_NEEDS in
# packs.tsv, and publish it to the CATALOG_TAG release if it changed.
cmd_catalog() {
    local work tag assets name f missing line count
    need gh perl
    work=$(mktemp -d) || die "could not create a temporary folder"
    trap "rm -rf -- '$work'" EXIT
    gh api --paginate "repos/$REPO/releases?per_page=100" \
        --jq '.[] | select(.tag_name | startswith("pack-")) | [.tag_name, ([.assets[].name] | join(" "))] | @tsv' \
        > "$work/releases" || die "could not list the releases of $REPO"
    : > "$work/packs.tsv"
    while IFS=$'\t' read -r tag assets; do
        name=${tag#pack-}
        missing=()
        for f in "${CATALOG_NEEDS[@]}"; do
            [[ " $assets " == *" $f "* ]] || missing+=("$f")
        done
        if (( ${#missing[@]} )); then
            echo "Pack $name: not listed yet, it has no ${missing[*]}."
            continue
        fi
        gh release download "$tag" --repo "$REPO" --pattern pack.conf --output "$work/$name.conf" \
            || die "could not download the pack.conf of $tag"
        [[ $(conf_value "$work/$name.conf" PACK) == "$name" ]] \
            || { echo "Pack $name: not listed, its pack.conf has another PACK." >&2; continue; }
        line=$(printf '%s\t%s\t%s\t%s\t%s' "$name" "$(conf_value "$work/$name.conf" VOICE_ID)" \
            "$(conf_value "$work/$name.conf" VOICE_NAME)" "$(conf_value "$work/$name.conf" ACCENT)" \
            "$(conf_value "$work/$name.conf" GENDER)")
        # The same check a node makes, so one bad line can't hide the list.
        if ! perl -ne 'exit 1 unless /^[a-z0-9_-]+\t[A-Za-z0-9]+\t[^\t\x00-\x1f]+\t[a-z]*\t[a-z]*$/' <<< "$line"; then
            echo "Pack $name: not listed, its pack.conf has a value a node would not accept." >&2
            continue
        fi
        echo "$line" >> "$work/packs.tsv"
    done < "$work/releases"
    sort -t$'\t' -k4,4 -k5,5r -k1,1 -o "$work/packs.tsv" "$work/packs.tsv"
    count=$(wc -l < "$work/packs.tsv")
    (( count )) || die "no pack is complete: nothing to list"

    if gh release download "$CATALOG_TAG" --repo "$REPO" --pattern packs.tsv --output "$work/published.tsv" 2> /dev/null \
        && cmp -s -- "$work/published.tsv" "$work/packs.tsv"; then
        echo "The list of packs is unchanged ($count)."
        return 0
    fi
    if ! gh release view "$CATALOG_TAG" --repo "$REPO" > /dev/null 2>&1; then
        gh release create "$CATALOG_TAG" --repo "$REPO" --prerelease --latest=false \
            --title "Ready-made voice list" \
            --notes "packs.tsv lists the ready-made ElevenLabs voices (the pack-NAME releases) that nodes can choose. Made by packs/pack-tool.sh catalog." \
            || die "could not create release $CATALOG_TAG"
    fi
    gh release upload "$CATALOG_TAG" --repo "$REPO" --clobber "$work/packs.tsv" \
        || die "could not upload packs.tsv"
    echo "Published the list of $count packs:"
    cut -f1,3 "$work/packs.tsv" | sed 's/^/  /'
}

# Remake the list of packs after a pack may have become complete. A
# failure here doesn't fail the command that ran it: the next catalog
# (the daily workflow) tries again.
update_catalog() {
    ( cmd_catalog ) || echo "WARNING: could not update the list of packs. Run: packs/pack-tool.sh catalog" >&2
}

# link DIR TEXTS NODENAMES  - point NODENAMES/<node>.ulaw at the pack's
# file for each node in TEXTS, as a hard link (a copy if DIR is on another
# filesystem). Each link is made under a temp name and renamed, so a node
# always has a complete announcement. Nodes whose text the pack doesn't
# have are left as they are.
cmd_link() {
    local dir=$1 texts=$2 to=$3
    check_dir "$dir"
    [[ -d $to ]] || die "$to not found"
    perl -MDigest::MD5=md5_hex -e '
        my ($dir, $texts, $to) = @ARGV;
        open(my $t, "<", $texts) or die "$texts: $!\n";
        my ($linked, $same, $absent, $failed) = (0, 0, 0, 0);
        while (<$t>) {
            chomp;
            my ($node, $text) = split /\t/, $_, 2;
            next unless defined $text && $node =~ /^[0-9]+$/;
            my $src = "$dir/files/" . md5_hex($text) . ".ulaw";
            my @s = stat $src;
            if (!@s) { $absent++; next }
            my $dst = "$to/$node.ulaw";
            my @d = stat $dst;
            if (@d && $d[0] == $s[0] && $d[1] == $s[1]) { $same++; next }
            my $tmp = "$dst.tmp.$$";
            if ((link($src, $tmp) || system("cp", "--", $src, $tmp) == 0) && rename($tmp, $dst)) {
                $linked++;
            } else {
                unlink $tmp;
                warn "Could not link node $node\n";
                $failed++;
            }
        }
        print "Linked $linked nodes, $same already linked, $absent not in the pack, $failed failed.\n";
        exit($failed ? 1 : 0);
    ' "$dir" "$texts" "$to"
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
    telemetry) cmd_telemetry "$@" ;;
    preview) (( $# == 1 )) || { usage >&2; exit 1; }; cmd_preview "$@" ;;
    catalog) (( $# == 0 )) || { usage >&2; exit 1; }; cmd_catalog ;;
    link) (( $# == 3 )) || { usage >&2; exit 1; }; cmd_link "$@" ;;
    status) (( $# == 1 )) || { usage >&2; exit 1; }; cmd_status "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
