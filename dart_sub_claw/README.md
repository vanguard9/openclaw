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

Show config:

```sh
dartsub config list
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
  -d '{"message":"hello","sessionId":"default"}'
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
