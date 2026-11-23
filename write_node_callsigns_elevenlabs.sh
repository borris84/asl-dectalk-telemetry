#!/bin/bash
# write_node_callsigns_elevenlabs.sh
#
# Copyright (C) 2026 N2DYI
# Licensed under the GNU General Public License, version 2. See LICENSE.
#
# Make the node name announcements with ElevenLabs instead of DECtalk.
# Everything is done by write_node_callsigns_dectalk.sh, which takes the
# same options plus -S and -J; run this with -h for the details.

# readlink -f: find the real script, not a PATH symlink
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
ASL_TELEM_ENGINE=elevenlabs exec bash "$SCRIPT_DIR/write_node_callsigns_dectalk.sh" "$@"
