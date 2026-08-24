# OpenFish compatibility

English | [中文](openfish-compatibility.zh.md)

OpenFish compatibility is a tested contract, not a claim that every program called a Harness works automatically. The shell has two extension boundaries:

1. ACP-compatible Harnesses use the built-in ACP driver and require no native UI code. Models, reasoning levels, modes, and standard session options come from the live ACP configuration directory.
2. A non-ACP Harness needs one [`HarnessDriver` plugin](harness-driver-sdk.md). The catalog, installer, session pinning, storage, native shell, and phone transport remain shared.

## Support levels

| Level | Meaning |
| --- | --- |
| Release baseline | Blocks an OpenFish release through automated contract and packaged-runtime checks. |
| Verified alpha | Has release-baseline coverage plus a recorded real-runtime/manual path on a supported Mac. |
| Release candidate | The Pack and Driver are present, but the current artifact has not yet earned both automated and recorded live-runtime evidence. |
| Community compatible | Comes from the ACP Registry, OpenFish community catalog, or a custom Pack and uses the generic driver, but is not an OpenFish release blocker. |
| Unsupported protocol | Needs a Driver plugin before OpenFish can run it. |

## Current matrix

| Harness | Entry | Level | Authentication authority | Notes |
| --- | --- | --- | --- | --- |
| DeepSeek Harness | built-in `dsh` Pack | Release candidate | DSH provider configuration | The native Host/session and No Project lane must pass the final release artifact gate before it is promoted to Release baseline. |
| Codex CLI | built-in official `codex app-server` Pack | Release candidate | Existing Codex login, managed ChatGPT login, or OpenAI API key | Models and reasoning options come from the live app-server session. The current account/billing label comes from `account/read` without retaining email or credentials, and task forks use official `thread/fork`; promotion still requires recorded live login/model/reasoning/send/resume/fork evidence for each selected billing path. |
| Oh My Pi | curated `oh-my-pi` Pack | Release candidate | OMP | Runs through OMP's ACP command; promotion requires the generic ACP gate plus a recorded live OMP path. OMP private settings remain OMP-owned. |
| Pi | ACP Registry `pi-acp` | Community compatible | Pi | Uses the same generic ACP path; it is not yet a release-blocking real-account lane. |
| Other ACP Registry agents | Registry Pack | Community compatible | The selected agent | Registry admission verifies metadata/auth shape; OpenFish reports runtime compatibility only after launch. |
| OpenFish community Packs | Community catalog | Community compatible | Pack/agent | Pull-request review validates the public manifest and exact distribution pins; entries remain unverified until a real runtime succeeds. |
| Custom ACP process | user Pack | Community compatible | Pack/agent | Exact package versions are required; arbitrary secrets belong in authentication fields, not launch environment data. |
| Non-ACP Harness | public Driver SDK plugin | Unsupported until its Driver is loaded | Driver-defined | A name or executable alone cannot reveal private session semantics safely; the conformance report rejects incomplete lifecycle, workspace, editing, and observation claims before launch. |

## Release-blocking journeys

The Harness contract gate covers manifest admission, first launch, no-project sessions, Harness switching, model/config changes, resume pinning, missing authentication, ACP disconnect/cancel, unknown future standard options, and the packaged Host lifecycle. `script/check_harness_contract.sh` is called by the macOS release builder.

Compatibility reports must include the Harness id and version, OpenFish build, host architecture, workspace mode, authentication method name (never the credential), and a redacted first error. A passing Registry entry is discovery metadata, not a security review or quality endorsement.

This table describes the evidence required by the source tree; it is not itself evidence that the current working copy passed. A tagged release can promote a candidate only from the reports produced for that exact artifact.
