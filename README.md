# game-workload-recorder

Records keyboard/mouse input starting from the moment a game is **launched**, together
with a snapshot of the save taken right before, so automated experiments can replay it.
The game runs normally during replay and produces the load itself; this tool only
guarantees "the same starting point + the same input".

## Requirements

```sh
sudo dnf install python3-libevdev
```

Steam must already be running. Recording and replay both need `sudo` (reading
`/dev/input`, creating uinput devices).

## Recording

```sh
./record.sh <game> <name> <minutes>
# e.g. ./record.sh eldenring boss1 30
```

1. Checks that the game is not running (the save may still be being written)
2. Snapshots the whole save directory into `recordings/<game>/<name>/save/`
3. Launches the game with `steam -applaunch` right after the recorder starts, so time 0
   of the recording is the moment the game was launched
4. Stops automatically after `<minutes>` minutes; Ctrl+C stops early
5. Fill in `notes.md` afterwards

Output (`recordings/` is not tracked by git; override the location with `RECORDINGS=...`):

```
recordings/<game>/<name>/
  save/            # save snapshot taken before recording
  devices.json     # recorded input devices (replay creates uinput devices from this)
  events.tsv.gz    # monotonic_ns  dev  type  code  value
  meta.json        # launch time, kernel, sched_ext state at the time
  notes.md         # starting point, what was done, when it felt stuttery
```

### Recording notes

- **Turn Steam Cloud off** (game Properties → General): `record.sh` checks Steam's
  `sharedconfig.vdf` and refuses to record otherwise. Cloud sync at launch can swap the
  save, which then no longer matches the snapshot
- **Turn online features off**: start Elden Ring in offline mode, otherwise invasions,
  messages and phantoms differ every run
- **Leave plenty of slack between launch and your first input**: replay sends input by
  "time since launch", and launch/load times vary. If the recording happened to load
  quickly and a replay loads slower, input lands on the loading screen and gets lost,
  and everything after it is out of sync. Wait a few extra seconds after the title
  screen appears and after the save finishes loading
- **Switch the input method to English** (for both recording and replay): a Chinese
  input method intercepts key presses and the game receives none of them
- **Use only the keyboard from the title screen into the game** (E, Enter, ...): the
  cursor position differs every run, so replayed mouse clicks on menus miss
- Do not type passwords or anything private while recording; every key press is saved
- The stutter timestamps in `notes.md` are the most important clue for analysis; write
  them down whenever you notice one

### Limits of replay

Replay is open-loop (it sends input without looking at the screen). Fixed things such
as maps and routes reproduce well; randomized combat (boss AI) diverges from the
recording within seconds to tens of seconds, after which the input no longer matches
what is on screen. Exploration routes therefore make good primary workloads, while
combat only gives "the same kind of load, different every run".

## Why not libinput record/replay

`libinput replay` takes the **first recorded event** as time 0, so the gap between
launching the game and the first key press is dropped and title-screen input is sent
too early. `evrec.py` keeps each event's `CLOCK_MONOTONIC` timestamp and anchors replay
to the moment the game is launched again.

## Adding a game

Add a case to `game_config` in `games.sh`:

| Variable | Meaning |
|---|---|
| `APPID` | Steam app id |
| `SAVE_REL` | save directory, relative to the Proton prefix's `drive_c/users/steamuser/` |
| `PROC` | name `pgrep -f` matches while the game is running |

The Steam library location is found automatically from `libraryfolders.vdf`.
Currently supported:

| game | appid | save directory |
|---|---|---|
| `eldenring` | 1245620 | `AppData/Roaming/EldenRing` (contains `ER0000.sl2` + `.bak`) |
| `2077` | 1091500 | `Saved Games/CD Projekt Red/Cyberpunk 2077` |

## Replay

```sh
./replay.sh <game> <name>
```

1. Same checks as recording (Steam running, game not running, Steam Cloud off)
2. Backs up your current save to `recordings/<game>/.live-save/`
3. Overwrites the save directory with the recording's snapshot
4. Creates the uinput devices, launches the game, and sends events by "time since launch"
5. After the recorded duration, closes the game and **restores your own save**; aborting
   with Ctrl+C restores it as well

Progress the game saves during replay is discarded on purpose: every run must start
from the same snapshot.

`.live-save.pending` exists from the backup until the restore completes. If a previous
run did not finish (e.g. power loss) it is left behind and `replay.sh` refuses to run,
so the snapshot never overwrites what is then the only copy of your real save. In that
case copy `.live-save/` back into the save directory yourself, then delete `.pending`.

Do not touch the physical keyboard or mouse during replay.

[中文版說明文件](README.zh-TW.md)
