# 设计笔记

对话区是全站唯一有高频更新的地方，这份笔记记录它怎么渲染、怎么流、以及改之前必须知道的约定。

## 对话区

- **Markdown 渲染**：标题、段落、有序/无序/嵌套/任务列表、引用、分隔线、表格、
  图片、行内代码/粗体/斜体/删除线/链接；代码块带语言标签、复制按钮与轻量高亮
  （dart / ts / python / shell / sql / json / yaml）；数学公式 `$x^2$` / `$$E=mc^2$$`
  （轻量 LaTeX：希腊字母、上下标、分数、根号、运算符、`\text{}`），`$5` 这类价格不会误判。
- **流式输出**：provider 走 token 增量时按增量实时长出（`delta` 事件）；provider 不流式时，
  最终消息到达后按长度在 0.7–2.8s 内平滑展开，视觉上仍是打字机。
  两种模式都实时渲染完整 Markdown（标题、列表、代码块、公式），不是纯文本占位。
  注意：**本机模型请求必须绕过 HTTP_PROXY**，代理会拦掉或缓冲 localhost 的 SSE ——
  `index.ts` 启动时把 127.0.0.1/localhost 写进 `NO_PROXY`，否则增量事件全丢。
- **失败即报错**：`stopReason: error` 的消息原样展示 `errorMessage` + 一句诊断 + 重试，
  不再出现"空回复"这种掩盖原因的文案。
- **空会话是配置铭牌**（`chat_empty.dart`）：左窄右宽的清单列出当前模型、技能、扩展/插件、
  提示词模板的**具体名字**（带停用 / 未加载状态），底部给工作目录与总项数。没有示例提问卡片。
  模型读 `GET /models` + `GET /resources`，不读运行时 `state` —— 后端在没有 runtime 时
  （首次进入、只读预览）不返回 `model` 字段，旧界面据此写死「未选模型」是误判。
  模型行本身是切换入口（`PUT /model`），未配置时点它会跳到「模型」标签页。

## 模型接入

界面「模型」页可以直接接任何 OpenAI 兼容端点（本机路由、LM Studio、vLLM、各类网关）：

1. 填 `baseUrl`（`http://127.0.0.1:3425/v1`，不带 `/v1` 会自动补）、`apiKey`、`providerId`；
2. 点「探测模型」—— 读端点 `/v1/models`，把模型名、上下文、是否支持工具、是否支持推理一次列出来；
3. 勾选要保留的模型，指定默认模型，保存。

保存后写入该 Agent 自己的 `models.json`，同时在 `settings.json` 里写 `defaultProvider` / `defaultModel`。
**apiKey 是明文存在这个 Agent 的目录里的**，所以不同 Agent 可以用不同端点、不同凭据，互不影响。

探测时会把网关的 `pricing`（每 token 美元）换算成 pi 要的「每百万 token」，
`reasoning_levels` 换算成 `thinkingLevelMap` —— 网关不支持的推理档位会被隐藏，避免发出去被拒。

## 性能约定

改动对话区时守住这几条：

1. `delta` 与打字机进度只更新 `_live`（`ValueNotifier`），不调用父级 `setState`；
   列表作为 `child` 缓存，只有末尾两项订阅 `_live`，历史消息不随 token 重建。
2. 流式与打字机期间也渲染完整 Markdown，但必须带 `streaming: true`：
   `MarkdownStreamParser` 以「围栏外的最后一个空行」为界，只重解析最后一个
   未完成块，已封口的块缓存复用；正式消息走全量解析。代码高亮正则按语言只编译一次，
   已完成块的 `MarkdownText` / `_CodeBlock` 按正文与主题缓存 span，不随每次刷新重算。
3. 后端只推 `delta` 与精简 `state`：SDK 原始事件不透传，内容重复的 `state` 直接丢弃。
4. **「查看会话」与「激活会话」分开**：点侧栏只改 `_viewSessionId`，走
   `GET /sessions/:id/state` 只读历史（后端直接读 JSONL，不碰 runtime），命中前端
   缓存（最近 8 个）时零请求；只有发出新消息 / 重试才调 `activateSession`，
   此时后端才切会话。查看历史是默认行为，顶部不挂解释性提示条，
   侧栏只用「预览 ·」轻量区分查看态与激活态。
   SSE 订阅带 `?session=`，后端给每个事件附 `sessionId` 并按期望会话过滤，
   预览时不会串到别的会话；激活后同一条连接自然接上 delta，无需重建面板。
5. 后端 `createAgentRuntime` 按 cwd 复用重资源（模型凭据 / settings / skills / extensions），
   切会话只重建 `AgentSession`；`GET /sessions` 按目录签名缓存，目录没变不重复读 JSONL；
   只读预览按文件大小 + mtime 缓存最近 24 份历史。
6. `/a/:id` 只有一条路由，换 Agent 时 `WorkspacePage` 的 State 会被复用：
   `didUpdateWidget` 清空会话列表、状态缓存、查看/激活号并重新 bootstrap；
   所有异步回调带 `_agentEpoch`，上一个 Agent 的迟到响应直接丢弃。

长回复（超过 800 字）的增量刷新、打字机每帧推进都合并到约 30fps，
流式正文用 `StringBuffer` 累积；`DaemonClient.events()` 用游标扫帧并跳过
`heartbeat` / `session_event`。

## 验证

```bash
cd daemon && bun run typecheck && bun run scripts/poc-isolation.ts   # 隔离性 6 项断言
flutter analyze && flutter test
```

`scripts/poc-isolation.ts` 会建两个 Agent、各放一个技能，断言彼此看不见对方的资源。

`test/library_test.dart` 用同一套假 daemon 覆盖资源库：读数、选中检视、启停落盘、
900/1024/1440 三种宽度不溢出、窄窗口改弹窗。

`test/workspace_test.dart` 用 `MockClient` 注入假数据渲染真实工作区，
验证「点击查看不触发 activate、发消息才切换、激活失败保留输入」、
会话栏读数正确、窄窗口不溢出 —— 不依赖本机 daemon 是否在跑。
`DaemonClient` 因此开了一个可选的 `httpClient` 参数，仅供测试注入。

## 本机环境注意

系统设了 `HTTP_PROXY` / `HTTPS_PROXY` 时，`flutter test` 会报
`Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request`。
跑测试前清空代理变量：

```bash
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= flutter test
```
