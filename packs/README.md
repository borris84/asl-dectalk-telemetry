# Prebuilt node name voice packs

Making every node name announcement with ElevenLabs takes hours and tens
of thousands of credits. These packs hold them ready-made, in four
ElevenLabs default voices, together with the telemetry prompts in the same
voice, so a node can download them instead, with no API key of its own. A
node with a key, even a free one, then only needs it for its own
announcements.

| Pack | Voice | Accent |
| --- | --- | --- |
| `callum` | Callum - Husky Trickster | American, male |
| `sarah` | Sarah - Mature, Reassuring, Confident | American, female |
| `daniel` | Daniel - Steady Broadcaster | British, male |
| `alice` | Alice - Clear, Engaging Educator | British, female |

All use `eleven_v4_turbo` at speed 1.2. Call signs are spelled out,
without the node number (`-P` and `-i` are not in the packs).

## How a pack is stored

Each pack is a GitHub release, tagged `pack-NAME`, with these assets:

- `pack.conf`: the voice and settings every announcement was made with
  (the same as `NAME.conf` here).
- `index.tsv`: one line per announcement, `md5<TAB>text<TAB>archive`. The
  text is what `write_node_callsigns_elevenlabs.sh -T` says a call sign
  field is spoken as, and the md5 is of that text.
- `base.tar.xz`: the first full build, as `<md5>.ulaw` files.
- `delta-<time>.tar.xz`: announcements added later.
- `telemetry.tar.xz`: the telemetry prompts in `elevenlabs-prompt-list.txt`,
  laid out like `/usr/share/asterisk/sounds/custom` (`digits/0.ul` and so
  on), with the `.elevenlabs-prompts` manifest that
  `elevenlabs-telemetry.sh` keeps. A node with a key and the same voice
  settings sees them as up to date and makes none of them again.
- `telemetry.tsv`: a copy of that manifest, to check for changes without
  downloading the archive.

There is one file per distinct text, not one per node: nodes with the same
call sign share it, so a node is added by hard-linking `NODE.ulaw` to its
text's file. A new node with a known call sign needs nothing new.

## Keeping the packs up to date

`.github/workflows/voice-packs.yml` runs every day. It downloads the
AllStarLink node list, makes the announcements each published pack lacks
(using the `ELEVENLABS_API_KEY` repository secret), and uploads them as a
delta archive. Once a pack has more than 30 delta archives, they are merged
into one. It also remakes any telemetry prompt that is new or whose text
changed, and runs when `elevenlabs-prompt-list.txt` changes on main.

## Building a pack

```sh
packs/pack-tool.sh texts /var/lib/asterisk > texts.tsv
packs/pack-tool.sh init packs/sarah.conf work/sarah
packs/pack-tool.sh render work/sarah texts.tsv
packs/pack-tool.sh publish work/sarah
packs/pack-tool.sh telemetry work/sarah
```

`import` takes announcements that were already made with the pack's exact
settings from a node name folder instead of making them again, and
`telemetry -i /usr/share/asterisk/sounds/custom` does the same for
telemetry prompts. Run
`packs/pack-tool.sh` with no arguments for all the commands.
