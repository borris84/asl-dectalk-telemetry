# elevenlabs-common.sh
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Shared code for the ElevenLabs scripts. Not run on its own: the scripts
# source it after setting SCRIPT_DIR.
#
# The settings are in elevenlabs.conf beside the scripts (or, if there is
# none, in /opt/asl-telem), one KEY=VALUE per
# line (written by install.sh, readable by root only because it holds the
# API key):
#   API_KEY     ElevenLabs API key
#   VOICE_ID    voice used unless another is given
#   VOICE_NAME  that voice's name, for messages
#   MODEL_ID    text to speech model (default eleven_v4_turbo)
#   LANGUAGE    language code sent to models that take one (default en)
#   SPEED       0.7 to 1.2, 1 is the voice's normal pace
#   STABILITY, SIMILARITY  optional voice settings (0 to 1); the voice's
#               own settings are used when they are not set
#   NODE_METHOD join (node names are joined from the telemetry letter and
#               digit sounds: free, the default) or speak (each node name
#               is one request: more natural, but uses credits)
#   JOBS        requests sent at once (default 2)
#   API_URL     default https://api.elevenlabs.io
#
# Audio is requested as 8 kHz PCM, then silence is trimmed from both ends,
# its level set to EL_TARGET_RMS (RMS, dBFS) with peaks kept below -1 dBFS,
# and it is written as u-law.

# The settings beside the script, or else the installed ones, so a copy
# run from the repository uses what install.sh set up.
if [[ -z ${EL_CONF:-} ]]; then
    EL_CONF=$SCRIPT_DIR/elevenlabs.conf
    [[ ! -e $EL_CONF && -e /opt/asl-telem/elevenlabs.conf ]] && EL_CONF=/opt/asl-telem/elevenlabs.conf
fi
EL_KEYS_URL=https://elevenlabs.io/app/settings/api-keys
EL_DEFAULT_MODEL=eleven_v4_turbo
EL_TARGET_RMS=-24
EL_SILENCE=-50dB
EL_CONF_KEYS=(API_KEY VOICE_ID VOICE_NAME MODEL_ID LANGUAGE SPEED STABILITY SIMILARITY NODE_METHOD JOBS API_URL)

# Read elevenlabs.conf into EL_API_KEY, EL_VOICE_ID and so on. Values are
# taken literally: the file is never run as shell code. Returns 1 if the
# file can't be read.
el_load_config() {
    local line key value k
    for k in "${EL_CONF_KEYS[@]}"; do printf -v "EL_$k" '%s' ""; done
    [[ -r $EL_CONF ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        value=${value%"${value##*[![:space:]]}"}
        for k in "${EL_CONF_KEYS[@]}"; do
            [[ $key == "$k" ]] && printf -v "EL_$k" '%s' "$value"
        done
    done < "$EL_CONF"
    el_defaults
}

el_defaults() {
    EL_MODEL_ID=${EL_MODEL_ID:-$EL_DEFAULT_MODEL}
    EL_LANGUAGE=${EL_LANGUAGE:-en}
    EL_SPEED=${EL_SPEED:-1.0}
    EL_NODE_METHOD=${EL_NODE_METHOD:-join}
    [[ $EL_JOBS =~ ^[1-9][0-9]*$ ]] || EL_JOBS=2
    EL_API_URL=${EL_API_URL:-https://api.elevenlabs.io}
    EL_API_URL=${EL_API_URL%/}
    # Parallel workers are new shells: they get the settings from the
    # environment.
    local k
    for k in "${EL_CONF_KEYS[@]}"; do export "EL_$k"; done
    export EL_TARGET_RMS EL_SILENCE
}

# Write the EL_* settings to elevenlabs.conf, readable by its owner only.
el_save_config() {
    local k v tmp
    tmp=$(umask 077 && mktemp "$EL_CONF.tmp.XXXXXX") || return 1
    {
        echo "# ElevenLabs settings for the asl-telem scripts, written by install.sh."
        echo "# Holds your API key: keep it readable by root only. See elevenlabs-common.sh"
        echo "# for what each setting does."
        for k in "${EL_CONF_KEYS[@]}"; do
            v="EL_$k"
            [[ -n ${!v:-} ]] && printf '%s=%s\n' "$k" "${!v}"
        done
    } > "$tmp" && chmod 600 -- "$tmp" && mv -f -- "$tmp" "$EL_CONF" \
        || { rm -f -- "$tmp"; return 1; }
}

# Return 0 if the configuration has what is needed to speak.
el_configured() {
    [[ -n ${EL_API_KEY:-} && -n ${EL_VOICE_ID:-} ]]
}

# Print a short, readable error message from an API error response FILE.
el_error_message() {
    perl -MJSON::PP -0777 -ne '
        my $j = eval { JSON::PP::decode_json($_) };
        if (ref $j eq "HASH") {
            my $d = $j->{detail};
            if (ref $d eq "HASH") { print $d->{message} // $d->{status} // ""; exit }
            if (ref $d eq "ARRAY" && ref $d->[0] eq "HASH") { print $d->[0]{msg} // ""; exit }
            if (defined $d && !ref $d) { print $d; exit }
            if (defined $j->{message}) { print $j->{message}; exit }
        }
        s/\s+/ /g; print substr($_, 0, 200);
    ' "$1" 2> /dev/null
}

# Print the "status" word of an API error response FILE (quota_exceeded...).
el_error_status() {
    perl -MJSON::PP -0777 -ne '
        my $j = eval { JSON::PP::decode_json($_) };
        print $j->{detail}{status} // "" if ref $j eq "HASH" && ref $j->{detail} eq "HASH";
    ' "$1" 2> /dev/null
}

# el_request METHOD PATH OUT [BODY_FILE]
# Send one API request and write the response body to OUT. Busy and
# server errors are retried a few times. Returns 0 for a 2xx response;
# otherwise EL_ERROR says why. The API key is passed to curl on a file
# descriptor, so it never shows up in the process list.
el_request() {
    local method=$1 path=$2 out=$3 body=${4:-} code=000 try status=""
    local -a args=(-sS -X "$method" -o "$out" -w '%{http_code}' --connect-timeout 15 --max-time 120)
    [[ -n $body ]] && args+=(-H "Content-Type: application/json" --data-binary "@$body")
    EL_ERROR=""
    for try in 1 2 3 4 5; do
        code=$(curl "${args[@]}" -H @<(printf 'xi-api-key: %s\n' "$EL_API_KEY") \
            "$EL_API_URL$path" 2> "$out.curlerr") || code=000
        if [[ $code == 2* ]]; then
            rm -f -- "$out.curlerr"
            return 0
        fi
        if [[ $code == 000 ]]; then
            EL_ERROR="Could not reach $EL_API_URL: $(tr '\n' ' ' < "$out.curlerr")"
        else
            EL_ERROR="ElevenLabs said (HTTP $code): $(el_error_message "$out")"
        fi
        status=$(el_error_status "$out")
        # Retry only what may succeed later: too many requests at once,
        # a busy or failing server, or no connection.
        case $code in
            429) [[ $status == quota_exceeded ]] && break ;;
            5*|000) ;;
            *) break ;;
        esac
        (( try < 5 )) && sleep $(( try * 2 ))
    done
    rm -f -- "$out.curlerr"
    # ElevenLabs answers 401 or 429 when the credits have run out.
    if [[ $status == quota_exceeded ]]; then
        EL_ERROR="Your ElevenLabs account is out of credits. $EL_ERROR"
    elif [[ $code == 401 ]]; then
        EL_ERROR="The ElevenLabs API key was not accepted, or may not do this. $EL_ERROR"
    fi
    return 1
}

# el_get PATH  - put the response body of a GET request in EL_BODY.
# These functions set variables rather than print, so that EL_ERROR
# reaches the caller (a $(...) subshell would lose it).
el_get() {
    local tmp rc=0
    EL_BODY=""
    tmp=$(mktemp) || { EL_ERROR="Could not create a temporary file."; return 1; }
    el_request GET "$1" "$tmp" || rc=1
    (( rc )) || EL_BODY=$(< "$tmp")
    rm -f -- "$tmp"
    return $rc
}

# Put "voice_id<TAB>name<TAB>description" lines for every voice in the
# account's library, sorted by name, in EL_VOICE_LIST.
el_voices() {
    local token="" all="" lines
    EL_VOICE_LIST=""
    while :; do
        el_get "/v2/voices?page_size=100&include_total_count=false${token:+&next_page_token=$token}" || return 1
        lines=$(perl -MJSON::PP -0777 -ne '
            my $j = JSON::PP::decode_json($_);
            for my $v (@{ $j->{voices} || [] }) {
                my $l = $v->{labels} || {};
                my @d = grep { defined && length } map { $l->{$_} } qw(gender age accent descriptive use_case);
                unshift @d, $v->{category} if $v->{category} && $v->{category} ne "premade";
                my $name = $v->{name} // $v->{voice_id};
                s/[\t\n]/ /g for $name, @d;
                print "$v->{voice_id}\t$name\t", join(", ", @d), "\n";
            }
            my $t = $j->{has_more} && $j->{next_page_token} ? $j->{next_page_token} : "";
            $t =~ s/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord $1)/ge;
            print "TOKEN\t$t\n";
        ' <<< "$EL_BODY") || { EL_ERROR="Could not read the voice list from ElevenLabs."; return 1; }
        token=$(sed -n 's/^TOKEN\t//p' <<< "$lines")
        all+=$(grep -v '^TOKEN' <<< "$lines")$'\n'
        [[ -n $token ]] || break
    done
    EL_VOICE_LIST=$(grep . <<< "$all" | sort -t $'\t' -k 2,2f)
    [[ -n $EL_VOICE_LIST ]] || { EL_ERROR="Your ElevenLabs library has no voices."; return 1; }
}

# el_find_voice NAME_OR_ID  - put the ID and name of the library voice with
# that ID or name (any case) in EL_FOUND_ID and EL_FOUND_NAME.
el_find_voice() {
    local want=$1 found
    EL_FOUND_ID="" EL_FOUND_NAME=""
    el_voices || return 1
    found=$(awk -F'\t' -v w="$want" '
        $1 == w { print $1 "\t" $2; found = 1; exit }
        tolower($2) == tolower(w) && n == "" { n = $1 "\t" $2 }
        END { if (!found && n != "") print n }
    ' <<< "$EL_VOICE_LIST")
    [[ -n $found ]] || { EL_ERROR="There is no voice called \"$want\" in your ElevenLabs library."; return 1; }
    IFS=$'\t' read -r EL_FOUND_ID EL_FOUND_NAME <<< "$found"
}

# Put "model_id<TAB>name<TAB>credits per character" lines for each text to
# speech model the account can use in EL_MODEL_LIST.
el_models() {
    EL_MODEL_LIST=""
    el_get /v1/models || return 1
    EL_MODEL_LIST=$(perl -MJSON::PP -0777 -ne '
        for my $m (@{ JSON::PP::decode_json($_) }) {
            next unless $m->{can_do_text_to_speech};
            my $r = $m->{model_rates} || {};
            my $c = ($r->{character_cost_multiplier} // 1) * ($r->{cost_discount_multiplier} // 1);
            print "$m->{model_id}\t", ($m->{name} // $m->{model_id}), "\t", $c + 0, "\n";
        }
    ' <<< "$EL_BODY") || { EL_ERROR="Could not read the model list from ElevenLabs."; return 1; }
}

# Put this billing period's used and total credits in EL_CREDITS_USED and
# EL_CREDITS_LIMIT. Fails if the key may not read the subscription.
el_credits() {
    EL_CREDITS_USED="" EL_CREDITS_LIMIT=""
    el_get /v1/user/subscription || return 1
    read -r EL_CREDITS_USED EL_CREDITS_LIMIT < <(perl -MJSON::PP -0777 -ne '
        my $j = JSON::PP::decode_json($_);
        print(($j->{character_count} // 0), " ", ($j->{character_limit} // 0), "\n");
    ' <<< "$EL_BODY")
    [[ $EL_CREDITS_LIMIT =~ ^[0-9]+$ ]]
}

# el_tts TEXT OUT [VOICE_ID]  - write TEXT spoken by ElevenLabs to OUT as
# raw 8 kHz 16-bit PCM.
el_tts() {
    local text=$1 out=$2 voice=${3:-$EL_VOICE_ID} body rc=0
    body=$(mktemp) || return 1
    # language_code is only sent to the models that take it.
    local lang=""
    [[ $EL_MODEL_ID =~ ^eleven_(v4|v3|flash_v2_5|turbo_v2_5) ]] && lang=$EL_LANGUAGE
    TEXT=$text MODEL=$EL_MODEL_ID LANG_CODE=$lang SPEED=$EL_SPEED \
        STAB=${EL_STABILITY:-} SIM=${EL_SIMILARITY:-} perl -MJSON::PP -e '
        my %b = (text => $ENV{TEXT}, model_id => $ENV{MODEL});
        $b{language_code} = $ENV{LANG_CODE} if $ENV{LANG_CODE} ne "";
        my %s;
        $s{speed} = $ENV{SPEED} + 0 if $ENV{SPEED} ne "";
        $s{stability} = $ENV{STAB} + 0 if $ENV{STAB} ne "";
        $s{similarity_boost} = $ENV{SIM} + 0 if $ENV{SIM} ne "";
        $b{voice_settings} = \%s if %s;
        print JSON::PP->new->canonical->encode(\%b);
    ' > "$body" || { rm -f -- "$body"; EL_ERROR="Could not build the request."; return 1; }
    el_request POST "/v1/text-to-speech/$voice?output_format=pcm_8000" "$out" "$body" || rc=1
    rm -f -- "$body"
    return $rc
}

# el_pcm_to_ulaw IN OUT  - trim, level and encode 8 kHz 16-bit PCM as
# u-law. Done in perl, which is quicker than starting ffmpeg twice (to
# measure, then to change the level) for every one of thousands of node
# names:
#   - samples quieter than EL_SILENCE dBFS are trimmed from both ends
#   - the gain that brings the RMS level of the rest to EL_TARGET_RMS dBFS
#     is applied; peaks above 0.7 are softly limited to 0.891 (-1 dBFS)
#   - each sample is encoded as G.711 u-law
el_pcm_to_ulaw() {
    local in=$1 out=$2 rc=0
    perl -e '
        use strict; use warnings;
        my ($target, $silence) = @ARGV[0, 1];
        binmode STDIN; binmode STDOUT;
        local $/; my $raw = <STDIN> // "";
        my @s = unpack("s<*", $raw);
        my $th = 32768 * 10 ** ($silence / 20);
        my ($a, $b) = (0, $#s);
        $a++ while $a <= $b && abs($s[$a]) < $th;
        $b-- while $b >= $a && abs($s[$b]) < $th;
        exit 3 if $a > $b;
        my $sum = 0; $sum += $_ * $_ for @s[$a .. $b];
        my $gain = 10 ** ($target / 20) / (sqrt($sum / ($b - $a + 1)) / 32768);
        my ($k, $l) = (0.7, 0.891);
        my $out = "";
        for my $x (@s[$a .. $b]) {
            my $v = $x / 32768 * $gain;
            my $m = abs $v;
            if ($m > $k) { my $e = exp(2 * ($m - $k) / ($l - $k)); $m = $k + ($l - $k) * ($e - 1) / ($e + 1) }
            my $n = int($m * 32768 + 0.5);
            $n = 32635 if $n > 32635;
            $n += 0x84;
            my $exp = 7;
            for (my $mask = 0x4000; ($n & $mask) == 0 && $exp > 0; $mask >>= 1) { $exp-- }
            $out .= chr(~(($v < 0 ? 0x80 : 0) | ($exp << 4) | (($n >> ($exp + 3)) & 0x0F)) & 0xFF);
        }
        print $out;
    ' -- "$EL_TARGET_RMS" "${EL_SILENCE%dB}" < "$in" > "$out" || rc=$?
    case $rc in
        0) [[ -s $out ]] && return 0; EL_ERROR="No audio was made." ;;
        3) EL_ERROR="The audio from ElevenLabs had no speech in it." ;;
        *) EL_ERROR="The audio from ElevenLabs could not be converted." ;;
    esac
    return 1
}

# el_render TEXT OUT [VOICE_ID]  - speak TEXT into OUT (8 kHz u-law).
el_render() {
    local text=$1 out=$2 voice=${3:-} pcm rc=0
    pcm=$(mktemp) || { EL_ERROR="Could not create a temporary file."; return 1; }
    el_tts "$text" "$pcm" $voice && el_pcm_to_ulaw "$pcm" "$out" || rc=1
    rm -f -- "$pcm"
    return $rc
}

# el_count N WORD  - print "N WORD", with an "s" unless N is 1.
el_count() {
    if [[ $1 == 1 ]]; then echo "$1 $2"; else echo "$1 ${2}s"; fi
}

# el_cost_report CHARACTERS  - print how many credits CHARACTERS will use
# with the configured model, and how many are left, as far as the API key
# lets us find out.
el_cost_report() {
    local chars=$1 rate="" credits
    el_models 2> /dev/null && rate=$(awk -F'\t' -v m="$EL_MODEL_ID" '$1 == m { print $3; exit }' <<< "$EL_MODEL_LIST")
    if [[ -n $rate ]]; then
        credits=$(awk -v c="$chars" -v r="$rate" 'BEGIN { printf "%d", c * r + 0.5 }')
        echo "That is about $(el_count "$chars" character), or $(el_count "$credits" credit) with $EL_MODEL_ID."
    else
        echo "That is about $(el_count "$chars" character)."
    fi
    if el_credits 2> /dev/null && (( EL_CREDITS_LIMIT > 0 )); then
        echo "Your account has $((EL_CREDITS_LIMIT - EL_CREDITS_USED)) of $(el_count "$EL_CREDITS_LIMIT" credit) left this billing period."
    fi
}

export -f el_error_message el_error_status el_request el_tts el_pcm_to_ulaw el_render
