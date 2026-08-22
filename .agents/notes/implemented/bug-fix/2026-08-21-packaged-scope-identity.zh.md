# Agent Note: 打包环境中的 Scope 身份

Status: implemented

[English](2026-08-21-packaged-scope-identity.md) | 中文

## Problem

打包应用可能载入多个物理副本的 `@deepseek-ai/dsh-scope`。模块局部 Symbol 与父链接映射会在同一个 Cordis Runtime 中描述彼此不同的 Scope 空间。Agent Preset 行因此读不到 Roster 创建的 Scope，原本限定作用域的 Persona 会尝试占用全局 `deployment:persona` 槽，导致所有使用 Preset 的 DSH Session 都无法创建或恢复。

## Decision

Scope Context 标记与进程状态使用稳定的 `Symbol.for` 键。同一个 JavaScript 进程中的每个物理模块副本读取相同的 Context 标记、父链接 WeakMap 与 Carrier WeakMap。Scope Key 仍是以对象身份比较的不透明值，不同进程仍由各自的全局对象隔离。

## Alternatives considered

- **只对 Open Fish 包依赖图去重。** 某一种 Lockfile 布局可以隐藏问题，却无法让公开的 Scope Primitive 在其他打包器或插件依赖图中保持安全。
- **移除 Preset Persona。** 这会丢失按 Agent 定义身份的能力，而且只是掩盖错误的 Scope 关系。
- **使用字符串 Scope id。** 字符串相等会让无关 Runtime 与重复标签发生冲突；不透明对象身份仍是正确地址。

## Consequences

源码工作区与打包应用得到相同的作用域注册行为。进程级 Symbol 名称成为兼容性标识符，而存储在其后的值仍只有已在应用进程中执行并具备应用权限的模块才能访问。
