# 架构与隔离

## 界面结构

```
启动页 /            选 Agent（卡片网格 + 新建）；右上角 LIBRARY 进统一资源库
  ├─ /library       跨 Agent 的能力总账：同一份资源装给了谁、谁停着、谁没有
  ↓ 点某个 Agent
工作区 /a/:id
├─ 顶栏    Agent 下拉菜单（切 Agent / 新建 Agent / 返回启动页）
│          + 小菜单：对话 · 模型 · 配置 · 资源库（单个 Agent）
├─ 左侧    会话列表：新建、预览、删除；当前查看的高亮，发消息才切换
└─ 右侧    对应功能区
```

进工作区默认**查看最近一次会话**（只读预览），不会立刻恢复运行中的 runtime；
没有历史就显示空会话。点开某条会话只是看历史，**发出新消息时**才真正切到该会话并创建 runtime。
删除会话时条目先淡化转圈，再淡出、左移、收起高度（280ms），动画走完才刷新列表。
会话存在该 Agent 的 `sessions/` 下，是 Agent 私有的 —— 所以换 Agent 等于换整套会话。

## 一个 Agent 长什么样

```
~/.pi-manager/agents/<id>/
├─ auth.json              独立凭据（不展示在界面里）
├─ models.json            独立模型目录
├─ settings.json          压缩、重试等行为
├─ AGENTS.md              系统提示词 / 长期人格
├─ skills/                启用的技能（含 SKILL.md 的目录）
├─ skills.disabled/       禁用的技能
├─ extensions/            扩展（.ts / .js）
├─ extensions.disabled/
├─ prompts/               提示词模板（.md）
├─ prompts.disabled/
├─ sessions/              会话历史（JSONL）
└─ workspace/             未指定工作目录时的默认落点
```

注册表在 `~/.pi-manager/registry.json`，可用 `PI_MANAGER_HOME` 换位置。

## 隔离是怎么做到的

pi 的 `DefaultResourceLoader` 默认会去扫 `~/.pi/agent/skills`、`~/.agents/skills`、项目 `.pi/` 等一堆位置。
放着不管，所有 Agent 会看到同一批资源，隔离就是空话。

`daemon/src/runtime.ts` 里把默认发现全部关掉，只挂当前目录：

```ts
noSkills: true,            additionalSkillPaths: [configDir/skills]
noExtensions: true,        additionalExtensionPaths: [configDir/extensions]
noPromptTemplates: true,   additionalPromptTemplatePaths: [configDir/prompts]
noThemes: true,
```

`noContextFiles` 特意没关 —— 让 `agentDir/AGENTS.md` 作为该 Agent 的人格生效。

**启停技能用移动文件实现**：`skills/foo` ↔ `skills.disabled/foo`。
好处是外部工具（pi CLI、手改目录）看到的世界和管理器完全一致，没有第二份"启用状态"数据要对账。

## 资源库

分两层：**启动页 → LIBRARY** 是跨 Agent 的统一视图；**工作区 → 04 资源库** 是单个 Agent 的明细。

统一视图一行一个能力，右侧每个 Agent 一个状态块，点一下就在三种状态间走：
已启用 → 停用；已停用 → 启用；未安装 → 从别的 Agent 复制一份（`POST /api/library/copy`，只复制不动源）。

「单个 Agent 的资源库」是这个 Agent 的能力总账：技能、扩展、提示词模板放在同一个列表里，按类型分组，
顶上是四项读数（总数 / 已启用 / 磁盘占用 / 告警数）。

- **磁盘与生效分开看**：`loaded` 来自运行中会话的资源加载器。已启用但 `SKILL.md` 缺
  description 的技能会被 pi 静默跳过，界面标黄色「未加载」，而不是假装成功。
- **告警是 pi 真的会报的错**：name 不合规、description 缺失或超长。这些都在 `issues` 里，
  不用等运行时报错才发现。
- **右侧检视**：SKILL.md 全文、文件结构、相对/绝对路径、frontmatter、扩展注册的
  `registerTool` / `registerCommand`。窄窗口下同一套内容改用弹窗。
- **导入与新建**：从本机路径复制目录或单文件进 `skills/`（或禁用目录），冲突默认拒绝，
  勾选覆盖才替换；新建技能直接生成合规的 SKILL.md 骨架。
- **启停仍靠移动文件**，只是这次扩展也能点了 —— 旧实现用去掉扩展名的 name 去 rename，
  `.ts` 文件永远找不到，等于扩展开关是坏的。

## 进程模型

所有 Agent 跑在同一个 daemon 进程里，靠 `agentDir` 隔离（详见[已知限制](limitations.md)）。
`createAgentRuntime` 按 cwd 复用重资源（模型凭据 / settings / skills / extensions），
切会话只重建 `AgentSession`；`GET /sessions` 按目录签名缓存，目录没变不重复读 JSONL；
只读预览按文件大小 + mtime 缓存最近 24 份历史。
