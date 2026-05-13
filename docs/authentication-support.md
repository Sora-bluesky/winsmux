# Authentication Support Policy

winsmux is a platform for safely operating multiple CLI agents.  
Within that model, winsmux does **not** broker OAuth logins or extract and relay authentication material on behalf of another tool.

## Core policy

- winsmux support is defined by **authentication mode**, not only by tool name
- a CLI may support a given authentication mode without that mode being formally supported by winsmux
- winsmux launches, supervises, compares, and governs CLIs
- winsmux itself does not become an OAuth intermediary

## Support matrix

| Tool | Authentication mode | winsmux support level |
| ------- | ------- | ------- |
| Claude Code | API key / documented enterprise auth | Supported |
| Claude Code | Pro / Max OAuth | This PC only, interactive use |
| Codex | API key through the official agent CLI | Supported |
| Codex | ChatGPT OAuth through the official agent CLI | This PC only, interactive use |
| Gemini | Gemini API key through the official agent CLI | Supported |
| Gemini | Gemini API through Gemini Enterprise Agent Platform and the official agent CLI | Supported |
| Gemini | Google OAuth through the official agent CLI | This PC only, interactive use |

Model families such as Gemma, Llama, Mistral, Qwen, DeepSeek, and Kimi are not
authentication providers by themselves. For Colab workers, authenticate the
official model source or hosted endpoint inside the Colab-owned or
adapter-owned flow, and record only non-secret model metadata in winsmux
evidence.

## What the terms mean

### Supported

This authentication mode is part of the standard winsmux workflow.

- it may be used for pane execution
- it may be used for compare and multi-agent operation
- it is allowed by preflight checks

### This PC only, interactive use

This means the CLI itself may complete its own official login flow on that same PC.

That allows:

- the user to launch the official CLI locally
- the CLI itself to run its own official login flow
- winsmux to launch or observe that already-authenticated local CLI session

That does **not** allow:

- winsmux to present the login UI on the CLI's behalf
- winsmux to receive the URL that completes authentication
- winsmux to extract tokens from the authentication storage used by the CLI
- winsmux to share those tokens with other panes or users

### Unsupported

This authentication mode is not part of the standard winsmux workflow.

- it is stopped during preflight checks
- it is not shown as a standard launch path
- it is not part of the default compare or multi-agent flow

## What winsmux will not do

winsmux does not:

- complete OAuth logins on behalf of another CLI
- receive the URL used to finish authentication
- extract tokens from authentication storage
- relay or share tokens across panes or users
- treat consumer OAuth as shared credentials for multi-pane operation

## Preflight handling

Preflight handling looks at both the CLI name and the authentication mode.
The launcher uses the provider capability registry and the configured `auth_mode`
before it starts a pane.

Examples:

- `gemini-api-key` is allowed
- `gemini-vertex` is allowed
- `gemini-google-oauth` is limited to interactive use on that same PC
- `codex-chatgpt-local` is limited to interactive use on that same PC
- `claude-pro-max-oauth` is limited to interactive use on that same PC

Local interactive modes are allowed only when the official CLI owns the login.
They are not shared credentials for other panes.
Preflight must stop if a workflow asks winsmux to receive callback URLs,
extract tokens, or share tokens across panes.

The following `auth_mode` values are explicitly blocked:

- `oauth-broker`
- `token-broker`
- `callback-url`
- `callback-url-receiver`
- `shared-token`
- `provider-api-proxy`

## Terminology

This document and `README.md` use these meanings consistently.

- control plane -> operating platform / governance layer
- orchestration -> multi-agent operation
- launcher -> launch path
- preflight -> preflight check
- dispatch -> execution routing
- operator docs -> operator-facing docs
- credential store -> authentication storage
- callback URL / localhost redirect -> the URL used to finish authentication
- local interactive only -> this PC only, interactive use
- fail-closed -> stop when the required condition is not satisfied
