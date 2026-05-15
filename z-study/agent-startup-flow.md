# OpenClaw Agent 启动流程分析

## 工作区 Bootstrap 文件一览

OpenClaw agent 在会话启动时会从工作区目录中读取以下 Markdown 文件，按固定顺序加载并注入到 LLM 的 system prompt 中。

定义位置：`src/agents/workspace.ts` L26-L36

| 文件名 | 常量名 | 作用 | 会话类型 |
|--------|--------|------|----------|
| `AGENTS.md` | `DEFAULT_AGENTS_FILENAME` | **Agent 核心指令**。定义工作流规则、行为约束、会话启动序列、红线规则等。是最重要的配置文件，compaction 后还会提取 `## Session Startup` 和 `## Red Lines` 重新注入 | 所有会话 |
| `SOUL.md` | `DEFAULT_SOUL_FILENAME` | **人格与语气**。定义 agent 的性格、说话风格、语调。system prompt 中会额外注入指令："If SOUL.md is present, embody its persona and tone" | 所有会话 |
| `TOOLS.md` | `DEFAULT_TOOLS_FILENAME` | **工具参考笔记**。存储本地工具相关信息（SSH 详情、摄像头名称、语音偏好等），供 agent 在使用工具时参考 | 所有会话 |
| `IDENTITY.md` | `DEFAULT_IDENTITY_FILENAME` | **Agent 身份标识**。定义 agent 是"谁"，区别于 SOUL.md 的语气层面，更偏向身份与角色定义 | 所有会话 |
| `USER.md` | `DEFAULT_USER_FILENAME` | **用户档案**。描述 agent 要服务的人类用户的信息，帮助 agent 了解用户背景和偏好 | 所有会话 |
| `HEARTBEAT.md` | `DEFAULT_HEARTBEAT_FILENAME` | **心跳轮询指引**。当 agent 收到心跳消息时读取此文件，决定是否需要主动执行任务（如检查邮件、日历等） | 仅主会话 |
| `BOOTSTRAP.md` | `DEFAULT_BOOTSTRAP_FILENAME` | **首次运行引导**。agent 的"出生证明"，按其指引完成初始化后应删除 | 仅主会话 |
| `MEMORY.md` | `DEFAULT_MEMORY_FILENAME` | **长期记忆**。agent 精心整理的持久记忆（决策、上下文、教训等），出于安全考虑仅在主会话中加载，不暴露给群聊/子 agent | 仅主会话 |

> **会话类型说明**：
> - **所有会话**：主会话、子 agent 会话、定时任务会话都会加载
> - **仅主会话**：子 agent (`isSubagentSessionKey()`) 和 Cron (`isCronSessionKey()`) 会话中被过滤掉

---

## 完整启动流程

```
用户消息到达 (Telegram / Discord / Web / WhatsApp …)
        │
        ▼
┌─────────────────────────────────────────────────┐
│  runPreparedReply()                             │
│  入口：auto-reply/reply/get-reply-run.ts        │
└────────────────────┬────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────┐
│  runEmbeddedAttempt()                           │
│  位置：pi-embedded-runner/run/attempt.ts         │
│                                                  │
│  这是核心调度函数，按顺序执行以下 4 步：           │
└────────────────────┬────────────────────────────┘
                     │
    ─────────────────┼─────────────────
    步骤 ①           │
                     ▼
┌─────────────────────────────────────────────────────┐
│  resolveBootstrapContextForRun()                    │
│  位置：src/agents/bootstrap-files.ts L63-L81        │
│                                                      │
│  ┌───────────────────────────────────────────────┐  │
│  │ (a) loadWorkspaceBootstrapFiles(dir)          │  │
│  │     位置：workspace.ts L525-L568               │  │
│  │                                                │  │
│  │     按固定顺序从磁盘读取 8 个 .md 文件：        │  │
│  │     AGENTS → SOUL → TOOLS → IDENTITY → USER   │  │
│  │     → HEARTBEAT → BOOTSTRAP → MEMORY           │  │
│  │                                                │  │
│  │     每个文件经过安全防护：                       │  │
│  │     · openBoundaryFile() 路径边界检查           │  │
│  │     · 2MB 单文件大小上限                        │  │
│  │     · inode 指纹（dev:ino:size:mtime）缓存    │  │
│  └───────────────────────────────────────────────┘  │
│                         │                            │
│                         ▼                            │
│  ┌───────────────────────────────────────────────┐  │
│  │ (b) filterBootstrapFilesForSession()          │  │
│  │     位置：workspace.ts L582-L591               │  │
│  │                                                │  │
│  │     主会话   → 全部 8 个文件保留                 │  │
│  │     子agent  → 仅 AGENTS/SOUL/TOOLS/           │  │
│  │                IDENTITY/USER (排除 3 个)        │  │
│  │     定时任务 → 同子 agent                       │  │
│  └───────────────────────────────────────────────┘  │
│                         │                            │
│                         ▼                            │
│  ┌───────────────────────────────────────────────┐  │
│  │ (c) applyBootstrapHookOverrides()             │  │
│  │     位置：bootstrap-hooks.ts L7-L30            │  │
│  │                                                │  │
│  │     触发 agent.bootstrap 钩子，                 │  │
│  │     插件可以增删改 bootstrap 文件列表            │  │
│  └───────────────────────────────────────────────┘  │
│                         │                            │
│                         ▼                            │
│  ┌───────────────────────────────────────────────┐  │
│  │ (d) buildBootstrapContextFiles()              │  │
│  │     位置：pi-embedded-helpers/bootstrap.ts     │  │
│  │           L187-L246                            │  │
│  │                                                │  │
│  │     · 每文件限 20,000 字符                      │  │
│  │       超出时按 70%头 + 20%尾 截断               │  │
│  │     · 总预算 150,000 字符                       │  │
│  │     · 缺失文件标记 "[MISSING]"                  │  │
│  │     → 输出 EmbeddedContextFile[]               │  │
│  └───────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────┘
                     │
    ─────────────────┼─────────────────
    步骤 ②           │
                     ▼
┌─────────────────────────────────────────────────────┐
│  buildEmbeddedSystemPrompt()                        │
│  位置：pi-embedded-runner/system-prompt.ts L11-L72   │
│                                                      │
│  └─ buildAgentSystemPrompt({contextFiles, ...})     │
│     位置：src/agents/system-prompt.ts L189-L756      │
│                                                      │
│     组装完整 system prompt，主要区块：                 │
│     ┌────────────────────────────────────────┐       │
│     │ 1. Identity Line (你是谁)               │       │
│     │ 2. ## Tooling (可用工具)                │       │
│     │ 3. ## Safety (安全规则)                 │       │
│     │ 4. ## Skills (技能提示)                 │       │
│     │ 5. ## Memory Recall (记忆召回)          │       │
│     │ 6. ## Authorized Senders               │       │
│     │ 7. ## Current Date & Time              │       │
│     │ 8. ## Workspace (工作区路径)            │       │
│     │ 9. ## Reactions / Reply Tags           │       │
│     │ 10. ## Runtime (agent/host/model 信息) │       │
│     │                                        │       │
│     │ 11. # Project Context  ← 核心注入点    │       │
│     │     ## AGENTS.md                       │       │
│     │     <文件内容>                          │       │
│     │     ## SOUL.md                         │       │
│     │     <文件内容> + 人格指令               │       │
│     │     ## USER.md                         │       │
│     │     <文件内容>                          │       │
│     │     ...                                │       │
│     └────────────────────────────────────────┘       │
└────────────────────┬────────────────────────────────┘
                     │
    ─────────────────┼─────────────────
    步骤 ③           │
                     ▼
┌─────────────────────────────────────────────────────┐
│  createAgentSession()                               │
│  位置：pi-embedded-runner/run/attempt.ts L630-L645   │
│                                                      │
│  创建 Pi SDK 的 agent 会话实例                        │
│  （此时 system prompt 尚未设置）                      │
└────────────────────┬────────────────────────────────┘
                     │
    ─────────────────┼─────────────────
    步骤 ④           │
                     ▼
┌─────────────────────────────────────────────────────┐
│  applySystemPromptOverrideToSession()               │
│  位置：pi-embedded-runner/system-prompt.ts L74-L88   │
│                                                      │
│  session.agent.setSystemPrompt(prompt)              │
│  → bootstrap 文件正式注入 LLM 上下文                 │
│  → 同时存储 _baseSystemPrompt 供 compaction 重用    │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│  subscribeEmbeddedPiSession()                       │
│  → Agent 开始响应用户消息                            │
│    所有 bootstrap 文件内容已作为上下文生效             │
└─────────────────────────────────────────────────────┘
```

---

## 关键机制详解

### 1. 文件读取安全防护

位置：`src/agents/workspace.ts` L56-L87

```
readWorkspaceFileWithGuards()
    │
    ├─ openBoundaryFile()      防止路径穿越，文件必须在工作区根目录内
    ├─ stat 指纹校验            用 dev:ino:size:mtime 防止 TOCTOU 竞态攻击
    ├─ 2MB 磁盘读取上限         MAX_WORKSPACE_BOOTSTRAP_FILE_BYTES
    └─ 内存缓存                 相同 inode 指纹命中缓存则跳过重读
```

### 2. 会话级缓存

位置：`src/agents/bootstrap-cache.ts` L5-L17

- 按 `sessionKey` 缓存在内存 `Map` 中
- **一次会话只读一次**，后续不做动态重新加载
- 工作区 .md 文件改动需要**新会话**才能生效

### 3. SOUL.md 特殊处理

位置：`src/agents/system-prompt.ts` L723-L728

当检测到 SOUL.md 存在时，在 `# Project Context` 段落中额外注入：

> "If SOUL.md is present, embody its persona and tone. Avoid stiff, generic replies; follow its guidance unless higher-priority instructions override it."

### 4. 会话类型过滤逻辑

位置：`src/agents/workspace.ts` L582-L591

```
MINIMAL_BOOTSTRAP_ALLOWLIST = {
    AGENTS.md,       ✅ 所有会话
    SOUL.md,         ✅ 所有会话
    TOOLS.md,        ✅ 所有会话
    IDENTITY.md,     ✅ 所有会话
    USER.md,         ✅ 所有会话
}

主会话     → 全部文件
子agent    → 仅 MINIMAL_BOOTSTRAP_ALLOWLIST（排除 HEARTBEAT/BOOTSTRAP/MEMORY）
Cron 定时  → 同子 agent
```

### 5. 内容截断策略

位置：`src/agents/pi-embedded-helpers/bootstrap.ts` L127-L166

| 维度 | 限制 | 说明 |
|------|------|------|
| 单文件上限 | 20,000 字符 | `bootstrapMaxChars`，可配置 |
| 总上限 | 150,000 字符 | `bootstrapTotalMaxChars`，可配置 |
| 截断方式 | 70% 头部 + 20% 尾部 | 中间 10% 丢弃，插入 `[...truncated...]` 标记 |
| 预算耗尽 | 停止添加后续文件 | 按固定顺序，靠前的文件优先获得预算 |

配置路径：`config.agents.defaults.bootstrapMaxChars` / `bootstrapTotalMaxChars`

### 6. Post-Compaction 上下文刷新

位置：`src/auto-reply/reply/post-compaction-context.ts`

当会话历史被压缩（compaction）后，AGENTS.md 中的 `## Session Startup` 和 `## Red Lines` 两个章节会被重新提取并注入，确保关键规则不会因为上下文压缩而丢失。

---

## 关键源文件索引

| 文件 | 作用 |
|------|------|
| `src/agents/workspace.ts` | 定义 bootstrap 文件常量、加载函数、安全防护、会话过滤 |
| `src/agents/bootstrap-files.ts` | 完整的 bootstrap 解析流水线入口 (`resolveBootstrapContextForRun`) |
| `src/agents/bootstrap-cache.ts` | 按 sessionKey 的内存缓存 |
| `src/agents/bootstrap-hooks.ts` | 插件钩子，允许插件修改 bootstrap 文件列表 |
| `src/agents/pi-embedded-helpers/bootstrap.ts` | 截断 & 打包为 `EmbeddedContextFile[]` |
| `src/agents/system-prompt.ts` | 组装完整 system prompt，注入 `# Project Context` |
| `src/agents/pi-embedded-runner/system-prompt.ts` | 嵌入式 agent 的 prompt 构建包装 |
| `src/agents/pi-embedded-runner/run/attempt.ts` | Agent 会话创建主流程（步骤 ①~④ 的调度） |
| `src/auto-reply/reply/post-compaction-context.ts` | Compaction 后重注入 AGENTS.md 关键章节 |
| `src/routing/session-key.ts` | 会话类型判断 (`isSubagentSessionKey`, `isCronSessionKey`) |

---

## 一句话总结

OpenClaw agent **不是在运行时动态读取** .md 文件 —— 而是在**每次会话启动时**，将工作区的 AGENTS.md、SOUL.md 等文件内容经过安全检查、过滤、截断后，**拼接到 LLM 的 system prompt 中**。从此这些内容成为 LLM 上下文的一部分，agent 的"人格"、"规则"、"记忆"全靠这些注入的 markdown 内容驱动。
