#!/bin/zsh
# Energy of a workload, from powermetrics (CPU, GPU and Neural Engine power). powermetrics needs root, so this is run by the owner:
#
#     sudo spikes/asr/energy_session.sh <label> <command> [args...]
#
# Example (the two Whisper candidates, same audio; run each once, on a quiet Mac, on mains power, lid open):
#     sudo spikes/asr/energy_session.sh whisperkit-large ~/Library/Developer/SmartAsset/phase3/isolation/sbx.sh run \
#         /usr/bin/env CFFIXED_USER_HOME=$HOME/Library/Developer/SmartAsset/phase3/home \
#         ~/Library/Developer/SmartAsset/phase3/work/whisperkit-bench/.build/release/whisperkit-run \
#         openai_whisper-large-v3-v20240930_626MB energy-run
#
# The command runs as the user who invoked sudo, not as root. Only powermetrics runs as root, and only reads counters.
# Output: phase3/results/energy/<label>.powermetrics.txt and <label>.summary.json (parse_powermetrics.py).
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo (powermetrics needs root)"; exit 1; }
label=$1; shift
P3=${SUDO_USER:+/Users/$SUDO_USER}/Library/Developer/SmartAsset/phase3
out=$P3/results/energy; sudo -u $SUDO_USER mkdir -p $out
echo "idle baseline 10 s..."
/usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power -i 500 -o $out/$label.powermetrics.txt &
pm=$!
sleep 10
start=$(date +%s)
sudo -u $SUDO_USER "$@"
end=$(date +%s)
kill $pm; wait $pm 2>/dev/null || true
chown $SUDO_USER $out/$label.powermetrics.txt
sudo -u $SUDO_USER /usr/bin/python3 -I ${0:A:h}/parse_powermetrics.py $out/$label.powermetrics.txt 10 $((end-start)) > $out/$label.summary.json
cat $out/$label.summary.json
