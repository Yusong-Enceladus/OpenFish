# Agent Note: OpenFish Native Interaction Consistency

Status: implemented

English | [中文](2026-08-20-openfish-native-interaction-consistency.zh.md)

## Problem

The native macOS and iPhone clients exposed model selection, conversation ordering, project creation, dictation, and task navigation through inconsistent presentation. A chosen reasoning effort disappeared behind the model name, assistant reasoning rendered after its answer, the macOS composer used a placeholder with different text insets than its editor, local project creation incorrectly delegated to a Host picker without native capability, and task metadata permanently consumed sidebar height.

## Decision

Both clients present the selected model and reasoning effort as one persistent label and mark the exact current choice inside nested menus. Assistant reasoning remains a distinct disclosure rendered before answer text, matching the order of the authoritative content blocks without replacing a reasoning-only block with answer prose.

The macOS composer owns one AppKit text view for placeholder, caret, and entered text geometry. Its text container has explicit insets and line-fragment padding, plain Return submits, and Shift-Return inserts a newline. The iPhone composer uses one native multiline field style with explicit font and vertical inset. Dictation failures surface through each client's existing error presentation, while intentional recognition cancellation cannot publish a late false failure.

The local macOS Add Project action opens `NSOpenPanel` directly and sends only the chosen path to `workspace.create`; remote connections continue to use the Host directory browser. Desktop task rows omit idle relative time, keep live and approval state as compact indicators, and expose title, project, and update time through the native hover help. Both native task lists use reduced row heights.

The product display name is OpenFish. Its installed app icon and in-app mark use a fish outline around the preserved `>_` terminal symbol. Internal persistence keys and wire identifiers retain their established values because changing product presentation does not require invalidating device pairing, cached projections, or user preferences.

## Alternatives considered

- **Keep platform-specific interaction patterns.** That preserves local implementation shortcuts but makes the same Host state appear different on macOS and iPhone.
- **Rename persistence and wire identifiers with the product display name.** Presentation does not justify invalidating compatible device, cache, and preference state.

## Consequences

Model state remains visible after menu dismissal, conversation chronology reads in production order, local folder selection no longer depends on a composed Host picker, and task navigation fits more work without hiding detailed metadata. The shared OpenFish mark remains legible at sidebar and app-icon sizes while preserving the terminal identity.
