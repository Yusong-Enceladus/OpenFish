# HTTP Server

English | [中文](web-server.zh.md)

[dsh-host-webserver](../../packages/host/webserver) is the browser HTTP carrier for the GUI host: a single `node:http` plugin providing `ctx.webServer`, a named-route registry, index.html transform callbacks, and one fallback handler that a plugin may claim. It is not part of the agent loop and not a capability seam; it knows no harness concepts, and another plugin registers every feature route, including the `/api` bridge, plugin bundles, and the HMR event stream ([layering note](../../.agents/notes/implemented/architecture/2026-07-19-gui-layering-and-rpc-protocol.md)). It serves browsers only: Electron loads the built files over `file://` and sends fetch requests through an IPC bridge instead of this server.

Source: [`packages/host/webserver/src/index.ts`](../../packages/host/webserver/src/index.ts)

## Routes

```ts type-equiv
/** Route match kind: 'exact' matches the pathname verbatim; 'prefix' p matches p and p/<anything>. */
type WebRouteKind = 'exact' | 'prefix'
```

```ts type-equiv
/** One named route registration. */
interface WebRoute {
  kind: WebRouteKind
  /** Absolute pathname, no trailing slash. */
  path: string
  /** Owns the full response lifecycle (may hold the response open, e.g. SSE). */
  handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>
}
```

Match order is fixed: exact table first, then longest matching prefix, then the registered fallback. Registration order carries no request-facing semantics — named routes are composed to be disjoint, and the fallback seat answers anything no named route claims; one owner only, a second registration throws. The shipped Web composition claims the seat with [`dsh-host-frontend-static`](../../packages/host/frontend-static/src/index.ts), the SPA dist server with locked semantics: non-GET/HEAD is 405, traversal outside the dist root is 403, any miss falls back to `index.html` with HTTP 200 (SPA routing), and unknown extensions ship as octet-stream.

## Config

```ts type-equiv
/** Gateway config: the listen address. */
interface Config {
  /** Listen host; the two supported values are loopback and all-interfaces. */
  host: '127.0.0.1' | '0.0.0.0'
  /** Listen port; zero requests an OS-assigned port. */
  port: number
  /** Optional TLS-only all-interfaces listener for native remote clients. */
  remoteTlsHost?: '' | '0.0.0.0'
  /** Remote TLS port; zero requests an OS-assigned port. */
  remoteTlsPort?: number
  /** PEM certificate path for the remote TLS listener. */
  remoteTlsCertificatePath?: string
  /** PEM private-key path for the remote TLS listener. */
  remoteTlsPrivateKeyPath?: string
}
```

`host` accepts only `127.0.0.1` (default posture) and `0.0.0.0` (deliberate plain-HTTP exposure). Native remote clients use the separate optional TLS-only listener: it binds only to all interfaces, requires explicit certificate and private-key paths, rejects unsafe key permissions, and does not weaken the browser listener's default loopback posture. Authentication and origin policy remain responsibilities of the routes layered on the carrier. The dist location is an assembly fact of the frontend plugin that claims the seat.

## The service

`WebServer` (`ctx.webServer`) listens immediately on activation; a listen failure (EADDRINUSE…) rejects initialization, and the boot process reports the failed fiber. `register(route)` adds one named route and returns its disposer; a duplicate `(kind, path)` throws because route patterns are a composition-level contract and a collision is a misconfiguration. `tapIndex(transform)` adds a pure html-to-html transform applied to every index response — `/` and each SPA fallback — in registration order; [dsh-client-modules](../../packages/client/modules) uses it to inject the boot manifest. `port` reads the listening port, including the port assigned by the OS when `config.port` is 0.

A request whose handling throws (a malformed %-escape hitting `decodeURIComponent`, a client dropping mid-body) is logged as a warning and answered 400 — or the socket destroyed when headers are already out — never a process exit. Disposal pairs `close()` with `closeAllConnections()` because a handler may hold its response open (SSE) and such connections never end on their own; without the force-close, teardown would hang. The package never prints: the URL line belongs to the shell. Per-package operational detail, including the dev-mode bundle watch pipeline, stays in the [README](../../packages/host/webserver/README.md).

<!-- BEGIN GENERATED cordis-surface (gen-cordis-catalog.ts) — do not edit between markers -->

<a id="cordis-surface"></a>

## Cordis API

Generated from source by `scripts/gen-cordis-catalog.ts` (verified fresh by `pnpm run verify-cordis-catalog` in doc-sync; regenerate with `pnpm run gen-cordis-catalog`) — this section is byte-identical in both language sides of the page. Signature blocks use a `ts cordis-catalog` fence and keep the original source JSDoc; dispatch modes are defined in the [primer](../cordis-primer.md#dispatch-modes), and the framework-inherited `ctx` API lives in [cordis-api/inherited.md](../cordis-api/inherited.md).

<a id="ctxwebserver--webserver"></a>

### `ctx.webServer` — `WebServer`

The browser HTTP carrier service. Activation listens immediately. Route registration order does not affect requests because configured named routes must be distinct, and the fallback handler answers anything not yet claimed during startup with 404 until its owner registers. A listen failure rejects initialization, and the boot process reports the failed fiber.

```ts cordis-catalog
/**
 * Register a named route. Duplicate (kind, path) throws — route patterns are
 * a composition-level contract, so a collision is a misconfiguration.
 * @param route - kind, path, and the owning handler.
 * @returns the disposer removing the route.
 */
register(route: WebRoute): () => void

/**
 * Register an exact-path HTTP upgrade route. Duplicate paths throw because
 * one socket can have only one protocol owner.
 * @param route - pathname and handler owning negotiation plus socket use.
 * @returns the disposer removing the route.
 */
registerUpgrade(route: WebUpgradeRoute): () => void

/**
 * Claim the fallback seat: the handler answering every request no named
 * route matches (the SPA dist server in the shipped Web composition). One
 * owner only — a second registration throws, because two fallbacks cannot
 * compose.
 * @param handler - owns the full response lifecycle of unmatched requests.
 * @returns the disposer releasing the seat.
 */
registerFallback(handler: WebRoute['handler']): () => void

/**
 * Register an index.html transform, applied by the fallback owner to every
 * index response ({@link applyIndexTaps}) in registration order.
 * @param transform - pure html-to-html function.
 * @returns the disposer removing the transform.
 */
tapIndex(transform: (html: string) => string): () => void

/**
 * Run an index.html body through the registered taps in registration order
 * — called by the fallback owner on every index response it renders.
 * @param html - the raw index.html body.
 * @returns the transformed body.
 */
applyIndexTaps(html: string): string
```

Source: [`packages/host/webserver/src/index.ts:90`](../../packages/host/webserver/src/index.ts)

<a id="ctxxnative--xnative"></a>

### `ctx.xNative` — `XNative`

DSH-owned bootstrap service used before a native client joins the ordinary API.

```ts cordis-catalog
/**
 * Return the minimal liveness and protocol-negotiation handshake.
 * @returns Stable OpenCodex product and DSH runtime facts.
 */
handshake(): NativeHandshake

/**
 * Read mounted package names for composition capability detection.
 * @returns A fresh set of mounted Loader package names.
 */
mountedPackages(): Set<string>

/**
 * Describe the live DSH composition and the ordinary API a native client should join.
 * @returns Current bootstrap capability facts.
 */
capabilities(): NativeCapabilities

/**
 * Read the live `/api` method manifest without taking ownership of those methods.
 * @returns Methods sorted by endpoint, or an empty list when Typert is absent.
 */
methods(): NativeMethod[]

/**
 * Register one native device through the DSH pairing store.
 * @param request - Validated device identity supplied by the loopback route.
 * @returns The durable device identity and its one-time bearer token.
 */
pair(request: PairRequest): Promise<PairResponse>

/**
 * Mint one short-lived Host-local code for an iPhone or remote Mac.
 * @returns A single-use code and its expiry time.
 */
createPairingCode(): PairingCodeResponse

/**
 * Redeem a one-time code and create a durable device token.
 * @param request - Device identity and the Host-minted single-use code.
 * @returns The registered device identity and its one-time bearer token.
 */
redeem(request: PairRequest & { code: string }): Promise<PairResponse>

/**
 * List non-secret views of registered native devices.
 * @returns Current, non-expired device registrations.
 */
devices(): Promise<NativeDeviceView[]>

/**
 * Revoke one durable device registration and its bearer token.
 * @param deviceId - Stable identifier of the device to revoke.
 * @returns Whether a current registration was removed.
 */
revoke(deviceId: string): Promise<boolean>
```

Source: [`packages/bundle/x-native/src/index.ts:195`](../../packages/bundle/x-native/src/index.ts)
<!-- END GENERATED cordis-surface -->
