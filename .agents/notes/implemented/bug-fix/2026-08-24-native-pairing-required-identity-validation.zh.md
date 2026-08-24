# Agent Note: 原生配对必须先验证身份再登记

Status: implemented

[English](2026-08-24-native-pairing-required-identity-validation.md) | 中文

## Problem

`PairRequest` 要求 `surface` 与 `deviceName`，但 Schemastery 解析器把这两个 HTTP 字段视为可选。loopback 对 `/x-native/v2/pair` 发送空 JSON 对象时，可能提交一个没有客户端身份的设备记录。TypeScript 接口无法保护 HTTP 解析器，而畸形记录仍会占用有上限的设备 registry 名额。

## Decision

原生 HTTP schema 将 `surface`、`deviceName` 与 Host 本地撤销请求的 `deviceId` 标记为必填。配对必须在 `PairingStore` 提交记录前验证完整客户端身份；畸形请求以稳定的 `invalid-request` 失败，并且不会修改 registry。

iPhone 客户端会先解码 Host 的结构化 HTTP 错误，再回退到数字状态码。因此配对失败会保留稳定的 Host 错误码，同时不修改凭据。

## Verification

x-native 路由测试通过已注册的 HTTP handler 发送空配对对象，断言返回 `400 invalid-request`，并观察到设备 registry 仍为空。Release Host smoke 也会运行打包后的路由，而不是只测试源码解析器。

## Alternatives considered

**信任 `PairRequest` 接口。** HTTP JSON 是无类型边界，编译期必填属性无法拒绝运行时缺失字段。

**在 `PairingStore.pair()` 内验证。** Store 的调用方是同进程类型化代码，它不拥有 JSON 解析。在这里复制 wire schema 会混合传输校验与串行 registry 修改。

**在列出设备时修复畸形记录。** 这仍允许无效输入修改持久状态并提前占用设备名额。提交前拒绝可以让 registry 始终保持权威。

## Consequences

本地开发调用方必须提供与远程客户端相同的身份字段。畸形配对与撤销请求会在修改前失败；原生客户端也能展示明确的 Host 拒绝原因，而不是没有区分度的 HTTP 状态。
