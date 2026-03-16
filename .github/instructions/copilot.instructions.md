# OpenClaw Codebase Patterns

**Always reuse existing code — no redundancy!**

## Project Overview

**OpenClaw** is a personal AI assistant that runs on your own devices. It answers on the channels you already use (WhatsApp, Telegram, Slack, Discord, Google Chat, Signal, iMessage, Microsoft Teams, IRC, WebChat) plus extension channels (BlueBubbles, Matrix, Zalo, Mattermost, Nostr, etc.). The Gateway is the control plane; the product is the assistant.

- **Repo**: https://github.com/openclaw/openclaw
- **Docs**: https://docs.openclaw.ai (Mintlify)
- **License**: MIT

## Tech Stack

- **Runtime**: Node 22+ (Bun also supported for dev/scripts)
- **Language**: TypeScript (ESM, strict mode)
- **Package Manager**: pnpm (`pnpm-lock.yaml` is the lockfile)
- **Lint/Format**: Oxlint + Oxfmt (`pnpm check`)
- **Tests**: Vitest with V8 coverage (70% threshold)
- **CLI Framework**: Commander + @clack/prompts
- **Build**: tsdown (outputs to `dist/`)
- **UI**: Lit (legacy decorators, `experimentalDecorators: true`)
- **Mobile/Desktop**: SwiftUI (macOS/iOS), Kotlin (Android)

## Project Structure

```
src/                   # Core source code
  cli/                 # CLI wiring, option parsers, program entry
  commands/            # CLI command implementations (agent, onboard, doctor, etc.)
  gateway/             # Gateway server (WebSocket/HTTP control plane)
  channels/            # Channel registry, dock, session, plugin types
  routing/             # Message routing, bindings, session keys
  plugins/             # Plugin loader, registry, hooks, services
  plugin-sdk/          # Public SDK exported as `openclaw/plugin-sdk`
  infra/               # Infrastructure utilities (ports, env, errors, exec, etc.)
  providers/           # Model/LLM provider integrations
  agents/              # Agent runtime, skills, subagent registry
  config/              # Config loading, sessions, types
  terminal/            # Table rendering, themes, palette
  media/               # Media pipeline (images, audio, video)
  web/                 # WhatsApp Web integration
  telegram/            # Telegram channel
  discord/             # Discord channel
  slack/               # Slack channel
  signal/              # Signal channel
  imessage/            # iMessage channel
  tts/                 # Text-to-speech
  tui/                 # Terminal UI
extensions/            # Plugin/extension packages (workspace packages)
apps/                  # Native apps
  macos/               # macOS SwiftUI app
  ios/                 # iOS SwiftUI app
  android/             # Android Kotlin app
  shared/              # Shared Swift code (OpenClawKit)
ui/                    # Control UI (Lit web components)
docs/                  # Mintlify documentation
scripts/               # Build, release, CI helper scripts
test/                  # E2E and integration test fixtures
```

## Anti-Redundancy Rules

- **Never re-export**. Import directly from the original source module.
- **Never duplicate**. Before creating any formatter, utility, or helper, search for existing implementations first.
- If a function already exists, import it — do NOT create a duplicate in another file.

## Source of Truth Locations

### Formatting Utilities (`src/infra/`)

- **Time formatting**: `src/infra/format-time/`

**NEVER create local `formatAge`, `formatDuration`, `formatElapsedTime` functions — import from centralized modules.**

### Terminal Output (`src/terminal/`)

- Tables: `src/terminal/table.ts` (`renderTable`)
- Themes/colors: `src/terminal/theme.ts` (`theme.success`, `theme.muted`, etc.)
- Palette: `src/terminal/palette.ts` (shared CLI color palette)
- Progress: `src/cli/progress.ts` (`osc-progress` + `@clack/prompts` spinner)

### CLI Patterns

- CLI option wiring: `src/cli/`
- Commands: `src/commands/`
- Dependency injection via `createDefaultDeps` (`src/cli/deps.ts`)
- CLI entry: `src/index.ts` → `src/cli/program.ts` (`buildProgram()`)

### Gateway

- Gateway server: `src/gateway/server.impl.ts` (`startGatewayServer()`)
- Channel lifecycle: `src/gateway/server-channels.ts` (`createChannelManager()`)
- Routing & bindings: `src/routing/resolve-route.ts`, `src/routing/bindings.ts`

### Channels & Plugins

- Channel registry: `src/channels/registry.ts` (core channel IDs + metadata)
- Channel dock: `src/channels/dock.ts` (per-channel capabilities/adapters)
- Channel plugin types: `src/channels/plugins/types.ts`
- Plugin SDK: `src/plugin-sdk/index.ts` (public API exported as `openclaw/plugin-sdk`)
- Plugin loader: `src/plugins/loader.ts`
- Plugin hooks: `src/plugins/hooks.ts`

### Config

- Config loading: `src/config/config.ts` (`loadConfig()`)
- Session store: `src/config/sessions.ts`

## Import Conventions

- Use `.js` extension for cross-package imports (ESM requirement)
- Direct imports only — no re-export wrapper files
- Types: `import type { X }` for type-only imports
- Plugin-SDK path alias: `openclaw/plugin-sdk` → `src/plugin-sdk/index.ts`

## Code Quality

- TypeScript (ESM), strict typing, avoid `any`
- Never add `@ts-nocheck`; do not disable `no-explicit-any`
- Never share class behavior via prototype mutation — use explicit inheritance/composition
- Keep files under ~500–700 LOC; extract helpers when larger
- Add brief comments for tricky or non-obvious logic
- Colocated tests: `*.test.ts` next to source files; E2E in `*.e2e.test.ts`

## Naming Conventions

- **OpenClaw**: use for product/app/docs headings
- **openclaw**: use for CLI command, package/binary, paths, config keys
- Channels: always consider **all** built-in + extension channels when refactoring shared logic

## Commands

| Task | Command |
|------|---------|
| Install deps | `pnpm install` |
| Dev CLI | `pnpm openclaw ...` or `pnpm dev` |
| Type-check | `pnpm tsgo` |
| Build | `pnpm build` |
| Lint + format | `pnpm check` |
| Format fix | `pnpm format:fix` |
| Tests | `pnpm test` |
| Coverage | `pnpm test:coverage` |
| E2E tests | `pnpm test:e2e` |

## Extensions / Plugins

- Extensions live under `extensions/*` as workspace packages
- Keep plugin-only deps in the extension's own `package.json`
- Runtime deps go in `dependencies`; avoid `workspace:*` in deps
- Put `openclaw` in `devDependencies` or `peerDependencies` (runtime resolves via jiti alias)
- Plugin install runs `npm install --omit=dev` in plugin dir

## Gateway Architecture

The Gateway is a WebSocket/HTTP server that:
1. Manages channel lifecycle (start/stop/restart with backoff)
2. Routes inbound messages to the correct agent via bindings
3. Hosts the Control UI (Lit web app)
4. Exposes plugin services, exec approval, heartbeat, cron
5. Supports Tailscale exposure, TLS, mDNS discovery

## Security Notes

- Read `SECURITY.md` before triage/severity decisions
- Secure defaults without killing capability
- Exec approvals: `src/infra/exec-approvals.ts`, safe-bin policies
- Host env security: `src/infra/host-env-security.ts`
- Never commit real phone numbers, credentials, or live config values

## Docs (Mintlify)

- Internal doc links: root-relative, no `.md`/`.mdx` extension (e.g. `[Config](/configuration)`)
- Anchors: `[Hooks](/configuration#hooks)`
- Avoid em dashes and apostrophes in headings (breaks Mintlify anchors)
- `docs/zh-CN/**` is generated — do not edit unless explicitly asked

## Commit & PR Guidelines

- Create commits with `scripts/committer "<msg>" <file...>` (scoped staging)
- Concise, action-oriented messages (e.g. `CLI: add verbose flag to send`)
- One PR = one issue/topic; keep PRs focused
- Run `pnpm build && pnpm check && pnpm test` before pushing

If you are coding together with a human, do NOT use `scripts/committer`, but `git` directly and run the above commands manually to ensure quality.

## Control UI (Lit)

- Uses **legacy decorators** (`experimentalDecorators: true`, `useDefineForClassFields: false`)
- Use `@state()` and `@property()` — not standard `accessor` fields
- Signals via `signal-utils` + `@lit-labs/signals`

## Tool Schema Guardrails

- Avoid `Type.Union` in tool input schemas (no `anyOf`/`oneOf`/`allOf`)
- Use `stringEnum`/`optionalStringEnum` for string lists
- Use `Type.Optional(...)` instead of `... | null`
- Avoid raw `format` property name in tool schemas (reserved keyword)
