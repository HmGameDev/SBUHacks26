# generate_cues

Turns the fixed cue vocabulary in `Scout/Feedback/CueAssets/phrases.json` into bundled ElevenLabs clips (`<id>.mp3` in the same folder). The app plays these with no network. Any clip that is missing falls back to on-device speech, so the app works before you run this.

```sh
export ELEVENLABS_API_KEY=...          # keep it in your shell, never in git or the app
export ELEVENLABS_VOICE_ID=...         # optional
python3 tools/generate_cues/generate_cues.py --normalize
```

- `--force` regenerates clips that already exist.
- `--only stop,left,right` regenerates just those ids.
- `--normalize` runs ffmpeg loudnorm so every cue plays at the same level (recommended for the phone speaker).
- Reserved phrases (cues the app no longer plays, like Duck) are skipped.
- Obstacle names are sentences joined from pieces (`ahead_door` "There's a door just ahead," + `go_left` "step left to go around it."). A plain run adds new pieces. The `label_` pieces changed wording on 2026-10-25 ("Person." became "A person"), so regenerate those once:

  ```sh
  python3 tools/generate_cues/generate_cues.py --normalize --force --only "$(python3 -c "import json; print(','.join(p['id'] for p in json.load(open('Scout/Feedback/CueAssets/phrases.json'))['phrases'] if p['id'].startswith('label_')))")"
  ```

To change wording, edit `phrases.json`, then rerun with `--only <id> --force`. Listen to the clips through the phone speaker at walking volume before committing them; short words like "Left." must be unmistakable from "Right." outdoors.
