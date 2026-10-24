#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Usage: record.sh <game> <name> <minutes>
# Snapshot the save, then record input from the moment the game is launched.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/games.sh"

USAGE="usage: record.sh <game> <name> <minutes>"
GAME=${1:?$USAGE}
NAME=${2:?$USAGE}
MINUTES=${3:?$USAGE}
[[ "$MINUTES" =~ ^[1-9][0-9]*$ ]] || { echo "minutes must be a positive integer: $MINUTES"; exit 1; }

game_config "$GAME" || { echo "unknown game: $GAME (see games.sh)"; exit 1; }
LIB=$(steam_library_of "$APPID") || { echo "app $APPID not found in any Steam library"; exit 1; }
SAVE="$LIB/steamapps/compatdata/$APPID/pfx/drive_c/users/steamuser/$SAVE_REL"
OUT="${RECORDINGS:-$HERE/recordings}/$GAME/$NAME"

[[ -d "$SAVE" ]] || { echo "save dir not found: $SAVE"; exit 1; }
[[ ! -e "$OUT" ]] || { echo "already exists: $OUT"; exit 1; }
pgrep -x steam >/dev/null || { echo "start Steam first"; exit 1; }
if pgrep -f "$PROC" >/dev/null; then
	echo "$PROC is running; quit the game first so the save is not mid-write"
	exit 1
fi

# Cloud sync at launch can swap in a different save than the snapshot taken here.
if steam_cloud_enabled "$APPID"; then
	echo "Steam Cloud is on for $APPID; turn it off (Properties → General) first"
	exit 1
fi
keep_sudo
trap 'kill "$SUDO_KEEPER" 2>/dev/null || true' EXIT

mkdir -p "$OUT"
cp -a "$SAVE" "$OUT/save"
echo "save snapshot: $(du -sh "$OUT/save" | cut -f1)"

READY="$OUT/.recorder_pid"
sudo python3 "$HERE/evrec.py" record "$OUT" --duration $((MINUTES * 60)) \
	--ready "$READY" --owner "$(id -u):$(id -g)" &
REC=$!
# Background jobs of a non-interactive shell ignore SIGINT, so forward Ctrl+C by hand.
trap 'sudo -n kill -INT "$(cat "$READY")" 2>/dev/null || true' INT TERM HUP

for _ in $(seq 100); do
	[[ -s "$READY" ]] && break
	sleep 0.1
done
[[ -s "$READY" ]] || { echo "recorder did not start"; exit 1; }

T0=$(launch_game "$APPID")

cat > "$OUT/meta.json" <<JSON
{
  "game": "$GAME",
  "appid": $APPID,
  "launch_monotonic_ns": $T0,
  "duration_s": $((MINUTES * 60)),
  "date": "$(date -Iseconds)",
  "kernel": "$(uname -r)",
  "sched_ext": "$(cat /sys/kernel/sched_ext/state 2>/dev/null) $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || true)"
}
JSON

cat > "$OUT/notes.md" <<'MD'
- 起點：
- 操作：
- 卡頓：
MD

echo "recording for $MINUTES min, stops automatically (Ctrl+C here to stop early)"
# wait returns early when the trap fires; wait again for the recorder to flush.
wait $REC || wait $REC || true
# Ctrl+C may have cut the recording short; replay holds for duration_s.
python3 - "$OUT/meta.json" "$T0" <<'PY'
import json, sys, time
p, t0 = sys.argv[1], int(sys.argv[2])
m = json.load(open(p))
m["duration_s"] = min(m["duration_s"], (time.clock_gettime_ns(time.CLOCK_MONOTONIC) - t0) // 1_000_000_000)
json.dump(m, open(p, "w"), indent=2)
PY
rm -f "$READY"
echo "done: $OUT  — fill in notes.md"
