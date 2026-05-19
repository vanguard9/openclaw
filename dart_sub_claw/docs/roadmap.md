# dart_sub_claw Roadmap

## Phase 0: Core Loop

Status: started.

Deliverables:

- Dart package scaffold.
- CLI entrypoint.
- JSON config store.
- Named environments for test/prod style provider separation.
- JSONL session store.
- OpenAI-compatible provider.
- OpenAI-compatible streaming for TUI output.
- `agent --message` command.
- `tui` command using `dart_tui` for terminal chat.
- TUI input history with Up and Down recall.
- TUI chat history scrolling with PageUp, PageDown, Ctrl-U, Ctrl-D, Ctrl-G, and mouse wheel.
- TUI runtime controls for Esc, `/cancel`, and OpenClaw-style Ctrl-C.
- `doctor` command for config, provider, model, port, and session checks.
- Local gateway with `/health`, `/sessions`, `/agent`, `/agent/stream`, and `/events`.
- Gateway SSE streaming with `/agent/stream` and disconnect cancellation.
- Gateway request IDs and structured error codes.
- Provider timeout, retry, and backoff controls.
- Tool runtime MVP with `shell`, `read_file`, and `write_file`.
- Tool permission model with read-only defaults and TUI confirmation for dangerous tools.
- Architecture documentation.

Exit criteria:

- `dartsub config list` creates and prints config after local activation.
- `dartsub agent --message "hello"` can return a provider reply when an API key is configured.
- Session files contain user and assistant messages.
- Gateway can run on `127.0.0.1:18987`.

## Phase 1: Better Developer Ergonomics

Deliverables:

- Replace ad hoc CLI parsing with a stable parser if command complexity grows.
- Add a real test dependency and unit tests.
- Expand TUI smoke coverage beyond input editing and command handling.
- Add provider response metadata.
- Add persistent tool policy controls, such as per-tool allowlists and session-scoped remember decisions.
- Add structured logging.
- Add a small `doctor` command for config and provider checks.

## Phase 2: Streaming And Gateway Contracts

Deliverables:

- Streaming provider responses.
- Gateway event stream with token deltas.
- Request cancellation surfaced through gateway streams.
- Minimal OpenAI-compatible HTTP surface if useful.

## Phase 3: First Channel Adapter

Recommended order:

1. Webhook channel.
2. Telegram Bot API.
3. Discord.
4. Other channels only after routing and permissions are clear.

Deliverables:

- `Channel` lifecycle manager.
- Inbound message normalization.
- Outbound text delivery.
- Channel-specific config.
- Basic allowlist or owner-only guard.

## Phase 4: Media

Deliverables:

- Local file attachments.
- Remote URL fetch with size limits.
- MIME detection.
- Image payload forwarding to providers that support vision.
- Media retention policy.

## Phase 5: OpenClaw Interop

Deliverables:

- Read-only import from selected OpenClaw config/session formats.
- Migration report before writing anything.
- Optional export back to a neutral interchange format.
- Compatibility tests against representative OpenClaw fixtures.

## Phase 6: Plugin Or Extension Model

Only start this after channels and gateway contracts are stable.

Open questions:

- Dart plugin model: dynamic process protocol, package imports, or isolates?
- How much should match OpenClaw's TypeScript plugin SDK?
- Which extension APIs must be stable before public use?
