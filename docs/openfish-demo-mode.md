# OpenFish demo mode

English | [中文](openfish-demo-mode.zh.md)

OpenFish includes a deterministic state for screenshots, talks, and release previews. Every visible project, task, path, computer name, Harness, model, and conversation in this mode is synthetic.

## Privacy boundary

- The Mac app skips preference migration and does not bootstrap the bundled Host.
- The iPhone app does not restore a saved Host credential and does not start a network connection.
- Demo state is constructed in memory and is not written to the task cache.
- Fixture clients use the non-network `openfish-demo:` URL scheme, and normal Demo State refuses dictation and voice-conversation starts. The separate iPhone voice-smoke launch mode is test-only and is not used to create public assets.
- A visible `DEMO` or `Demo data · offline` label distinguishes it from a live session.

Do not mix real screenshots into `docs/assets/`. Regenerate the three documented images from demo mode whenever the public UI changes. The release check rejects image metadata, private-looking raw strings, and OCR-visible personal paths, email addresses, local hostnames, private IPs, or credential-like values; a human still reviews the final image.

## macOS

Build the native app, then pass the launch argument:

```sh
open apps/x-macos/.build/OpenFish.app --args --openfish-demo
```

The repository's visual smoke runner uses the same fixture to produce a stable 1260 × 820 dark-mode image without launching the Host.

## iPhone Simulator

Build and install the iPhone app in Simulator, then launch it with:

```sh
xcrun simctl launch booted app.openfish.ios --openfish-demo
```

Use an iPhone Simulator with no personal Apple account or content. Capture only the OpenFish window and remove PNG metadata before committing the image.
