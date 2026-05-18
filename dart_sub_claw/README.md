# dart_sub_claw

`dart_sub_claw` is a small Dart-first reimplementation track for the core ideas in OpenClaw.
It is intentionally independent from the TypeScript runtime while the design is still being shaped.

The first milestone is not feature parity. The first milestone is a working core loop:

1. Accept a message from CLI or a local gateway API.
2. Load local config.
3. Call an OpenAI-compatible chat completions endpoint.
4. Persist the conversation as JSONL.
5. Return the assistant reply.

## Current Commands

Run one agent turn:

```sh
dart run bin/dart_sub_claw.dart agent --message "hello" --session default
```

Start the local gateway:

```sh
dart run bin/dart_sub_claw.dart gateway run
```

After local activation, use the shorter command:

```sh
dart pub global activate --source path .
dartsub gateway run
```

Set provider config:

```sh
dartsub config set provider.model gpt-4.1-mini
dartsub config set provider.apiKeyEnv OPENAI_API_KEY
```

Set provider config for a named environment:

```sh
dartsub config --env test set provider.baseUrl https://ark.cn-beijing.volces.com/api/v3
dartsub config --env test set provider.model glm-4-7-251222
dartsub config --env test set provider.apiKey <secret>
```

Show config:

```sh
dartsub config list
```

Run with an environment:

```sh
dartsub agent --env test --message "hello" --session test
dartsub gateway run --env test
```

Start the terminal chat UI:

```sh
dartsub tui
dartsub tui --env test --session test
```

The TUI is built with `dart_tui`. It uses the package Model-Update-View runtime and spinner, while `dartsub` owns input editing compatibility for `Backspace`, `Ctrl-H`, pasted text, and wide-character wrapping. It shows a `思考中` spinner until the first streamed chunk arrives, streams assistant output as chunks arrive from the provider, and then persists the full reply to the session.

TUI keys:

```text
Up / Down       recall previous inputs for the current session
Left / Right    move within the input line
Backspace       delete the previous character
Ctrl-H          delete the previous character in terminals that emit Ctrl-H
PageUp/PageDown scroll chat history
Ctrl-U/Ctrl-D   scroll chat history
Ctrl-G          jump back to the latest message
Mouse wheel     scroll chat history
Ctrl-C          exit the TUI
```

TUI commands:

```text
/help
/status
/history
/session <id>
/env <name|default>
/clear
/exit
```

Run diagnostics:

```sh
dartsub doctor
dartsub doctor --env test
dartsub doctor --skip-model
```

`doctor` checks config loading, provider fields, API key availability, model connectivity, gateway port availability, and the session directory.

Run the current smoke tests:

```sh
dart run test/agent_service_test.dart
dart run test/tui_smoke_test.dart
```

## Gateway API

Default bind:

```text
http://127.0.0.1:18987
```

Endpoints:

```text
GET  /health
GET  /sessions
POST /agent
WS   /events
```

Example:

```sh
curl -s http://127.0.0.1:18987/agent \
  -H 'content-type: application/json' \
  -d '{"message":"hello","sessionId":"default","environment":"test"}'
```

## Runtime Data

By default, runtime state is stored outside this repository:

```text
~/.dart_sub_claw/config.json
~/.dart_sub_claw/sessions/*.jsonl
```

Override the home directory when testing:

```sh
DART_SUB_CLAW_HOME=/tmp/dart-sub-claw dartsub config list
```

## Technical Docs

- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
