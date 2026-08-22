# OpenFish

[English](README.md) | 中文

<p align="center">
  <img src="apps/x-macos/Sources/XMac/Assets.xcassets/AppIcon.appiconset/OpenFish-1024.png" alt="OpenFish 应用图标" width="112">
</p>

<p align="center">一个承载多种编程智能体 Harness 的原生入口：Mac 上用，手机上继续。</p>

![使用合成演示任务的 OpenFish macOS 界面](docs/assets/openfish-macos-demo.png)

OpenFish 是一个原生 macOS 与 iPhone 编程智能体客户端：用户只安装一个应用，选择自己要用的 Harness，并在 Mac 与已配对的 iPhone 上继续使用同一批持久任务、审批、模型控制和实时活动。

OpenFish 构建在 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) （`dsh`）之上，并保留其 MIT 许可证与第三方声明。DSH 负责 Host、会话日志、工具、权限和插件组合；OpenFish 增加原生壳子、托管式 Harness 安装、ACP 兼容层与跨设备体验。

<p align="center">
  <img src="docs/assets/openfish-iphone-demo.png" alt="OpenFish iPhone 合成远程任务界面" width="320">
</p>

以上图片来自 OpenFish 确定性、网络隔离的 Demo 状态，不含真实账号、主机名、项目路径、任务或对话。

## Public Alpha

OpenFish 当前适合公开评估，尚不承诺稳定兼容。Harness 与 ACP 都在快速变化，未来可能出现破坏性变更。判断某个 Harness 是否受支持前，请先阅读[兼容矩阵](docs/openfish-compatibility.md)，在主力电脑安装前还应阅读 [Public Alpha 发布说明](docs/openfish-public-alpha.md)。

## 它有什么不同

- **一个自包含 Mac 应用。** 应用内含 Host 与固定版本的 Runtime，用户无需预装 Node、Bun、uv、DSH、Codex 或 Pi。
- **Harness 选择权属于用户。** 首次启动选择默认项；每个新任务仍可换用其他 Harness，旧任务不会被改写。
- **控件由协议驱动。** ACP 模型、思考强度、模式与未来标准选项来自正在运行的 Harness，而不是 UI 中按厂商名称写死。
- **Mac 与 iPhone 共享一个权威状态。** 手机通过 LAN 或 Tailscale 配对到 Mac Host，共用会话日志、审批、队列与任务状态。
- **任务固定 Harness 版本。** 已有任务继续使用创建时的 Pack；新任务可以选更新版本。
- **Harness Studio。** 查看 Pack 如实声明的架构图，创建或编辑可组合节点，导入／导出不含凭证的 Manifest，并把 Pack 提交到生成后的 OpenFish 社区目录。

![使用合成 DSH、Oh My Pi 与 Codex 条目的 OpenFish 默认 Harness 选择器](docs/assets/openfish-harness-picker-demo.png)

详见 [macOS 指南](apps/x-macos/README.md)、[iPhone 指南](apps/x-ios/README.md)与 [Harness Pack 契约](packages/harness/harness/README.md)。Pack 作者可以阅读 [社区发布指南](docs/publishing-harness-packs.md)。

## 试用 Alpha

从源码构建本地未签名 macOS 产物：

```sh
pnpm install --frozen-lockfile
./script/build_openfish_release.sh "$(uname -m)"
```

DMG 会输出到 `dist/openfish-<architecture>/`。配置 Apple 发布凭证后，`openfish-v*` 标签会通过仓库 Release 工作流生成签名并公证的 Apple Silicon 与 Intel 产物。

发布标签之前运行：

```sh
pnpm run release:openfish:preflight
```

该检查会主动拒绝脏工作区或缺失发布文件的源码树。

## 运行截图安全的 Demo

Mac 与 iPhone 原生应用都支持 `--openfish-demo` 启动参数。Demo 模式不会启动内置 Host，也不会连接远程电脑；它只用生产 SwiftUI 界面渲染合成的项目、Harness、模型与对话。详见 [Demo 与截图指南](docs/openfish-demo-mode.md)。

## DeepSeek Harness 开发

### 通过 `npm` 运行

安装 `Node.js`，然后运行：

```sh
npx @deepseek-ai/dsh web
```

该命令默认会在 `http://127.0.0.1:3080` 启动 Web UI，本机启动时还会用默认浏览器打开页面。通过 SSH 启动时只打印宿主机 URL，因为本地转发地址由 SSH 客户端或编辑器持有。传入 `--no-open` 可仅运行服务器而不打开浏览器。详见 [Web UI 指南](docs/user/guide/index.md)。

### 从源码运行

如需从仓库源码运行：

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh web
```

`pnpm run build` 会准备仓库产物。`pnpm dsh web` 会直接使用这些已构建产物，不会重新构建。

## 社区与支持

- OpenFish Bug 请使用 OpenFish Issue 模板，并提供应用版本、macOS／iOS 版本、Harness id／版本、工作区模式与首条脱敏错误。
- 安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。
- DeepSeek Harness 本身的问题请提交到上游 [DSH Discussions](https://github.com/deepseek-ai/deepseek-harness/discussions)。
- 为你的插件仓库添加 [`dsh-plugin`](https://github.com/topics/dsh-plugin) 话题，便于被发现。
- 欢迎加入 DeepSeek Harness 企微群：扫码添加企微小助手并填写入群问卷，完成后小助手会邀请你入群。

<table>
  <thead>
    <tr>
      <th align="center">企微小助手</th>
      <th align="center">入群问卷</th>
      <th align="center">微信公众号</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center"><img src="https://cdn.deepseek.com/harness/readme/community-wecom-assistant.png" alt="DeepSeek Harness 企微小助手二维码" width="180" height="180"></td>
      <td align="center"><a href="https://trtgsjkv6r.feishu.cn/share/base/form/shrcnIt5twSVdLGD52KJBckGCgg"><img src="https://cdn.deepseek.com/harness/readme/community-wecom-survey.png" alt="DeepSeek Harness 入群问卷二维码" width="180" height="180"></a></td>
      <td align="center"><img src="https://cdn.deepseek.com/harness/readme/community-wechat-official-account.png" alt="DeepSeek Harness 团队微信公众号二维码" width="180" height="180"></td>
    </tr>
  </tbody>
</table>

## 参与贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 开发

请先阅读[开发指南](docs/development.md)与[架构文档](docs/architecture.md)。

面向 agent：请遵循 [AGENTS.md](AGENTS.md)。

## 许可证

[MIT](LICENSE)

第三方依赖及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
