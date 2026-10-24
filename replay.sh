#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Usage: replay.sh <game> <name>
# Restore the recording's save, launch the game, replay its input, then close
# the game and put the player's own save back.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/games.sh"

USAGE="usage: replay.sh <game> <name>"
GAME=${1:?$USAGE}
NAME=${2:?$USAGE}

game_config "$GAME" || { echo "unknown game: $GAME (see games.sh)"; exit 1; }
LIB=$(steam_library_of "$APPID") || { echo "app $APPID not found in any Steam library"; exit 1; }
SAVE="$LIB/steamapps/compatdata/$APPID/pfx/drive_c/users/steamuser/$SAVE_REL"
REC="${RECORDINGS:-$HERE/recordings}/$GAME/$NAME"

for f in save devices.json events.tsv.gz meta.json; do
	[[ -e "$REC/$f" ]] || { echo "missing $REC/$f"; exit 1; }
done
pgrep -x steam >/dev/null || { echo "start Steam first"; exit 1; }
if pgrep -f "$PROC" >/dev/null; then
	echo "$PROC is running; quit the game first"
	exit 1
fi
if steam_cloud_enabled "$APPID"; then
	echo "Steam Cloud is on for $APPID; turn it off (Properties → General) first"
	exit 1
fi
keep_sudo

# PENDING exists from backup until restore: if a previous run died in between,
# LIVE is the only copy of the player's save and must not be overwritten.
LIVE="${RECORDINGS:-$HERE/recordings}/$GAME/.live-save"
PENDING="$LIVE.pending"
if [[ -e "$PENDING" ]]; then
	echo "a previous replay did not restore the save; your save is in $LIVE"
	echo "copy it back to $SAVE yourself, then delete $PENDING"
	exit 1
fi
mkdir -p "$LIVE"
rsync -a --delete "$SAVE/" "$LIVE/"
touch "$PENDING"
echo "your current save is backed up to $LIVE"

RUN=$(mktemp -d)
REPLAYER=

close_game() {
	pgrep -f "$PROC" >/dev/null || return 0
	pkill -TERM -f "$PROC" || true
	for _ in $(seq 60); do
		pgrep -f "$PROC" >/dev/null || return 0
		sleep 0.5
	done
	pkill -KILL -f "$PROC" || true
	sleep 2
}

finish() {
	# A second Ctrl+C here used to abort the restore and leave PENDING behind.
	trap '' INT TERM HUP
	trap - EXIT
	echo "cleaning up: stopping replay, closing the game, restoring your save — please wait"
	if [[ -n "$REPLAYER" && -s "$RUN/ready" ]]; then
		sudo -n kill -TERM "$(cat "$RUN/ready")" 2>/dev/null || true
		wait "$REPLAYER" 2>/dev/null || true
	fi
	close_game
	rsync -a --delete "$LIVE/" "$SAVE/"
	rm -f "$PENDING"
	echo "restored your save"
	kill "$SUDO_KEEPER" 2>/dev/null || true
}
trap finish INT TERM HUP EXIT

rsync -a --delete "$REC/save/" "$SAVE/"

sudo python3 "$HERE/evrec.py" replay "$REC" --ready "$RUN/ready" --launched "$RUN/launched" &
REPLAYER=$!

for _ in $(seq 100); do
	[[ -s "$RUN/ready" ]] && break
	sleep 0.1
done
[[ -s "$RUN/ready" ]] || { echo "replayer did not start"; exit 1; }

launch_game "$APPID" > "$RUN/launched.tmp"
mv "$RUN/launched.tmp" "$RUN/launched"

DUR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["duration_s"])' "$REC/meta.json")
echo "replaying $GAME/$NAME for ${DUR}s — don't touch the keyboard or mouse (Ctrl+C here to abort)"
wait "$REPLAYER" || true
REPLAYER=
echo "replay finished"
