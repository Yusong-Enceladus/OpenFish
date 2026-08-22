# OpenFish demo mode

OpenFish includes a deterministic state for screenshots, talks, and release
previews. Every visible project, task, path, computer name, Harness, model, and
conversation in this mode is synthetic.

## Privacy boundary

- The Mac app skips preference migration and does not bootstrap the bundled Host.
- The iPhone app does not restore a saved Host credential and does not start a network connection.
- Demo state is constructed in memory and is not written to the task cache.
- A visible `DEMO` or `Demo data · offline` label distinguishes it from a live session.

Do not mix real screenshots into `docs/assets/`. Regenerate the two documented
images from demo mode whenever the public UI changes.

## macOS

Build the native app, then pass the launch argument:

```sh
open apps/x-macos/.build/OpenFish.app --args --openfish-demo
```

The repository's visual smoke runner uses the same fixture to produce a stable
1260 × 820 dark-mode image without launching the Host.

## iPhone Simulator

Build and install the iPhone app in Simulator, then launch it with:

```sh
xcrun simctl launch booted app.openfish.ios --openfish-demo
```

Use an iPhone Simulator with no personal Apple account or content. Capture only
the OpenFish window and remove PNG metadata before committing the image.
