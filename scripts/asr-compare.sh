#!/bin/bash
# Compares Apple's on-device speech recognition (the engine VibeMeeting uses)
# with NVIDIA Parakeet TDT 0.6B v3 on the same English audio, against the
# video's human-made subtitles. Nothing in the app changes.
#
#   scripts/asr-compare.sh "https://www.youtube.com/watch?v=..." [minutes]
#
# Installs what it needs with Homebrew (yt-dlp, ffmpeg, uv, yap) and uv
# (parakeet-mlx), downloads the audio and subtitles into
# ~/Desktop/asr-test/<video id>, transcribes the first [minutes] (default 5)
# with both engines and prints the word error rate of each. Apple runs on the
# whole file here, not live as in the app, so its result is a little better
# than in a meeting.
set -euo pipefail

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
command -v parakeet-mlx >/dev/null 2>&1 || uv tool install parakeet-mlx -U

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
python3 - "$reference_vtt" "$seconds" "$apple_time" "$parakeet_time" <<'PY'
import html, re, sys

vtt_path, seconds, apple_time, parakeet_time = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]

def to_seconds(stamp):
    parts = stamp.replace(",", ".").split(":")
    value = 0.0
    for part in parts:
        value = value * 60 + float(part)
    return value

# Reference: subtitle cues that start inside the cut, without tags and sound labels.
lines, keep = [], False
for raw in open(vtt_path, encoding="utf-8"):
    line = raw.strip()
    if "-->" in line:
        keep = to_seconds(line.split("-->")[0].strip()) < seconds
        continue
    if not line or not keep or line.startswith(("WEBVTT", "Kind:", "Language:", "NOTE")):
        continue
    line = html.unescape(re.sub(r"<[^>]+>", "", line))
    line = re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", line)  # [Music], (laughs)
    line = re.sub(r"^\s*(>>|-)\s*", "", line)           # speaker change marks
    if line and (not lines or lines[-1] != line):
        lines.append(line)
reference = " ".join(lines)
open("reference.txt", "w", encoding="utf-8").write(reference)

def words(text):
    text = text.lower().replace("’", "'").replace("‘", "'")
    text = re.sub(r"[-–—/]", " ", text)
    text = re.sub(r"[^\w\s']", " ", text)
    return [w.strip("'") for w in text.split() if w.strip("'")]

def align(ref, hyp):
    """Word-level edit distance with the substitutions it implies."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
    i, j, subs, dels, ins, pairs = n, m, 0, 0, 0, []
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (0 if ref[i - 1] == hyp[j - 1] else 1):
            if ref[i - 1] != hyp[j - 1]:
                subs += 1
                pairs.append((ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            dels += 1
            i -= 1
        else:
            ins += 1
            j -= 1
    return d[n][m], subs, dels, ins, list(reversed(pairs))

ref = words(reference)
print(f"\nReference: {len(ref)} words from the subtitles (first {int(seconds // 60)} min)\n")
for name, path, took in [("Apple", "apple.txt", apple_time), ("Parakeet v3", "parakeet.txt", parakeet_time)]:
    hyp = words(open(path, encoding="utf-8").read())
    errors, subs, dels, ins, pairs = align(ref, hyp)
    wer = errors / max(1, len(ref))
    print(f"{name:12} WER {wer * 100:5.1f}%  (accuracy {max(0, 100 - wer * 100):5.1f}%)  "
          f"substituted {subs}, missed {dels}, extra {ins}  [{took} s]")
    shown = ", ".join(f"{r}→{h}" for r, h in pairs[:15])
    print(f"{'':12} first mix-ups: {shown or 'none'}\n")
print("Files: reference.txt, apple.txt, parakeet.txt in this folder.")
print("Subtitles are sometimes lightly edited, which raises both WERs alike; compare the two numbers with each other.")
PY
