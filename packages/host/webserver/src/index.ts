/**
 * @deepseek-ai/dsh-host-webserver — Web route-registration plugin: a node:http
 * server plus the `webServer` service (HTTP and upgrade route registries,
 * index transform taps, and the single fallback seat for everything no route
 * claims). Knows no harness concepts and serves no files; the composing
 * application's frontend plugin owns dist serving through the fallback hook.
 * Web shape only — Electron loads dist over file:// and carries fetch over an
 * IPC bridge. This package never prints: the URL line belongs to the shell.
 */

import { constants } from 'node:fs'
import { open } from 'node:fs/promises'
import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse, Server } from 'node:http'
import { createServer as createSecureServer, type Server as SecureServer } from 'node:https'
import { X509Certificate } from 'node:crypto'
import type { AddressInfo } from 'node:net'
import type { Duplex } from 'node:stream'
import { Context, Service } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'

declare module '@deepseek-ai/cordis' {
  interface Context {
    webServer: WebServer
  }
}

/** Route match kind: 'exact' matches the pathname verbatim; 'prefix' p matches p and p/<anything>. */
export type WebRouteKind = 'exact' | 'prefix'

/** One named route registration. */
export interface WebRoute {
  kind: WebRouteKind
  /** Absolute pathname, no trailing slash. */
  path: string
  /** Owns the full response lifecycle (may hold the response open, e.g. SSE). */
  handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>
}

/** One exact-path HTTP upgrade registration. */
export interface WebUpgradeRoute {
  /** Absolute pathname, no trailing slash. */
  path: string
  /** Owns protocol negotiation and the upgraded socket after dispatch. */
  handler: (req: IncomingMessage, socket: Duplex, head: Buffer) => void | Promise<void>
}

/** Gateway config: the listen address. */
export interface Config {
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

const MAX_TLS_CREDENTIAL_BYTES = 1024 * 1024

/** Read one PEM file without following a replacement symlink or accepting a public private key. */
async function readCredentialFile(path: string, privateKey: boolean): Promise<Buffer> {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  try {
    const info = await handle.stat()
    if (!info.isFile() || info.size <= 0 || info.size > MAX_TLS_CREDENTIAL_BYTES) {
      throw new Error(`webserver: invalid TLS ${privateKey ? 'private key' : 'certificate'} file`)
    }
    if (privateKey && process.platform !== 'win32' && (info.mode & 0o077) !== 0) {
      throw new Error('webserver: TLS private key must not be readable by group or other users')
    }
    return await handle.readFile()
  } finally {
    await handle.close()
  }
}

/**
 * The browser HTTP carrier service. Activation listens immediately. Route
 * registration order does not affect requests because configured named routes
 * must be distinct, and the fallback handler answers anything not yet claimed
 * during startup with 404 until its owner registers. A listen failure rejects
 * initialization, and the boot process reports the failed fiber.
 */
export class WebServer extends Service {
  static Config: z<Config> = z.object({
    host: z.union([z.const('127.0.0.1'), z.const('0.0.0.0')]).required(),
    port: z.natural().max(65535).required(),
    remoteTlsHost: z.union([z.const(''), z.const('0.0.0.0')]).default(''),
    remoteTlsPort: z.natural().max(65535).default(0),
    remoteTlsCertificatePath: z.string().default(''),
    remoteTlsPrivateKeyPath: z.string().default(''),
  })

  private readonly exact = new Map<string, WebRoute>()
  private readonly prefixes = new Map<string, WebRoute>()
  private readonly upgrades = new Map<string, WebUpgradeRoute>()
  private readonly upgradedSockets = new Set<Duplex>()
  private readonly indexTaps: ((html: string) => string)[] = []
  private fallback: WebRoute['handler'] | undefined
  private server!: Server
  private remoteServer: SecureServer | undefined
  private listenedPort!: number
  private listenedRemotePort: number | undefined
  private remoteFingerprint: string | undefined

  constructor(ctx: Context, private config: Config) {
    super(ctx, 'webServer')
  }

  /** The listening port (the OS-assigned value when config.port is 0). */
  get port(): number {
    return this.listenedPort
  }

  /** The configured bind host (the loopback or all-interfaces literal). */
  get host(): Config['host'] {
    return this.config.host
  }

  /** TLS-only remote port, absent when this composition is loopback-only. */
  get remotePort(): number | undefined {
    return this.listenedRemotePort
  }

  /** Whether this carrier has a separately encrypted all-interfaces listener. */
  get exposesSecureRemote(): boolean {
    return this.listenedRemotePort !== undefined
  }

  /** SHA-256 fingerprint of the remote listener's leaf certificate. */
  get remoteCertificateFingerprint(): string | undefined {
    return this.remoteFingerprint
  }

  /**
   * Register a named route. Duplicate (kind, path) throws — route patterns are
   * a composition-level contract, so a collision is a misconfiguration.
   * @param route - kind, path, and the owning handler.
   * @returns the disposer removing the route.
   */
  register(route: WebRoute): () => void {
    const table = route.kind === 'exact' ? this.exact : this.prefixes
    if (table.has(route.path)) {
      throw new Error(`webserver: duplicate ${route.kind} route "${route.path}"`)
    }
    table.set(route.path, route)
    return () => { table.delete(route.path) }
  }

  /**
   * Register an exact-path HTTP upgrade route. Duplicate paths throw because
   * one socket can have only one protocol owner.
   * @param route - pathname and handler owning negotiation plus socket use.
   * @returns the disposer removing the route.
   */
  registerUpgrade(route: WebUpgradeRoute): () => void {
    if (this.upgrades.has(route.path)) {
      throw new Error(`webserver: duplicate upgrade route "${route.path}"`)
    }
    this.upgrades.set(route.path, route)
    return () => { this.upgrades.delete(route.path) }
  }

  /**
   * Claim the fallback seat: the handler answering every request no named
   * route matches (the SPA dist server in the shipped Web composition). One
   * owner only — a second registration throws, because two fallbacks cannot
   * compose.
   * @param handler - owns the full response lifecycle of unmatched requests.
   * @returns the disposer releasing the seat.
   */
  registerFallback(handler: WebRoute['handler']): () => void {
    if (this.fallback !== undefined) {
      throw new Error('webserver: fallback already registered')
    }
    this.fallback = handler
    return () => { this.fallback = undefined }
  }

  /**
   * Register an index.html transform, applied by the fallback owner to every
   * index response ({@link applyIndexTaps}) in registration order.
   * @param transform - pure html-to-html function.
   * @returns the disposer removing the transform.
   */
  tapIndex(transform: (html: string) => string): () => void {
    this.indexTaps.push(transform)
    return () => {
      const at = this.indexTaps.indexOf(transform)
      if (at !== -1) this.indexTaps.splice(at, 1)
    }
  }

  /** Listen; resolves once the socket is bound (rejection = FAILED fiber). */
  async [Service.init](): Promise<void> {
    const handle = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
      /* v8 ignore next -- `?? '/'` arm: node:http always sets url on server
      requests; the field is only optional on the client-side IncomingMessage type */
      const rawPath = new URL(req.url ?? '/', 'http://x').pathname
      const route = this.match(rawPath)
      if (route !== undefined) {
        await route.handler(req, res)
        return
      }
      const fallback = this.fallback
      if (fallback === undefined) {
        res.writeHead(404)
        res.end()
        return
      }
      await fallback(req, res)
    }
    const handleFailure = (req: IncomingMessage, res: ServerResponse): void => {
      handle(req, res).catch((err: unknown) => {
        this.ctx.logger.warn(err instanceof Error ? err : new Error(String(err)))
        if (res.headersSent) {
          res.destroy()
          return
        }
        res.writeHead(400)
        res.end()
      })
    }
    // Last-resort guard: handle() rejecting would otherwise be an unhandled
    // rejection killing the process on one malformed request (bad %-escape,
    // client dropping mid-body). Per-request failures log and answer 400 —
    // never a process exit.
    const remote = await this.remoteTlsConfiguration()
    this.server = createServer(handleFailure)
    this.installUpgradeHandler(this.server)
    if (remote !== undefined) {
      this.remoteServer = createSecureServer({
        cert: remote.certificate,
        key: remote.privateKey,
        minVersion: 'TLSv1.3',
      }, handleFailure)
      this.installUpgradeHandler(this.remoteServer)
      this.remoteFingerprint = new X509Certificate(remote.certificate).fingerprint256
        .replaceAll(':', '')
        .toLowerCase()
    }
    try {
      await this.listen(this.server, this.config.port, this.config.host)
      this.listenedPort = (this.server.address() as AddressInfo).port
      if (this.remoteServer !== undefined && remote !== undefined) {
        await this.listen(this.remoteServer, remote.port, '0.0.0.0')
        this.listenedRemotePort = (this.remoteServer.address() as AddressInfo).port
      }
    } catch (error) {
      await Promise.all([this.server, this.remoteServer]
        .filter((server): server is Server | SecureServer => server?.listening === true)
        .map(server => new Promise<void>((resolve) => { server.close(() => { resolve() }) })))
      throw error
    }

    // Node does not include upgraded sockets in closeAllConnections(). The service
    // owns them with the other connections, so it tracks and destroys them explicitly.
    this.ctx.effect(() => async () => {
      const servers = [this.server, this.remoteServer].filter(
        (server): server is Server | SecureServer => server !== undefined,
      )
      const closed = servers.map(server => new Promise<void>((resolve) => {
        server.close(() => { resolve() })
        server.closeAllConnections()
      }))
      const upgradedClosed = [...this.upgradedSockets].map(socket => new Promise<void>((resolve) => {
        socket.once('close', () => { resolve() })
        socket.destroy()
      }))
      await Promise.all([...closed, ...upgradedClosed])
    }, 'webServer.listen')
  }

  private installUpgradeHandler(server: Server | SecureServer): void {
    server.on('upgrade', (req, socket, head) => {
      const onError = (error: Error): void => {
        this.ctx.logger.warn(error)
        socket.destroy()
      }
      socket.on('error', onError)
      socket.once('close', () => {
        socket.off('error', onError)
        this.upgradedSockets.delete(socket)
      })
      let route: WebUpgradeRoute | undefined
      try {
        /* v8 ignore next -- node:http always sets url on server requests. */
        route = this.upgrades.get(new URL(req.url ?? '/', 'http://x').pathname)
      } catch (error) {
        this.ctx.logger.warn(error instanceof Error ? error : new Error(String(error)))
        socket.destroy()
        return
      }
      if (route === undefined) {
        socket.destroy()
        return
      }
      this.upgradedSockets.add(socket)
      try {
        Promise.resolve(route.handler(req, socket, head)).catch((error: unknown) => {
          this.ctx.logger.warn(error instanceof Error ? error : new Error(String(error)))
          socket.destroy()
        })
      } catch (error) {
        this.ctx.logger.warn(error instanceof Error ? error : new Error(String(error)))
        socket.destroy()
      }
    })
  }

  private async listen(server: Server | SecureServer, port: number, host: string): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(port, host, () => {
        server.off('error', reject)
        server.on('error', (err) => { this.ctx.logger.error(err) })
        resolve()
      })
    })
  }

  private async remoteTlsConfiguration(): Promise<{
    certificate: Buffer
    privateKey: Buffer
    port: number
  } | undefined> {
    const host = this.config.remoteTlsHost ?? ''
    const certificatePath = this.config.remoteTlsCertificatePath?.trim() ?? ''
    const privateKeyPath = this.config.remoteTlsPrivateKeyPath?.trim() ?? ''
    const enabled = host !== '' || certificatePath !== '' || privateKeyPath !== ''
    if (!enabled) return undefined
    if (host !== '0.0.0.0' || certificatePath === '' || privateKeyPath === '') {
      throw new Error('webserver: remote TLS requires host 0.0.0.0 plus certificate and private-key paths')
    }
    const [certificate, privateKey] = await Promise.all([
      readCredentialFile(certificatePath, false),
      readCredentialFile(privateKeyPath, true),
    ])
    return { certificate, privateKey, port: this.config.remoteTlsPort ?? 0 }
  }

  /** Longest-prefix-wins over the prefix table after an exact-table miss. */
  private match(pathname: string): WebRoute | undefined {
    const exact = this.exact.get(pathname)
    if (exact !== undefined) return exact
    let best: WebRoute | undefined
    for (const [prefix, route] of this.prefixes) {
      if (pathname !== prefix && !pathname.startsWith(`${prefix}/`)) continue
      if (best === undefined || prefix.length > best.path.length) best = route
    }
    return best
  }

  /**
   * Run an index.html body through the registered taps in registration order
   * — called by the fallback owner on every index response it renders.
   * @param html - the raw index.html body.
   * @returns the transformed body.
   */
  applyIndexTaps(html: string): string {
    let out = html
    for (const transform of this.indexTaps) out = transform(out)
    return out
  }
}

export default WebServer
