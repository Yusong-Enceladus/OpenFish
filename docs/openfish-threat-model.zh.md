# OpenFish 威胁模型

[English](openfish-threat-model.md) | 中文

本文描述 OpenFish Public Alpha 的安全边界。它是设计与发布审查依据，并不保证第三方 Agent 代码安全。

## 资产与信任边界

OpenFish 区分五种权威：

1. 原生 Mac 与 iPhone Client 负责呈现状态和用户决定。
2. 基于 DSH 的 Host 负责持久任务、受管 Runtime 文件、凭证、进程监管和配对设备传输。
3. 所选 Harness 负责 Agent Loop、协议行为、模型流量、工具和远端 Session 语义。
4. 所选账号／Provider 负责认证、计费、保留策略和模型服务政策。
5. Project 或 No Project 目录定义该任务请求的文件边界。

Host、Harness 进程、模型 Provider、Pack Publisher 与已配对手机不是同一种信任身份。OpenFish 分别显示这些身份，并把 Harness 版本、认证方式名称、Workspace 模式、模型、思考选项和协商 Capability 固定到任务。Secret 值与认证 Cookie 永远不属于任务身份。

## 威胁、控制与剩余风险

### Harness 与依赖供应链

- Built-in、ACP Registry、OpenFish Community 与用户 Pack 分别标记。可发现性、Publisher Verification、安装完整性、协议兼容和 Runtime 测试成功是彼此独立的事实。
- 用户与 Community 的 Package Distribution 必须固定准确版本。所有远端 Binary 安装都必须使用无凭据 HTTPS 来源与 SHA-256；缺少 checksum 的 Registry 条目可以保留在发现目录中，但不能安装。ZIP／TAR 在进程内解包，具有条目数、路径长度、压缩与解包体积上限，会拒绝链接、设备、重复输出与路径穿越，并统一收紧生成文件的私有权限。npm／Bun 固定版本只在没有上游 checksum 时表示准确 Registry 版本，界面不会把它说成加密校验。
- 安装先在 Staging 中完成，再原子提升；旧 Pack 版本保留用于回滚。仍被任务引用的版本不能被静默卸载。
- 第三方 Driver Bundle 的 Package Manager 与 Lifecycle Script 在封闭且每次操作独立的环境中运行：使用私有 HOME／Cache／Temp、空 npm User 与 Global Config、公共 npm Registry、App 打包的 Toolchain Path，禁用系统 Git 配置与凭据提示，并且不继承 Provider Key、npm Token、Shell Hook、`NODE_OPTIONS` 或 `NODE_PATH`。项目 `.npmrc` 会被拒绝，而不会借用私有 Registry 的信任环境。用户在 Mac 上明确授权后，已准入的 Driver Code 本身仍属于受信任的 Host Plugin Code。
- Driver Lifecycle Script 默认禁用。Mac 会把授权记录到准确 Driver 来源；回滚沿用该来源已记录的选择，如果旧来源没有授权记录则拒绝自动执行。Plugins 页面会显示这项记录。
- Registry 或 Community 收录不等于源码审核、恶意软件审核或安全背书。Package Manager 基础设施或上游维护者被攻破仍是剩余风险。

### Harness 进程权限

- 受管 Harness 获得私有 HOME、Cache、Config、Data 和临时目录；环境中的用户 Home 被隐藏。可读 Root 只包含所选 Workspace、准确安装／Runtime Snapshot、OpenFish 打包 Runtime，以及所选认证方式明确需要的 Root。
- 内置 Host 使用 Allowlist 环境启动，不继承 Mac App 的完整环境。Provider Key、Package Manager Credential、Shell Hook、`NODE_OPTIONS`、`SSH_AUTH_SOCK` 与无关 App Variable 不会进入 Host，也不会转发给 Harness 进程。
- 在 read-only 与 workspace-write 模式下，OpenFish 要求平台 Sandbox 真正执行受保护读取、文件写入限制、禁止监听入站端口、禁止控制 Host 进程与 Host IPC。常驻进程边界只有部分 Enforcement 时会在启动前失败。
- 远端模型 Provider 与 Package Registry 需要出站网络，因此出站访问仍然可用。Harness 可以把自己被允许读取的数据发送给 Provider。`danger-full-access` 是用户明确授权绕过 OpenFish 进程限制的模式；两种模式都不是虚拟机。
- 被攻破的 Harness 可以滥用 Workspace、注入给它的凭证以及用户明确授予的权限。OpenFish 无法在授予这些权限后把不可信 Agent 代码变成安全代码。

### 凭证与计费

- Secret 值只通过 Host Credential Service 与原生 Keychain-backed Store 写入。Pack 只包含 Credential Reference 和非 Secret 的认证方式名称，绝不包含 API Key、密码、Bearer Token、Cookie、Recovery Code 或一次性配对码。
- 只有所选 Harness 进程会收到所选认证方式需要的凭证。非 Loopback Client 无法调用 Host-local Credential 与 Pack Authoring RPC。
- 当 Pack／Driver 有证据时，OpenFish 会显示任务使用 Subscription、Usage-billed API、本地模型还是 Harness-managed Account。OpenFish 不会把一个 Provider 的订阅变成另一个 Provider 的额度，也无法保证上游计费与保留行为。

### Mac–iPhone 连接

- 配对码只能从 Loopback 创建，具有过期时间且只能兑换一次。远端兑换必须使用配对码本身生成与 Host TLS Certificate 绑定的 HMAC；Bootstrap Connection 中公开传输的 Code Id 不足以伪造该证明。Host 只在兑换或过期前于内存保留原始配对码，只持久化配对 Token 的 SHA-256 摘要；手机把 Bearer Credential 与固定的 Host Certificate Fingerprint 存入 Keychain。
- Remote Request 必须使用允许的 Host Authority、已经接受的 TLS Socket、固定的 Host Certificate 与已配对认证。Credential／Settings 修改、可能暴露本地配置的 Model Provider Discovery、Pack Authoring／Removal、Driver Bundle 授权、交互式 Terminal Login、文件选择器，以及对其他设备的管理始终只允许 Loopback。已配对设备只能撤销由自身 Token 证明的注册；Host Mac 可以列出和撤销所有设备。已配对手机可以请求已审核 Pack 的生命周期操作，但不能授权 Host 代码。
- 当前直连传输只面向可信 LAN 或 Tailscale，不提供 OpenFish Relay。OpenFish 会拒绝远端 Host 的明文 HTTP；仍建议使用 Tailscale 或其他经过认证的网络层控制可达性与暴露范围。绝不能把 Host Port 暴露到公网。
- 打包 Host 会一直使用相互匹配的 TLS Certificate／Key，直到证书实际过期，因此普通重启不会让已经固定 Fingerprint 的手机失联。无效、不匹配或过期材料会以事务方式替换；Fingerprint 变化后必须重新配对。
- 已配对手机可以执行 Remote Contract 暴露的任务操作，包括发送 Prompt 和处理 Approval。设备丢失或共享后应立即撤销。

### Driver Bundle 授权

- 非内置协议 Pack 在 Mac App 完成准确 Driver 来源准入、重启经验证的内置 Host、观察到 Driver 注册并提交一条仅限 Loopback 的授权记录之前，不能安装、登录、预检、设为默认、创建、恢复或 Fork。
- 授权按协议与准确包来源限定。启用不同 Driver 来源会替换旧证明；旧 Pack 会以可操作的准确版本提示停止，而不会悄悄借用较新的代码运行。
- 授权记录只包含包身份、准确来源与授权时间，不包含包管理器凭据、Provider Secret、Session Token 或用户内容。

### 任务、文件与诊断

- No Project 任务使用 OpenFish 私有数据 Root 下的独立 Session 目录，不使用 Desktop 或 Host 启动目录。Project 任务使用所选 Project Root。删除或丢弃 No Project 任务时，只会在 Session Lifecycle 释放后删除其受管目录。
- Mac 与 iPhone 的离线 Projection 按 Host 分开存放在仅 Owner 可访问且排除备份的 OpenFish Application Support 目录；iPhone 还应用 Data Protection。Composer 文本和待发送附件从不写入缓存。撤销授权或明确解除配对会清除对应 Host Projection 与草稿身份。
- 原生 Client 会预先分配并只持久化已准备空白任务的 id 与 Harness id。重试会采用相同 id，因此响应丢失或 App 重启不会再创建一个上游会话。Codex 可以永久删除对应空白 Thread；ACP 没有标准远端删除操作，因此通用 ACP Harness 仍可能按照自身协议保留 Provider 所有的空白 Session 状态。
- Session Log 必然包含 Prompt、模型输出、Tool Result、Path 与 Approval History。Runtime Architecture Projection 只记录不含内容的 Signal 名称和 Node／Edge 状态；不会复制 Prompt、Command、Credential、Account Label 或 Tool Argument。
- Compatibility Report 包含 Build／Platform、Harness／Driver 版本、Workspace 模式、认证方式名称、Capability 结果和第一条脱敏失败。Public Export 会拒绝常见个人路径、本地主机、私网 IP、Credential-like Value、未固定 Package 与携带 Secret 的 Environment Field。
- 用户仍必须人工检查导出的 Task、Pack、Diagnostics、Screenshot 与 Issue Attachment。自动脱敏无法识别所有保密项目名或业务事实。

### Community 发布与公开素材

- Publish 会为明确的 Repository Pull Request 准备无凭证 Pack 与 Compatibility Report；不会静默上传源码、Task 内容、Credential 或本地 Runtime 文件。
- 公开截图必须来自网络隔离的确定性 Demo State。发布检查会拒绝内嵌图片 Metadata，以及 OCR 能识别的个人路径、Email、本地主机名、私网 IP 与 Credential-like Text。OCR 与正则并不完整，因此仍需人工审核。
- Demo State 使用合成 Project、Task、Account、Model、Error、Approval 与 Architecture Evidence；不会读取 Production State、启动 Host、联系 Provider 或请求麦克风权限。

## 发布审查

Public Release 需要通过 Source Secret／Path Scan、公开素材 Metadata 与 OCR 审核、Dependency License 与 Third-party Notice 审核、打包 Bundle 的 Path 与 Symlink 检查、Harness Contract Test、受支持的原生 Build，以及对最终 Git History 和 Release Artifact 的人工审核。真实 iPhone 连续性和麦克风检查在具备可信 Device Lab 之前属于手工 Release Evidence；Simulator Build 绝不能被描述成物理设备证明。

请按照 [SECURITY.md](../SECURITY.md) 的说明，通过 GitHub 私有 **Security → Report a vulnerability** 流程报告漏洞。
