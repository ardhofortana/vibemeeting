#!/bin/bash
# Compares Apple's on-device speech recognition (the engine VibeMeeting uses)
# with NVIDIA Parakeet TDT 0.6B v3 on the same English audio, against the
# video's human-made subtitles. Nothing in the app changes.
#
#   scripts/asr-compare.sh "https://www.youtube.com/watch?v=..." [minutes]
#   scripts/asr-compare.sh --score <video id> <transcript file>
#   scripts/asr-compare.sh --against <reference text file> <transcript file> [them|you]
#
# The second form scores another transcript of the same audio, e.g. one
# copied from VibeMeeting (Transcript → Copy transcript, Them lines only),
# next to Apple and Parakeet, against the reference saved by the first run.
# The third scores a transcript copied from VibeMeeting against any text known
# to be what was said, e.g. a voice assistant's replies as its chat shows them
# (Them lines) or a passage read aloud into the mic (you), such as
# scripts/asr-passage.txt.
#
# Installs what it needs with Homebrew (yt-dlp, ffmpeg, uv, yap) and uv
# (parakeet-mlx), downloads the audio and subtitles into
# ~/Desktop/asr-test/<video id>, transcribes the first [minutes] (default 5)
# with both engines and prints the word error rate of each. Apple runs on the
# whole file here, not live as in the app, so its result is a little better
# than in a meeting.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--score" ]; then
    dir="$HOME/Desktop/asr-test/${2:?video id, e.g. _y9JuojAIg0}"
    file="${3:?transcript file}"
    case "$file" in /*) ;; *) file="$PWD/$file" ;; esac
    cd "$dir"
    python3 "$here/asr_score.py" --reference reference.txt Apple=apple.txt "Parakeet v3=parakeet.txt" "This file=$file"
    exit 0
fi

if [ "${1:-}" = "--against" ]; then
    reference="${2:?reference text file}"
    file="${3:?transcript file}"
    python3 "$here/asr_score.py" --reference "$reference" --speaker "${4:-them}" "This file=$file"
    exit 0
fi

url="${1:-}"
minutes="${2:-5}"
if [ -z "$url" ]; then
    echo "Usage: scripts/asr-compare.sh \"https://www.youtube.com/watch?v=...\" [minutes]" >&2
    exit 1
fi
case "$minutes" in
    ''|*[!0-9]*) echo "minutes must be a whole number, e.g. 5" >&2; exit 1 ;;
esac

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is needed: install it from https://brew.sh, then run this again." >&2
    exit 1
fi

echo "== Checking tools"
for tool in yt-dlp ffmpeg uv; do
    command -v "$tool" >/dev/null 2>&1 || brew install "$tool"
done
command -v yap >/dev/null 2>&1 || brew install finnvoor/tools/yap
export PATH="$HOME/.local/bin:$PATH"
# MLX ships wheels for released Pythons only, so pin one rather than the
# newest Homebrew Python (uv downloads it if needed).
command -v parakeet-mlx >/dev/null 2>&1 || uv tool install parakeet-mlx -U --python 3.12

id="$(yt-dlp --get-id "$url" | head -n 1)"
dir="$HOME/Desktop/asr-test/$id"
mkdir -p "$dir"
cd "$dir"
echo "== Working in $dir"

if [ ! -f full.m4a ]; then
    echo "== Downloading audio"
    yt-dlp -q -x --audio-format m4a -o "full.%(ext)s" "$url"
fi
rm -f ref*.vtt
echo "== Downloading the human-made English subtitles"
yt-dlp -q --write-subs --sub-langs "en.*,en" --sub-format vtt --skip-download -o "ref" "$url" || true
reference_vtt="$(ls ref*.vtt 2>/dev/null | head -n 1 || true)"
if [ -z "$reference_vtt" ]; then
    echo "This video has no human-made English subtitles (only automatic ones). Pick another video." >&2
    exit 1
fi

seconds=$((minutes * 60))
echo "== Cutting the first $minutes minutes"
ffmpeg -loglevel error -y -i full.m4a -t "$seconds" -ac 1 -ar 16000 test.wav

echo "== Apple (SpeechAnalyzer, via yap)"
start=$(date +%s)
yap transcribe test.wav --locale en-US --txt -o apple.txt
apple_time=$(( $(date +%s) - start ))

echo "== Parakeet TDT 0.6B v3 (via parakeet-mlx; downloads the model once)"
start=$(date +%s)
rm -rf parakeet-out
parakeet-mlx test.wav --model mlx-community/parakeet-tdt-0.6b-v3 --output-format txt --output-dir parakeet-out >/dev/null
cp "$(ls parakeet-out/*.txt | head -n 1)" parakeet.txt
parakeet_time=$(( $(date +%s) - start ))

echo "== Comparing"
python3 "$here/asr_score.py" --vtt "$reference_vtt" --seconds "$seconds" \
    "Apple=apple.txt:$apple_time" "Parakeet v3=parakeet.txt:$parakeet_time"
echo "Files: reference.txt, apple.txt, parakeet.txt in $dir"
