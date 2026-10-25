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
- Reserved phrases (cues the app no longer plays, like Duck) are skipped. Run with `--only label_person,label_bicycle,label_motorbike,label_vehicle,label_dog,label_pole,label_chair,label_bench,label_table,label_couch,label_plant,label_bag,label_hydrant,label_parking_meter,label_door,label_wheelchair,label_cart,label_tree,label_desk,label_bed,label_shelf,label_cabinet,label_trash_can,label_box,on_left,on_right` to add just the obstacle names.

To change wording, edit `phrases.json`, then rerun with `--only <id> --force`. Listen to the clips through the phone speaker at walking volume before committing them; short words like "Left." must be unmistakable from "Right." outdoors.
