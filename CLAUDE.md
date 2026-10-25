# SBUHacks26

Chest-mounted iPhone LiDAR app that guides blind and low-vision walkers with spoken cues and vibration.

Read `docs/FOUNDATION_PROMPT.md` before any work. It holds the constraints, architecture, build order, and gates.

- `reference/shepherd/` is read-only reference from the team's earlier project. Never add it to the Xcode target.
- Never put API keys in the app or in git. ElevenLabs is used only by `tools/generate_cues/`.
- Follow the phase gates in section 9 of the foundation prompt; ask the team before skipping one.
