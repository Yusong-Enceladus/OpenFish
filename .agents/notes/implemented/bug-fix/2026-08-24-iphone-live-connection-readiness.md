# Agent Note: iPhone live connection readiness follows authenticated WebSocket open

Status: implemented

English | [中文](2026-08-24-iphone-live-connection-readiness.zh.md)

## Problem

The iPhone could complete REST pairing and persist a valid Host identity while remaining at Connecting. `URLSessionWebSocketTask.resume()` only scheduled the two event sockets, and using a ping immediately afterward as a readiness probe could wait indefinitely before the HTTP upgrade completed on a physical device. Host replacement also needed a bounded attempt so one socket generation could not consume the reconnect loop forever.

## Decision

The iPhone live connection publishes Connected only after both authenticated Host event sockets report `URLSessionWebSocketDelegate.didOpenWithProtocol`. The shared TLS delegate bridges each open, close, and completion callback into the async connection attempt while preserving certificate pinning and bearer authentication.

Each socket-open generation has a five-second bound. A close, transport completion, or timeout fails that generation; the connection owner cancels both sockets and retries them together with bounded backoff. Foreground activation creates a new generation only when no connection task is active, while background entry saves the projection and reaches connection quiescence.

Physical test launches can opt into a DEBUG-only keep-awake environment switch so Host-replacement checks remain foreground and distinguish network reconnection from device auto-lock. Release builds never change the user's idle-timer policy.

## Verification

A physical iPhone completes fresh pairing, restores the saved profile after a cold launch, observes an exact installed Host process replacement, and reconnects without another pairing code while remaining foreground. A separate DEBUG hardware probe activates the real microphone and survives five start/stop cycles. The iOS app also completes its physical-device build with the UI-test runner signed for the same device.

The Simulator UI lane passes explicit Host states, cached offline behavior, accessibility-size empty/setup states, the declared Harness architecture, approval and structured-question completion, repeated voice toggles, and the deterministic microphone-denied recovery path. The authenticated Host test lane proves that one bearer can revoke only its own paired device and that replay is rejected. The physical XCTest device-control channel did not attach to the runner, so those Simulator and protocol results are not reported as physical end-to-end UI proof.

## Alternatives considered

**Treat `resume()` as connected.** Scheduling a URL session task does not prove that the authenticated HTTP upgrade succeeded, so this would publish a false live state.

**Send an immediate ping.** A pre-open ping is not a portable readiness barrier for Apple's WebSocket implementation and can leave the attempt waiting indefinitely.

**Refresh REST state before the event sockets open.** This creates a predictable startup race and still cannot prove that approvals, questions, and task events will arrive.

## Consequences

Connected means both authenticated downlinks are usable, and a Host handoff cannot strand the app inside one unbounded socket generation. Reconnection can take one bounded open interval plus backoff, and DEBUG physical checks may deliberately keep the screen awake when the test launch requests it.
