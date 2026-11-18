# asl-dectalk-telemetry

DECtalk voice telemetry and node name announcements for AllStarLink 3 (ASL3).

Version 0.17

This project replaces the stock ASL3 telemetry voice with DECtalk. It also
builds a spoken announcement for every node in the AllStarLink node
database, so Asterisk says "N2DYI" instead of reading out a node number.

It contains:

| File | Purpose |
| --- | --- |
| `install.sh` | Guided installer. Installs DECtalk and the scripts, and configures Asterisk. |
| `dectalk-telemetry.sh` | Generates the telemetry prompts listed in `prompt-list.txt` with DECtalk. This is a minimal prompt list, only what is necessary for app_rpt, not the full set from Asterisk. |
| `write_node_callsigns_dectalk.sh` | Generates a DECtalk announcement for each node in the ASL node database. |
| `prompt-list.txt` | The telemetry prompts: a sound file name and the text DECtalk speaks for it. |
| `dec-init.cfg` | DECtalk voice settings (speaking rate, pitch and so on) used by both scripts. |
| `node-overrides.conf` | Your saved node announcement overrides (empty to start with). |

## Requirements

- AllStarLink 3 on Debian (for example the ASL3 Raspberry Pi image)
- Root access
- An internet connection during install
- About 500 MB of free disk space if DECtalk has to be built

**HamVoIP is not supported.** The installer detects HamVoIP and stops.
It is not recommended to run these scripts on highly customized commercial products, like Clear Node. If it breaks, you keep the pieces.

## Why this project exists:
I have been a long-time user of Asterisk PBX, since around 2005 or so, long before finding the world of Allstarlink. I was never a fan of the stock Allison voice. Not the cadence, not the tone, etc.
This followed me to Allstarlink.org.

As a full-time user of text-to-speech technology with screen readers, I wanted something that would speak telemetry much faster, while also still being very clear to understand, just for my own personal use.

On the first node I built, I compiled a vocabulary list consisting of all the core phrases needed by app_rpt, and some extras required by HamVoIP, then wrote a script that rendered all that using a formant text-to-speech synthesizer (Macintalk Fred) at a very high speaking rate, combined with a script to speak call signs instead of node numbers, which simply concatenated files together.
This is what I used for years, but it wasn't particularly portable or easy to manage, especially with HamVoIP's way of doing things.
A few other hams wanted my configuration, but it wasn't as easy as saying "just unzip some files here". As much as I dislike Allison, I equally dislike the sound of GSM audio compression, and HamVoIP used that format for all sound files. Not only that, but it had many built-in scripts that were hard-coded to look specifically for GSM files.
Doing package updates would knock out my custom sounds, and undo all the find/replacing I did on the script tree.

Thanks to ASL3's use of a much more modern version of Asterisk, which supports a custom sounds directory, none of that is necessary anymore, and we can have a TTS generate standard app_rpt telemetry at any desired speaking rate, plus readout of call signs as single utterances rather than concatenating a bunch of tiny files together, which sounds less natural than trying to speed up the existing Allison voice, which I have tried doing several different ways, none of which were to my satisfaction.

I'm using DECtalk in this project because it's small, light-weight, local, and runs on pretty much anything, but this script could be adapted to use other TTS options, like Elevenlabs.

Yes, ASL does have it's own text-to-speech option, which uses Piper, but I'm not really a fan of most of the available Piper voices, plus it takes much, much longer to generate sounds using it, especially on low-end and modest hardware, for a result that is, in my opinion, not nearly as good as what can be achieved with a Klatt formant synth, so I opted not to use it here.
Piper itself can produce good results, but finding well--trained voices is hard. Almost nothing available publicly is done well enough for me. I'm very picky about speech.

## Install

Run this one line as root, or as a user who can use `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/borris84/asl-dectalk-telemetry/main/install.sh | sudo bash
```

If you are already logged in as root, you can leave out `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/borris84/asl-dectalk-telemetry/main/install.sh | bash
```

The installer downloads the release files to
`/usr/local/src/asl-dectalk-telemetry-0.17` and runs from there.

### Install from a copy of the repository

```sh
git clone https://github.com/borris84/asl-dectalk-telemetry.git
cd asl-dectalk-telemetry
sudo ./install.sh
```

## Upgrading

To upgrade an existing install to the latest version without changing
anything else, run:

```sh
curl -fsSL https://raw.githubusercontent.com/borris84/asl-dectalk-telemetry/main/install.sh | sudo bash -s -- --upgrade
```

If you are already logged in as root, you can leave out `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/borris84/asl-dectalk-telemetry/main/install.sh | bash -s -- --upgrade
```

Or, from a copy of the repository, `sudo ./install.sh --upgrade`.

An upgrade:

- replaces the scripts in `/opt/asl-telem`
- asks whether to keep your copy of `dec-init.cfg` or `prompt-list.txt` if
  you have edited them
- keeps your `node-overrides.conf`
- doesn't install packages, change the Asterisk config, or generate any
  sounds

It stops if nothing is installed yet. When it finishes, it lists anything
that isn't set up, for example a setting added in a newer version. Run the
installer without `--upgrade` to set those up; it skips everything that is
already done.

Existing sounds aren't changed by an upgrade. To use changes in the new
version, regenerate them (see
[Generating the node name announcements](#generating-the-node-name-announcements)).

## How the installer works

The installer asks before each change. It answers most questions with a
default when you press Enter. Every config file it edits is backed up first
as `<file>.bak-<date-time>`. You can run it again at any time; finished
steps are detected and skipped.

1. **Checks the system.** It must be run as root, on ASL3, and not on
   HamVoIP.
2. **Installs DECtalk** if `/usr/local/bin/say` is missing or doesn't work.
   DECtalk is downloaded from <https://github.com/dectalk/dectalk> and
   built for the machine it runs on (for example arm64 on a Raspberry Pi 4
   or 5, or amd64 on a PC). It is installed in `/opt/dectalk`, and
   `/usr/local/bin/say` is linked to it. Only US English is built, which
   takes a minute or two on a Raspberry Pi. It is done in `/usr/local/src/dectalk-build`
   because `/tmp` is too small on many Pis, and that folder is removed
   afterwards.
3. **Installs ffmpeg and perl** if they are missing.
4. **Turns on automatic node database updates** so that
   `/var/lib/asterisk/astdb.txt` exists and stays current (see
   [The node database](#the-node-database-astdbtxt)).
5. **Installs the scripts** in `/opt/asl-telem`, with links in
   `/usr/local/bin` so you can run them from anywhere. If you have edited
   `dec-init.cfg` or `prompt-list.txt` since a previous install, it asks
   whether to keep your copy or replace it. Your `node-overrides.conf` is
   never replaced.
6. **Sets the speaking rate** in `dec-init.cfg` (see
   [Changing the voice](#changing-the-voice)). You can hear a preview first:
   it is played on a node on this system with `rpt localplay`, like any
   other announcement, so it is transmitted if the node has a radio. If
   there are several nodes in `/etc/asterisk/rpt.conf`, you choose one.
   After the preview you can play it again, try another rate, or keep it.
7. **Enables custom sounds** by setting `sounds_search_custom_dir = yes` in
   `/etc/asterisk/asterisk.conf`.
8. **Points node names at the new announcements** by setting
   `nodenames = /usr/share/asterisk/sounds/custom/rpt/nodenames` in the
   `[node-main]` template of `/etc/asterisk/rpt.conf`. Existing node name
   sounds elsewhere are not changed or deleted.
9. **Checks the installation** and lists anything that is wrong.
10. **Offers to generate the sounds.** The telemetry prompts are generated
    first, then the node names (see below for why the order matters).
11. **Offers to restart Asterisk** if a config file was changed. Restarting
    drops any active connections, so you can choose to do it later with
    `systemctl restart asterisk`.

## The node database (astdb.txt)

`write_node_callsigns_dectalk.sh` reads each node's call sign from
`/var/lib/asterisk/astdb.txt`. ASL3 downloads this file from AllStarLink
with the `asl3-update-astdb` service and timer, part of the
`asl3-update-nodelist` package. **Both are turned off by default.**

The installer turns them on for you. To do it by hand, as described in the
`asl3-update-astdb` man page (`man asl3-update-astdb`):

```sh
sudo systemctl enable asl3-update-astdb.service
sudo systemctl enable asl3-update-astdb.timer
sudo systemctl start asl3-update-astdb.timer
```

The timer then downloads the file at every boot and every 6 hours. To
download it right away:

```sh
sudo systemctl start asl3-update-astdb.service
```

To check that the timer is running and see when it runs next:

```sh
systemctl list-timers asl3-update-astdb.timer
```

Private nodes (such as 1000 to 1999) aren't in the AllStarLink database.
To give them a call sign, add them to `/etc/asterisk/privatenodes.txt`, one
per line in the same `node|callsign|frequency|location` format as
`astdb.txt`. `asl3-update-astdb` adds them to `astdb.txt` on every update.
You can also give a private node an announcement with an override (below).

## Generating the telemetry prompts

```sh
sudo dectalk-telemetry.sh
```

Each prompt in `/opt/asl-telem/prompt-list.txt` is spoken by DECtalk and
saved as 8 kHz u-law in `/usr/share/asterisk/sounds/custom/<name>.ul`, with
silence trimmed from both ends.

If the custom sounds folder already has files in it, the script asks whether
to rename it, delete it, use it (overwriting matching files), or quit.

**Run this before `write_node_callsigns_dectalk.sh`.** The node name
announcements are stored inside the custom sounds folder, so renaming or
deleting it here also removes them.

### Editing the prompts

Each line of `prompt-list.txt` is a file name, a colon, and the text to
speak:

```text
digits/0: zero
rpt/connected: connected
```

The file name is relative to `/usr/share/asterisk/sounds/custom` and has no
extension. Blank lines and lines starting with `#` are ignored. Run
`dectalk-telemetry.sh` again after editing.

## Generating the node name announcements

```sh
sudo write_node_callsigns_dectalk.sh -a      # first time: every node
sudo write_node_callsigns_dectalk.sh         # later: only new or changed nodes, probably what you want on a crontab if the node list gets refreshed every so often
```

Announcements are saved in `/usr/share/asterisk/sounds/custom/rpt/nodenames`
as `<node>.ulaw`. The node database is read from
`/var/lib/asterisk/astdb.txt` (or `/var/log/asterisk/astdb.txt`). A copy of
it is kept as `previous_astdb.txt` in the same folder, so later runs only
rebuild nodes whose call sign changed.

Many call signs have several nodes. Nodes that say exactly the same thing
share one announcement: it is made once, and the other nodes' files are
hard links to it. Without `-i` this roughly halves the time of a full run
and the disk space used. With `-i` every announcement is different, so
nothing is shared. If you copy the folder somewhere, use `cp -a` or
`rsync -aH` to keep the sharing; other copies work but take the full space.

How the call sign field is spoken:

- Anything shaped like an amateur radio call sign is spelled out:
  `N2DYI` is spoken as "N 2 D Y I".
- A `/` or `-` joined to a call sign is spoken: `KA4EPS/R` is
  "K A 4 E P S slash R".
- `VA` and `VE` prefixes get a short pause after the V so the letters don't
  run together.
- Anything else, such as `FIRESIDE` or `Seattle`, is spoken as a word.
  Asterisks are dropped.

### Phonetic call signs

With `-P`, call signs are spoken with the phonetic alphabet instead of
letters. There is a short pause between items, and the last one falls in
pitch so the announcement sounds finished:

| Call sign field | Spoken as |
| --- | --- |
| `N2DYI` | November, 2, Delta, Yankee, India. |
| `KA4EPS/R` | Kilo, Alfa, 4, Echo, Papa, Sierra, slash R. |
| `VA2RXP-25` | Victor, Alfa, 2, Romeo, X-ray, Papa, dash, 25. |

- Only call signs are spoken phonetically. Other text, such as `FIRESIDE`,
  is spoken as before.
- A short suffix joined to a call sign by `/` or `-` is spoken as part of
  it, except `/R`. That marks a repeater and isn't part of the call, so it
  is spoken as "slash R".
- `-P` works with `-i`: "November, 2, Delta, Yankee, India. Node 5 0 6 3 1 1".
- Papa and Delta are written as DECtalk phonemes, so that they are said
  "pah-PAH" (not "poppa") and "DELL-tah" (not "delda").
- To make just one node phonetic, see
  [Making one node phonetic](#making-one-node-phonetic).
- The pause is DECtalk's comma pause, which you can change with the
  `[:comma ...]` command in `dec-init.cfg` (see
  [Changing the voice](#changing-the-voice)).

### Options

| Option | Meaning |
| --- | --- |
| `-a` | Process all nodes. Existing files are skipped unless `-r` is given. |
| `-i` | Say the node number after the call sign, for example "N 2 D Y I, node 5 0 6 3 1 1". |
| `-P` | Speak call signs phonetically. See [Phonetic call signs](#phonetic-call-signs). |
| `-n NODE` | Process one node. |
| `-r` | Regenerate files even if they already exist. |
| `-f` | Don't ask for confirmation before starting. |
| `-v` | Show each node as it is processed. |
| `-j N` | Number of nodes to process at once (default: number of CPU cores). |
| `-d PATH` | Folder to write announcements to. |
| `-s PATH` | Folder that holds `astdb.txt`. |
| `-p PATH` | Where to keep the previous copy of the database. |
| `-o KEY=TEXT` | Save an override of what is spoken for a node or call sign. See below. |
| `-t NODE=TEXT` | Save custom text for a node. See below. |
| `-m KEY=WORDS` | Save a mode that turns `-P` or `-i` on or off for one node or call sign. See below. |
| `-x KEY` | Remove the saved override for a node or call sign. |
| `-l` | List the saved overrides. |
| `-c PATH` | Use a different overrides file. |
| `-h` | Show help. |

`-i` and `-P` only affect announcements that are built during that run.
After turning either one on or off, rebuild every announcement:

```sh
sudo write_node_callsigns_dectalk.sh -a -r -P      # for example, to switch to phonetic
```

### Making one node phonetic

To rebuild a single node phonetically, for example node 51018 (W6EK):

```sh
sudo write_node_callsigns_dectalk.sh -n 51018 -r -P
```

Add `-i` if your other announcements include node numbers. Normal runs
leave the node as it is, but it goes back to letters if its call sign
changes in the node database, or if you rebuild everything without `-P`.

To keep it phonetic for good, save a mode for it instead (see
[Per-node modes](#per-node-modes)):

```sh
sudo write_node_callsigns_dectalk.sh -m "51018=phonetic"
```

### Overriding a node's announcement

When several nodes share a call sign, they all sound the same. An override
replaces what is spoken for a node, so you can tell them apart. Overrides
are saved in `/opt/asl-telem/node-overrides.conf` and applied every time the
script runs.

There are three kinds of entry:

- **override** replaces the call sign field from the database. It can be
  for one node number, or for a call sign (every node with that call sign).
  The text is still handled like a call sign field, so call signs in it are
  spelled out.
- **text** speaks the text exactly as written for one node, with no call
  sign spelling. DECtalk commands such as `[:ra 200]` can be used in it.
- **mode** changes how a node is spoken, without changing what is said.
  See [Per-node modes](#per-node-modes).

For the same node, a text entry wins over an override, and a node-number
override or mode wins over a call sign one.

#### Adding overrides from the command line

`-o` and `-t` save the override to the file, then rebuild the nodes it
affects. Both can be given more than once.

```sh
# Every node with call sign N2DYI
sudo write_node_callsigns_dectalk.sh -o "N2DYI=N2DYI repeater"

# Just node 506311 (wins over the call sign override above)
sudo write_node_callsigns_dectalk.sh -o "506311=N2DYI hub"

# Custom text for private node 1999
sudo write_node_callsigns_dectalk.sh -t "1999=the lab node"
```

Giving `-o`, `-t` or `-m` again for the same node or call sign replaces
the saved entry.

#### Per-node modes

A mode turns phonetic call signs (`-P`) and node numbers (`-i`) on or off
for just one node, or for every node with a call sign, every time those
nodes are built. For example, to make node 506311 phonetic, and node 506312
spelled with letters plus its node number:

```sh
sudo write_node_callsigns_dectalk.sh -m "506311=phonetic" -m "506312=letters number"
```

The words are:

| Word | Effect |
| --- | --- |
| `phonetic` | Speak call signs phonetically, as with `-P`. |
| `letters` | Spell call signs with letters, even when `-P` is given. |
| `number` | Add the node number, as with `-i`. |
| `no-number` | Leave out the node number, even when `-i` is given. |

- Use one word from each pair, or one from both. Commas between words are
  optional.
- Anything a mode doesn't mention follows the command line. With
  `mode 506311 = phonetic`, node 506311 gets its node number only when the
  script is run with `-i`.
- A mode works with an `override` or `text` entry for the same node. With a
  `text` entry only `number` and `no-number` matter, because text is
  spoken as written.

#### Listing and removing overrides

```sh
sudo write_node_callsigns_dectalk.sh -l            # list saved overrides
sudo write_node_callsigns_dectalk.sh -x 506311     # remove the override for node 506311
sudo write_node_callsigns_dectalk.sh -x N2DYI      # remove the override for call sign N2DYI
```

`-x` removes every entry (override, text and mode) for that node or call
sign, then rebuilds the affected nodes as they would sound without them. If a node isn't in the
database and its override is removed, its announcement is deleted.

#### Editing the overrides file

You can also edit `/opt/asl-telem/node-overrides.conf` with any text
editor, for example to add many overrides at once:

```sh
sudo nano /opt/asl-telem/node-overrides.conf
```

The format is one entry per line:

```text
# Lines starting with # and blank lines are ignored.
override N2DYI = N2DYI repeater
override 506311 = N2DYI hub
text 1999 = the lab node
text 1998 = the [:ra 200] test node
mode 506311 = phonetic
mode 506312 = letters number
```

- `override KEY = TEXT`: KEY is a node number or a call sign. Call signs
  are matched in any case.
- `text NODE = TEXT`: NODE must be a node number.
- `mode KEY = WORDS`: KEY is a node number or a call sign. WORDS are listed
  in [Per-node modes](#per-node-modes).
- Spaces around `=` are optional.
- TEXT can't contain `|`.
- If the same node or call sign is listed twice, the last line wins.
- A line that doesn't match the format is skipped with a warning.

After saving the file, run the script to apply the changes:

```sh
sudo write_node_callsigns_dectalk.sh
```

Only nodes whose override, text or mode was added, changed or removed are
rebuilt. The
script keeps a copy of the overrides it last applied in
`/var/lib/asterisk/previous_node_overrides.conf` to work this out. A run
with `-n NODE` only rebuilds that node and doesn't update this copy, so the
next full run still applies any other changes.

### Keeping node names up to date

Once node database updates are on (see
[The node database](#the-node-database-astdbtxt)), `astdb.txt` is updated
every 6 hours. To pick up new and changed nodes, run the script from cron,
for example every night at 3:00. Edit root's crontab with
`sudo crontab -e` and add:

```text
0 3 * * * /usr/local/bin/write_node_callsigns_dectalk.sh -f
```

If you use `-i` or `-P`, add them to the same line. Overrides don't need to be
given, because they are read from the overrides file.

## Changing the voice

`/opt/asl-telem/dec-init.cfg` holds DECtalk commands that are put in front
of every prompt and announcement. The default is:

```text
[:phoneme on] [:ra 350] [:dv ap 100] [:dv sr 60 pr 60]
```

`[:ra 350]` is the speaking rate in words per minute, and the `[:dv ...]`
commands set the voice's pitch and stress.

The installer can set the speaking rate for you:

| Choice | Setting | About |
|--------|---------|-------|
| Slowest | `[:ra 180]` | 180 words per minute |
| Slow | `[:ra 250]` | 250 words per minute |
| Normal (default) | `[:ra 350]` | 350 words per minute |
| Faster | `[:ra 350] [:spf 67]` | 520 words per minute |
| Fastest | `[:ra 300] [:spf 50]` | 600 words per minute |
| Custom | `[:ra 75]` to `[:ra 600]` | the rate you enter, 75 to 600 words per minute |

DECtalk drops and slurs sounds above about 350 words per minute.
`[:spf]` speeds up the synthesizer instead: it is the percentage of the
normal amount of audio produced for each 6.4 ms frame (default 100, from 1
to 500). Lower is faster: 67 plays 1.5 times as fast and 50 twice as fast,
without changing the pitch. See the DECtalk documentation in
`/opt/dectalk/doc` for all the commands. After changing it, regenerate
everything:

```sh
sudo dectalk-telemetry.sh
sudo write_node_callsigns_dectalk.sh -a -r
```

## Uninstalling

Remove what the installer added. This also deletes your
`node-overrides.conf`, so copy it somewhere first if you want to keep it.

```sh
sudo rm -f /usr/local/bin/dectalk-telemetry.sh /usr/local/bin/write_node_callsigns_dectalk.sh
sudo rm -rf /opt/asl-telem
sudo rm -f /var/lib/asterisk/previous_astdb.txt /var/lib/asterisk/previous_node_overrides.conf
```

Then, if you no longer want them:

- Restore `/etc/asterisk/rpt.conf` and `/etc/asterisk/asterisk.conf` from
  their `.bak-<date-time>` copies, or comment out the `nodenames` and
  `sounds_search_custom_dir` lines.
- Remove the generated sounds in `/usr/share/asterisk/sounds/custom`.
- Remove DECtalk: `sudo rm -rf /opt/dectalk /usr/local/bin/say`.
- Turn off node database updates, if nothing else uses them (Supermon and
  AllScan do):
  `sudo systemctl disable --now asl3-update-astdb.timer asl3-update-astdb.service`.

Restart Asterisk afterwards with `sudo systemctl restart asterisk`.

## Credits

- `write_node_callsigns_dectalk.sh` is based on `write_node_callsigns.sh`
  by N5LSN, updated by Jory A. Pratt
  (<https://github.com/hardenedpenguin/asl-misc-scripts>).
- DECtalk source code: <https://github.com/dectalk/dectalk>.

## License

Copyright (C) 2026 N2DYI

Licensed under the GNU General Public License, version 2. See
[LICENSE](LICENSE). `write_node_callsigns_dectalk.sh` is based on a
GPL-2.0 script, so the whole project uses the same license.

DECtalk itself is not part of this project. The installer downloads it
from its own repository, and its own terms apply.
