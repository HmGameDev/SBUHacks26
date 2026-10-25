# SBUHacks26

Chest-mounted iPhone LiDAR app that guides blind and low-vision walkers with spoken cues and vibration.

Read `docs/FOUNDATION_PROMPT.md` before any work. It holds the constraints, architecture, build order, and gates.

- `reference/shepherd/` is read-only reference from the team's earlier project. Never add it to the Xcode target.
- Never put API keys in git. The only key the app may hold is ElevenLabs, for live spoken directions, read from the gitignored `Scout/Secrets.plist` or pasted in Settings (team decision, 2026-10-25). Safety cues always use bundled clips from `tools/generate_cues/`.
- Follow the phase gates in section 9 of the foundation prompt; ask the team before skipping one.
