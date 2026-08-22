# DSH Voice Apple Provider

[English](README.md) | 中文

这个 Cordis Provider 为 macOS 与 iPhone 声明 DSH voice 的 `apple-local` 实现。Swift 平台适配器执行 Apple 本地识别器及 premium/enhanced 合成器；最终 transcript 仍进入 DSH session API。

## 模型体验

无，因为该 Provider 不增加任何面向模型的内容。

#### KV Cache 影响

无；Provider 描述只属于启动元数据。

## 已知限制与待办事项

- 本包声明能力元数据；Apple 授权与音频执行由 Swift 客户端负责。
- 可用性与语言质量取决于操作系统和已安装的 Apple 语音。
