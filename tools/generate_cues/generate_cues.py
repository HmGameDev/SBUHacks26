#!/usr/bin/env python3
"""Turn the fixed cue vocabulary into bundled ElevenLabs clips.

Reads Wayfinder/Feedback/CueAssets/phrases.json and writes <id>.mp3 next to it for every
non-reserved phrase. The API key comes from the environment and never touches the app or git.

    export ELEVENLABS_API_KEY=...            # required
    export ELEVENLABS_VOICE_ID=...           # optional, defaults to a stock voice
    python3 tools/generate_cues/generate_cues.py [--force] [--only stop,left] [--normalize]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Wayfinder" / "Feedback" / "CueAssets"
DEFAULT_VOICE = "21m00Tcm4TlvDq8ikWAM"
MODEL = "eleven_multilingual_v2"
OUTPUT_FORMAT = "mp3_44100_128"


def synthesize(text, key, voice):
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format={OUTPUT_FORMAT}"
    body = json.dumps({
        "text": text,
        "model_id": MODEL,
        # Steady, clear delivery: short cues should sound the same every time.
        "voice_settings": {"stability": 0.75, "similarity_boost": 0.75, "style": 0.0, "use_speaker_boost": True},
    }).encode()
    request = urllib.request.Request(url, data=body, method="POST", headers={
        "xi-api-key": key,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
    })
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def normalize(path):
    """Loudness-normalize so every cue plays at the same level through the phone speaker."""
    temp = path.with_suffix(".tmp.mp3")
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(path), "-af", "loudnorm=I=-14:TP=-1.0:LRA=7", str(temp)],
        check=True,
    )
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true", help="regenerate clips that already exist")
    parser.add_argument("--only", help="comma-separated phrase ids to generate")
    parser.add_argument("--normalize", action="store_true", help="loudness-normalize with ffmpeg")
    args = parser.parse_args()

    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY in your shell. Never commit it.")
    voice = os.environ.get("ELEVENLABS_VOICE_ID", DEFAULT_VOICE)
    if args.normalize and not shutil.which("ffmpeg"):
        sys.exit("--normalize needs ffmpeg on PATH.")

    phrases = json.loads((ASSETS / "phrases.json").read_text())["phrases"]
    only = set(args.only.split(",")) if args.only else None
    failures = 0
    for phrase in phrases:
        if phrase.get("reserved") or (only and phrase["id"] not in only):
            continue
        path = ASSETS / f"{phrase['id']}.mp3"
        if path.exists() and not args.force:
            print(f"skip  {phrase['id']} (exists)")
            continue
        try:
            path.write_bytes(synthesize(phrase["text"], key, voice))
            if args.normalize:
                normalize(path)
            print(f"wrote {path.relative_to(ROOT)}")
        except urllib.error.HTTPError as error:
            failures += 1
            print(f"FAIL  {phrase['id']}: HTTP {error.code} {error.read()[:200]!r}", file=sys.stderr)
        except Exception as error:  # noqa: BLE001 - report and keep going
            failures += 1
            print(f"FAIL  {phrase['id']}: {error}", file=sys.stderr)
    if failures:
        sys.exit(f"{failures} clip(s) failed; the app will use on-device speech for those.")


if __name__ == "__main__":
    main()
