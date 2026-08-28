---
description: "OpenFish Harness Pack 使用的通用 ACP Driver 与官方 Codex app-server Driver。"
kind: "package-reference"
---

# @deepseek-ai/dsh-harness-acp

[English](README.md) | 中文

## 概述

`dsh-harness-acp` 通过按协议实现的 Driver，把已准入的 Harness Pack 接入普通 OpenFish 任务，而且不会把某个 Harness 的私有能力描述成可移植的 ACP 行为。

## 目录

- [使用该包](#use-this-package)
- [模型体验](#model-experience)
- [已知限制与待办事项](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用该包

此包是 Open Fish Harness Pack 背后的通用 ACP Driver。安装使用壳子自带且固定版本的 Node/npm 或 Bun runtime，把每个 Pack 版本放入 Open Fish 管理状态。会话从该精确快照以不经过 shell 的 argv 启动可执行文件，而不会再次解析网络包。随后 Driver 把远端 ACP 会话映射到普通 DSH `Agent`、`Session`、inbox、审批、取消和状态约定。

## Model Experience

### ACP 拥有的对话

#### 模型看到什么

所选 ACP Harness 会通过 ACP `session/prompt` 接收用户按顺序提交的文本提示词。Open Fish 不会向该远端 Harness 对话注入 DSH 系统提示词或工具 schema。

#### Token 影响

取决于数据，并由所选 Harness 及其模型提供方拥有；此桥接不增加提示词 token。

#### KV Cache 影响

当 Harness 支持 ACP load-session 时，在远端 Harness 会话内保持仅追加；Open Fish 会让恢复失败，而不会创建无关历史。

## Known Limitations and Deferred Work

- 通用 ACP 会桥接权限请求、图片提示、限制在工作区内的文本文件操作，以及有输出上限的客户端终端。所选 Harness 仍拥有自己的 Agent Loop，并决定使用哪些标准回调。
- Pack 声明的认证方式可在 OpenFish 中选择。由 Agent 管理的浏览器登录仍归 Harness；API Key 在每次启动时从 Host 的只写 credential 服务解析，绝不进入 Pack 状态。
- Codex 使用独立的内置 Driver 对接官方 `codex app-server` 协议，包括实时账号、模型／思考强度、thread 恢复／删除和真实的 `thread/fork`；它不经过通用 ACP 适配器。
- 通用 ACP 尚无标准的提供方侧会话删除或 Fork 原语。OpenFish 会在本地停止被放弃的 ACP 草稿，并禁用 Fork，而不会伪造这些远端语义。
- 受管理的 Harness 进程会在所选 OpenFish 工作区和进程沙箱策略中启动，并使用私有 HOME／缓存／配置／临时目录。发布者元数据和 ACP Registry 传输仍不能替代包完整性、沙箱执行或明确的用户审批。
- 带校验和的平台归档由 OpenFish 在进程内解包，不委托给宿主机归档工具。系统接受 ZIP、TAR、TAR.GZ、TGZ、TAR.BZ2 与 TBZ2，拒绝链接和非普通归档条目，并把归档限制为最多 20,000 个条目、1,024 字节路径、512 MiB 压缩体积和 2 GiB 解包／解压体积；所有内容只能写入全新的受管版本目录。直接下载的可执行文件在声明的 SHA-256 匹配时仍然受支持。

<a id="dev-note"></a>
### 开发备注

<details>
<summary>供维护者使用的工作上下文 — 点击展开</summary>

无。

</details>
