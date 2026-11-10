#!/bin/bash
# make smoketest (tools/linux/smoketest.sh [AppImage]): release check of the x86-64 AppImage on this machine, in three
# launches of the AppImage itself (default build/dist/EoWRecomp-<version>-linux-x86_64.AppImage):
#   0. setup, as the start screen's Set up does it: this checkout's extracted/ (exefs, romfs) into an empty data folder,
#      and the game code built from it with the bundled generator and compiler (runtime/gamebuild.c)
#   1. start screen: rendered with the game files found ("Game files ready")
#   2. game: a new session straight into the game - the opening, then the first controllable scene with scripted input
#      (the corridor walk of docs/STATUS.md); screenshots of each, none black, no crash, the frame rate from the log
# Result: build/smoke/report.txt (PASS / FAIL per check), build/smoke/sheet.png (every screenshot, labelled) and the
# screenshots in build/smoke/shots/. Exit status 0 = ready for release. Uses this checkout's extracted/ (as the folder
# a player picks); no save needed (a new game in a scratch save folder). Nothing in ~/.local/share/eowrecomp is used
# or changed. Run it on the machine you want to check (a Steam Deck in desktop mode, for one): the GPU and driver are
# named in the report.
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
VERSION=$(sed -n 's/^#define EOWRECOMP_VERSION "\(.*\)"/\1/p' runtime/ui/launcher.mm)
APP=$(realpath "${1:-build/dist/EoWRecomp-$VERSION-linux-x86_64.AppImage}")
O=$REPO/build/smoke
[ -x "$APP" ] || { echo "smoketest: no AppImage at $APP (make appimage)"; exit 2; }
[ -d extracted/exefs ] || { echo "smoketest: no extracted/ game files in this checkout (tools/nca_extract.py)"; exit 2; }

rm -rf "$O" && mkdir -p "$O/root/build" "$O/shots" "$O/save"
# test runs: no update check, no sound, a data folder of their own (runtime/paths.h), the AppImage run without FUSE
export EOWRECOMP_DATA_ROOT=$O/root EOWRECOMP_SAVE_DIR=$O/save EOWRECOMP_SETTINGS=$O/root/eowrecomp.ini \
       EOWRECOMP_NO_UPDATE_CHECK=1 EOWRECOMP_NO_AUDIO=1 APPIMAGE_EXTRACT_AND_RUN=1
FAILS=0
report() {  # PASS|FAIL, text
    printf '%-4s  %s\n' "$1" "$2" | tee -a "$O/report.txt"
    [ "$1" = PASS ] || FAILS=$((FAILS + 1))
}
dark() { python3 -I -c "
import sys
from PIL import Image, ImageStat
print(1 if sum(ImageStat.Stat(Image.open(sys.argv[1]).convert('L')).mean) < 12 else 0)" "$1"; }

# The AppImage runtime starts the game as a child process: each run gets a process group of its own (setsid), so
# stopping it stops the game too.
start_app() {  # VAR=value...: the AppImage in the data folder, with those settings
    (cd "$O/root" && exec env "$@" setsid "$APP" </dev/null >/dev/null 2>&1) &
    APP_PG=$!
}
app_alive() { ps -e -o pgid=,stat= | awk -v g="$APP_PG" '$1 == g && $2 !~ /^Z/ {f = 1} END {exit !f}'; }
stop_app() {
    kill -TERM -- -"$APP_PG" 2>/dev/null
    for i in $(seq 1 20); do app_alive || break; sleep 0.5; done
    app_alive && kill -KILL -- -"$APP_PG" 2>/dev/null
    while app_alive; do sleep 0.5; done
    wait "$APP_PG" 2>/dev/null
}
wait_app() {  # seconds: status 0 = the game ended by itself in time, else it is stopped
    for i in $(seq 1 "$1"); do app_alive || { wait "$APP_PG" 2>/dev/null; return 0; }; sleep 1; done
    stop_app
    return 1
}

# ---- 0. setup (headless: EOWRECOMP_LAUNCHER_EXTRACT runs the start screen's Set up, logs the result and exits)
t0=$(date +%s)
start_app EOWRECOMP_LAUNCHER_EXTRACT="$REPO/extracted"
wait_app 1800
mv "$O/root/eowrecomp.log" "$O/setup.log" 2>/dev/null
lib=$(ls "$O/root/extracted"/eowgame.* 2>/dev/null | head -1)
if grep -q '\[launcher\] setup: .* -> READY' "$O/setup.log" && [ -n "$lib" ]; then
    report PASS "setup: game files and game code built ($(( $(date +%s) - t0 )) s, $(basename "$lib") $(du -m "$lib" | cut -f1) MB)"
else
    report FAIL "setup: $(grep -m1 '\[launcher\] setup:' "$O/setup.log" || echo 'no result') (see build/smoke/setup.log)"
fi

# ---- 1. start screen
# (no terminal: the app logs to eowrecomp.log in its data folder, runtime/platform/linux.c)
start_app EOWRECOMP_LAUNCHER_SHOT=150 EOWRECOMP_SHOT_PATH="$O/shots/00_start_screen.png"
wait_app 90
mv "$O/root/eowrecomp.log" "$O/start_screen.log" 2>/dev/null
if [ -f "$O/shots/00_start_screen.png" ] && [ "$(dark "$O/shots/00_start_screen.png")" = 0 ] &&
   ! grep -qE '\*\*\* |FATAL' "$O/start_screen.log"; then
    report PASS "start screen ($(grep -o 'using .*' "$O/start_screen.log" | head -1))"
else
    report FAIL "start screen (see build/smoke/start_screen.log)"
fi

# ---- 2. game: straight in (EOWRECOMP_NO_LAUNCHER), the game image at OPENING and SCENE frames (EOWRECOMP_SHOT_AT ->
# build/frames/ in the data folder), the window at END, then exit. The input is the walk of docs/STATUS.md: up the
# corridor into the room once the first scene is playable (~frame 1500). ~9-12 fps on an Iris Xe: END in ~4 minutes.
OPENING=600 SCENE=1500 WALK=2000 END=2100
start_app EOWRECOMP_NO_LAUNCHER=1 EOWRECOMP_INPUT="1550:STICK_UP:150,1820:A:10" \
    EOWRECOMP_SHOT_AT="$OPENING,$SCENE,$WALK" EOWRECOMP_WINDOW_SHOT=$END EOWRECOMP_EXIT_AFTER_SHOT=1 \
    EOWRECOMP_SHOT_PATH="$O/shots/04_window_end.png"
wait_app 1200
L=$O/game.log
mv "$O/root/eowrecomp.log" "$L" 2>/dev/null
for f in $OPENING:01_opening $SCENE:02_first_scene $WALK:03_walk; do
    cp "$O/root/build/frames/frame_$(printf %05d "${f%%:*}").png" "$O/shots/${f#*:}.png" 2>/dev/null
done
gpu=$(grep -m1 -o '\[vk\] using .*' "$L" | cut -c12-)
if grep -qE '\*\*\* |FATAL' "$L"; then report FAIL "crash in the game session: $(grep -m1 -E '\*\*\* |FATAL' "$L") (see build/smoke/game.log)"
elif ! [ -f "$O/shots/04_window_end.png" ]; then
    report FAIL "game: frame $END never reached ($(grep -o 'frame [0-9]*' "$L" | tail -1), see build/smoke/game.log)"
else report PASS "game: frame $END reached without a crash (${gpu:-GPU not logged})"; fi
for n in 01_opening 02_first_scene 03_walk; do
    if [ -f "$O/shots/$n.png" ] && [ "$(dark "$O/shots/$n.png")" = 0 ]; then report PASS "$n: image"
    else report FAIL "$n: missing or black (build/smoke/shots/$n.png)"; fi
done
# frame rate: the renderer's periodic "[vk] ... N fps" lines once the first scene is up (the shader compiles of the
# opening left out); informational, not a check
fps=$(awk -v s=$SCENE '/\[vk\] t=.* frame [0-9]+ .* fps/ { for (i = 1; i <= NF; i++) { if ($i == "frame") f = $(i + 1);
        if ($i == "fps") v = $(i - 1) } if (f >= s) { t += v; n++ } } END { if (n) printf "%.1f", t / n }' "$L")
echo "info  frame rate in the first scene: ${fps:-not logged} fps" | tee -a "$O/report.txt"

python3 -I - "$O/sheet.png" "$O"/shots/*.png <<'PY'
import os, sys
from PIL import Image, ImageDraw
out, fs = sys.argv[1], sys.argv[2:]
w, h, cols = 400, 225, 4
rows = (len(fs) + cols - 1) // cols
m = Image.new('RGB', (w * cols, h * rows))
for i, f in enumerate(fs):
    im = Image.open(f).convert('RGB').resize((w, h))
    d = ImageDraw.Draw(im)
    label = os.path.basename(f)[3:-4].replace('_', ' ')
    d.rectangle((0, 0, 8 + 7 * len(label), 16), fill=(0, 0, 0))
    d.text((4, 2), label, fill=(255, 230, 80))
    m.paste(im, ((i % cols) * w, (i // cols) * h))
m.save(out)
PY
if [ $FAILS -eq 0 ]; then echo "READY FOR RELEASE: every check passed" | tee -a "$O/report.txt"
else echo "NOT READY: $FAILS check(s) failed" | tee -a "$O/report.txt"; fi
[ $FAILS -eq 0 ]
