# Agent Note: OpenFish 原生交互一致性

Status: implemented

[English](2026-08-20-openfish-native-interaction-consistency.md) | 中文

## Problem

原生 macOS 与 iPhone 客户端在模型选择、对话顺序、项目创建、听写和任务导航方面采用了不一致的呈现。选中的思考强度会隐藏在模型名称之后；assistant reasoning 显示在答案后面；macOS 输入框的占位文字和编辑器使用不同的文字内边距；本地项目创建错误地委托给不具备 native capability 的 Host picker；任务元数据则长期占用侧栏高度。

## Decision

两个客户端会把所选模型与思考强度作为一个持续可见的标签，并在嵌套菜单内标记准确的当前选项。Assistant reasoning 保持独立 disclosure，显示在答案正文之前，与权威 content block 的顺序一致，同时不会把仅含 reasoning 的 block 冒充为答案正文。

macOS 输入框由同一个 AppKit text view 管理占位文字、光标和已输入文字的几何位置。Text container 使用明确的 inset 与 line-fragment padding；直接按 Return 提交，Shift-Return 插入换行。iPhone 输入框使用一个原生多行字段样式，并明确字体和纵向 inset。听写失败会进入各客户端已有的错误提示；主动停止识别不会在稍后错误地发布一次取消失败。

macOS 本地 Add Project 操作会直接打开 `NSOpenPanel`，并且只把用户选择的路径传给 `workspace.create`；远程连接继续使用 Host 目录浏览器。桌面任务行不再常驻显示空闲相对时间，运行和审批状态使用紧凑标志，标题、项目归属和更新时间通过原生悬停帮助显示。两个原生任务列表都会缩短行高。

产品显示名称为 OpenFish。安装后的应用图标和应用内标志都使用包裹既有 `>_` 终端符号的鱼形轮廓。内部持久化 key 与 wire identifier 保留既有值，因为产品展示改名不应使设备配对、投影缓存或用户偏好失效。

## Alternatives considered

- **保留平台各自的交互模式。** 这会保留局部实现捷径，却让同一份 Host 状态在 macOS 与 iPhone 上表现不同。
- **随产品显示名称一起重命名持久化与 Wire 标识符。** 展示层变化不足以成为破坏兼容设备、缓存与偏好状态的理由。

## Consequences

菜单关闭后模型状态仍然可见，对话时间顺序符合生成顺序，本地文件夹选择不再依赖组合 Host picker，任务导航能在不丢失详细元数据的前提下显示更多工作。统一的 OpenFish 标志在侧栏和应用图标尺寸下都能辨认，并保留终端身份。
