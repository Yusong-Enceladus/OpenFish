# `@deepseek-ai/dsh-credentials-keychain`

[中文](README.zh.md)

OpenFish's macOS Host credential provider. Each credential reference is stored
as a generic password in the current user's login Keychain under the
`app.openfish.credentials` service. `describe` returns only configured/source
metadata; secret values are available only to Host-side consumers.

An inherited environment value remains a read-only, higher-priority source for
CI, while project and user `.env` files remain read-only fallbacks below
Keychain for compatibility with existing setups. On the first launch after upgrading from the file
provider, an owner-only `$DSH_HOME/.credentials.yaml` is imported locally; the
plaintext file is removed only after every entry is present in Keychain. New
writes and removals affect Keychain and emit the ordinary
`credentials/updated` event. The provider invokes `/usr/bin/security` with an
argument vector and never constructs a shell command.
