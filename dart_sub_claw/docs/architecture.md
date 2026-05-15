# dart_sub_claw Architecture

## Design Goal

`dart_sub_claw` should start as a compact, understandable Dart core rather than a direct port of every OpenClaw subsystem.
The first implementation keeps the same high-level shape as OpenClaw but chooses smaller contracts:

- CLI as the operator surface.
- Gateway as a local control plane.
- Agent service as the core message execution path.
- Provider abstraction for model calls.
- Session store for durable conversation history.
- Channel abstraction reserved for later messaging integrations.

## OpenClaw Mapping

| OpenClaw area | Current TypeScript path | Dart MVP equivalent |
| --- | --- | --- |
| CLI bootstrap | `src/entry.ts`, `src/cli/program/build-program.ts` | `bin/dart_sub_claw.dart`, executable `dartsub`, `lib/src/cli/cli.dart` |
| Command registration | `src/cli/program/command-registry.ts` | Small switch-based CLI dispatcher |
| Agent turn | `src/commands/agent.ts` | `lib/src/agent/agent_service.dart` |
| Gateway | `src/gateway/server.impl.ts` | `lib/src/gateway/gateway_server.dart` |
| Provider/model call | `src/agents/*` | `lib/src/providers/*` |
| Sessions | `src/config/sessions.ts`, `src/commands/agent/session*.ts` | `lib/src/sessions/*` |
| Channels | `src/channels/*`, `extensions/*` | `lib/src/channels/channel.dart` |
| Media | `src/media/*` | Not implemented yet |
| Plugins | `src/plugins/*`, `extensions/*` | Not implemented yet |

## Runtime Flow

```mermaid
flowchart LR
  CLI["CLI or Gateway API"] --> AgentService["AgentService"]
  AgentService --> ConfigStore["ConfigStore"]
  AgentService --> SessionStore["SessionStore"]
  AgentService --> Provider["OpenAI-compatible Provider"]
  Provider --> ModelAPI["Chat Completions API"]
  AgentService --> SessionStore
  AgentService --> CLI
```

## Modules

### CLI

`lib/src/cli/cli.dart` is deliberately simple. It supports:

- `agent --message <text> [--session <id>]`
- `gateway run [--host <host>] [--port <port>]`
- `config list`
- `config get <key>`
- `config set <key> <value>`

This avoids committing early to a third-party argument parser. If command complexity grows, the CLI layer can be replaced without changing the core services.

### Config

`ConfigStore` persists JSON to `~/.dart_sub_claw/config.json` unless `DART_SUB_CLAW_HOME` is set.

Supported config keys:

- `provider.kind`
- `provider.baseUrl`
- `provider.model`
- `provider.apiKey`
- `provider.apiKeyEnv`
- `gateway.host`
- `gateway.port`

The default provider kind is `openai-compatible`. The API key can be stored directly for local experiments, but the preferred path is `provider.apiKeyEnv`.

### Agent Service

`AgentService` owns the core turn:

1. Validate input.
2. Ensure config exists.
3. Load prior messages from the session.
4. Append the user message.
5. Call the provider with the full history.
6. Append the assistant reply.
7. Return the reply.

This is the first stable boundary. Future tools, routing, streaming, and channel metadata should attach around this service rather than leaking into the provider.

### Provider

`OpenAiCompatibleProvider` calls:

```text
POST {provider.baseUrl}/chat/completions
```

It expects:

```text
choices[0].message.content
```

The next provider improvement should be a normalized response type that can carry usage, raw provider metadata, and streaming deltas.

### Gateway

`GatewayServer` uses `dart:io` only.

Current endpoints:

- `GET /health`
- `GET /sessions`
- `POST /agent`
- `WS /events`

The gateway broadcasts coarse lifecycle events:

- `hello`
- `agent.started`
- `agent.completed`
- `error`

This is enough to build a small local UI or integration test before channel adapters exist.

### Sessions

Sessions are JSONL files:

```text
~/.dart_sub_claw/sessions/default.jsonl
```

Each line is:

```json
{"role":"user","content":"hello","createdAt":"2026-05-15T00:00:00.000Z"}
```

JSONL is intentionally chosen because it is append-friendly and easy to inspect during early development.

### Channels

`lib/src/channels/channel.dart` defines only the future adapter shape. No real messaging channel is implemented yet.

The first real channel should probably be a webhook channel or Telegram. WhatsApp, Discord, Slack, Signal, iMessage, plugins, media, pairing, allowlists, and command gating should come after the core loop is stable.

## Non Goals For MVP

- No OpenClaw config compatibility.
- No plugin system.
- No media pipeline.
- No channel auth, pairing, or allowlists.
- No daemon/service installer.
- No fallback model routing.
- No Codex/Claude/Pi CLI backend support.
- No browser automation.
- No mobile/macOS app integration.

## Compatibility Rules

During early development, keep `dart_sub_claw` isolated:

- Do not write to `~/.openclaw`.
- Do not bind the same default port as OpenClaw.
- Do not assume OpenClaw plugin packages can be loaded by Dart.
- Treat this as a new implementation that may later gain import/export bridges.
