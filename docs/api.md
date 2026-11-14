# API

daemon 默认监听 `127.0.0.1:4317`，只绑本机并校验 Host / Origin。

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
| GET | `/api/agents/:id/sessions/:sid/state` | 只读预览会话历史，不切换 runtime |
| POST | `/api/agents/:id/sessions/:sid/activate` | 切到某个历史会话（仅在要发消息时调用） |
| DELETE | `/api/agents/:id/sessions/:sid` | 删除会话（删当前会话会自动新建一个空的） |
| POST | `/api/agents/:id/chat` | 发消息（202 接受，事件走 SSE） |
| GET | `/api/agents/:id/events?session=` | SSE 事件流，按期望会话过滤（每个事件带 `sessionId`） |
| POST | `/api/agents/:id/action` | `abort` / `new` / `reload` |
