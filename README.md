# Pi Agent Manager

管理多个 pi Agent 的桌面应用。**每个 Agent 一套完全独立的配置目录与工作目录**，技能、扩展、提示词、
模型凭据、会话历史互不干扰——写代码的 Agent 装一堆代码审查技能，做 PPT 的 Agent 一个都不装，两边互不影响。

- 前端：Flutter 桌面（`lib/`）
- 后端：Bun + pi SDK（`daemon/`）
- 参考项目：已迁移到 `E:/fanx_reference_backup/pi_cloth/`（纯备份，不纳入 Git）

## 仓库结构

```
fanx/
├─ lib/          Flutter 前端：状态、主题、UI 组件、各功能页
├─ daemon/       Bun + pi SDK 后端：src/ 服务、scripts/ 校验脚本
├─ test/         Flutter widget 测试（注入假 daemon 的 MockClient）
├─ assets/       静态资源（字体目录预留）
├─ android/ ios/ web/ windows/   各平台壳工程
├─ pubspec.yaml  前端依赖
└─ README.md
```

参考项目 `pi_cloth/` 单独备份在 `E:/fanx_reference_backup/pi_cloth/`，该目录不初始化 Git；
需要对照时移回即可：`mv /e/fanx_reference_backup/pi_cloth /e/fanx/pi_cloth`。

## 启动

```bash
# 1. 后端（默认 127.0.0.1:4317）
cd daemon
bun install
bun run dev

# 2. 前端（另开一个终端）
flutter run -d windows
```

前端连不上后端时，界面会直接给出离线提示和重试按钮，不会白屏。

## 界面结构

```
启动页 /            选 Agent（卡片网格 + 新建）；右上角 LIBRARY 进统一资源库
  ├─ /library       跨 Agent 的能力总账：同一份资源装给了谁、谁停着、谁没有
  ↓ 点某个 Agent
工作区 /a/:id
├─ 顶栏    Agent 下拉菜单（切 Agent / 新建 Agent / 返回启动页）
│          + 小菜单：对话 · 模型 · 配置 · 资源库（单个 Agent）
├─ 左侧    会话列表：新建、切换、删除；当前会话高亮
└─ 右侧    对应功能区
```

进工作区默认恢复**最近一次会话**；没有历史就开一个空会话。会话存在该 Agent 的 `sessions/` 下，
是 Agent 私有的——所以换 Agent 等于换整套会话。

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

`noContextFiles` 特意没关——让 `agentDir/AGENTS.md` 作为该 Agent 的人格生效。

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
- **启停仍靠移动文件**，只是这次扩展也能点了——旧实现用去掉扩展名的 name 去 rename，
  `.ts` 文件永远找不到，等于扩展开关是坏的。

## 对话区

- **Markdown 渲染**：标题、段落、有序/无序/嵌套/任务列表、引用、分隔线、表格、
  图片、行内代码/粗体/斜体/删除线/链接；代码块带语言标签、复制按钮与轻量高亮
  （dart / ts / python / shell / sql / json / yaml）；数学公式 `$x^2$` / `$$E=mc^2$$`
  （轻量 LaTeX：希腊字母、上下标、分数、根号、运算符、\text{}），`$5` 这类价格不会误判。
- **流式输出**：provider 走 token 增量时按增量实时长出（`delta` 事件）；provider 不流式时，
  最终消息到达后按长度在 0.7–2.8s 内平滑展开，视觉上仍是打字机。
  两种模式都实时渲染完整 Markdown（标题、列表、代码块、公式），不是纯文本占位。
  注意：**本机模型请求必须绕过 HTTP_PROXY**，代理会拦掉或缓冲 localhost 的 SSE——
  `index.ts` 启动时把 127.0.0.1/localhost 写进 `NO_PROXY`，否则增量事件全丢。
- **失败即报错**：`stopReason: error` 的消息原样展示 `errorMessage` + 一句诊断 + 重试，
  不再出现"空回复"这种掩盖原因的文案。

## 模型接入

界面「模型」页可以直接接任何 OpenAI 兼容端点（本机路由、LM Studio、vLLM、各类网关）：

1. 填 `baseUrl`（`http://127.0.0.1:3425/v1`，不带 `/v1` 会自动补）、`apiKey`、`providerId`；
2. 点「探测模型」——读端点 `/v1/models`，把模型名、上下文、是否支持工具、是否支持推理一次列出来；
3. 勾选要保留的模型，指定默认模型，保存。

保存后写入该 Agent 自己的 `models.json`，同时在 `settings.json` 里写 `defaultProvider` / `defaultModel`。
**apiKey 是明文存在这个 Agent 的目录里的**，所以不同 Agent 可以用不同端点、不同凭据，互不影响。

探测时会把网关的 `pricing`（每 token 美元）换算成 pi 要的「每百万 token」，
`reasoning_levels` 换算成 `thinkingLevelMap`——网关不支持的推理档位会被隐藏，避免发出去被拒。

## API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查 |
| GET | `/api/agents` | Agent 列表（含资源计数） |
| GET | `/api/library` | 跨 Agent 能力总账：合并同名资源 + 每个 Agent 的启用/加载状态 |
| POST | `/api/library/copy` | 把某 Agent 的资源复制给另一个 Agent |
| POST | `/api/agents` | 新建（可指定 `id` / `configDir` / `cwd` / `cloneFrom`） |
| GET/PATCH/DELETE | `/api/agents/:id` | 详情 / 改名改目录 / 删除（`?deleteDir=true` 连带删目录） |
| GET/PUT | `/api/agents/:id/config` | 读写系统提示词与配置 |
| GET | `/api/agents/:id/resources` | 扫描技能 / 扩展 / 提示词（含体积、文件数、告警、是否加载） |
| GET | `/api/agents/:id/resources/item?type=&name=` | 单个资源全文、文件树、注册的工具与命令 |
| POST | `/api/agents/:id/resources/toggle` | 启用或禁用某个资源 |
| POST | `/api/agents/:id/resources/batch` | 批量启停（`type` / `names[]` / `enabled`） |
| POST | `/api/agents/:id/resources/import` | 从本机路径导入（目录→技能，单文件→扩展/模板） |
| POST | `/api/agents/:id/resources/create` | 新建技能骨架 |
| DELETE | `/api/agents/:id/resources/item?type=&name=` | 删除资源（磁盘级） |
| GET | `/api/agents/:id/models` | 已配置的端点、模型清单、当前生效模型 |
| POST | `/api/agents/:id/models/probe` | 探测端点模型，不落盘 |
| PUT | `/api/agents/:id/models` | 写入端点与模型，设定默认模型 |
| PUT | `/api/agents/:id/model` | 切换默认模型（运行中会同步切换） |
| GET | `/api/agents/:id/sessions` | 会话列表（含 `active` / `messageCount`） |
| POST | `/api/agents/:id/sessions` | 新建会话 |
| POST | `/api/agents/:id/sessions/:sid/activate` | 切到某个历史会话 |
| DELETE | `/api/agents/:id/sessions/:sid` | 删除会话（删当前会话会自动新建一个空的） |
| POST | `/api/agents/:id/chat` | 发消息（202 接受，事件走 SSE） |
| GET | `/api/agents/:id/events` | SSE 事件流 |
| POST | `/api/agents/:id/action` | `abort` / `new` / `reload` |

## 验证

```bash
cd daemon && bun run typecheck && bun run scripts/poc-isolation.ts   # 隔离性 6 项断言
flutter analyze && flutter test
```

`scripts/poc-isolation.ts` 会建两个 Agent、各放一个技能，断言彼此看不见对方的资源。

`test/library_test.dart` 用同一套假 daemon 覆盖资源库：读数、选中检视、启停落盘、
900/1024/1440 三种宽度不溢出、窄窗口改弹窗。

`test/workspace_test.dart` 用 `MockClient` 注入假数据渲染真实工作区，
验证会话栏读数正确、窄窗口不溢出——不依赖本机 daemon 是否在跑。
`DaemonClient` 因此开了一个可选的 `httpClient` 参数，仅供测试注入。

## 性能约定

对话区是全站唯一有高频更新的地方，改动时守住三条：

1. `delta` 与打字机进度只更新 `_live`（`ValueNotifier`），不调用父级 `setState`；
   列表作为 `child` 缓存，只有末尾两项订阅 `_live`，历史消息不随 token 重建。
2. 流式与打字机期间也渲染完整 Markdown，但必须带 `streaming: true`：
   `MarkdownStreamParser` 以「围栏外的最后一个空行」为界，只重解析最后一个
   未完成块，已封口的块缓存复用；正式消息走全量解析。代码高亮正则按语言只编译一次，
   已完成块的 `MarkdownText` / `_CodeBlock` 按正文与主题缓存 span，不随每次刷新重算。
3. 后端只推 `delta` 与精简 `state`：SDK 原始事件不透传，内容重复的 `state` 直接丢弃。

长回复（超过 800 字）的增量刷新、打字机每帧推进都合并到约 30fps，
流式正文用 `StringBuffer` 累积；`DaemonClient.events()` 用游标扫帧并跳过
`heartbeat` / `session_event`。

## 已知限制

1. **环境变量里的 API Key 对所有 Agent 共享**。pi 会读 `DEEPSEEK_API_KEY` 之类的环境变量，
   所以 `auth.json` 为空也能用。要给某个 Agent 独立凭据，写它自己的 `models.json`（界面「模型」页会做）。
2. **单进程多 runtime**。所有 Agent 跑在同一个 daemon 进程里，靠 `agentDir` 隔离。
   某个扩展崩溃可能波及整个 daemon，要进程级隔离得再拆 worker。
3. **没有认证**。服务只绑 `127.0.0.1` 并校验 Host / Origin，不适合暴露到网络。
4. **pi 调用失败不抛异常**：它照常结束这一轮，把原因写进 assistant 消息的
   `stopReason: "error"` 与 `errorMessage`（例如 `502 upstream connect failed (os error 10061)`）。
   后端现在原样透传这两项，界面把原始报错、provider/model、耗时摊在失败卡片里，并给一句
   可行动的诊断（端点拒绝连接 / 鉴权失败 / 超时 / 限流…），失败的那条消息可一键重试。
   只剩一种情况仍属推测：`stopReason` 正常但正文为空，界面会标明"模型返回了空内容"。

## 本机环境注意

系统设了 `HTTP_PROXY` / `HTTPS_PROXY` 时，`flutter test` 会报
`Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request`。
跑测试前清空代理变量：

```bash
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= flutter test
```

## 版本控制

本目录是 Git 仓库。`daemon/node_modules/`、`build/`、`.dart_tool/`、
`windows/flutter/ephemeral/` 等生成物，以及 `.devhome/`（本地 Agent 配置与 auth.json）、
`.workbuddy/`、`.preview/` 都由 `.gitignore` 排除，不入库。克隆后按上面的「启动」装依赖即可，
不需要提交任何本地凭据。参考项目的备份目录不初始化 Git。

提交前建议跑一遍：

```bash
cd daemon && bun run typecheck
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= flutter analyze && flutter test
```
