# OpenFish iPhone client

English | [中文](README.zh.md)

This directory contains the native SwiftUI iPhone client for the OpenFish DSH composition. It uses the ordinary DSH `/api`, Host stream, mux stream, session log, projections, approvals, questions, queue, model catalog, permission presets, and agent presets. It owns only iOS presentation, Keychain-held device credentials, local speech capture/playback, notifications, and temporary file handoff.

The app implements a Remote-style connected-computer filter, collapsible project and task navigation (including archived tasks and bottom-bar search), paginated shared history, streamed CommonMark/GFM assistant output with fenced code, structured terminal/diff/read/search/web tool details, durable conversation images, bottom-oriented approvals and multi-question answers, queue/steer/cancel, model and reasoning selection, permission confirmation, agent-preset selection for blank tasks, rename/fork, image prompts, local dictation and read-aloud, pairing/reconnect, Codex/DSH import, and DSH export. A fresh stream generation reloads authoritative DSH baselines before applying live events, so reconnect never treats the phone as the business-state owner.

Build the library:

```sh
./build.sh
```

The Xcode application target is described by `project.yml` and the files under `App/`. A composed OpenFish DSH Host is expected at the configured LAN or Tailscale address. Release parity still requires real-device and side-by-side evidence; this README describes implemented reachability, not a release-verification claim.

## Physical smoke checks (Debug)

The `--openfish-voice-autotest` launch argument exercises five real microphone start/stop cycles after the required permissions are granted. It discards recognized speech and replaces `Library/Caches/openfish-voice-hardware-history.txt` with a timestamped, content-free record for each invocation. A cancelled run cannot report success.

The `--openfish-lifecycle-autotest` argument exercises the production connection handlers and waits for a fresh, fully refreshed Host baseline. The separate `--openfish-projectless-autotest` argument prepares a real No Project task without sending a prompt; it refuses to replace unsent text or attachments. After switching to another app and returning, the next Host refresh checks that the same blank task, Harness, model, reasoning selection, and available model catalog survive.

Connection checks replace `Library/Caches/openfish-connection-history.txt` at boot and record only timestamps and coarse states. These checks require an already paired Host and configured default Harness. They do not replace XCTest coverage of taps and layout, and a runner connection failure is not a passing UI test.
