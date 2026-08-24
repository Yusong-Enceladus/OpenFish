# OpenFish Harness Driver SDK

English | [中文](harness-driver-sdk.zh.md)

OpenFish has two intentionally different extension paths. A compatible ACP process needs only a validated Harness Pack because the built-in ACP Driver owns the protocol. A non-ACP Harness needs both a Pack and one Driver plugin; the shell never guesses lifecycle, authentication, model, or tool semantics from an executable name.

## What the shell provides

Once a Pack and Driver pass admission, OpenFish reuses the catalog, exact-version installation snapshots, transactional update and rollback, private Runtime roots, Project and No Project locations, session identity pinning, native Mac and iPhone task surfaces, and evidence-backed architecture lenses. A Driver does not reimplement those product layers.

## What a Driver must provide

A Driver declares one stable `protocol`, Driver API `apiVersion`, and concrete capabilities for each Pack. It must create, resume, and dispose sessions; support at least Project or No Project; expose the Pack architecture; and validate every editable setting whose operational meaning it claims to own. Optional hooks add permanent blank-draft discard, installation, prompt-free live preflight, credential-reference discovery, and interactive authentication. A preflight sends no model prompt, but the Driver must not promise that a provider creates no state or charges no provider-specific setup cost.

```ts
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { Context } from '@deepseek-ai/cordis'
import {
  defineHarnessDriver,
  registerHarnessDriver,
  type HarnessForkRequest,
  type HarnessSessionRequest,
} from '@deepseek-ai/dsh-harness'

declare function launchMyRuntime(request: HarnessSessionRequest): Promise<Agent>
declare function resumeMyRuntime(request: HarnessSessionRequest): Promise<Agent>
declare function forkMyRuntime(request: HarnessForkRequest): Promise<Agent>
declare function stopMyRuntime(sessionId: HarnessSessionRequest['sessionId']): Promise<void>
declare function deleteBlankRemoteDraft(sessionId: HarnessSessionRequest['sessionId']): Promise<void>

export const inject = ['harnesses']

const driver = defineHarnessDriver({
  apiVersion: 1,
  protocol: 'my-runtime',
  capabilities: async () => [
    { id: 'session.create', status: 'supported', source: 'driver' },
    { id: 'session.resume', status: 'supported', source: 'driver' },
    { id: 'session.fork', status: 'supported', source: 'driver' },
    { id: 'workspace.no-project', status: 'supported', source: 'driver' },
    { id: 'architecture.manifest', status: 'supported', source: 'pack' },
    { id: 'architecture.runtime-observation', status: 'supported', source: 'driver' },
  ],
  validatePack: async pack => pack.graph.nodes.some(node => node.editable)
    ? ['Replace this example with validation for every editable binding.']
    : [],
  runtimeSignals: event => event.type === 'turn/end'
    ? [{
        signal: 'driver.my-runtime.turn-settled',
        status: event.data.reason.kind === 'error' ? 'failed' : 'completed',
      }]
    : [],
  available: async () => undefined,
  create: launchMyRuntime,
  resume: resumeMyRuntime,
  fork: forkMyRuntime,
  dispose: async sessionId => stopMyRuntime(sessionId),
  discard: async sessionId => deleteBlankRemoteDraft(sessionId),
})

export function apply(ctx: Context): void {
  registerHarnessDriver(ctx, driver)
}
```

## Ship and load the Driver

A Driver is a Host plugin, so publish it as an ordinary DSH Profile Bundle. Keep the module as a namespace plugin: export `name`/`inject`/`apply` and **do not add a default export**, because the real Loader unwraps a default export and would otherwise discard the injection contract.

```yaml
# cordis.patch.yml
- insert:
    - id: my-runtime-harness-driver
      name: '@acme/openfish-driver-my-runtime'
```

```json
{
  "name": "@acme/openfish-driver-my-runtime",
  "type": "module",
  "files": ["lib/index.js", "lib/types/**/*.d.ts", "cordis.patch.yml"],
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } },
  "peerDependencies": {
    "@deepseek-ai/cordis": "^4",
    "@deepseek-ai/dsh-harness": "^0.1"
  }
}
```

An OpenFish user does not need DSH, Node, npm, or pnpm installed. In **Settings → Plugins → Add Driver**, enter an exact trusted package version or full Git commit. OpenFish installs the candidate into a disposable private staging profile, validates its package identity, contained Bundle patch, and owned Loader entry without importing it, then activates the same dependency in the `x` Profile and restarts only its verified embedded Host. npm lifecycle scripts are disabled by default; enabling them is a separate code-execution acknowledgement. Managed npm uses the public registry and a private temporary environment without ambient npm/Git credentials or project `.npmrc` files. OpenFish records that script decision against the exact source and restores the same source and decision if an update fails; an older installation with no consent record remains inactive until explicitly reinstalled.

For ordinary users, put the same closed source in the public Harness Pack. Selecting that Harness by name then presents one exact code-consent sheet and performs Driver installation, Host restart, API negotiation, Pack installation, authentication, and preflight as one recoverable setup flow:

```json
{
  "protocol": "my-runtime",
  "driverBundle": {
    "apiVersion": 1,
    "package": "@acme/openfish-driver-my-runtime",
    "spec": "@acme/openfish-driver-my-runtime@1.2.3",
    "requiresInstallScripts": false
  }
}
```

The npm package identity and `spec` identity must match. The alternative source is `github:owner/repository#<full-40-character-commit>` with the expected package identity declared separately. Floating tags, ranges, branches, built-in Driver replacement, and a public non-ACP Pack without this descriptor are rejected. iPhone never installs Host code; it shows the exact Bundle and directs the user to complete setup on the paired Mac.

Driver developers can exercise the identical closed command from a development installation:

```sh
dsh driver --profile x install @acme/openfish-driver-my-runtime@1.2.3
# or: dsh driver --profile x --package @acme/openfish-driver-my-runtime \
#   install github:acme/openfish-driver-my-runtime#<full-40-character-commit>
```

The Pack can then be created/imported in the Manifest Editor. Structural admission proves only that the Bundle is safely pinned and loadable as a Profile layer; the Harness row becomes runnable only after the Driver loads, negotiates API v1, passes Pack conformance, and the Mac app commits an exact loopback-only Driver authorization before Pack installation and live preflight. That authorization is protocol-scoped and replaced by a different exact Driver source, so pinned older Packs fail visibly instead of silently borrowing newer code. Removing or updating the Bundle follows the same deactivate-first profile transaction and verified Host restart.

The example deliberately fails editable Packs until the author implements binding validation. Removing that failure without implementing the setting is not conformance: a visible control must change real Driver behavior.

Runtime observation follows the same truthfulness rule. Built-in normalized facts use names such as `turn.started` and `tool.activity`. Protocol-specific facts must use `driver.<protocol>.*`, appear in the Pack node or edge `observes` list, and come from `runtimeSignals`. The mapper returns only a stable signal and status. OpenFish derives the visible activity label and deliberately discards prompts, paths, commands, tool arguments, account names, and any caller-supplied text before cross-device projection.

`session.fork` is equally strict. Advertise it only when `fork(request, pack)` creates a real branch in the Harness's own durable session system and publishes the local child over the exact completed `request.seed`. A transcript copy that starts a fresh remote conversation is not a Harness fork. If the protocol has no branch primitive, omit `fork` and declare the capability `unsupported`; OpenFish hides the action. The built-in Codex Driver maps this contract to the official app-server `thread/fork` operation, while generic ACP remains unsupported until ACP defines equivalent semantics.

`session.archive` is different: it is an OpenFish shell operation that hides or restores a task without deleting the Harness session or durable transcript. The Host injects this capability into every admitted Driver snapshot. Drivers must not claim remote deletion or implement an archive hook merely to make the native action appear.

`dispose` and `discard` are also intentionally different. `dispose` stops local runtime work while preserving a durable blank task for resume after the app closes. Optional `discard` is called only after the Host proves that a task has never started and the user abandons it; a Driver should use it to delete any provider-side identity allocated during live model/configuration discovery. If the protocol has no such primitive, omit `discard` and OpenFish falls back to `dispose` without pretending remote deletion occurred.

## Credential contract

Pack authentication fields and `secret-reference` node controls contain references such as `OPENAI_API_KEY`, never values. Values live in the Mac Host credential service and are resolved only by trusted local Runtime code. The iPhone cannot inspect or mutate that credential store.

## Admission and proof

Call `inspectHarnessDriver(driver, pack)` in development or `assertHarnessDriverConformance(driver, pack)` in tests. OpenFish repeats the same negotiation during registration and before create, resume, and preflight. Compatibility is recorded only after a concrete installed Pack initializes successfully; catalog presence alone is not proof.

## Compatibility boundary

A future ACP Harness can normally be added as data. A future non-ACP protocol can be added without changing session storage or native UI, but it cannot be added without executable protocol code. If a private Harness does not expose architecture evidence, its truthful graph level is `opaque`; OpenFish displays one boundary instead of inventing internals.
