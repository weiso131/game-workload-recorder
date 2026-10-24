# Per-game settings, sourced by record.sh.
#   APPID      Steam app id
#   SAVE_REL   save directory, relative to the Proton prefix's steamuser dir
#   PROC       process name pgrep matches while the game is running

game_config() {
	case "$1" in
	eldenring)
		APPID=1245620
		SAVE_REL="AppData/Roaming/EldenRing"
		PROC="eldenring.exe"
		;;
	2077)
		APPID=1091500
		SAVE_REL="Saved Games/CD Projekt Red/Cyberpunk 2077"
		PROC="Cyberpunk2077.exe"
		;;
	*)
		return 1
		;;
	esac
}

# Steam libraries can live outside ~/.local/share/Steam; find the one that has the game.
steam_library_of() {
	local vdf=~/.local/share/Steam/steamapps/libraryfolders.vdf lib
	while read -r lib; do
		if [[ -f "$lib/steamapps/appmanifest_$1.acf" ]]; then
			echo "$lib"
			return 0
		fi
	done < <(sed -n 's/^\s*"path"\s*"\(.*\)"/\1/p' "$vdf")
	return 1
}

# Prints the CLOCK_MONOTONIC ns taken right before launching, the anchor evrec.py replays against.
launch_game() {
	python3 -c '
import subprocess, sys, time
print(time.clock_gettime_ns(time.CLOCK_MONOTONIC), flush=True)
subprocess.Popen(["steam", "-applaunch", sys.argv[1]],
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
' "$1"
}

# Per-app toggle lives in sharedconfig.vdf; a missing entry means Steam's default (on).
steam_cloud_enabled() {
	local f
	for f in ~/.local/share/Steam/userdata/*/7/remote/sharedconfig.vdf; do
		[[ -f "$f" ]] || continue
		awk -v app="\"$1\"" '
			$1 == app { inapp = 1; next }
			inapp && $1 == "}" { exit }
			inapp && $1 == "\"cloudenabled\"" && $2 == "\"0\"" { off = 1 }
			END { exit off ? 1 : 0 }
		' "$f" || return 1
	done
	return 0
}

# The sudo timestamp expires mid-run (Fedora: 5 min), and an interactive prompt
# inside a trap blocks cleanup. Caller kills $SUDO_KEEPER when done.
keep_sudo() {
	sudo -v
	while sudo -n -v 2>/dev/null; do sleep 60; done &
	SUDO_KEEPER=$!
}
