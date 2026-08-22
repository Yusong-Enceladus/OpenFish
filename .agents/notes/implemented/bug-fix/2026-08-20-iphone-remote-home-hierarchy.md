# Agent Note: iPhone Remote Home Hierarchy

Status: implemented

English | [中文](2026-08-20-iphone-remote-home-hierarchy.zh.md)

## Problem

The iPhone target lacked a generated launch screen, so modern devices could present the app in a letterboxed compatibility canvas. The Remote home also exposed every task in always-open workspace sections, which consumed the small screen before the user chose a project.

## Decision

The iPhone-only target generates a native launch screen, requires the full screen, and declares phone orientations so SwiftUI receives the full device canvas instead of an iPad-compatible window. The Remote home reproduces the ChatGPT Remote geometry with a 44-point custom header, 32-point connected-computer chips, 44-point flat task rows, and a persistent 40-point bottom search and action bar. The custom bars avoid iOS 26 navigation and Liquid Glass sizing that otherwise makes the controls substantially larger than the Remote reference. DSH workspaces remain first-class 36-point collapsible groups because they are the user's project navigation unit. The workspace with the most recently updated task expands first; search temporarily reveals matching tasks across collapsed groups.

Session rows are indented beneath their workspace header rather than sharing the workspace's leading edge. Every task collection filters Host-declared blank sessions, including unfiled and archived collections, so placeholder sessions never appear as repeated `New task` rows and an empty `Other tasks` group disappears. A recorded `cwd` is not Git metadata, so the client does not infer or draw a Git/worktree badge from it; such a badge may appear only after the Host protocol provides explicit Git data.

Task detail uses one continuous conversation instead of separating messages into decorative cards. User, assistant, reasoning, notice, and web-result prose render through a native CommonMark/GFM renderer rather than a raw SwiftUI `Text`; headings, lists, tables, links, block quotes, inline code, fenced code, and task lists therefore retain their authored structure while incomplete streamed Markdown degrades readably. Durable image blocks load through the authenticated `session.attachment` boundary instead of leaking Host paths or remote image URLs.

Tool activity stays compact and expandable. Its collapsed summary is derived from presenter titles and salient argument fields, not serialized argument JSON. Expanded content switches on the Host-owned render-intent card: terminal commands and output use copyable monospace blocks with exit state, diffs use colored before/after lines, reads keep line numbers and language hints, searches keep grouped matches or paths and truncation recovery, web results keep Markdown answers and sources, and the generic fallback pretty-prints structured input/output while preserving every content block. Permission requests use a bottom-oriented action card, and the composer remains fixed at the bottom. These presentation choices preserve the additional DSH controls in the task menu without placing them in the primary reading path.

The hierarchy remains a presentation of Host workspace and session data. Pairing, synchronization, task selection, and conversation execution keep their existing owners and wire behavior.

## Alternatives considered

**Keep ordinary always-open `Section` groups.** Native sections require less state, but they reproduce the unbounded task wall that makes project selection difficult on a phone.

**Keep the system `List`, section chrome, and navigation-bar search.** Those controls provide swipe actions and system styling with little code, but together they make every project look like a wide settings card and move the primary actions away from the Remote task surface. The custom scroll hierarchy still uses semantic SwiftUI controls, Dynamic Type, context menus, and labeled actions.

**Copy ChatGPT Remote's time groups exactly.** Pinned and Today are useful for the official product's global task stream, but replacing DSH workspaces with them would remove the project-level folding the client needs. The implementation borrows the density and navigation pattern while keeping workspace ownership visible.

## Consequences

The home screen fills current iPhone displays and lets users scan projects before expanding task history. Expansion state is intentionally transient; reopening the app again favors the workspace with the freshest work. Search takes precedence over collapsed state so a matching task is never hidden. Blank placeholders cannot be selected from any home collection, and workspace counts describe only started tasks. Row archiving moves from a swipe action to a context menu, trading one-handed discoverability for the flat Remote layout; restore remains directly available in the expanded archive group.
