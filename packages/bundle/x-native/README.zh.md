# OpenCodex 原生启动组合包

[English](README.md) | 中文

原生 OpenCodex 客户端加入普通 DSH API 前所需的小型协议 DSH 插件。它拥有发现、能力协商、实时方法清单和原生设备身份。业务 RPC 仍位于现有 DSH `/api` gateway；该组合包不复制会话、工作区、agent、工具、审批、设置或语音领域操作。

## 路由

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/x-native/v2/health` | 存活检查与版本化握手 |
| GET | `/x-native/v2/capabilities` | 实时组合与传输能力事实 |
| GET | `/x-native/v2/methods` | 用于原生代码生成的实时 `/api` 方法清单 |
| POST | `/x-native/v2/pairing-code` | 在 Host 上生成短期配对码 |
| POST | `/x-native/v2/pair` | 注册本地设备或兑换远程配对码 |
| GET | `/x-native/v2/devices` | 在 Host 上列出不含 secret 的设备记录 |
| POST | `/x-native/v2/revoke` | 在 Host 上撤销设备 token |

## 协议事实

- `protocolVersion: v2` 与 `minimumClientProtocol: v2` 来自组合后的启动协议。当前原生客户端会在读取业务状态前拒绝不兼容的握手。
- `api.base: /api`，事件位于 `/api/events.host` 与 `/api/events.mux`；这些路径由 `dsh-client-connection` 拥有，此处只将其镜像为启动发现事实。
- 方法清单来自实时 Typert 本地注册表，因此未组合 `typert` 服务时为空，并会自动包含完整 Web profile 中所有已挂载的远程 namespace。
- 配对记录存储在 `$DSH_HOME/x-native/devices.json`（可通过 `config.dataDir` 覆盖）。token 以 SHA-256 摘要持久化；secret 只在配对时返回一次。
- 本地客户端可直接配对。远程客户端必须兑换 Host 上创建的十分钟、一次性配对码。所得 bearer 会被普通 DSH HTTP 与 WebSocket 信任边界接受；设备列表、配对码创建和撤销仍只允许 Host 本地操作。
- LAN 与 Tailscale 共用同一条经过认证的 DSH carrier。relay 仍是可替换的传输插件，只在已挂载时报告。
- 图片生成能力标志表示已挂载 provider registry；OpenCodex 刻意不内置图片模型。
- 未指定 Workspace 的原生任务使用 `$DSH_HOME/openfish/sessions/no-workspace` 作为 cwd，绝不继承 Host 进程的启动目录。

## 组合

该组合包必须挂载到 Web／原生 Host profile 中：

```yaml
- insert:
    - id: x-native
      name: '@deepseek-ai/dsh-bundle-x-native'
      inject: [webServer, connection]
      config:
        protocolVersion: v2
```

它不属于 headless，也不会修改 anchored agent preset。

## 验证

```sh
pnpm build:lib:host
pnpm vitest run packages/bundle/x-native/tests/x-native.spec.ts
DSH_HOME=<profile home> dsh --profile x-native-dev --host 127.0.0.1 --port 3180
curl http://127.0.0.1:3180/x-native/v2/capabilities
```

## 安全边界

- 配对码只存在于 Host 内存中，十分钟后过期，并在设备注册开始前即被消费。
- 设备变更会串行执行；registry 以 `0600` 权限原子写入；bearer 通过恒定时间摘要比较验证。
- bearer 可授权普通的非特权 DSH API。配置与凭据方法仍服从 Host connection 层更严格的 loopback-only 策略。
- registry 目前采用部署级授权，尚无逐设备 ACL。relay 行为属于所选 relay 插件，而不属于本组合包。

## 模型体验

无，因为这个仅限启动的组合包不注册任何面向模型的提示词、工具、schema 或结果。

#### KV Cache 影响

无；启动元数据永远不会进入模型请求前缀。

## 已知限制与待办事项

- 授权粒度目前是整个部署，而不是逐设备、工作区或会话。
- relay 传输有意留给可替换的 DSH 传输插件。
- 只有组合后的 rc.8 Host 暴露迁移／导入能力时才会报告该能力；它不属于原生启动职责。
