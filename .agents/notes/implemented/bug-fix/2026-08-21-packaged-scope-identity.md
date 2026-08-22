# Agent Note: Packaged Scope Identity

Status: implemented

English | [中文](2026-08-21-packaged-scope-identity.zh.md)

## Problem

A packaged application can load more than one physical copy of `@deepseek-ai/dsh-scope`. Module-local symbols and parent-link maps then describe different scope universes inside one Cordis runtime. Agent Preset rows lose the scope minted by the roster, so a scoped persona attempts to occupy the global `deployment:persona` slot and every DSH Session using a preset fails to create or resume.

## Decision

The scope context tag and process state use stable `Symbol.for` keys. Every physical module copy in one JavaScript process reads the same context tag, parent-link WeakMap, and carrier WeakMap. Scope keys remain opaque object identities, and separate processes remain isolated by their own global object.

## Alternatives considered

- **Deduplicate only the Open Fish package graph.** A lockfile layout can hide the defect for one artifact but leaves the public scope primitive unsafe for another packager or plugin graph.
- **Remove preset personas.** That discards per-agent identity and masks the broken scope relationship instead of restoring it.
- **Use string scope ids.** String equality would make unrelated runtimes and reused labels collide; opaque object identity remains the correct address.

## Consequences

Source workspaces and packaged applications observe the same scoped registration behavior. Process-global symbol names become compatibility identifiers, while the values stored behind them remain unreachable without an in-process module already executing with application authority.
