# 社区 Harness Pack Manifest

[English](README.md) | 中文

每个文件加入一个公开且不含凭证的 `*.json` Harness Pack，文件名应与 Pack id 一致。提交 Pull Request 前运行 `pnpm run gen-openfish-community-catalog`。

每个包或 Python 分发必须使用准确版本。二进制分发必须提供 SHA-256 校验和，OpenFish 才会安装。凭证名称写入 `authMethods`；绝不要把凭证值写入 Manifest、Issue、测试日志或截图。
