#!/usr/bin/env bash
# Starts JACK and the drone engine.
#   ./start-engine.sh            uses $DRONE_AUDIO_DEVICE, or hw:0
#   ./start-engine.sh hw:1       picks a specific sound card (list them with: aplay -l)
set -e
cd "$(dirname "$0")"
DEVICE="${1:-${DRONE_AUDIO_DEVICE:-hw:0}}"

if ! pgrep -x jackd >/dev/null; then
  if [ "$DEVICE" = "dummy" ]; then
    jackd -d dummy -r 48000 -p 256 &
  else
    # -p 256 gives ~5ms latency; raise to 512 if you hear crackles
    jackd -R -d alsa -d "$DEVICE" -r 48000 -p 256 -n 3 -P &
  fi
  sleep 2
fi

export QT_QPA_PLATFORM=offscreen
export SC_JACK_DEFAULT_OUTPUTS="system:playback_1,system:playback_2"
exec sclang drone.scd
