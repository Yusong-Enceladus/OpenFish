# OpenFish iPhone client

English | [中文](README.zh.md)

This directory contains the native SwiftUI iPhone client for the OpenFish DSH composition. It uses the ordinary DSH `/api`, Host stream, mux stream, session log, projections, approvals, questions, queue, model catalog, permission presets, and agent presets. It owns only iOS presentation, Keychain-held device credentials, local speech capture/playback, notifications, and temporary file handoff.

The app implements a Remote-style connected-computer filter, collapsible project and task navigation (including archived tasks and bottom-bar search), paginated shared history, streamed CommonMark/GFM assistant output with fenced code, structured terminal/diff/read/search/web tool details, durable conversation images, bottom-oriented approvals and multi-question answers, queue/steer/cancel, model and reasoning selection, permission confirmation, agent-preset selection for blank tasks, rename/fork, image prompts, local dictation and read-aloud, pairing/reconnect, Codex/DSH import, and DSH export. A fresh stream generation reloads authoritative DSH baselines before applying live events, so reconnect never treats the phone as the business-state owner.

Build the library:

```sh
./build.sh
```

The Xcode application target is described by `project.yml` and the files under `App/`. A composed OpenFish DSH Host is expected at the configured LAN or Tailscale address. Release parity still requires real-device and side-by-side evidence; this README describes implemented reachability, not a release-verification claim.
