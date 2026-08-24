# Agent Note: OpenFish 发布前同时构建两种 package face

Status: implemented

[English](2026-08-24-openfish-release-builds-both-faces.md) | 中文

## Problem

OpenFish 发布脚本在复制 workspace package 到内嵌 runtime 前只构建 Host face，但 Host 使用的部分 package 会在 Client build face 才生成 Node 入口。例如，`dsh-client-connection` 的 TypeScript 源码和声明可以是最新的，`lib/index.js` 却仍然是旧文件。源码 Host 能接受原生客户端的 LAN TLS 请求，而打包 Host 会拒绝同一个请求。

## Decision

发布构建在组装内嵌 runtime 前运行完整的 `build:lib` contract，同时生成 Host 与 Client face。打包 Host smoke 使用当前有效的非 loopback IPv4 authority 连接，因此旧 connection 入口无法再通过 loopback trust 快捷路径。

## Verification

打包 runtime 必须通过真实 LAN TLS listener 返回带版本的 health 响应。同一 smoke 还验证 listener 隔离，并通过已注册路由提交畸形配对请求，确认设备 registry 不发生变化。

## Alternatives considered

**只显式构建 `dsh-client-connection`。** 这会把一个已知的跨 face 依赖写死在发布脚本中；下一个 Client 阶段生成 Node 入口的 package 进入 Host closure 后，问题会再次出现。

**信任 `lib/types` 下的 TypeScript 输出。** 打包 manifest 导出的是 `lib/index.js`；新声明无法让旧 runtime 入口自动变新。

**只保留 loopback TLS smoke。** loopback 会按设计绕过 deployment authority 列表，因此不能代表 iPhone 请求。

## Consequences

发布构建会额外运行 Client face，但每个打包 Node 入口都来自当前 checkout。只在源码环境或只在 loopback 下工作的 package 会在 DMG 生成前失败。
