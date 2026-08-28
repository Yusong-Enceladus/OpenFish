# OpenFish macOS client

English | [中文](README.zh.md)

Native SwiftUI/AppKit shell for the OpenFish product composition. The app
consumes the existing `/api` RPC assembly, Host and mux WebSocket streams,
session projections, and answerable approval frames. It embeds the OpenFish
Host plus a pinned Node runtime, starts them when no healthy local Host exists,
and uses the Harness service to install and run DSH, ACP catalog entries, and
custom Harness Packs without introducing a second session store or a
native-only business protocol.

A clean install does not silently select DSH or a model. First-run onboarding
loads the live Harness catalog, asks for a default, installs its pinned runtime,
discovers its authentication methods, and stores credentials in the user's
macOS Keychain through a write-only Host API. DSH model choices are limited to configured
providers; external ACP Harness model choices come from that live session's ACP
configuration. The default can be changed in Settings, while existing tasks
remain pinned to the Harness and Pack version that created them. “No Project”
tasks use a session-owned `$DSH_HOME/openfish/sessions/no-workspace/<session-id>` directory,
so two unrelated tasks never share an accidental Desktop or scratch cwd.

The current vertical slice implements project/task navigation, durable session
loading, streamed user/assistant/tool event projection, model selection,
cancellation, DSH permission selection through the `permissions` projection
and `commands/execute` Remote, and approval-response paths. The primary shell
is native; a WebView is not used for task navigation or conversation
rendering.

The release workflow builds separate Apple Silicon and Intel artifacts from
clean GitHub-hosted runners. Pull requests produce unsigned test artifacts;
`openfish-v*` tags require a Developer ID certificate and notarization
credentials, then publish signed, notarized DMGs and SHA-256 files. The bundle
contains pinned Node, npm/Bun dependencies, and uv, and its release smoke starts
the embedded Host with an empty isolated state directory.

Release acceptance requires the TypeScript and native builds, isolated Host
smoke, no-project task creation, first-run Harness selection, authentication,
model discovery/selection, resume pinning, privacy scan, and signed/notarized
artifact checks to pass. A Registry listing is discovery metadata rather than
a quality endorsement; Open Fish reports its own compatibility result only
after actually starting that Pack.

Build without opening Xcode:

```sh
./build.sh
```

Build and inspect a local unsigned release artifact:

```sh
./script/build_openfish_release.sh "$(uname -m)"
```

The executable is written to `.build/OpenFish`. The integrated build-and-run
workflow packages a standalone Host runtime inside `OpenFish.app`; users do not
need a separate Node or DSH installation. The development launcher installs one
copy in the user's Applications folder and exercises that embedded Host, so a
stale source-checkout Host cannot mask packaging defects.

Run the isolated composed-runtime behavior path without an external model
request or a visible application window:

```sh
./Tests/behavior-smoke.sh
```
