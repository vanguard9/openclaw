# Cursor Memory Template

一套基于 OpenClaw 记忆系统设计的 Cursor 项目级持久化记忆模板。

## 使用方法

1. 将整个文件夹内容复制到你的项目根目录：

```bash
cp -r cursor-memory-template/{.cursorrules,MEMORY.md,memory} /path/to/your/project/
```

2. 正常使用 Cursor 对话即可，AI 会自动：
   - **读取**记忆文件来恢复上下文
   - **写入**重要决策、Bug、偏好等到对应文件

## 文件结构

```
your-project/
├── .cursorrules           # 系统提示词（记忆规则 + 编码规范）
├── MEMORY.md              # 项目核心知识（架构、约定、发现）
├── memory/
│   ├── decisions.md       # 架构/技术决策 + 理由
│   ├── tasks.md           # 任务追踪
│   ├── bugs.md            # Bug 调查记录
│   ├── preferences.md     # 用户编码偏好
│   └── sessions.md        # 对话摘要（手动触发）
```

## .gitignore 建议

```gitignore
# 个人偏好不进版本控制
memory/preferences.md
memory/sessions.md
```

如果是个人项目，所有文件都可以提交到 git。

## 与 OpenClaw 的对应关系

| 本模板         | OpenClaw                           | 说明                   |
| -------------- | ---------------------------------- | ---------------------- |
| `.cursorrules` | System Prompt + Memory Recall 指令 | AI 行为规则            |
| `MEMORY.md`    | `MEMORY.md` (workspace)            | 核心知识库             |
| `memory/*.md`  | `memory/*.md` + SQLite 索引        | 分类记忆（无向量搜索） |
| AI 读取文件    | `memory_search` 工具               | 记忆召回               |
| AI 写入文件    | Agent 自动写入                     | 记忆持久化             |
