# OpenCodex 产品 profile 模板

[English](README.md) | 中文

该目录及 `dsh --profile x` 拼写是遗留兼容名称。此模板在 DSH 上组合 OpenCodex Host：launcher 安装由安装项拥有的基础组合（`dsh-base` + `dsh-web-app` + `dsh-bundle-x-native`），本目录则把语音、调度与时间上下文作为普通 Cordis 插件加入。DSH 仍是唯一运行时和持久会话所有者；`x-native` 只贡献启动发现、版本协商、配对、身份与传输事实。

从源码 checkout 中直接运行：

```sh
pnpm dsh --profile x --port 3080
```

CLI 会在首次使用时写入这份完整模板。OpenCodex 默认绑定到 LAN/Tailscale，所有远程 API 或 WebSocket 请求都必须携带已配对设备的 bearer；如需仅允许本机访问，请传入 `--host 127.0.0.1`。

anchored agent preset 与此模板一同位于 `apps/cli/config/agent-presets/anchored`，并从安装项随附的 preset 根目录以 system trust 自动挂载。可在 Settings → Agent presets 中将其设为默认值，也可按会话选择。遗留 profile 名称不授权任何脱离普通 DSH 服务与 Cordis 组合的产品行为。
