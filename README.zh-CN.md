# OpenClaw 项目学习指南（中文）

> 本文档用于帮助中文开发者理解 OpenClaw 项目的架构、代码组织和核心概念。

## 一、项目是什么？

**OpenClaw** 是一个运行在你自己设备上的**个人 AI 助手**。它不是一个云服务，而是你自己部署和控制的本地 AI。

核心理念：
- **本地优先**：Gateway（网关）运行在你自己的机器上
- **多渠道**：通过 WhatsApp、Telegram、Slack、Discord、Google Chat、Signal、iMessage、Microsoft Teams、IRC、WebChat 等渠道与你对话
- **隐私安全**：你的数据留在你的设备上
- **可扩展**：通过插件系统支持任意功能扩展

项目经历了多次更名：Warelay → Clawdbot → Moltbot → OpenClaw。

## 二、整体架构

```
消息渠道 (WhatsApp / Telegram / Slack / Discord / Signal / ... )
               │
               ▼
┌───────────────────────────────────────────┐
│              Gateway（网关）                │
│          WebSocket + HTTP 控制平面          │
│         ws://127.0.0.1:18789              │
│                                           │
│  ┌─────────┐ ┌──────────┐ ┌───────────┐  │
│  │ 渠道管理 │ │ 消息路由  │ │  插件系统  │  │
│  └─────────┘ └──────────┘ └───────────┘  │
│  ┌─────────┐ ┌──────────┐ ┌───────────┐  │
│  │ Agent   │ │  会话管理  │ │  工具系统  │  │
│  └─────────┘ └──────────┘ └───────────┘  │
└──────────────┬────────────────────────────┘
               │
    ┌──────────┼──────────────────┐
    │          │                  │
    ▼          ▼                  ▼
 CLI 命令行   Web 控制台      原生应用
(openclaw)   (Control UI)   (macOS/iOS/Android)
```

### 核心组件

| 组件 | 说明 |
|------|------|
| **Gateway** | 网关服务器，整个系统的控制平面。管理渠道、路由消息、托管 Web UI |
| **Agent** | AI 代理，通过 Pi agent runtime (RPC 模式) 运行，带有工具和技能 |
| **Channel** | 消息渠道，每个渠道（Telegram/Discord/...）是一个插件 |
| **Routing** | 路由系统，将入站消息分发到正确的 Agent |
| **Plugin** | 插件系统，通过 npm 包或本地扩展加载 |
| **Session** | 会话管理，支持主会话、群组隔离、会话持久化 |

## 三、技术栈

| 分类 | 技术 |
|------|------|
| 运行时 | Node.js 22+（Bun 也支持用于开发/脚本） |
| 语言 | TypeScript（ESM 模块，严格模式） |
| 包管理器 | pnpm（锁文件：`pnpm-lock.yaml`） |
| 构建工具 | tsdown（输出到 `dist/`） |
| 代码检查 | Oxlint（lint）+ Oxfmt（格式化） |
| 测试框架 | Vitest + V8 覆盖率（阈值 70%） |
| CLI 框架 | Commander + @clack/prompts |
| Web UI | Lit（Web Components，旧版装饰器） |
| macOS/iOS | SwiftUI（Observation 框架） |
| Android | Kotlin |
| 依赖注入 | `createDefaultDeps`（非框架，手动模式） |

## 四、目录结构详解

```
openclaw/
├── src/                        # 核心源代码（最重要的目录）
│   ├── index.ts                # 程序入口 → 加载 CLI 程序
│   ├── entry.ts                # 替代入口点
│   ├── runtime.ts              # 运行时环境类型定义
│   ├── globals.ts              # 全局变量（调试标志等）
│   │
│   ├── cli/                    # CLI 命令行层
│   │   ├── program.ts          #   buildProgram() - Commander 程序构建
│   │   ├── deps.ts             #   createDefaultDeps() - 依赖注入
│   │   ├── progress.ts         #   进度条/Spinner (osc-progress + clack)
│   │   ├── prompt.ts           #   用户交互提示
│   │   ├── *-cli.ts            #   各子命令的 CLI 选项绑定
│   │   └── run-main.ts         #   CLI 主运行入口
│   │
│   ├── commands/               # CLI 命令实现
│   │   ├── agent.ts            #   agent 命令（与 AI 对话）
│   │   ├── onboard.ts          #   onboard 引导安装向导
│   │   ├── doctor.ts           #   doctor 诊断工具
│   │   ├── channels.ts         #   channels 渠道管理
│   │   ├── sessions.ts         #   sessions 会话管理
│   │   ├── status.ts           #   status 状态查看
│   │   ├── message.ts          #   message 发送消息
│   │   └── ...                 #   更多子命令
│   │
│   ├── gateway/                # Gateway 网关服务器（核心!）
│   │   ├── server.impl.ts      #   startGatewayServer() - 网关主实现
│   │   ├── server-channels.ts  #   createChannelManager() - 渠道生命周期
│   │   ├── server-plugins.ts   #   loadGatewayPlugins() - 插件加载
│   │   ├── server-methods.ts   #   WebSocket RPC 方法处理
│   │   ├── server-ws-runtime.ts#   WebSocket 连接管理
│   │   ├── server-startup.ts   #   网关启动流程
│   │   ├── server-close.ts     #   网关关闭处理
│   │   ├── server-cron.ts      #   定时任务服务
│   │   ├── server-discovery*.ts#   mDNS/Bonjour 设备发现
│   │   ├── node-registry.ts    #   设备节点注册表
│   │   └── ...
│   │
│   ├── channels/               # 渠道抽象层
│   │   ├── registry.ts         #   CHAT_CHANNEL_ORDER - 核心渠道注册表
│   │   ├── dock.ts             #   ChannelDock - 每个渠道的能力/适配器
│   │   ├── session.ts          #   入站会话记录
│   │   └── plugins/            #   渠道插件类型定义
│   │       ├── types.ts        #     ChannelPlugin 接口
│   │       └── types.plugin.ts #     ChannelConfigSchema
│   │
│   ├── routing/                # 消息路由
│   │   ├── resolve-route.ts    #   resolveAgentRoute() - 路由解析
│   │   ├── bindings.ts         #   Agent 绑定配置
│   │   └── session-key.ts      #   会话键构建
│   │
│   ├── plugins/                # 插件系统
│   │   ├── loader.ts           #   插件加载器（从 npm 或本地加载）
│   │   ├── registry.ts         #   插件注册表
│   │   ├── hooks.ts            #   插件钩子系统
│   │   ├── services.ts         #   插件服务
│   │   ├── slots.ts            #   插件槽位（如 memory 只能有一个）
│   │   └── tools.ts            #   插件提供的工具
│   │
│   ├── plugin-sdk/             # 插件 SDK（公开 API）
│   │   ├── index.ts            #   导出暴露给插件开发者的所有类型和函数
│   │   └── runtime.ts          #   插件运行时辅助
│   │
│   ├── config/                 # 配置管理
│   │   ├── config.ts           #   loadConfig() - 加载 openclaw.json
│   │   ├── sessions.ts         #   会话存储
│   │   └── types.agents.ts     #   Agent 配置类型
│   │
│   ├── agents/                 # Agent 运行时
│   │   ├── agent-scope.ts      #   Agent 作用域解析
│   │   ├── subagent-registry.ts#   子 Agent 注册
│   │   └── skills/             #   技能管理
│   │
│   ├── infra/                  # 基础设施工具库（非常大）
│   │   ├── errors.ts           #   错误处理
│   │   ├── env.ts              #   环境变量
│   │   ├── ports.ts            #   端口管理
│   │   ├── fetch.ts            #   HTTP 请求
│   │   ├── exec-approvals.ts   #   命令执行审批
│   │   ├── host-env-security.ts#   主机环境安全策略
│   │   ├── format-time/        #   时间格式化（源头模块!）
│   │   ├── backoff.ts          #   退避重试策略
│   │   ├── restart.ts          #   进程重启
│   │   ├── tailscale.ts        #   Tailscale 集成
│   │   └── ...（200+ 文件）
│   │
│   ├── terminal/               # 终端输出
│   │   ├── table.ts            #   renderTable() - 表格渲染
│   │   ├── theme.ts            #   主题色定义
│   │   └── palette.ts          #   CLI 调色板
│   │
│   ├── providers/              # LLM 模型提供商
│   ├── media/                  # 媒体处理管道（图片/音频/视频）
│   ├── tts/                    # 文字转语音
│   ├── tui/                    # 终端 UI
│   ├── security/               # 安全策略
│   ├── secrets/                # 密钥管理
│   │
│   │                           # === 内置渠道实现 ===
│   ├── telegram/               # Telegram 渠道（grammY）
│   ├── discord/                # Discord 渠道（discord.js / Carbon）
│   ├── slack/                  # Slack 渠道（Bolt）
│   ├── signal/                 # Signal 渠道（signal-cli）
│   ├── imessage/               # iMessage 渠道（legacy）
│   ├── web/                    # WhatsApp Web (Baileys)
│   └── line/                   # LINE 渠道
│
├── extensions/                 # 扩展插件（pnpm workspace 包）
│   ├── bluebubbles/            #   BlueBubbles（推荐的 iMessage 集成）
│   ├── msteams/                #   Microsoft Teams
│   ├── matrix/                 #   Matrix
│   ├── discord/                #   Discord 扩展功能
│   ├── telegram/               #   Telegram 扩展功能
│   ├── slack/                  #   Slack 扩展功能
│   ├── signal/                 #   Signal 扩展功能
│   ├── whatsapp/               #   WhatsApp 扩展功能
│   ├── zalo/                   #   Zalo OA
│   ├── zalouser/               #   Zalo 个人
│   ├── voice-call/             #   语音通话
│   ├── talk-voice/             #   Talk Mode 语音
│   ├── memory-core/            #   核心记忆系统
│   ├── memory-lancedb/         #   LanceDB 记忆后端
│   ├── lobster/                #   Lobster UI 主题
│   ├── copilot-proxy/          #   GitHub Copilot 代理
│   ├── feishu/                 #   飞书
│   ├── googlechat/             #   Google Chat
│   ├── mattermost/             #   Mattermost
│   ├── nostr/                  #   Nostr 协议
│   ├── irc/                    #   IRC
│   ├── shared/                 #   共享工具库
│   ├── test-utils/             #   测试工具
│   └── ...
│
├── apps/                       # 原生应用
│   ├── macos/                  #   macOS 菜单栏应用（SwiftUI）
│   │   └── Sources/            #     Swift 源代码
│   ├── ios/                    #   iOS 应用（SwiftUI）
│   │   └── Sources/            #     Swift 源代码
│   ├── android/                #   Android 应用（Kotlin）
│   │   └── app/                #     Kotlin 源代码
│   └── shared/                 #   共享 Swift 库（OpenClawKit）
│       └── OpenClawKit/
│
├── ui/                         # Control UI（Lit Web Components）
│
├── docs/                       # 文档（Mintlify 托管）
│   ├── channels/               #   各渠道配置文档
│   ├── concepts/               #   核心概念文档
│   ├── gateway/                #   网关运维文档
│   ├── tools/                  #   工具/技能文档
│   ├── install/                #   安装指南
│   ├── platforms/              #   各平台指南
│   ├── zh-CN/                  #   中文翻译（自动生成，勿手动编辑）
│   └── ...
│
├── scripts/                    # 构建/发布/CI 脚本
├── test/                       # E2E 测试
├── patches/                    # pnpm 依赖补丁
├── packages/                   # 内部包
│   ├── clawdbot/               #   Clawdbot 兼容包
│   └── moltbot/                #   Moltbot 兼容包
│
├── package.json                # 项目配置 + 依赖
├── tsconfig.json               # TypeScript 配置
├── vitest.config.ts            # Vitest 测试配置
├── tsdown.config.ts            # 构建配置
├── AGENTS.md / CLAUDE.md       # AI 代理指导文件
├── VISION.md                   # 项目愿景
├── CONTRIBUTING.md             # 贡献指南
├── SECURITY.md                 # 安全策略
└── CHANGELOG.md                # 变更日志
```

## 五、核心流程解析

### 5.1 消息处理流程

```
1. 用户在 Telegram/WhatsApp/... 发送消息
       │
2. 对应渠道插件 (ChannelPlugin) 接收消息
       │
3. 路由解析 (resolveAgentRoute)
   └── 根据 bindings 配置匹配 Agent
   └── 构建 sessionKey（会话键）
       │
4. Agent 处理消息
   └── 加载会话上下文
   └── 调用 LLM (模型提供商)
   └── 执行工具调用 (如需要)
       │
5. 响应回传
   └── 通过渠道的 outbound adapter 发送回复
   └── 支持流式输出和分块发送
```

### 5.2 Gateway 启动流程

```typescript
// src/gateway/server.impl.ts
startGatewayServer(port=18789, opts)
  ├── 加载配置 (loadConfig)
  ├── 初始化认证限流 (createAuthRateLimiter)
  ├── 加载插件 (loadGatewayPlugins)
  ├── 创建渠道管理器 (createChannelManager)
  ├── 启动 WebSocket 服务
  ├── 启动渠道 (startChannels)
  ├── 启动定时任务 (buildGatewayCronService)
  ├── 启动设备发现 (startGatewayDiscovery)
  ├── 启动 Tailscale 暴露 (可选)
  └── 返回 GatewayServer 实例
```

### 5.3 CLI 命令流

```
openclaw <command>
    │
src/index.ts
    │  loadDotEnv() → normalizeEnv() → enableConsoleCapture()
    │  assertSupportedRuntime()
    │
src/cli/program.ts
    │  buildProgram() → 注册所有子命令
    │
src/commands/<command>.ts
    │  执行具体命令逻辑
    │
createDefaultDeps()
    └── 注入运行时依赖
```

## 六、关键设计概念

### 6.1 渠道（Channel）

每个消息平台是一个 **Channel 插件**，需要实现：

```typescript
interface ChannelPlugin {
  id: ChannelId;              // 渠道标识（如 "telegram"）
  meta: ChannelMeta;          // 元数据（标签、图标、文档路径）
  capabilities: ChannelCapabilities; // 能力声明
  messaging?: ChannelMessagingAdapter;   // 消息收发
  outbound?: ChannelOutboundAdapter;     // 出站消息
  config?: ChannelConfigAdapter;         // 配置管理
  setup?: ChannelSetupAdapter;           // 安装引导
  status?: ChannelStatusAdapter;         // 状态检查
  gateway?: ChannelGatewayAdapter;       // 网关生命周期钩子
  // ... 更多适配器
}
```

核心渠道在 `src/channels/registry.ts` 中注册，扩展渠道在 `extensions/` 下作为独立包。

### 6.2 路由和绑定（Routing & Bindings）

路由系统决定消息发往哪个 Agent：

```json5
// openclaw.json 中的 bindings 配置
{
  "bindings": [
    {
      "agentId": "work-agent",
      "match": {
        "channel": "slack",
        "accountId": "work-bot"
      }
    },
    {
      "agentId": "personal-agent",
      "match": {
        "channel": "telegram"
      }
    }
  ]
}
```

路由优先级：`peer` → `guild+roles` → `guild` → `team` → `account` → `channel` → `default`

### 6.3 插件系统

插件通过 npm 包分发，运行时通过 jiti 动态加载：

```
extensions/<plugin-name>/
├── package.json          # name, version, dependencies
├── src/
│   ├── index.ts          # 插件入口，导出 ChannelPlugin
│   └── ...               # 插件实现
└── *.test.ts             # 测试
```

关键规则：
- 运行时依赖放 `dependencies`（`npm install --omit=dev` 必须能工作）
- `openclaw` 放 `devDependencies` 或 `peerDependencies`
- **不要**在 `dependencies` 中使用 `workspace:*`

### 6.4 会话管理

```
会话键 (sessionKey) = agentId:channel:accountId:peer
                     ↓
main 会话：直接聊天，共享上下文
group 会话：按群组隔离
per-peer 会话：按对话人隔离
```

会话存储在 `~/.openclaw/sessions/` 下。

### 6.5 安全模型

- **主会话**：工具在主机上直接运行（完全信任）
- **非主会话**（群组/渠道）：可配置 Docker 沙箱隔离
- **DM 配对**：未知发送者需要通过配对码验证
- **执行审批**：危险命令需要审批（`exec-approvals`）
- **安全路径策略**：`safe-bin-policy` 限制可执行的命令

## 七、开发常用命令

```bash
# 安装依赖
pnpm install

# 开发模式运行 CLI
pnpm openclaw <command>
# 或者
pnpm dev

# TypeScript 类型检查
pnpm tsgo

# 构建
pnpm build

# 代码检查（lint + 格式化）
pnpm check

# 自动修复格式化
pnpm format:fix

# 运行测试
pnpm test

# 运行测试（带覆盖率）
pnpm test:coverage

# E2E 测试
pnpm test:e2e

# 构建 macOS 应用
bash scripts/package-mac-app.sh

# 构建 UI
pnpm ui:build

# 启动开发网关（自动重载）
pnpm gateway:watch
```

## 八、配置文件

主配置文件位于 `~/.openclaw/openclaw.json`：

```json5
{
  // 模型配置
  "agent": {
    "model": "anthropic/claude-opus-4-6"
  },

  // 渠道配置
  "channels": {
    "telegram": {
      "botToken": "123456:ABCDEF"
    },
    "discord": {
      "token": "your-discord-token"
    },
    "whatsapp": {
      "allowFrom": ["+1234567890"]
    }
  },

  // 网关配置
  "gateway": {
    "mode": "local",
    "bind": "loopback",     // loopback | lan | tailnet | auto
    "controlUi": { "enabled": true }
  },

  // Agent 绑定（路由规则）
  "bindings": [
    {
      "agentId": "default",
      "match": { "channel": "telegram" }
    }
  ],

  // 沙箱配置
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "non-main"  // 非主会话使用 Docker 沙箱
      }
    }
  }
}
```

## 九、主要依赖说明

| 依赖 | 用途 |
|------|------|
| `grammy` | Telegram Bot API |
| `@whiskeysockets/baileys` | WhatsApp Web 协议 |
| `@slack/bolt` | Slack Bot |
| `@buape/carbon` | Discord 集成（**禁止更新**） |
| `commander` | CLI 命令解析 |
| `@clack/prompts` | CLI 交互提示 |
| `express` | HTTP 服务器 |
| `ws` | WebSocket |
| `sharp` | 图片处理 |
| `playwright-core` | 浏览器控制 |
| `@sinclair/typebox` | JSON Schema 类型构建 |
| `zod` | 数据验证 |
| `yaml` / `json5` | 配置文件解析 |
| `chalk` | 终端颜色 |
| `undici` | HTTP 客户端 |
| `chokidar` | 文件监听 |
| `@mariozechner/pi-*` | Pi agent 运行时（AI 代理核心） |

## 十、代码风格要点

1. **TypeScript ESM**：所有导入使用 `.js` 扩展名
2. **严格类型**：避免 `any`，禁止 `@ts-nocheck`
3. **文件大小**：目标 500-700 行以内，超出则拆分
4. **测试共位**：`foo.ts` 的测试在 `foo.test.ts`
5. **禁止重复**：先搜索现有实现，再创建新的
6. **禁止原型链变异**：用继承/组合代替 `prototype` 修改
7. **命名规范**：
   - `OpenClaw` → 产品/文档标题
   - `openclaw` → CLI 命令/包名/路径/配置键
8. **导入类型**：`import type { X }` 用于纯类型导入
9. **注释**：仅在逻辑不明显时添加简短注释

## 十一、发布渠道

| 渠道 | 说明 | npm 标签 |
|------|------|---------|
| **stable** | 正式发布（`vYYYY.M.D`） | `latest` |
| **beta** | 预发布（`vYYYY.M.D-beta.N`） | `beta` |
| **dev** | `main` 分支最新代码 | `dev` |

## 十二、常见问题

### Q: 如何快速搭建开发环境？

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
pnpm install
pnpm ui:build
pnpm build
pnpm openclaw onboard   # 交互式引导
```

### Q: 如何调试 Gateway？

```bash
# 开发模式（自动重载）
pnpm gateway:watch

# 或者直接运行
pnpm openclaw gateway run --port 18789 --verbose
```

### Q: 如何开发新渠道插件？

1. 在 `extensions/` 下创建新目录
2. 初始化 `package.json`，将 `openclaw` 放入 `peerDependencies`
3. 实现 `ChannelPlugin` 接口
4. 在 `pnpm-workspace.yaml` 中注册
5. 更新 `.github/labeler.yml` 添加标签

### Q: 如何运行特定测试？

```bash
# 运行单个测试文件
pnpm exec vitest run src/routing/resolve-route.test.ts

# 运行匹配模式的测试
pnpm exec vitest run --filter "gateway"

# 监听模式
pnpm test:watch
```

### Q: 遇到配置问题怎么办？

```bash
openclaw doctor    # 诊断检查
openclaw status    # 查看状态
```

## 十三、学习建议

**如果你想了解系统是如何工作的**，建议按以下顺序阅读：

1. `src/index.ts` → `src/cli/program.ts` — 了解 CLI 入口
2. `src/gateway/server.impl.ts` — 了解 Gateway 启动流程
3. `src/channels/registry.ts` → `src/channels/dock.ts` — 了解渠道抽象
4. `src/routing/resolve-route.ts` — 了解消息路由
5. `src/plugins/loader.ts` → `src/plugin-sdk/index.ts` — 了解插件系统
6. `src/config/config.ts` — 了解配置加载
7. `extensions/telegram/` — 参考一个具体的渠道插件实现

**如果你想贡献代码**：
1. 阅读 `CONTRIBUTING.md`
2. 阅读 `VISION.md` 了解项目方向
3. 查看 GitHub Issues 中的 "good first issue"
4. 本地运行 `pnpm build && pnpm check && pnpm test` 确保通过

## 十四、相关链接

- 仓库：https://github.com/openclaw/openclaw
- 文档：https://docs.openclaw.ai
- Discord：https://discord.gg/clawd
- 技能市场：https://clawhub.ai
- 网站：https://openclaw.ai
