# OpenFish Harness Driver SDK

[English](harness-driver-sdk.md) | 中文

OpenFish 有两条刻意分开的扩展路径。兼容 ACP 的进程只需要一个通过校验的 Harness Pack，因为内置 ACP Driver 已经拥有协议语义。非 ACP Harness 必须同时提供 Pack 与一个 Driver 插件；壳子绝不会根据可执行文件名称猜测生命周期、认证、模型或工具语义。

## 壳子提供什么

Pack 与 Driver 通过准入后，OpenFish 会复用目录、精确版本安装快照、事务化更新与回滚、私有 Runtime 根目录、Project 与 No Project 位置、会话身份固定、Mac 与 iPhone 原生任务界面，以及有证据支撑的架构视图。Driver 不需要重新实现这些产品层。

## Driver 必须提供什么

Driver 为每个 Pack 声明一个稳定的 `protocol`、Driver API `apiVersion` 与具体能力。它必须创建、恢复和销毁会话，至少支持 Project 或 No Project 之一，暴露 Pack 架构，并校验它声称拥有运行语义的每一项可编辑设置。可选 Hook 可以增加永久删除空白草稿、安装、不发送模型提示词的实时 Preflight、凭据引用发现与交互式认证。Preflight 不发送模型提示词，但 Driver 不得承诺 Provider 不创建状态，也不得承诺不存在 Provider 自己定义的初始化成本。

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

## 发布并加载 Driver

Driver 属于 Host 插件，因此应按普通 DSH Profile Bundle 发布。模块必须保持命名空间插件形态：导出 `name`／`inject`／`apply`，并且**不要添加 default export**；真实 Loader 会优先解包默认导出，否则会丢失注入契约。

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

OpenFish 用户无需另外安装 DSH、Node、npm 或 pnpm。在 **设置 → 插件 → 添加 Driver** 中输入经过信任检查的精确包版本或完整 Git commit。OpenFish 会先把候选项安装到一次性的私有暂存 Profile，在不导入候选模块的情况下校验包身份、Bundle patch 是否位于包内，以及它是否插入了归属于该包的 Loader 条目；随后才会在同一个 `x` Profile 中激活该依赖，并且只重启经过进程身份校验的内置 Host。npm 生命周期脚本默认禁用；启用它们需要单独确认代码执行风险。受管 npm 固定使用公共 Registry 与私有临时环境，不继承 npm／Git 凭据，也不读取项目 `.npmrc`。OpenFish 会把脚本决定记录到准确来源；更新失败时恢复同一来源与同一决定。没有许可记录的旧安装会保持停用，直到用户显式重装。

面向普通用户时，应把同一个封闭来源写进公开 Harness Pack。用户只要按名称选择该 Harness，就会看到一次准确的代码许可提示；随后 Driver 安装、Host 重启、API 协商、Pack 安装、认证与 Preflight 会组成一条可恢复的配置流程：

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

npm 包身份必须与 `spec` 中的身份一致。也可以使用 `github:owner/repository#<完整 40 字符 commit>`，并单独声明预期包身份。浮动 Tag、版本范围、分支、替换内置 Driver，以及没有该描述的公开非 ACP Pack 都会被拒绝。iPhone 绝不会安装 Host 代码；它只显示准确 Bundle，并引导用户在已配对 Mac 上完成配置。

Driver 开发者可以在开发环境中运行同一套封闭命令：

```sh
dsh driver --profile x install @acme/openfish-driver-my-runtime@1.2.3
# or: dsh driver --profile x --package @acme/openfish-driver-my-runtime \
#   install github:acme/openfish-driver-my-runtime#<full-40-character-commit>
```

随后可以在 Manifest Editor 创建或导入对应 Pack。通过结构准入只证明 Bundle 已安全固定，并且可以作为 Profile 层加载；只有 Driver 已加载、协商 Driver API v1、通过 Pack Conformance，并由 Mac App 提交准确且仅限 Loopback 的 Driver 授权后，才能安装 Pack 并执行实时 Preflight。该授权按协议限定，切换到另一个准确 Driver 来源会替换旧授权，因此固定到旧版本的 Pack 会明确失败，而不会悄悄借用新代码。删除或更新 Bundle 会经过同一套「先停用、再修改 Profile」事务，并重启经过身份校验的 Host。

示例会故意拒绝可编辑 Pack，直到作者为每个 Binding 实现校验。没有实现真实设置就删掉这个失败分支并不符合契约：界面里可见的控制必须改变真实 Driver 行为。

Runtime Observation 遵循同一条真实性规则。内置标准化事实使用 `turn.started`、`tool.activity` 等名称；协议专属事实必须使用 `driver.<protocol>.*`，必须出现在 Pack 节点或图边的 `observes` 列表中，并由 `runtimeSignals` 提供。映射器只返回稳定 Signal 与 Status。OpenFish 自己生成可见活动标签，并在跨设备投影前刻意丢弃 Prompt、路径、命令、工具参数、账号名及任何调用方文本。

`session.fork` 同样严格。只有当 `fork(request, pack)` 会在 Harness 自己的持久会话系统中创建真实分支，并把本地子任务发布在精确完成的 `request.seed` 上时，才可以声明支持。复制 Transcript 后新建一个无关远端会话不算 Harness Fork。协议没有分支原语时，应省略 `fork` 并把能力声明为 `unsupported`，OpenFish 会隐藏该操作。内置 Codex Driver 把此契约映射到官方 app-server 的 `thread/fork`；通用 ACP 在 ACP 定义等价语义之前保持不支持。

`session.archive` 不同：它是 OpenFish 壳层拥有的操作，只隐藏或恢复任务，不会删除 Harness 会话或持久 Transcript。Host 会把该能力注入每个通过准入的 Driver 快照。Driver 不应为了显示原生操作而声称远程删除能力或另行实现 archive hook。

`dispose` 与 `discard` 也刻意不同。`dispose` 只停止本地 Runtime 工作，并保留可在 App 重启后恢复的持久空白任务。可选的 `discard` 只会在 Host 已证明任务从未开始、且用户明确放弃该草稿后调用；如果实时模型／配置发现阶段已经分配了 Provider 侧身份，Driver 应在这里将其删除。协议没有这种原语时就省略 `discard`，OpenFish 会退回到 `dispose`，但不会假装远端已经删除。

## 凭据契约

Pack 认证字段与 `secret-reference` 节点控制只包含 `OPENAI_API_KEY` 这类引用名，不包含值。值保存在 Mac Host 凭据服务中，只由受信任的本地 Runtime 代码解析。iPhone 不能检查或修改该凭据库。

## 准入与证明

开发时调用 `inspectHarnessDriver(driver, pack)`，测试中调用 `assertHarnessDriverConformance(driver, pack)`。OpenFish 在注册以及 create、resume 与 preflight 之前会重复同一套协商。只有具体已安装 Pack 成功初始化后，系统才会记录兼容；出现在目录中本身不构成证明。

## 兼容性边界

未来的 ACP Harness 通常可以仅以数据方式加入。未来的非 ACP 协议可以在不修改会话存储与原生 UI 的情况下加入，但不可能缺少可执行协议代码。私有 Harness 如果不公开架构证据，真实的图级别就是 `opaque`；OpenFish 会显示一个边界，而不会编造内部结构。
