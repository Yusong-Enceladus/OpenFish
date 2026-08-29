# Agent Note: OpenFish Harness proof, Studio, and Lab

Status: implemented

English | [中文](2026-08-29-openfish-harness-proof-studio-and-lab.zh.md)

## Problem

OpenFish could already install and run multiple Harnesses, project their live
configuration into native clients, retain exact Pack versions, and expose a
manifest graph. Those capabilities did not by themselves prove the product's
core claim. One compatibility label could hide whether OpenFish had merely
parsed a Pack, found an executable, launched a protocol, or completed a real
session. A later preflight could replace stronger session evidence, and evidence
from one Pack version could be read as evidence for another.

The architecture surface had the same ambiguity. A Pack-authored graph, a live
trace, and a Host compatibility result were visually adjacent but not a common
proof contract. Desktop coordinates squeezed directly onto iPhone made the map
hard to read. Studio could edit real Driver-backed controls but did not clearly
separate non-mutating admission, exact installation, live preflight, and real
task observation.

Finally, answering “which Harness is best?” still depended on anecdotes. Shell
compatibility is not task quality, repository popularity is not task quality,
and a single successful prompt is not a leaderboard. OpenFish needed an
inspectable comparison path without collecting answers or silently spending
provider quota.

## Decision

### Exact-version proof ledger

Every catalog row now carries five separate Host-derived facts:

1. **Declared** records that the Pack and its graph passed admission. It does
   not verify the publisher's architectural claim.
2. **Resolved** records the exact executable and installation identity. A
   version pin remains distinct from a verified checksum.
3. **Observed** records a real create, resume, or fork result for that exact
   Pack version. Only operation metadata is retained, never task content.
4. **Evaluated** records the exact Host operation that produced compatibility:
   bundled contract, Driver admission, live preflight, create, resume, or fork.
5. **Opaque** records that private internals remain one explicit boundary
   rather than an invented graph.

Harness state advances to version 8 and stores operation evidence by exact Pack
version and basis. Migration treats a pre-v8 compatibility result conservatively
as Driver admission. Update, rollback, and restart preserve retained-version
evidence. A later preflight can change the latest compatibility conclusion but
cannot erase a real session observation, and version A never certifies version
B. A fully verified summary requires every applicable fact to be verified;
available observation support is not mislabeled as an observed run.

Pack graph evidence remains `declared`, `resolved`, or `observed`. `evaluated`
belongs only to the Host proof ledger, so an untrusted Pack cannot author its
own compatibility result. Legacy `source-derived` and `runtime-observed`
manifest values remain readable and normalize to the canonical vocabulary so
pinned tasks are not stranded.

### Progressive Lens and narrow-screen map

Mac and iPhone use the same four lenses: Overview, Map, Trace, and Studio.
Overview leads with the proof ledger. Map is the default architecture view and
shows every declared relationship; the stage summary is a secondary reading
aid. Trace remains an ordered, bounded, content-free record tied to declared
nodes and edges. Studio owns authoring and publication semantics.

Built-in DSH, Codex, and OMP manifests now carry intentional authored positions
instead of depending on source-array order. The Mac canvas preserves those
positions with complete node hit targets, selection, search, keyboard focus,
zoom, and pan. iPhone does not shrink that desktop canvas: it preserves authored
vertical bands or inferred dependency levels and splits each band into at most
two full-size cards per row. Selecting a component highlights only its declared
routes, while exact incoming and outgoing relationship labels move into the
component inspector instead of obscuring nodes or crossing lines. The topology
and evidence remain shared while the reading layout is device appropriate.

Demo fixtures are regenerated from the same built-in manifests and carry an
explicit partially verified Demo ledger. Synthetic trace events demonstrate
interaction only and never impersonate a live provider or compatibility run.

### Studio proof stages

Studio adds a Review page that shows material changes, the immutable draft,
installed, and retained version line, and four proof stages: draft admission,
exact installation, prompt-free live preflight, and real task observation.

`validate-draft` is a Host-local, non-mutating operation. It runs Pack schema
and custom-Pack admission without adding a catalog row, installing code, or
starting a Harness. Save remains a separate mutation. Install and Live
Preflight remain explicit and require the same code-consent and exact-version
boundaries as ordinary Harness setup. A behavioral edit to an installed version
is rejected until its version changes. Existing typed Driver bindings,
secret-reference validation, undo/redo, diff, import/export, live preflight,
version retention, and GitHub review publication remain the executable Studio
contract; unsupported nodes are never presented as behavior-changing controls.

### Harness Lab

Harness Lab prepares dedicated No Project sessions for two or more installed,
authenticated Harnesses and discovers each route's live account label, model
catalog, model-specific reasoning values, and permission options. It sends the
same explicit task sequentially, rotates order by round, supports repetitions
and timeout, never answers an approval request on the user's behalf, and retains
each task for ordinary inspection. The selected permission mode may still allow
an operation without asking, so the exact mode remains part of every result.

The result separates mechanical facts—terminal reason, elapsed time, first
output, tool and approval counts, provider-reported tokens, and final-answer
length—from an explicit user rating and private note. It does not compute a
global score or declare a winner. Preparing is prompt-free; running clearly
warns that the selected subscription or API route may consume quota.

The optional JSON report excludes session ids, response text, account labels,
paths, and local task ids. Task text and private notes are excluded by default
and have separate opt-ins; diagnostics and optional notes pass local redaction.
The report records exact Harness/model/reasoning/permission routes, run order,
repetitions, failures, measurements, and its statistical limitations.

## Alternatives considered

**Use one green compatibility badge.** Rejected because it collapses manifest
admission, executable identity, launch readiness, and real session evidence.

**Treat a successful preflight as task observation.** Rejected because a
prompt-free protocol initialization does not prove model inference, tools,
resume, or answer quality.

**Let Packs declare evaluated evidence.** Rejected because compatibility is a
Host-owned conclusion, not publisher-authored graph metadata.

**Compress the Mac graph onto iPhone.** Rejected because readable labels and
touch targets matter more than preserving presentation coordinates. The phone
preserves topology, not desktop geometry.

**Publish a Harness leaderboard from community heat or one user's runs.**
Rejected because account, model, settings, tasks, repetitions, failures, and
subjective quality materially change the result. Lab provides inspectable
experiments, not false universal ranking.

**Export prompts and answers automatically for reproducibility.** Rejected.
Original tasks remain locally inspectable, while the comparison report is
content-free by default and includes task text only with explicit consent.

## Consequences

A newly admitted or installed Harness will usually show partially verified
until live evidence exists. This is intentional friction: discoverability and
Driver admission are useful, but neither is a completed task.

A failing later preflight can make the current compatibility conclusion fail
while an earlier successful session remains visible as an independent observed
fact. Consumers must read the ledger rather than infer chronology from one
color.

Unknown private Harnesses remain useful through installation, authentication,
configuration, compatibility, trace, and diagnostics, but their internal map
stays opaque. Rich graphs require Pack evidence and cannot be generated from a
Harness name.

Harness Lab can spend provider quota and cannot make heterogeneous Harnesses
scientifically identical. Its dedicated No Project sessions, exact routes,
rotated order, repetitions, retained tasks, and explicit limitations make
comparisons auditable without claiming more than the experiment establishes.

## Testing

The focused contract covers non-mutating draft admission, exact-version proof
retention across preflight, update, reload, and pinned lookup, and controller
routing. The completed validation run passed all 250 Harness contract tests,
the TypeScript type check, Mac and iPhone Simulator Debug builds, focused Mac
Map/Trace/Studio/Builder/Lab UI tests, and iPhone Map/Trace UI tests. The Mac and
iPhone Map screenshots were inspected after the tests; graph prose no longer
overlaps nodes, exact relationships remain available in the selected component
inspector, and Demo Lab routes remain explicitly synthetic and offline.

Generated Codex API catalogs and deterministic Mac/iPhone Demo catalogs derive
from the updated types and live Pack manifests. The public-source privacy gate,
source release gate, standalone Host smoke, and unsigned arm64 Release artifact
are rerun after the final native changes. Physical-device microphone and
background-recovery tests remain part of the release verdict rather than being
inferred from Simulator coverage.
