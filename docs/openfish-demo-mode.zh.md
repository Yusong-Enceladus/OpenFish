# OpenFish Demo 模式

[English](openfish-demo-mode.md) | 中文

OpenFish 为截图、演示和发布预览提供确定性状态。该模式中可见的项目、任务、路径、电脑名、Harness、模型和对话全部是合成数据。

## 隐私边界

- Mac 应用跳过偏好迁移，不启动内置 Host。
- iPhone 应用不恢复已保存的 Host 凭证，也不建立网络连接。
- Demo 状态只在内存中构造，不写入任务缓存。
- Fixture Client 使用不能联网的 `openfish-demo:` URL Scheme；普通 Demo State 会拒绝听写与启动语音对话。单独的 iPhone Voice Smoke 启动模式只用于测试，不用于生成公开素材。
- 界面会显示 `DEMO` 或 `Demo data · offline`，与真实会话区分。

不要把真实截图混入 `docs/assets/`。公开 UI 变化后，应从 Demo 模式重新生成三张文档截图。发布检查会拒绝图片 Metadata、可疑 Raw String，以及 OCR 可见的个人路径、Email、本地主机名、私网 IP 或 Credential-like Value；最终图片仍需人工检查。

## macOS

构建原生应用，然后传入启动参数：

```sh
open apps/x-macos/.build/OpenFish.app --args --openfish-demo
```

仓库的视觉冒烟测试使用同一 Fixture，在不启动 Host 的情况下生成稳定的 1260 × 820 深色模式图片。

## iPhone Simulator

在 Simulator 中构建并安装 iPhone 应用，然后使用以下命令启动：

```sh
xcrun simctl launch booted app.openfish.ios --openfish-demo
```

使用不含个人 Apple 账号或内容的 iPhone Simulator。只截取 OpenFish 窗口，并在提交前移除 PNG 元数据。
