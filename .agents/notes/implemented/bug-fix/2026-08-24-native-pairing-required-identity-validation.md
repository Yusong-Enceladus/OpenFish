# Agent Note: Native pairing requires identity validation before registration

Status: implemented

English | [中文](2026-08-24-native-pairing-required-identity-validation.zh.md)

## Problem

`PairRequest` requires `surface` and `deviceName`, but the Schemastery parser treated both HTTP fields as optional. A loopback `POST /x-native/v2/pair` with an empty JSON object could therefore commit a device record with no client identity. The TypeScript interface did not protect the HTTP parser, and the malformed record still consumed one slot in the bounded device registry.

## Decision

The native HTTP schemas mark `surface`, `deviceName`, and the Host-local revocation `deviceId` as required. Pairing validates the complete client identity before `PairingStore` can commit a record, and invalid bodies return the stable `invalid-request` error without changing the registry.

The iPhone client decodes the Host's structured HTTP error before falling back to a numeric status. Pairing failures therefore retain the stable Host error code while credentials remain unmodified.

## Verification

The x-native route test sends an empty pairing object through the registered HTTP handler, expects `400 invalid-request`, and observes an empty device registry. The release Host smoke also exercises the packaged route rather than a source-only parser.

## Alternatives considered

**Trust the `PairRequest` interface.** HTTP JSON is an untyped boundary, so compile-time required properties cannot reject missing runtime fields.

**Validate inside `PairingStore.pair()`.** The store has typed same-process callers and does not own JSON parsing. Duplicating the wire schema there would mix transport validation with serialized registry mutation.

**Repair malformed records while listing them.** That would leave invalid input able to mutate durable state and spend a device slot before a later read. Rejecting before the commit point keeps the registry authoritative.

## Consequences

Local development callers must provide the same identity fields as remote clients. Malformed pairing and revocation requests fail before mutation, and native clients can present a precise Host rejection instead of an undifferentiated HTTP status.
