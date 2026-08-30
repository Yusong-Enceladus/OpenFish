# OpenFish iPhone 客户端

[English](README.md) | 中文

该目录包含 OpenFish DSH 组合的原生 SwiftUI iPhone 客户端。它使用普通 DSH `/api`、Host 事件流、mux 事件流、会话日志、投影、审批、问题、队列、模型目录、权限 preset 与 agent preset。它只拥有 iOS 呈现、存于 Keychain 的设备凭据、本地语音采集／播放、通知以及临时文件交接。

应用已实现 Remote 风格的已连接电脑筛选、可折叠项目与任务导航（含归档任务和底栏搜索）、共享历史分页、支持 fenced code 的 CommonMark／GFM assistant 流式输出、结构化 terminal／diff／read／search／web 工具详情、持久会话图片、靠近底部的审批与多问题回答、queue／steer／cancel、模型与 reasoning 选择、权限确认、空白任务 agent preset 选择、重命名／fork、图片提示、本地听写与朗读、配对／重连、Codex／DSH 导入以及 DSH 导出。每次新事件流 generation 都会先重新读取 DSH 权威基线，再应用实时事件，因此重连不会把手机当作业务状态所有者。

构建 library：

```sh
./build.sh
```

Xcode 应用 target 由 `project.yml` 与 `App/` 下的文件描述。运行时需要连接配置的 LAN 或 Tailscale 地址上的 OpenFish DSH Host。发布 parity 仍需真实设备与并排证据；本文只描述已实现的可触达能力，不构成 release verification 声明。

## 物理设备冒烟检查（Debug）

授予必要权限后，启动参数 `--openfish-voice-autotest` 会执行五次真实麦克风启停。检查丢弃识别到的语音，并在每次调用时用带时间戳、无内容的本次记录替换 `Library/Caches/openfish-voice-hardware-history.txt`。已取消的运行不能报告成功。

参数 `--openfish-lifecycle-autotest` 执行生产连接处理逻辑，并等待新的 Host 基线完整刷新。独立参数 `--openfish-projectless-autotest` 创建真实 No Project 任务但不发送提示词；存在未发送文字或附件时会拒绝替换。切换到其他应用再返回后，下一次 Host 刷新会检查同一个空白任务、Harness、模型、思考强度选择以及可用模型目录是否保留。

连接检查在启动时替换 `Library/Caches/openfish-connection-history.txt`，只记录时间戳与粗粒度状态。这些检查需要已配对的 Host 和配置完成的默认 Harness。它们不能替代点击与布局的 XCTest 覆盖，Runner 连接失败也不等于 UI 测试通过。
