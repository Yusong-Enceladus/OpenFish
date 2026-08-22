# OpenCodex on DSH

The branch name `x-superset` is legacy. The product is OpenCodex: a strict functional, information-architecture, and key-interaction superset of current Codex plus current DSH Web and `anchored`, implemented as a DSH product composition.

The binding architecture is [the OpenCodex Agent Note](.agents/notes/implemented/architecture/2026-08-17-opencodex-on-dsh.md). DSH remains the only runtime; native clients and CLI adapters consume its services, event log, Host API, and plugin graph. `x-native` is limited to bootstrap discovery, authentication/pairing, and transport negotiation.

Current evidence status is tracked in `../codex-parity/generated/parity-spec.json` and derived by `../codex-parity/tools/audit_parity_status.py`:

| Stage | Count |
|---|---:|
| `gap` | 865 |
| `implemented` | 158 |
| `integrated` | 64 |
| `behavior_verified` | 72 |
| `side_by_side_verified` | 0 |
| `release_verified` | 0 |

Package presence, generated command help, copied UI strings, unit tests, and builds do not constitute release parity.
