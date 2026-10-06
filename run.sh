#!/usr/bin/env bash
# Starts the engine and the touchscreen UI together. Ctrl+C (or Esc in the UI) stops both.
#   ./run.sh                    full screen, audio on $DRONE_AUDIO_DEVICE (default hw:0)
#   ./run.sh --window 800x480   any extra options are passed to the UI
cd "$(dirname "$0")"
./engine/start-engine.sh &
ENGINE=$!
trap 'kill $ENGINE 2>/dev/null; pkill -x scsynth; pkill -x jackd' EXIT
PY=python3; [ -x .venv/bin/python ] && PY=.venv/bin/python
$PY ui/ui.py "$@"
