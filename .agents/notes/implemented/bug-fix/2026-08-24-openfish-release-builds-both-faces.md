# Agent Note: OpenFish releases build both package faces before packaging

Status: implemented

English | [中文](2026-08-24-openfish-release-builds-both-faces.zh.md)

## Problem

The OpenFish release script built only the Host face before copying workspace packages into the embedded runtime. Some packages used by that Host publish their Node entry during the Client build face. In particular, `dsh-client-connection` could retain an old `lib/index.js` while its current TypeScript source and declarations passed. The source Host accepted a native LAN TLS request, but the packaged Host rejected the same request.

## Decision

The release build runs the complete `build:lib` contract, which emits both the Host and Client faces, before it assembles the embedded runtime. The packaged Host smoke connects through an active non-loopback IPv4 authority so a stale connection entry cannot pass through the loopback trust shortcut.

## Verification

The packaged runtime must answer the versioned health route through its real LAN TLS listener. The same smoke also proves listener isolation and submits an invalid pairing body through the registered route without changing the device registry.

## Alternatives considered

**Build only `dsh-client-connection` explicitly.** That would encode one known cross-face dependency in the release script and fail again when another Client-phase Node package enters the Host closure.

**Trust TypeScript output under `lib/types`.** The packaged manifest exports `lib/index.js`; fresh declarations do not make a stale runtime entry fresh.

**Keep a loopback-only TLS smoke.** Loopback deliberately bypasses the deployment authority list and therefore cannot represent an iPhone request.

## Consequences

Release builds perform the additional Client-face build, but every packaged Node entry now comes from the current checkout. A package that works only from source or only through loopback fails before a DMG is produced.
