# `@deepseek-ai/dsh-credentials-keychain`

[English](README.md)

这是 OpenFish macOS Host 的凭证 Provider。每个凭证引用都会作为通用密码存入当前用户
登录钥匙串中的 `app.openfish.credentials` 服务。`describe` 只返回是否已配置及来源元数据；
秘密值仅对 Host 侧消费者可用。

继承的环境变量仍是只读且优先级更高的 CI 来源；项目与用户 `.env` 则作为低于钥匙串的只读兼容回退。从文件 Provider
升级后的首次启动会在本机导入仅属主可读的 `$DSH_HOME/.credentials.yaml`；
只有在所有条目都已存入钥匙串后，才删除明文文件。之后的写入和删除只操作钥匙串，
并发送普通的 `credentials/updated` 事件。Provider 以参数数组调用
`/usr/bin/security`，不会构造 Shell 命令。
