# Foundation prompt: chest-mounted obstacle guidance app

You are building an iOS app for blind and low-vision walkers. The phone is worn on a chest harness. It uses LiDAR depth to find obstacles and drop-offs in the user's path. It tells the user where to go using short spoken words from the phone speaker and vibration patterns. It works with or without a GPS destination.

The app is a supplement to a white cane or guide dog, never a replacement. Every design choice should favor "silent and correct" over "chatty and clever".

The app is named **Scout** (renamed from the working name Wayfinder on 2026-10-25).

Read this whole file before writing code. When this file and a later instruction from the team disagree, the team wins; update this file to match.

---

## 1. Fixed constraints

These are decided. Do not revisit them without asking the team.

| Constraint | Value | Consequence for the code |
| --- | --- | --- |
| Mount | Chest harness, phone in portrait, back camera facing forward, screen against the body | Nobody can see or touch the screen while walking. All control is by voice, Siri, or setup before mounting. |
| Devices | iPhone 13 Pro (A15) and iPhone 17 Pro | Both have LiDAR. Budget performance for the 13 Pro; it is the slower and hotter device. |
| Audio out | Phone speaker only, no headphones | No stereo panning (the two speakers are top and bottom in portrait, so left/right audio is meaningless). Direction must be spoken. Keep words short and loud. |
| Haptics | Phone vibration only | The whole phone vibrates against the sternum, so vibration cannot say left or right. Use it for urgency and for distinct events. |
| Modes | **Guided**: obstacle guidance plus GPS route to a destination. **Passive**: obstacle guidance only, no destination, no GPS. | Passive is the default and must be complete on its own. Guided is built last. |
| Obstacle identification | Built behind an off-by-default switch (section 8) | Detection (something is there) ships first and never depends on it. Identification (it is a person, a pole) only names what LiDAR already sees. |
| Language | Swift (Swift 5 language mode on the Swift 6 compiler), SwiftUI, ARKit, CoreHaptics, AVFoundation | Minimum iOS 17. No third-party dependencies for the core pipeline. Swift 5 mode avoids strict-concurrency churn during the hackathon; the pipeline runs on one serial queue. |
| Testers | A blind tester is available for the demo | See section 10 for the test protocol. |

---

## 2. What to take from Shepherd

Shepherd is the team's earlier motorized smart cane. Selected source files are in `reference/shepherd/` for reading only. Do not add them to the Xcode target. Write new code that borrows ideas, and copy a function only when it is clearly correct.

Check the hackathon's rules on prior work before copying code. Many hackathons require code to be written during the event. If yours does, use the reference files only as design notes and say so in the submission.

| Shepherd file | Use | Notes |
| --- | --- | --- |
| `DepthSensor.swift` | Pattern | ARKit setup with `.sceneDepth` is correct. Add `.smoothedSceneDepth`, the confidence map, camera intrinsics, and process frames off the main thread. |
| `DepthVisualizer.swift` | Pattern | Heat-map color ramp and portrait rotation (`.right`) are correct and are the source of truth for orientation. |
| `ObstacleDetector.swift` | Idea only | Keep the 16-column gap search and the `[0.25, 0.5, 0.25]` smoothing kernel. Do **not** keep its image-space zones or `isLikelyFloor` heuristic. **Probable bug:** in portrait, it treats raw depth-buffer X as left/right, but the visualizer rotates the buffer 90 degrees, so raw X is actually up/down. Verify this with the debug view before trusting any Shepherd zone logic. |
| `SteeringEngine.swift` | Idea only | Proximity scaling (`powf(proximity, 0.6)`) is a good start. It has no smoothing because Shepherd's ESP32 smoothed the motor. You must add smoothing and hysteresis here. |
| `HapticManager.swift` | Reuse | CoreHaptics engine with restart handlers is fine. Replace the `Timer`-based pulsing with `CHHapticPattern` players. |
| `VoiceManager.swift` | Reuse speech input only | Its TTS output is replaced by the cue system in section 6. |
| `ObjectRecognizer.swift` | Later | `detectPerson` is the seed of identification (section 8). Its announcement throttle in Shepherd's controller never fired; do not copy that logic. |
| `NavigationSteering.swift`, `NavigationManager.swift`, `RouteService.swift`, `WaypointModels.swift` | Reuse in Guided mode | ORS wheelchair routing, Overpass crossings, micro-waypoints, and ARKit plus compass heading fusion all apply. On a chest mount, camera heading equals body heading, so the fusion works as designed. API keys go in an untracked `Secrets.swift`. |

Not taken: the ESP32 and BLE code, the Vapi voice agent, and the 948-line `SmartCaneController`. The controller is replaced by the module structure below.

---

## 3. Architecture

```
ARKit live ─┐
            ├─> FrameBundle ─> MountCalibration ─> PointCloudBuilder ─> OccupancyGrid ─> GapPlanner ─> CueArbiter ─┬─> SpeechChannel (bundled clips, AVSpeech fallback)
Replay file ┘                                                          ^                    ^                       └─> HapticChannel
                                                     ObstacleClassifier (stub)        GuidedNavigation (Guided mode only)
```

Rules:

1. Each box is a type behind a small protocol, so it can run alone against recorded frames and be swapped in tests.
2. Nothing downstream of `FrameBundle` knows whether a frame is live or replayed.
3. Only `CueArbiter` decides what the user hears or feels. No other module calls the speaker or the haptic engine.
4. All tunable numbers live in one `Tuning` struct (Observable), editable from the debug screens and saved to `UserDefaults`. Shepherd's debug sliders were the most useful tool it had; keep that habit.
5. Processing runs on a dedicated serial queue or actor, never the main thread. The UI reads published snapshots at up to 15 Hz.
6. No `print` per frame. Use `os.Logger` with a debug category, and a ring buffer for the debug UI.

### Core types

```swift
struct FrameBundle: Sendable {
    let timestamp: TimeInterval
    let depth: DepthImage          // Float32 meters, 256x192 on current devices
    let confidence: ConfidenceImage // ARConfidenceLevel per pixel
    let color: CVPixelBuffer?      // only when a debug view or classifier needs it
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4 // world from camera
}

enum CellState: UInt8 { case unknown, free, obstacle, dropOff, overhead }

struct GridCell {
    var state: CellState
    var minHeight: Float     // meters above floor
    var maxHeight: Float
    var hits: UInt16         // points that landed here this frame
}

struct PlannerOutput: Sendable {
    let heading: Float        // radians, negative = left, 0 = straight
    let urgency: Float        // 0 = clear, 1 = stop
    let nearestObstacle: Float? // meters, inside the walking corridor
    let dropOffAhead: Float?    // meters
    let overheadAhead: Float?   // meters
    let reason: String          // human-readable for the debug log
}
```

Design `ObstacleLabel` now as an enum with `.unknown` plus a few cases (`person`, `pole`, `vehicle`, `bicycle`, `furniture`, `door`). Do not populate it.

---

## 4. Perception pipeline

The chest mount simplifies Shepherd's hardest problem: camera height is roughly constant (about 1.2 to 1.4 m) and camera heading equals body heading. Still, people lean, bend, and breathe, so never assume a fixed tilt.

### 4.1 Calibration

On start, say "Stand still and face forward" and collect 2 seconds of frames. Estimate:

- **Floor height** in ARKit world coordinates: the 10th percentile of point Y values in the lower half of the image, refined by ARKit horizontal plane anchors when available.
- **Camera height** above the floor.

Re-estimate the floor continuously with a slow filter (time constant around 2 seconds) so ramps and slopes do not read as obstacles. Treat a sudden floor change larger than 0.15 m as a candidate step, not a recalibration.

### 4.2 Point cloud

For every Nth depth pixel (start with N = 2, about 12,000 points at 256x192):

1. Skip pixels with low confidence. Allow medium confidence only within 2.5 m.
2. Unproject with the intrinsics (scaled from the color image resolution to the depth resolution) and transform to world space with `cameraTransform`.
3. Compute height above the floor and position in a **body frame**: forward along the user's walking direction (camera forward projected to horizontal), right perpendicular to it.

This replaces every image-space zone in Shepherd and removes the orientation bug class entirely.

### 4.3 Occupancy grid

A top-down grid in the body frame, 0 to 4 m forward and 1.5 m to each side, 10 cm cells. Classify each point by height above floor:

| Height above floor | Meaning |
| --- | --- |
| below -0.12 m | Drop-off (curb down, stair down, hole) |
| -0.12 to 0.08 m | Floor |
| 0.08 to 2.0 m | Obstacle |
| over 2.0 m | Ignore (ceiling, sky, high branches) |

Mark a point between 1.2 and 2.0 m as **overhead** when there is no obstacle below it in the same cell. That is the hazard a cane misses. *Update after first device tests:* overhead was wrong too often on a chest mount, so it is drawn in the debug views but neither spoken nor blocking by default (`overheadBlocks`).

A cell needs at least 3 points to be marked, and must be marked in 2 of the last 3 frames before it counts. Cells with no points stay `unknown`. A large unknown region on the floor directly ahead, where floor was visible a moment ago, is a drop-off candidate too (LiDAR often returns nothing at a step edge).

Known LiDAR weak spots: glass, mirrors, black or shiny surfaces, and strong sunlight reduce range. Test all of them on day one and show them in the debug view.

### 4.4 Gap planner

Define a **walking corridor**: 0.7 m wide (user width plus margin), straight ahead from the body.

1. For 16 candidate headings from -40 to +40 degrees, march a 0.7 m wide corridor forward and record the free distance until the first obstacle, drop-off, or overhead cell.
2. Smooth the 16 distances with the `[0.25, 0.5, 0.25]` kernel from Shepherd.
3. Score each heading: free distance, minus a penalty for turning away from straight, minus a penalty for turning away from the previous chosen heading. In Guided mode, add a bonus toward the route bearing, scaled by `(1 - urgency)` so obstacles always win.
4. Urgency comes from the free distance straight ahead: 0 beyond 3 m, rising to 1 at 0.6 m. Use Shepherd's curve shape (`powf(x, 0.6)`) as a starting point.
5. Smooth the output with an exponential moving average (start around 0.15 per frame at 30 fps) and apply hysteresis: the chosen side must hold for 300 ms before it can change.

Process at 30 fps, not 60. It halves heat and is still fast enough at walking speed (about 1.3 m/s, so 4 cm per frame).

---

## 5. Thermal and battery

A phone running LiDAR, the camera, and processing inside a chest harness gets hot, and the 13 Pro throttles first. Plan for it from the start:

- Watch `ProcessInfo.thermalState`. At `.serious`, drop to 15 fps and stop color capture. At `.critical`, say "Phone is too hot, guidance paused" and stop.
- Do not request the color image unless a debug view or the classifier needs it.
- Keep the screen at minimum brightness while walking (it faces the body anyway) and set `isIdleTimerDisabled = true` so the session is not killed.
- Show battery and thermal state in the debug HUD.

---

## 6. Feedback: voice and vibration

### 6.1 Channels

| Tier | When | Speech | Vibration |
| --- | --- | --- | --- |
| Stop | Urgency at least 0.9, or drop-off within 1.5 m | "Stop." or "Step down." Interrupts anything. | One long strong buzz (0.6 s, full intensity) |
| Steer | Path ahead blocked within 2.5 m and a gap exists | "Left." "Right." "Slight left." "Slight right." | Pulse rate rises as the obstacle gets closer |
| Stairs | Three or more regular steps up or down within 2.5 m, seen by both corridor halves for 0.6 s | "Stairs going up ahead." / "Stairs going down ahead." | Two quick sharp taps |
| Clear | Path was blocked and is now clear for 1 s | "Clear." (optional, user setting) | Nothing |
| Status | Mode change, calibration, errors, low battery, heat | Full short sentence | One light tap |
| Guided | Turn instructions, arrival | Full sentence | One light tap before speaking |

Vibration encodes how urgent, never which way. Do not invent left/right vibration codes unless the blind tester asks for them; they add learning burden and are easy to confuse.

### 6.2 Speech source

Generate every fixed phrase once with ElevenLabs, using a script in `tools/generate_cues/`, and bundle the audio files in the app. Fixed phrases cover the Stop, Steer, Overhead, Clear, and most Status cues, plus distances of one to four meters (the sensor's useful range). Bundled clips play with no network and no delay, and keep the voice consistent.

For dynamic text (directions and street names in Guided mode), use live ElevenLabs (`eleven_flash_v2_5`) when a key is configured and the reply arrives within 1.5 s, and fall back to the best installed `AVSpeechSynthesizer` voice otherwise. Never route Stop, Steer, Stairs, or Step down through the network.

The team chose (2026-10-25) to ship the ElevenLabs key inside the demo app for live directions: it comes from a gitignored `Scout/Secrets.plist` or the Settings screen, never from git. Anyone with the app binary can extract it, so use a key with a low spending limit.

### 6.3 Speaker rules

- Audio session: `.playback` category with `.duckOthers`, so cues play with the silent switch on and lower other audio.
- Volume: play clips normalized loud. Warn at start if system volume is below 70 percent.
- Make sure the harness does not cover the speaker grille on the bottom edge. Test in a noisy hallway and outdoors next to traffic.
- Speak on change, not on every frame. Repeat a Steer cue only if it is still true after 2.5 s.
- Stop preempts everything, mid-word. Lower tiers queue and expire after 1.5 s.
- A user setting for verbosity: Minimal (Stop, Stairs, Step down only), Normal (adds Steer), Chatty (adds Clear and distances).
- Silence means the path is clear.

### 6.4 Control without touching the screen

The screen faces the chest, so:

- Expose App Intents so Siri can run "Start Scout", "Stop Scout", "Passive mode", "Navigate to <place>", "Quieter", "More detail".
- Before mounting, the home screen is one large button: tap anywhere to start. It must work fully with VoiceOver.
- On the iPhone 17 Pro, the Action button can be assigned to the start/stop intent.

---

## 7. Debug and visualization

The team must see exactly what the camera sees and why the app made each decision. Because the phone faces forward on someone's chest, the person watching is usually a teammate walking alongside, or the team afterward.

### 7.1 How to watch

1. **Live:** AirPlay screen mirroring from the iPhone to a teammate's Mac. Zero code, works today. Put the phone in debug mode before mounting.
2. **Afterward:** iOS screen recording captures the debug overlay with no extra code.
3. **Replay (build this, it is the most valuable tool):** record frame bundles to disk during a walk, then replay them on the phone or in the simulator through the exact same pipeline. Change a threshold, replay, compare. Store depth, confidence, pose, intrinsics, and a JPEG of the color frame at 5 fps. Name sessions by date and a spoken tag.

### 7.2 Debug screens

One debug mode with a tab per module, all reading the same snapshot:

| Screen | Shows |
| --- | --- |
| **Camera overlay** (main screen) | Live color image, with every sampled depth point drawn on top colored by class: floor green, obstacle red, drop-off purple, overhead orange, low confidence gray. The walking corridor drawn as a translucent band projected onto the floor. The chosen heading as an arrow. Nearest obstacle distance in large text. With Name obstacles on, detector boxes and confirmed names (section 8). |
| **Depth** | Heat map (Shepherd's color ramp) with a confidence mask toggle. |
| **Top-down grid** | The occupancy grid with cell colors, the 16 candidate headings with their free distances, and the chosen one highlighted. |
| **Side view** | Points projected onto forward-vs-height, with the estimated floor line and the class thresholds as horizontal lines. Best view for tuning drop-offs and overhead. |
| **Planner** | 10-second graphs of heading, urgency, and nearest distance, raw and smoothed. |
| **Cues** | Log of every cue: time, tier, words, vibration, and why it fired or was suppressed. Buttons to fire any cue by hand. |
| **Tuning** | Sliders for every value in `Tuning`, with reset and export. |
| **HUD** (on every screen) | fps, processing ms per frame, thermal state, battery, mode, calibration status, recording indicator. |

The camera overlay should always render at reduced cost (downsampled points, 15 fps) so debug mode does not change the timing it is measuring.

---

## 8. Obstacle identification (built behind a switch, 2026-10-25)

The team chose to build steps 1 to 3 of the identification plan before the gate 6 walk, behind **Settings > Name obstacles**, off by default. Turn it on for the tester only after Passive mode passes gate 6 with it off. Plan: https://claude.ai/artifact/7hXD4tRR26gGwYNLwd3YdZ

- **Rule:** the camera only names obstacles the depth grid already holds. It never creates, removes, or delays a cue. Stop plays its own clip first; the name follows ("Stop. Person.").
- **Tiers:** Hazard (person, bike, motorbike, vehicle, dog, pole) is named in Normal and Chatty when it is the obstacle the planner reacts to. Common (chair, bench, table, couch, plant, bag, hydrant, parking meter) is named in Chatty only. Chatty also says "Person. On your left." for a hazard just outside the corridor. Minimal never names anything. Each object is named once, again after 10 s or after it left the path for 3 s.
- **Sources:** Vision's `VNDetectHumanRectanglesRequest` and `VNRecognizeAnimalsRequest` at 5 Hz (2 Hz when warm) on their own queue; `LabelFusion` places each box with the depth inside it; `LabelTracker` confirms a name seen in 3 of the last 5 runs. Poles come from the grid (`PoleDetector`), confirmed in 12 of 20 frames, at least 0.6 s old, and standing still. Vision overrides a pole wherever it has seen something in the last second.
- **Next (step 4):** a COCO Core ML detector (YOLO11n, AGPL-3.0, accepted for the hackathon) for bikes, cars, and furniture, mapped onto the same labels.

Do not name the protocol `ObjectIdentifier`; that is a Swift standard library type.

---

## 9. Build order and gates

Each phase ends with a gate. Do not start the next phase until the gate passes, unless the team says so.

1. **Skeleton.** Xcode project, module protocols, `Tuning`, ARKit capture on a background queue, HUD. *Gate:* runs at 30 fps on the 13 Pro with the HUD showing.
2. **Record and replay.** *Gate:* record a 30 second walk, replay it, and get identical planner output twice.
3. **Point cloud, floor, and camera overlay.** *Gate:* on the overlay, a wall turns red, the floor stays green, and a curb or stair edge turns purple, all at the right distance. Resolve the orientation question here.
4. **Grid and planner, with top-down and side views.** *Gate:* replaying a cluttered hallway walk gives a stable heading with no left-right flipping.
5. **Cues: bundled voice and vibration.** *Gate:* the Stop cue plays in airplane mode in under 100 ms from the triggering frame, measured in the cue log.
6. **Passive mode end to end, Siri intents, verbosity.** *Gate:* the blind tester walks an indoor course safely with a cane and a spotter, and says the cues help more than they distract.
7. **Guided mode.** Walking routes from MapKit (no API key), and ARKit `.gravityAndHeading` for a north-aligned body heading instead of Shepherd's ORS routing and custom compass fusion. *Gate:* one short outdoor route end to end.
8. **Identification** (section 8). Built early behind a switch that stays off until gate 6 passes. *Gate:* the tester walks the gate 6 course with names on in Normal, then Chatty; no wrong Hazard names, and the names help more than they distract.

If time runs short, cut Guided mode before cutting replay, drop-off detection, or the camera overlay.

---

## 10. Testing with the blind tester

- The tester always uses their own cane or guide dog. A sighted spotter walks beside them, within arm's reach, every time.
- Indoor course first (hallway with chairs, a doorway, a box at waist height, something at head height), then outdoors on a quiet path with a curb.
- Ask before and after: which cues were useful, which were noise, was anything late, was the vibration noticeable through clothing.
- Record every test run with the replay recorder, so problems can be reproduced without asking the tester to walk again.
- Let the tester set verbosity. Their preference beats the defaults in this file.

---

## 11. Repository layout

```
Scout/                 Xcode project
  App/                     App entry, App Intents, settings
  Capture/                 ARKit source, replay source, recorder
  Perception/              Calibration, point cloud, grid, planner
  Feedback/                Cue arbiter, speech, haptics, cue assets
  Navigation/              Guided mode (later)
  Identification/          Labels, Vision detector, fusion, tracking, poles
  Debug/                   Overlay, views, HUD, tuning
ScoutTests/            Unit tests, replay-based tests
tools/generate_cues/       ElevenLabs script and phrase list
reference/shepherd/        Read-only reference, not in the build
docs/                      This file and notes
```

Write unit tests for the pure parts: unprojection, height classification, grid marking, gap scoring, hysteresis, and the cue arbiter's priority and expiry rules. Use recorded sessions as test fixtures once they exist.

---

## 12. Open items

- [ ] Confirm the hackathon's rules on reusing Shepherd code.
- [ ] Confirm the harness keeps the phone portrait and does not block the bottom speaker.
- [ ] Pick the final app name.
- [ ] Measure LiDAR range outdoors in daylight on both phones.
