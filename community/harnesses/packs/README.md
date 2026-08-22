# Community Harness Pack manifests

English | [中文](README.zh.md)

Add one public, credential-free `*.json` Harness Pack per file. The filename should match the Pack id. Run `pnpm run gen-openfish-community-catalog` before opening a pull request.

Every package or Python distribution must use an exact version. Binary distributions require a SHA-256 checksum before OpenFish installs them. Put credential names in `authMethods`; never put credential values in a manifest, issue, test log, or screenshot.
