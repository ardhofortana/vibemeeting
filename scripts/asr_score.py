"""Word error rate of transcripts against a reference, for scripts/asr-compare.sh.

    python3 asr_score.py --vtt ref.en.vtt --seconds 300 Apple=apple.txt:6 Parakeet=parakeet.txt:125
    python3 asr_score.py --reference reference.txt --speaker you App=app.txt

With --vtt the reference is built from the subtitle cues that start in the
first --seconds and saved as reference.txt. A transcript copied from
VibeMeeting ("[00:12] Them: …" lines) is scored on one speaker's lines,
Them unless --speaker says otherwise. Spelling that isn't a recognition error
is evened out on both sides first: contractions, small numbers written as
words, "7,000", okay/ok, British -ise. 'd and 's after a pronoun match either
full form ("I'd" is "I had" or "I would"), since the audio can't tell them apart.
"""
import argparse
import html
import re

CONTRACTIONS = {
    "i'm": "i am", "you're": "you are", "we're": "we are", "they're": "they are",
    "let's": "let us",
    "i've": "i have", "we've": "we have", "you've": "you have", "they've": "they have",
    "i'll": "i will", "we'll": "we will", "you'll": "you will", "they'll": "they will",
    "it'll": "it will", "don't": "do not", "doesn't": "does not", "didn't": "did not",
    "can't": "can not", "cannot": "can not", "won't": "will not", "isn't": "is not",
    "aren't": "are not", "wasn't": "was not", "weren't": "were not", "haven't": "have not",
    "hasn't": "has not", "wouldn't": "would not", "shouldn't": "should not",
    "couldn't": "could not", "gonna": "going to", "wanna": "want to", "ok": "okay",
}
# 'd is had or would, 's is is or has: after these words both full forms and
# the contraction become one token.
AMBIGUOUS = {
    "'d": ({"had", "would"}, {"i", "you", "he", "she", "it", "we", "they", "that", "there", "who", "what"}),
    "'s": ({"is", "has"}, {"he", "she", "it", "that", "there", "what", "here", "who", "where", "how"}),
}
NUMBERS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11",
    "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16",
    "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
}


def to_seconds(stamp):
    value = 0.0
    for part in stamp.replace(",", ".").split(":"):
        value = value * 60 + float(part)
    return value


def reference_from_vtt(path, seconds):
    """Cues that start inside the cut, without tags, sound labels or repeats."""
    lines, keep = [], False
    for raw in open(path, encoding="utf-8"):
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
    return " ".join(lines)


def transcript_text(path, speaker="them"):
    """Plain text, or one speaker's lines of a transcript copied from VibeMeeting."""
    text = open(path, encoding="utf-8").read()
    turns = re.findall(r"^\[[\d:]+\]\s*([^:\n]+):\s*(.*)$", text, flags=re.MULTILINE)
    if turns:
        return " ".join(words for name, words in turns if speaker == "all" or name.strip().lower() == speaker)
    return text


def words(text):
    text = text.lower().replace("’", "'").replace("‘", "'")
    text = re.sub(r"(?<=\d),(?=\d{3}\b)", "", text)  # 7,000 → 7000
    text = re.sub(r"[-–—/]", " ", text)
    text = re.sub(r"[^\w\s']", " ", text)
    result = []
    for word in text.split():
        word = word.strip("'")
        if not word:
            continue
        word = CONTRACTIONS.get(word, word)
        for suffix, (_, before) in AMBIGUOUS.items():
            if word.endswith(suffix) and word[:-2] in before:
                word = f"{word[:-2]} {suffix}"
        for part in word.split():
            if part not in AMBIGUOUS:
                part = part.replace("'", "")  # John's and Johns alike
            part = NUMBERS.get(part, part)
            part = re.sub(r"isation$", "ization", re.sub(r"ise$", "ize", part)) if len(part) > 5 else part
            if result:
                for suffix, (full, before) in AMBIGUOUS.items():
                    if part in full and result[-1] in before:
                        part = suffix
            result.append(part)
    return result


def align(ref, hyp):
    """Word-level edit distance and the substitutions behind it."""
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vtt")
    parser.add_argument("--seconds", type=float, default=300)
    parser.add_argument("--reference")
    parser.add_argument("--speaker", choices=["them", "you", "all"], default="them",
                        help="whose lines to score in a transcript copied from VibeMeeting")
    parser.add_argument("transcripts", nargs="+", help="Name=path[:seconds taken]")
    args = parser.parse_args()

    if args.vtt:
        reference = reference_from_vtt(args.vtt, args.seconds)
        open("reference.txt", "w", encoding="utf-8").write(reference)
    else:
        reference = open(args.reference, encoding="utf-8").read()
    ref = words(reference)
    print(f"\nReference: {len(ref)} words\n")
    for item in args.transcripts:
        name, _, rest = item.partition("=")
        path, _, took = rest.partition(":")
        hyp = words(transcript_text(path, args.speaker))
        errors, subs, dels, ins, pairs = align(ref, hyp)
        wer = errors / max(1, len(ref))
        timing = f"  [{took} s]" if took else ""
        print(f"{name:12} WER {wer * 100:5.1f}%  (accuracy {max(0, 100 - wer * 100):5.1f}%)  "
              f"substituted {subs}, missed {dels}, extra {ins}{timing}")
        shown = ", ".join(f"{r}→{h}" for r, h in pairs[:20])
        print(f"{'':12} mix-ups: {shown or 'none'}\n")
    print("A reference that was lightly edited (subtitles often are) raises every WER alike; "
          "compare the numbers with each other.")


if __name__ == "__main__":
    main()
