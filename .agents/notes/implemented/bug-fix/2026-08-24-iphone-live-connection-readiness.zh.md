# Agent Note: iPhone 实时连接就绪以认证后的 WebSocket 打开为准

Status: implemented

[English](2026-08-24-iphone-live-connection-readiness.md) | 中文

## Problem

iPhone 可能已经完成 REST 配对并持久化有效的 Host 身份，却一直停在 Connecting。`URLSessionWebSocketTask.resume()` 只会调度两个事件 socket；在 HTTP upgrade 完成前立即用 ping 探测就绪状态，可能在真机上无限等待。Host 进程替换还需要为每次尝试设置上限，避免某一代 socket 永久占住重连循环。

## Decision

iPhone 实时连接只有在两个通过认证的 Host 事件 socket 都收到 `URLSessionWebSocketDelegate.didOpenWithProtocol` 后才发布 Connected。共用的 TLS delegate 将每个打开、关闭和完成回调桥接到异步连接尝试，同时保留证书 pinning 与 bearer authentication。

每一代 socket 打开操作最多等待五秒。关闭、传输完成或超时都会使这一代失败；连接所有者会取消两个 socket，并以有上限的退避整体重试。前台激活只会在没有活动连接任务时创建新一代连接；进入后台会保存 projection，并让连接进入静止状态。

真机测试启动可以显式启用仅限 DEBUG 的防休眠环境开关，使 Host 替换检查保持前台运行，从而区分网络重连与设备自动锁屏。Release 构建绝不会修改用户的 idle-timer 策略。

## Verification

真实 iPhone 可以完成全新配对、冷启动后恢复已保存的 profile、观察已安装 Host 进程的精确替换，并在保持前台时无需新配对码自动重连。另一个仅限 DEBUG 的 Hardware Probe 会启用真实麦克风，并通过五轮启停。iOS App 也能完成真机构建，且 UI test runner 使用同一设备的签名配置。

Simulator UI Lane 已通过明确 Host State、Cached Offline 行为、Accessibility 字号下的 Empty／Setup State、声明的 Harness Architecture、Approval 与 Structured Question 完成、反复语音启停，以及确定性的 Microphone-denied 恢复路径。认证 Host Test Lane 证明一个 Bearer 只能 Revoke 自己配对的设备，且 Replay 会被拒绝。真机 XCTest Device-control Channel 未能连接到 Runner，因此这些 Simulator 与 Protocol 结果不会被描述成真机端到端 UI 证明。

## Alternatives considered

**把 `resume()` 当作已连接。** 调度 URL session task 不能证明认证后的 HTTP upgrade 已成功，这会发布虚假的实时状态。

**立即发送 ping。** 对 Apple 的 WebSocket 实现而言，upgrade 前的 ping 不是可移植的就绪屏障，并可能让连接尝试无限等待。

**在事件 socket 打开前刷新 REST 状态。** 这会制造可预测的启动竞态，而且仍不能证明审批、提问和任务事件能够到达。

## Consequences

Connected 表示两个认证后的下行通道都可用，Host 切换也不会把 App 卡在一代没有上限的 socket 中。重连最多需要一次有界打开等待加退避时间；当测试启动显式请求时，DEBUG 真机检查可以暂时保持屏幕常亮。
