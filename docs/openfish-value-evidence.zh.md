# OpenFish 价值证据

[English](openfish-value-evidence.md) | 中文

只有当 OpenFish 的控制面减少安装配置与跨设备衔接成本，同时不隐藏“谁在执行代码、谁会接收数据、谁向用户计费”时，它才真正有价值。目录很大、Graph 好看或 Build 成功都不能证明这个结果。本报告把产品价值与 Harness 任务质量分开，并如实记录缺失证据，而不是用宣传替代。

## 正在验证的声明

| 产品声明 | 成功指标 | 当前证据状态 | 发布解释 |
| --- | --- | --- | --- |
| 一个 App 能在干净 Mac 上完成第一个成功任务 | 从安装 App、明确完成 Harness 认证、选择实时模型、创建 Project／No Project，到收到完成响应的中位时间与失败分布 | 尚未在 Clean-machine 样本中测量 | 已实现 Release-candidate 路径；暂时不能声称零摩擦安装 |
| 用户无需学习不同 CLI 即可切换 Harness | 新任务 Override 成功、出现正确账号／模型／思考控件，而且旧任务不被修改 | Release Candidate 的 Harness／ACP Contract 与 Apple Silicon Packaged-runtime Gate 已通过；真实 DSH／Codex／OMP Artifact Matrix 仍待完成 | 可以声明协议驱动选择，不能声明通用成功 |
| App 与 Host 重启后任务可靠恢复 | 按 Harness／版本／Workspace 模式统计 Resume 成功，并保留 Remote Identity 与固定配置 | Resume、Fork、Pack Pinning Fixture 与 Packaged Clean-state Host Smoke 已通过；真实 Multi-Harness Retention Matrix 仍待完成 | 不能发布可靠性百分比 |
| 安装配置失败可以恢复 | 从缺失认证、无可路由模型、下载损坏、更新中断、Harness 退出、Registry 故障与 Host 重连恢复，同时不丢已有任务 | Missing Auth／Model、Invalid Pack、ACP Exit／Cancel、Host Reconnect 与 Update／Rollback Contract 已通过；尚未记录完整 Chaos Run | 可以说明存在明确恢复状态，不能声称鲁棒性已证明 |
| Architecture View 改善理解 | 用户能够从代表性 Pack 中正确识别 Host、Harness、Account／Provider、模型、Workspace Boundary、Evidence Level 与活跃 Runtime Component | 尚未进行理解度研究 | 只能称为 Evidence-backed Lens，不能声称已证明提升理解 |
| 技术用户可以高效创建 Pack | 从空 Manifest Editor 到通过接纳的准确版本 Pack、不发送模型提示词的实时 Preflight、无凭证 Export 与成功任务所需时间 | 已实现可执行 Workflow；尚未测量任务时间样本；不宣称 Provider 不创建状态或没有初始化成本 | 当前只能称 Manifest Editor，不能称通用可视化 Harness Builder |
| Mac–iPhone 连续性减少中断 | 在真实手机上完成 Pair／Reconnect／Follow-up／Approval／Question／Revoke，并能从后台或断网恢复 | DEBUG 真机 Candidate 已通过全新 Pair、冷启动 Profile 恢复、精确 Host 替换／重连与五轮麦克风启停；Simulator 的 Approval／Question 与 Microphone-denied UI、以及认证 Host 的 Self-revoke Contract 已通过，最终真机端到端 Interaction、Background 与 Revoke 记录仍待完成 | 不能从 Simulator 或 Protocol Test 推导尚未记录的真机行为 |

## Harness 质量是另一项实验

OpenFish Compatibility 回答一个 Harness 能否通过壳子完成安装、配置、调用、观测、恢复与控制；它不回答谁“最好”。比较 DSH、Codex、OMP、Pi、OpenCode、Claude Code 或其他 Agent，必须使用相同任务集，并分别测量任务完成、回归、延迟、成本、工具保真、安全行为与主观适配；结果还必须注明 Provider Quota 与账号类型。

OpenFish 不会根据 Repository Star、发布时间、名称、单次 Demo 或壳子自身的兼容结果给 Harness 排名。未来 Benchmark 报告必须公开任务、Harness 与模型版本、设置、账号／计费模式、重复次数、失败与脱敏后的 Raw Outcome。

## Release Evidence 记录

证据归准确 Release Candidate，而不是 Working-copy 实现。每项都要记录为 **passed**、**failed** 或 **not run**，并附 Artifact Version 与日期：

1. 干净 Apple Silicon 安装，以及受支持时的干净 Intel 安装。
2. DSH、官方 Codex app-server 与 OMP ACP 真实路径。
3. 全新通用 ACP Pack 与全新非 ACP Driver Conformance 路径。
4. Project／No Project 创建、发送、取消、恢复、归档、搜索、受支持时 Fork、更新、回滚与卸载保留。
5. Mac 与 iPhone 的 Loading、Empty、Setup、Offline、Recoverable、Fatal、Accessibility、Resize 与 Dynamic Type 状态。
6. 真实 iPhone Pair、Reconnect、Follow-up、Approval、Question、连续性、语音允许／拒绝、反复启停、后台恢复与 Revoke。
7. Source／History／Asset 隐私审查、Threat Model 审查、Packaged Runtime 检查、签名／公证与安装／卸载审查。

在最终 Artifact 的这些记录形成之前，诚实结论是：**OpenFish 已具有有意义且差异化的架构，但其公开影响力与可靠性尚未得到证明。**
