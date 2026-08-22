# OpenFish macOS 客户端

[English](README.md) | 中文

OpenFish 产品组合的原生 SwiftUI／AppKit 壳子。本应用消费现有 `/api` RPC
组合、Host 与 mux WebSocket 事件流、会话投影以及可回答的审批帧。App 内置
OpenFish Host 和固定版本的 Node 运行时；本地没有健康 Host 时会自动启动，并通过
Harness 服务安装和运行 DSH、ACP 目录条目及自定义 Harness Pack，同时不托管第二份
会话存储，也不引入原生专用业务协议。

全新安装不会静默选择 DSH 或模型。首次引导会加载实时 Harness 目录、让用户选择默认项、
安装其固定版本 Runtime、发现认证方式，并通过 Host 的只写 API 把凭证存入用户 macOS 钥匙串。DSH 模型只显示
已配置的提供方；外部 ACP Harness 的模型来自该实时会话的 ACP 配置。默认 Harness 可在设置中
修改，已有任务则继续固定到创建它的 Harness 与 Pack 版本。“No Project”任务使用应用自有的
`$DSH_HOME/openfish/sessions/no-workspace` 目录。

当前垂直切片实现了项目／任务导航、持久化会话加载、用户／assistant／工具事件的
流式投影、模型选择、通过 `permissions` 投影与 `commands/execute` Remote 完成的
DSH 权限选择、取消和审批响应路径。主要应用界面为原生实现；任务导航与对话渲染
不使用 WebView。

发布工作流会在干净的 GitHub 托管 Runner 上分别构建 Apple Silicon 与 Intel 产物。Pull
Request 生成未签名测试产物；`openfish-v*` 标签必须具备 Developer ID 证书与公证凭证，随后
发布已签名、已公证的 DMG 和 SHA-256 文件。应用包内含固定版本的 Node、npm／Bun 依赖和 uv；
发布 smoke 会用空的隔离状态目录启动内置 Host。

发布验收要求 TypeScript 与原生构建、隔离 Host smoke、无项目任务创建、首次 Harness 选择、
认证、模型发现／选择、恢复版本固定、隐私扫描，以及签名／公证产物检查全部通过。Registry
收录只是发现元数据，不是质量背书；Open Fish 只会在真正启动对应 Pack 后报告自己的兼容结果。

无需打开 Xcode 即可构建：

```sh
./build.sh
```

构建并检查本地未签名发布产物：

```sh
./script/build_openfish_release.sh "$(uname -m)"
```

可执行文件写入 `.build/OpenFish`。集成构建与运行流程会把独立 Host 运行时打包进
`OpenFish.app`，用户无需另行安装 Node 或 DSH。开发启动器只在用户 Applications
目录安装一份 App，并实际使用其内置 Host，避免过期的源码目录 Host 遮蔽打包问题。

无需外部模型请求或可见应用窗口即可运行隔离的组合运行时行为路径：

```sh
./Tests/behavior-smoke.sh
```
