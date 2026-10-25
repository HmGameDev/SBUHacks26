# SBUHacks26: Wayfinder

Chest-mounted iPhone LiDAR app that guides blind and low-vision walkers with spoken cues and vibration. It finds the clearest walking direction through obstacles, warns about drop-offs and head-height objects, and can optionally lean that direction toward a walking route.

The design, constraints, and phase gates are in [docs/FOUNDATION_PROMPT.md](docs/FOUNDATION_PROMPT.md). Read it first.

## Run it

1. Open `Wayfinder.xcodeproj` in Xcode 16 or later.
2. Select the **Wayfinder** target, then **Signing & Capabilities**, and pick your team. Change the bundle id if it clashes.
3. Run on an iPhone 12 Pro or later (13 Pro and 17 Pro are the test phones). The simulator has no LiDAR, so only the unit tests run there.
4. Run the unit tests with Cmd-U. They cover geometry, the gap planner, the cue arbiter, the frame codec, and a synthetic end-to-end pipeline.

Without generated clips the app speaks every cue with on-device speech, which is fine for development. For the demo, generate the ElevenLabs clips (see [tools/generate_cues](tools/generate_cues/README.md)) and rebuild. Rerun it after pulling new phrases (for example `stairs_up` and `stairs_down`).

### AI voice for directions (optional)

Spoken directions and search results can use live ElevenLabs. Either paste a key in the app (Settings, AI voice for directions; it is saved on the phone), or copy [docs/Secrets.example.plist](docs/Secrets.example.plist) to `Wayfinder/Secrets.plist`, fill in the key, and build:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ELEVENLABS_API_KEY</key>
    <string>your key</string>
    <key>ELEVENLABS_VOICE_ID</key>
    <string>21m00Tcm4TlvDq8ikWAM</string>
</dict>
</plist>
```

`Secrets.plist` is gitignored; never commit it. Anyone with the built app can extract the key, so give it a low spending limit. If no key is set or the network takes more than 1.5 seconds, the iPhone voice reads the text instead. Stop, Left, Right, Step down, and Stairs always use the bundled clips.

## Using it

- **Mount** the phone portrait on the chest, screen facing in, rear camera facing out, tilted down 15 to 25 degrees so the floor about a meter ahead is in view. Keep the bottom speaker uncovered.
- Press **Start**, then stand still and face forward for two seconds while it finds the floor. It says "Ready."
- **Just walk** (passive) guides around obstacles with no destination, and leans back toward the direction you were walking once you are past something. **Go somewhere** (guided) adds Apple Maps walking directions: tap the microphone and say a place, or type it, then pick a result. The top result is read aloud.
- **Settings** (gear icon) has how much it talks, cue volume, vibration strength, the iPhone voice and speed, and the AI voice. Every change plays an example. **Help** (question mark) plays each cue with what it means.
- **Open camera view after Start** opens the live detection view on its own full screen once guidance starts, with the route direction in blue and a large Stop bar at the bottom. "Hide camera" goes back home while guidance keeps running.
- The screen dims to save battery while guiding. Do not press the side button: iOS stops the camera when the app leaves the foreground, and the app says "Guidance stopped."
- Siri (open the app once after installing): "Start Wayfinder", "Stop Wayfinder", "Wayfinder passive mode", "Start navigation with Wayfinder" (Siri asks where to), "Stop navigation in Wayfinder" (obstacle warnings stay on), "Wayfinder where am I going", "Wayfinder quieter", "Wayfinder more detail".

What the cues mean: "Stop" with a long buzz means something is right ahead; "Step down" means a curb or single step down; "Stairs going up/down ahead" with a double tap means three or more matching steps, seen for at least 0.6 s by both halves of the walking path; "Left" / "Right" / "Slight left" / "Slight right" point at the clearest gap. Head-height obstacles are shown in the debug views but not spoken (too many false alarms on a chest mount). The repeating tap speeds up as the nearest obstacle gets closer. Silence means the way is clear.

## Debugging

Tap **Debug view**. Mirror the phone to a Mac with AirPlay so a teammate can watch while someone walks, or use iOS screen recording.

| Tab | Shows |
| --- | --- |
| Camera | Color or depth image with every sampled point colored by class (floor green, obstacle red, drop purple, overhead orange, low confidence gray), the walking corridor, the chosen heading (yellow), the route direction (blue dashes), and the next turn. |
| Map | Top-down occupancy grid (now remembered for 8 seconds, so walls beside you stay known) with the 16 candidate headings and the route or walking direction in blue, and a side view with the class thresholds and the stair profile in cyan. |
| Planner | Ten seconds of heading (raw and smoothed), urgency, and nearest distance. Left-right flipping shows up here. |
| Cues | Every cue considered, what was spoken, queued, expired, or dropped, and latency from the triggering frame. Buttons fire any cue by hand. |
| Setup | Record and replay, and every tuning value, live. |

**Record and replay.** Record a walk from Setup. Recordings live in the app's Documents folder (Finder or the Files app can copy them off). Replay runs the recording through the same pipeline, and the HUD shows a planner hash: two replays of one recording with the same tuning must show the same hash. Use recordings to reproduce a tester's problem without asking them to walk again.

## Status and known limits

- **Not yet compiled or run on a device.** The code was written without a Swift toolchain, so expect a handful of compile fixes on first build. The planner tests were checked with a numeric simulation; nothing has been measured on a phone.
- None of the section 9 gates have been run. Work through them in order on a device, starting with 30 fps on the 13 Pro.
- The portrait field of view is about plus or minus 24 degrees horizontally, so obstacles more than about half a meter to the side at one meter are not seen until the user turns toward them.
- The LiDAR cannot see the floor right under the user; the tilt-down mount and the inferred drop-off (floor that suddenly disappears) cover most of that.
- Changing the `Tuning` struct's fields resets saved tuning to defaults on next launch.

## Layout

```
Wayfinder/            App sources (App, Capture, Perception, Feedback, Navigation, Identification, Debug)
WayfinderTests/       Unit tests
tools/generate_cues/  ElevenLabs clip generator (the only place the API key is used)
reference/shepherd/   Read-only reference from Shepherd; not in the build
docs/                 Foundation prompt
```
