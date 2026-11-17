# asl-dectalk-telemetry

DECtalk voice telemetry and node name announcements for AllStarLink 3 (ASL3).

Version 0.10

This project replaces the stock ASL3 telemetry voice with DECtalk. It also
builds a spoken announcement for every node in the AllStarLink node
database, so Asterisk says "N 2 D Y I" instead of reading out a node number.

It contains:

| File | What it does |
| --- | --- |
| `install.sh` | Guided installer. Installs DECtalk and the scripts, and configures Asterisk. |
| `dectalk-telemetry.sh` | Generates the telemetry prompts listed in `prompt-list.txt` with DECtalk. |
| `write_node_callsigns_dectalk.sh` | Generates a DECtalk announcement for each node in the ASL node database. |
| `prompt-list.txt` | The telemetry prompts: a sound file name and the text DECtalk speaks for it. |
| `dec-init.cfg` | DECtalk voice settings (speaking rate, pitch and so on) used by both scripts. |

## Requirements

- AllStarLink 3 on Debian (for example the ASL3 Raspberry Pi image)
- Root access
- An internet connection during install
- About 1 GB of free disk space if DECtalk has to be built

**HamVoIP is not supported.** The installer detects HamVoIP and stops.

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
`/usr/local/src/asl-dectalk-telemetry-0.10` and runs from there.

### Install from a copy of the repository

```sh
git clone https://github.com/borris84/asl-dectalk-telemetry.git
cd asl-dectalk-telemetry
sudo ./install.sh
```

## What the installer does

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
   `/usr/local/bin/say` is linked to it. The build can take 10 minutes or
   more on a Raspberry Pi. It is done in `/usr/local/src/dectalk-build`
   because `/tmp` is too small on many Pis, and that folder is removed
   afterwards.
3. **Installs ffmpeg and perl** if they are missing.
4. **Installs the scripts** in `/opt/asl-telem`, with links in
   `/usr/local/bin` so you can run them from anywhere. If you have edited
   `dec-init.cfg` or `prompt-list.txt` since a previous install, it asks
   whether to keep your copy or replace it.
5. **Enables custom sounds** by setting `sounds_search_custom_dir = yes` in
   `/etc/asterisk/asterisk.conf`.
6. **Points node names at the new announcements** by setting
   `nodenames = /usr/share/asterisk/sounds/custom/rpt/nodenames` in the
   `[node-main]` template of `/etc/asterisk/rpt.conf`. Existing node name
   sounds elsewhere are not changed or deleted.
7. **Checks the installation** and lists anything that is wrong.
8. **Offers to generate the sounds.** The telemetry prompts are generated
   first, then the node names (see below for why the order matters).
9. **Offers to restart Asterisk** if a config file was changed. Restarting
   drops any active connections, so you can choose to do it later with
   `systemctl restart asterisk`.

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
sudo write_node_callsigns_dectalk.sh         # later: only new or changed nodes
```

Announcements are saved in `/usr/share/asterisk/sounds/custom/rpt/nodenames`
as `<node>.ulaw`. The node database is read from
`/var/lib/asterisk/astdb.txt` (or `/var/log/asterisk/astdb.txt`). A copy of
it is kept as `previous_astdb.txt` in the same folder, so later runs only
rebuild nodes whose call sign changed.

How the call sign field is spoken:

- Anything shaped like an amateur radio call sign is spelled out:
  `N2DYI` is spoken as "N 2 D Y I".
- A `/` or `-` joined to a call sign is spoken: `KA4EPS/R` is
  "K A 4 E P S slash R".
- `VA` and `VE` prefixes get a short pause after the V so the letters don't
  run together.
- Anything else, such as `FIRESIDE` or `Seattle`, is spoken as a word.
  Asterisks are dropped.

### Options

| Option | Meaning |
| --- | --- |
| `-a` | Process all nodes. Existing files are skipped unless `-r` is given. |
| `-i` | Say the node number after the call sign, for example "N 2 D Y I, node 5 0 6 3 1 1". |
| `-n NODE` | Process one node. |
| `-r` | Regenerate files even if they already exist. |
| `-f` | Don't ask for confirmation before starting. |
| `-v` | Show each node as it is processed. |
| `-j N` | Number of nodes to process at once (default: number of CPU cores). |
| `-d PATH` | Folder to write announcements to. |
| `-s PATH` | Folder that holds `astdb.txt`. |
| `-p PATH` | Where to keep the previous copy of the database. |
| `-o KEY=TEXT` | Override what is spoken for a node. See below. |
| `-t NODE=TEXT` | Speak custom text for a node. See below. |
| `-h` | Show help. |

### Overriding a node's announcement

When several nodes share a call sign, they all sound the same. `-o` replaces
the call sign field from the database before it is spoken, so you can tell
them apart. The text is still handled like a call sign field, so call signs
in it are spelled out.

```sh
# Every node with call sign N2DYI
sudo write_node_callsigns_dectalk.sh -o "N2DYI=N2DYI repeater"

# Just node 506311 (this wins over the call sign override above)
sudo write_node_callsigns_dectalk.sh -o "506311=N2DYI hub" -o "N2DYI=N2DYI repeater"
```

`-t` speaks the text exactly as written, with no call sign spelling.
DECtalk commands such as `[:ra 200]` can be used in it.

```sh
sudo write_node_callsigns_dectalk.sh -t "1999=the lab node"
```

Notes:

- `-o` and `-t` can be given more than once.
- `-t` wins over `-o` for the same node.
- `-o NODE=` and `-t` also work for nodes that aren't in the database, such
  as private nodes.
- Nodes with an override are regenerated every time the script runs.
- Overrides aren't saved. Give them each time you run the script, or put
  the command in a cron job (below).
- After removing an override, rebuild that node with `-n NODE -r`.
- The text can't contain `|`.

### Keeping node names up to date

ASL3 updates `astdb.txt` regularly. To pick up new and changed nodes,
run the script from cron, for example every night at 3:00. Edit root's
crontab with `sudo crontab -e` and add:

```text
0 3 * * * /usr/local/bin/write_node_callsigns_dectalk.sh -f
```

Add any `-i`, `-o` or `-t` options you use to the same line.

## Changing the voice

`/opt/asl-telem/dec-init.cfg` holds DECtalk commands that are put in front
of every prompt and announcement. The default is:

```text
[:phoneme on] [:ra 350] [:dv ap 100] [:dv sr 60 pr 60]
```

`[:ra 350]` is the speaking rate in words per minute, and the `[:dv ...]`
commands set the voice's pitch and stress. See the DECtalk documentation in
`/opt/dectalk/doc` for all the commands. After changing it, regenerate
everything:

```sh
sudo dectalk-telemetry.sh
sudo write_node_callsigns_dectalk.sh -a -r
```

## Uninstalling

Remove what the installer added:

```sh
sudo rm -f /usr/local/bin/dectalk-telemetry.sh /usr/local/bin/write_node_callsigns_dectalk.sh
sudo rm -rf /opt/asl-telem
```

Then, if you no longer want them:

- Restore `/etc/asterisk/rpt.conf` and `/etc/asterisk/asterisk.conf` from
  their `.bak-<date-time>` copies, or comment out the `nodenames` and
  `sounds_search_custom_dir` lines.
- Remove the generated sounds in `/usr/share/asterisk/sounds/custom`.
- Remove DECtalk: `sudo rm -rf /opt/dectalk /usr/local/bin/say`.

Restart Asterisk afterwards with `sudo systemctl restart asterisk`.

## Credits

- `write_node_callsigns_dectalk.sh` is based on `write_node_callsigns.sh`
  by N5LSN, updated by Jory A. Pratt
  (<https://github.com/hardenedpenguin/asl-misc-scripts>).
- DECtalk source code: <https://github.com/dectalk/dectalk>.
